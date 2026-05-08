defmodule Crank.Check.CompileTime do
  @moduledoc """
  Compile-time check that flags impure calls inside `turn/3` clause bodies
  and direct infrastructure references in the module body.

  Registered via `@before_compile Crank.Check.CompileTime` by the `use Crank`
  and `use Crank.Domain.Pure` macros. Cannot be ignored without an explicit
  `# crank-allow:` annotation. Produces a `CompileError` with the rich Crank
  error format on the first unsuppressed violation in the module.

  Scope is **local-only**: walks the module's own AST. Transitive purity
  enforcement (helper modules, third-party deps) is the topology layer's
  responsibility (`Crank.BoundaryIntegration`).

  Shares the blacklist with `Crank.Check.TurnPurity` (the Credo check) via
  `Crank.Check.Blacklist`.
  """

  alias Crank.Check.Blacklist
  alias Crank.Errors
  alias Crank.Suppressions

  defmacro __before_compile__(env) do
    module = env.module
    file = env.file

    turn_bodies = Module.get_attribute(module, :__crank_turn_bodies__) || []

    {suppressions, meta_violations} =
      case File.read(file) do
        {:ok, source} ->
          {table, meta} = Suppressions.parse(source)
          # Codex review #28 (2026-05-08): meta-violations
          # (CRANK_META_001..004) describe malformed suppression
          # annotations themselves and CANNOT be suppressed by the
          # very table they're part of. Surface them as proper
          # violations so the user sees a CompileError instead of
          # silently accepting the broken suppression.
          {table, Suppressions.build_meta_violations(file, meta)}

        _ ->
          {%{}, []}
      end

    violations = meta_violations ++ check_turn_bodies(turn_bodies, file, suppressions)

    case violations do
      [] ->
        :ok

      [first | _] ->
        raise Errors.to_compile_error(first)
    end

    quote do: :ok
  end

  @doc """
  `@on_definition` callback. Called by Elixir for every function defined
  in a module that registers `@on_definition Crank.Check.CompileTime`.

  Captures the body AST when the definition is `turn/3`, so the
  `@before_compile` hook can walk it for blacklisted calls. For modules
  marked `@__crank_domain_pure__`, every public/private function body is
  captured (since pure helpers must themselves be pure).

  Elixir's `@on_definition` protocol calls `__on_definition__/6` (not the
  underscore-stripped name).
  """
  def __on_definition__(env, _kind, :turn, args, _guards, body) when length(args) == 3 do
    existing = Module.get_attribute(env.module, :__crank_turn_bodies__) || []
    Module.put_attribute(env.module, :__crank_turn_bodies__, [body | existing])
    :ok
  end

  def __on_definition__(env, kind, _name, _args, _guards, body)
      when kind in [:def, :defp] do
    if Module.get_attribute(env.module, :__crank_domain_pure__) do
      existing = Module.get_attribute(env.module, :__crank_turn_bodies__) || []
      Module.put_attribute(env.module, :__crank_turn_bodies__, [body | existing])
    end

    :ok
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  # ── turn/3 body checks ────────────────────────────────────────────────────

  defp check_turn_bodies(bodies, file, suppressions) do
    bodies
    |> Enum.flat_map(fn body -> walk_for_violations(body, file, suppressions) end)
  end

  # The historical `register_*` API is kept as no-ops for any external code
  # that referenced them. The actual capture path is now `on_definition/6`.

  @doc false
  def register_turn_body(_module, _body_ast), do: :ok

  @doc false
  def register_module_ref(_module, _ref_ast), do: :ok

  defp walk_for_violations(ast, file, suppressions) do
    {_, violations} =
      Macro.prewalk(ast, [], fn node, acc ->
        case detect_violation(node, file) do
          nil -> {node, acc}
          violation -> {node, accumulate_violation(violation, acc, suppressions)}
        end
      end)

    Enum.reverse(violations)
  end

  defp detect_violation(node, file) do
    case Blacklist.match_call(node) do
      {:violation, code, message, _doc_url} ->
        line = call_line(node) || 0

        Errors.build(code,
          location: %{file: file, line: line},
          fix_category: message,
          violating_call: extract_call_info(node)
        )

      nil ->
        case discard_form(node) do
          {:discarded, line, info} ->
            # CRANK_PURITY_002: `_ = <call>` discards a return value
            # inside `turn/3`. Side-effect intent is the only reason to
            # discard a pure return; flag it for review.
            Errors.build("CRANK_PURITY_002",
              location: %{file: file, line: line},
              fix_category:
                "remove the discarded call or move it behind wants/2 — discarding a return signals side-effect intent",
              violating_call: info
            )

          :no ->
            nil
        end
    end
  end

  defp accumulate_violation(violation, acc, suppressions) do
    if Suppressions.suppressed?(violation, suppressions) do
      line = violation.location.line
      suppression = Map.get(suppressions, line)

      if suppression do
        Suppressions.emit_suppression_telemetry(violation, suppression)
      end

      acc
    else
      [violation | acc]
    end
  end

  # Recognises the `_ = <call>` pattern. We only fire CRANK_PURITY_002 for
  # local-call discards — remote-call discards whose target is impure are
  # already flagged by Blacklist with a more specific code, and the prewalk
  # visits the inner call anyway. Pure remote-call discards (e.g.
  # `_ = Map.get(memory, :x)`) are also valid signals but produce noise on
  # legitimate idioms; v1 keeps 002 scoped to local-call discards.
  defp discard_form({:=, meta, [{:_, _, _}, rhs]}) when is_list(meta) do
    case rhs do
      {fun, _, args}
      when is_atom(fun) and is_list(args) and fun not in [:., :__aliases__, :{}, :%{}, :__block__] ->
        line = Keyword.get(meta, :line, 0)
        info = %{module: Kernel, function: fun, arity: length(args)}
        {:discarded, line, info}

      _ ->
        :no
    end
  end

  defp discard_form(_), do: :no

  # ── helpers ──────────────────────────────────────────────────────────────

  defp call_line({{:., meta, _}, _, _}) when is_list(meta), do: Keyword.get(meta, :line)
  defp call_line({_fun, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp call_line(_), do: nil

  defp extract_call_info({{:., _meta, [{:__aliases__, _, parts}, fun]}, _, args})
       when is_list(parts) and is_atom(fun) and is_list(args) do
    %{module: Module.concat(parts), function: fun, arity: length(args)}
  end

  defp extract_call_info({{:., _meta, [erlang_mod, fun]}, _, args})
       when is_atom(erlang_mod) and is_atom(fun) and is_list(args) do
    %{module: erlang_mod, function: fun, arity: length(args)}
  end

  defp extract_call_info({fun, _meta, args}) when is_atom(fun) and is_list(args) do
    %{module: Kernel, function: fun, arity: length(args)}
  end

  defp extract_call_info(_), do: nil
end
