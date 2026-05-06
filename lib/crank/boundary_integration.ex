defmodule Crank.BoundaryIntegration do
  @moduledoc """
  Translates `Boundary` diagnostics into `Crank.Errors.Violation` structs.

  Boundary's compiler (`Mix.Tasks.Compile.Boundary`) emits its findings as
  `Mix.Task.Compiler.Diagnostic` structs derived from internal error tuples
  with shapes like `{:invalid_reference, %{from_boundary, to_boundary,
  reference: %{from, to, file, line}}}`. Crank wraps Boundary in
  `Mix.Tasks.Compile.Crank` (the `:crank` Mix compiler), and after Boundary
  has produced its diagnostics this module rewrites each one into a
  `%Crank.Errors.Violation{}` carrying the appropriate `CRANK_DEP_*` code.

  Two entry points are provided:

    * `translate_diagnostic/1` — accepts a `Mix.Task.Compiler.Diagnostic`
      whose `compiler_name == "boundary"`, normalises it, and returns either
      a Crank-formatted diagnostic or the original diagnostic untouched (if
      it doesn't correspond to one of the topology codes Crank knows about).
    * `translate_error/2` — accepts the raw error tuple Boundary's
      `Boundary.errors/2` returns, plus an opts keyword list (notably
      `:third_party_classification`), and produces a `Crank.Errors.Violation`.

  ## Code mapping

    * `{:invalid_reference, %{type: :normal | :runtime, ...}}` where the
      target is in the same OTP application → `CRANK_DEP_001`
      (dependency-direction violation).
    * `{:invalid_reference, %{type: :normal | :runtime, ...}}` where the
      target is in a different OTP application that's classified as
      `:third_party_impure` → `CRANK_DEP_001`.
    * `{:invalid_reference, %{type: :invalid_external_dep_call, ...}}` → if
      the target's app is unclassified, `CRANK_DEP_003`; otherwise
      `CRANK_DEP_001`.
    * Boundary `:unclassified_module` errors that hit a first-party module
      reachable from a `:domain` boundary → `CRANK_DEP_002` (unmarked
      first-party helper). Pure unclassified-module errors that never
      crossed into a `:domain` boundary are left as Boundary diagnostics
      (they're a setup hygiene issue, not a Crank topology violation).

  Other Boundary errors (`:cycle`, `:unknown_dep`, etc.) are configuration
  errors in the user's `boundary` definitions, not domain-purity violations.
  Those are returned untouched so users see Boundary's normal message.
  """

  alias Crank.Errors

  @typedoc """
  Classification of a third-party app for Boundary external-dep purposes.

  See the `External dependency policy` section of `purity-enforcement.md`
  (Phase 1.4) for the rationale and the starter config seed list.
  """
  @type third_party_classification :: %{
          required(:pure) => [Application.app()],
          required(:impure) => [Application.app()]
        }

  @typedoc "Options accepted by `translate_error/2` and `translate_diagnostic/2`."
  @type opts :: [
          {:third_party_classification, third_party_classification()}
        ]

  @doc """
  Translates a `Mix.Task.Compiler.Diagnostic` from the `:boundary` compiler
  into a Crank-formatted diagnostic.

  Returns the diagnostic unchanged if it doesn't correspond to a topology
  violation Crank knows about — this is intentional: Boundary configuration
  errors (cycles, unknown deps) should still surface, just not as Crank
  codes.
  """
  @spec translate_diagnostic(Mix.Task.Compiler.Diagnostic.t(), opts()) ::
          Mix.Task.Compiler.Diagnostic.t()
  def translate_diagnostic(diagnostic, opts \\ [])

  def translate_diagnostic(%Mix.Task.Compiler.Diagnostic{compiler_name: "boundary"} = diag, opts) do
    case classify_message(diag.message, opts) do
      {:ok, code} ->
        %{diag | compiler_name: "crank", message: prefix_with_code(code, diag.message)}

      :unhandled ->
        diag
    end
  end

  def translate_diagnostic(%Mix.Task.Compiler.Diagnostic{} = diag, _opts), do: diag

  @doc """
  Translates a Boundary error tuple into a `%Crank.Errors.Violation{}`.

  Used by tests (and by `Mix.Tasks.Compile.Crank` when run with the
  `--format=structured` flag) to surface topology violations as full
  Crank `%Violation{}` structs.
  """
  @spec translate_error(tuple(), opts()) :: Errors.Violation.t() | {:passthrough, tuple()}
  def translate_error(error_tuple, opts \\ [])

  def translate_error({:invalid_reference, info}, opts) do
    type = Map.get(info, :type, :normal)
    ref = Map.get(info, :reference, %{})

    code = code_for_invalid_reference(type, info, opts)

    Errors.build(code,
      location: location_for_reference(ref),
      violating_call: violating_call_for_reference(ref),
      context: context_for_reference(info, code),
      metadata: %{
        from_boundary: Map.get(info, :from_boundary),
        to_boundary: Map.get(info, :to_boundary),
        boundary_error_type: type
      }
    )
  end

  def translate_error({:unclassified_module, _module} = tuple, _opts) do
    # Per-error translator can't decide CRANK_DEP_002 alone — it needs
    # the references graph to know whether a Crank-domain module called
    # this unclassified helper. The Mix compiler task does the lookup
    # and calls `translate_unclassified/2` directly when it finds a
    # matching reference.
    {:passthrough, tuple}
  end

  def translate_error(other, _opts), do: {:passthrough, other}

  @doc """
  Builds a `CRANK_DEP_002` violation for an unclassified first-party
  helper that was referenced from a Crank-domain module.

  `helper` is the unclassified module. `domain_reference` is one entry
  from `Boundary.Mix.CompilerState.references()` (a `Boundary.ref()`
  map) where `from` is a Crank-domain module and `to` is `helper`.

  Returns a `Crank.Errors.Violation` ready to be wrapped in a
  `Mix.Task.Compiler.Diagnostic`.
  """
  @spec translate_unclassified(module(), Boundary.ref()) :: Errors.Violation.t()
  def translate_unclassified(helper, domain_reference) when is_atom(helper) and is_map(domain_reference) do
    Errors.build("CRANK_DEP_002",
      location: %{
        file: Map.get(domain_reference, :file),
        line: Map.get(domain_reference, :line),
        column: nil,
        function:
          case Map.get(domain_reference, :from_function) do
            {fun, arity} -> "#{fun}/#{arity}"
            _ -> nil
          end
      },
      violating_call: %{module: helper, function: nil, arity: nil},
      context:
        "Crank-domain module #{inspect(Map.get(domain_reference, :from))} references unmarked first-party helper #{inspect(helper)}. " <>
          "Mark the helper with `use Crank.Domain.Pure` (or add it to a Boundary).",
      metadata: %{
        helper: helper,
        from: Map.get(domain_reference, :from),
        ref_type: Map.get(domain_reference, :type)
      }
    )
  end

  @doc """
  Classifies the OTP app a module belongs to against the configured
  third-party classification.

  Returns `:first_party`, `:third_party_pure`, `:third_party_impure`, or
  `:third_party_unclassified`. Used by `translate_error/2` to distinguish
  `CRANK_DEP_001` (forbidden infrastructure) from `CRANK_DEP_003`
  (unclassified third-party).
  """
  @spec classify_app(atom(), atom(), third_party_classification()) ::
          :first_party | :third_party_pure | :third_party_impure | :third_party_unclassified
  def classify_app(target_app, main_app, classification)
      when is_atom(target_app) and is_atom(main_app) and is_map(classification) do
    cond do
      target_app == main_app -> :first_party
      target_app in (classification[:pure] || []) -> :third_party_pure
      target_app in (classification[:impure] || []) -> :third_party_impure
      true -> :third_party_unclassified
    end
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp code_for_invalid_reference(:invalid_external_dep_call, info, opts) do
    classification = Keyword.get(opts, :third_party_classification, %{pure: [], impure: []})
    main_app = Keyword.get(opts, :main_app, nil)
    target_app = Map.get(info, :target_app)

    cond do
      target_app == nil ->
        "CRANK_DEP_001"

      classify_app(target_app, main_app, classification) == :third_party_unclassified ->
        "CRANK_DEP_003"

      true ->
        "CRANK_DEP_001"
    end
  end

  defp code_for_invalid_reference(:not_exported, _info, _opts), do: "CRANK_DEP_001"

  defp code_for_invalid_reference(type, _info, _opts) when type in [:normal, :runtime] do
    "CRANK_DEP_001"
  end

  defp code_for_invalid_reference(_type, _info, _opts), do: "CRANK_DEP_001"

  defp location_for_reference(ref) do
    %{
      file: Map.get(ref, :file),
      line: Map.get(ref, :line),
      column: nil,
      function:
        case Map.get(ref, :from_function) do
          {fun, arity} -> "#{fun}/#{arity}"
          _ -> nil
        end
    }
  end

  defp violating_call_for_reference(ref) do
    case Map.get(ref, :to) do
      module when is_atom(module) and module != nil ->
        %{module: module, function: nil, arity: nil}

      _ ->
        nil
    end
  end

  defp context_for_reference(info, "CRANK_DEP_001") do
    "Domain boundary #{inspect(Map.get(info, :from_boundary))} references infrastructure boundary #{inspect(Map.get(info, :to_boundary))}."
  end

  defp context_for_reference(info, "CRANK_DEP_002") do
    "Domain boundary #{inspect(Map.get(info, :from_boundary))} calls unmarked first-party helper #{inspect(get_in(info, [:reference, :to]))}."
  end

  defp context_for_reference(info, "CRANK_DEP_003") do
    target_app = Map.get(info, :target_app)
    "Domain boundary #{inspect(Map.get(info, :from_boundary))} calls third-party app #{inspect(target_app)}, which is not classified in the Boundary config."
  end

  defp context_for_reference(_info, _code), do: nil

  # Parse a Boundary diagnostic message into a code. Boundary's compiler
  # produces messages like `forbidden reference to MyApp.Repo\n  (references
  # from Foo to Bar are not allowed)`.
  defp classify_message(message, _opts) when is_binary(message) do
    cond do
      String.contains?(message, "is not included in any boundary") ->
        :unhandled

      String.contains?(message, "forbidden reference to") ->
        {:ok, "CRANK_DEP_001"}

      true ->
        :unhandled
    end
  end

  defp classify_message(_, _), do: :unhandled

  defp prefix_with_code(code, message) do
    "[#{code}] #{message}"
  end
end
