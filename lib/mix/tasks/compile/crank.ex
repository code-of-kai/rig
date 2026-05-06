defmodule Mix.Tasks.Compile.Crank do
  @moduledoc """
  Mix compiler that runs Boundary's topology check and emits Crank-formatted
  diagnostics carrying `CRANK_DEP_*` codes.

  Activate by adding `:crank` to the project's `:compilers` list in
  `mix.exs`:

      def project do
        [
          # ...
          compilers: [:crank] ++ Mix.compilers()
        ]
      end

  This single entry runs the full Crank topology stack: CompilerState is
  started, Boundary's tracer is registered, and an `after_compiler(:app, _)`
  hook builds the dependency view, runs the cross-boundary check, and
  prints Crank-formatted diagnostics rather than Boundary's raw output.

  Adding `:boundary` separately to `compilers:` is **not** required and is
  in fact undesirable — running both would print every topology violation
  twice (once in Boundary's format, once in Crank's). `:crank` invokes
  Boundary's underlying machinery directly.

  See `Crank.BoundaryIntegration` for the translation logic and
  `plans/purity-enforcement.md` Phase 1.4 for the design rationale.
  """

  use Mix.Task.Compiler

  alias Boundary.Mix.{CompilerState, View}
  alias Mix.Task.Compiler, as: TaskCompiler
  alias Mix.Tasks.Compile.Boundary, as: BoundaryCompiler

  @recursive true

  @impl Mix.Task.Compiler
  def run(argv) do
    {opts, _rest, _errors} =
      OptionParser.parse(argv, strict: [force: :boolean, warnings_as_errors: :boolean])

    CompilerState.start_link(Keyword.take(opts, [:force]))
    TaskCompiler.after_compiler(:elixir, &after_elixir/1)
    TaskCompiler.after_compiler(:app, &after_app(&1, opts))

    tracers = Code.get_compiler_option(:tracers) || []
    Code.put_compiler_option(:tracers, [BoundaryCompiler | tracers])

    {:ok, []}
  end

  # ── after-compiler hooks ───────────────────────────────────────────────────

  # Mirror Boundary's behaviour: after the Elixir compiler runs, unload the
  # tracer so it doesn't fire on subsequent unrelated compiles in the same
  # session. The references captured during the elixir compile remain in
  # CompilerState's ETS tables — they're flushed and written to manifest in
  # `after_app/2`. Do NOT flush here; that wipes the references the
  # `:invalid_reference` checker needs.
  defp after_elixir(outcome) do
    tracers = Code.get_compiler_option(:tracers) || []
    cleaned = Enum.reject(tracers, &(&1 == BoundaryCompiler))
    Code.put_compiler_option(:tracers, cleaned)
    outcome
  end

  defp after_app({status, diagnostics}, opts) when status in [:ok, :noop] do
    Application.unload(Boundary.Mix.app_name())
    Application.load(Boundary.Mix.app_name())

    CompilerState.flush(Application.spec(Boundary.Mix.app_name(), :modules) || [])

    view = View.refresh(user_apps(), Keyword.take(opts, [:force]))

    references = CompilerState.references() |> Enum.to_list()
    boundary_errors = Boundary.errors(view, references)

    {dep_002_diagnostics, suppressed_unclassified} =
      detect_unmarked_helpers(boundary_errors, references)

    remaining_errors =
      Enum.reject(boundary_errors, fn
        {:unclassified_module, mod} -> mod in suppressed_unclassified
        _ -> false
      end)

    crank_diagnostics =
      (translate_errors(remaining_errors, view) ++ dep_002_diagnostics)
      |> Enum.sort_by(&{&1.file || "", &1.position || 0})

    print_diagnostics(crank_diagnostics)

    {final_status(crank_diagnostics, opts), diagnostics ++ crank_diagnostics}
  rescue
    e in Boundary.Error ->
      diag = boundary_setup_error(e)
      Mix.shell().info("")
      print_diagnostic(diag)
      {final_status([diag], opts), diagnostics ++ [diag]}
  end

  defp after_app(other, _opts), do: other

  # ── CRANK_DEP_002 — unmarked first-party helper called from a Crank domain ──

  # Walks the Boundary `:unclassified_module` errors against the references
  # graph. For each unclassified helper that a Crank-domain module calls,
  # emits a CRANK_DEP_002 diagnostic and consumes the underlying
  # `:unclassified_module` error so it isn't double-reported.
  defp detect_unmarked_helpers(boundary_errors, references) do
    unclassified =
      for {:unclassified_module, mod} <- boundary_errors,
          do: mod,
          into: MapSet.new()

    crank_domain_modules = compute_crank_domains(references)

    diagnostics =
      for ref <- references,
          MapSet.member?(unclassified, Map.get(ref, :to)),
          MapSet.member?(crank_domain_modules, Map.get(ref, :from)),
          do:
            ref
            |> Map.get(:to)
            |> Crank.BoundaryIntegration.translate_unclassified(ref)
            |> diagnostic_from_violation()

    suppressed =
      diagnostics
      |> Enum.map(fn diag -> diag.details.violating_call.module end)
      |> MapSet.new()

    {diagnostics, suppressed}
  end

  # The set of modules tagged with the `__crank_domain__` persisted
  # attribute (set by both `use Crank` and `use Crank.Domain.Pure`).
  # Read at this point because the `:from` modules in the references
  # graph are guaranteed loaded — they came from the just-completed
  # compile.
  defp compute_crank_domains(references) do
    references
    |> Enum.map(&Map.get(&1, :from))
    |> Enum.uniq()
    |> Enum.filter(&crank_domain_module?/1)
    |> MapSet.new()
  end

  defp crank_domain_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :__info__, 1) and
      module.__info__(:attributes)
      |> Keyword.get(:__crank_domain__, [])
      |> List.wrap()
      |> Enum.member?(true)
  rescue
    _ -> false
  end

  defp crank_domain_module?(_), do: false

  defp final_status([], _opts), do: :ok

  defp final_status([_ | _], opts) do
    if Keyword.get(opts, :warnings_as_errors, false), do: :error, else: :ok
  end

  # ── translation ────────────────────────────────────────────────────────────

  defp translate_errors(boundary_errors, view) do
    classification = third_party_classification_from_config()
    main_app = Mix.Project.config()[:app]

    boundary_errors
    |> Enum.map(&translate_error(&1, view, main_app, classification))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{&1.file || "", &1.position || 0})
  end

  defp translate_error({:invalid_reference, info}, view, main_app, classification) do
    target_app =
      case Map.fetch(info, :target_app) do
        {:ok, app} -> app
        :error -> Boundary.app(view, get_in(info, [:reference, :to]))
      end

    info_with_app = Map.put(info, :target_app, target_app)
    err = {:invalid_reference, info_with_app}

    case Crank.BoundaryIntegration.translate_error(err,
           main_app: main_app,
           third_party_classification: classification
         ) do
      %Crank.Errors.Violation{} = violation -> diagnostic_from_violation(violation)
      {:passthrough, _} -> nil
    end
  end

  defp translate_error(other, _view, _main_app, _classification) do
    # Boundary configuration errors (cycles, unknown deps, unclassified
    # modules etc.) aren't Crank topology violations; emit them under
    # Boundary's name with the original error text, preserving the
    # information for the developer.
    boundary_native_diagnostic(other)
  end

  defp diagnostic_from_violation(%Crank.Errors.Violation{} = violation) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "crank",
      severity: violation.severity,
      file: location_file(violation),
      position: location_position(violation),
      message: format_message(violation),
      details: violation
    }
  end

  defp location_file(%Crank.Errors.Violation{location: %{file: file}}) when is_binary(file) do
    Path.relative_to_cwd(file)
  end

  defp location_file(_), do: nil

  defp location_position(%Crank.Errors.Violation{location: %{line: line}}) when is_integer(line) do
    line
  end

  defp location_position(_), do: nil

  defp format_message(%Crank.Errors.Violation{} = violation) do
    short = violation.context || "topology violation"
    "[#{violation.code}] #{short}\n  Fix: #{violation.fix.category}\n  See: #{violation.fix.doc_url}"
  end

  defp boundary_native_diagnostic({:unclassified_module, module}) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "boundary",
      severity: :warning,
      file: nil,
      position: nil,
      message: "#{inspect(module)} is not included in any boundary",
      details: nil
    }
  end

  defp boundary_native_diagnostic({:cycle, modules}) do
    cycle = Enum.map_join(modules, " -> ", &inspect/1)

    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "boundary",
      severity: :warning,
      file: nil,
      position: nil,
      message: "dependency cycle found:\n#{cycle}",
      details: nil
    }
  end

  defp boundary_native_diagnostic({_kind, info}) when is_map(info) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "boundary",
      severity: :warning,
      file: Map.get(info, :file),
      position: Map.get(info, :line),
      message: inspect(info),
      details: nil
    }
  end

  defp boundary_native_diagnostic(other) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "boundary",
      severity: :warning,
      file: nil,
      position: nil,
      message: inspect(other),
      details: nil
    }
  end

  defp boundary_setup_error(%Boundary.Error{message: message, file: file, line: line}) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "boundary",
      severity: :warning,
      file: file && Path.relative_to_cwd(file),
      position: line,
      message: message,
      details: nil
    }
  end

  # ── output ─────────────────────────────────────────────────────────────────

  defp print_diagnostics([]), do: :ok

  defp print_diagnostics(diags) do
    Mix.shell().info("")
    Enum.each(diags, &print_diagnostic/1)
  end

  defp print_diagnostic(%Mix.Task.Compiler.Diagnostic{} = diag) do
    severity_part =
      case diag.severity do
        :error -> [:bright, :red, "error: ", :reset]
        :warning -> [:bright, :yellow, "warning: ", :reset]
        _ -> [:bright, :reset]
      end

    location_part =
      cond do
        diag.file && diag.position -> "\n  #{diag.file}:#{diag.position}\n"
        diag.file -> "\n  #{diag.file}\n"
        true -> "\n"
      end

    Mix.shell().info(severity_part ++ [diag.message, location_part])
  end

  # ── config ─────────────────────────────────────────────────────────────────

  defp third_party_classification_from_config do
    boundary_config = Mix.Project.config()[:boundary] || []

    %{
      pure: boundary_config[:third_party_pure] || [],
      impure: boundary_config[:third_party_impure] || []
    }
  end

  defp user_apps do
    deps = Mix.Project.config()[:deps] || []

    for {app, opts} when is_list(opts) <- deps,
        Enum.any?(opts, &(&1 == {:in_umbrella, true} or match?({:path, _}, &1))),
        into: MapSet.new([Boundary.Mix.app_name()]),
        do: app
  end
end
