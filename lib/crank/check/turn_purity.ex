# Credo is an optional dev/test dependency for downstream Crank consumers.
# Wrap this module so it only compiles when Credo is available — otherwise
# downstream projects depending on `:crank` would fail to compile here
# because `Credo.Check` is not loaded. The `@before_compile` hook in
# `Crank.Check.CompileTime` covers the same ground at compile time and is
# always available regardless of Credo's presence.
#
# Skip the second condition during a re-load (e.g. when Credo's own scan
# requires this file at runtime); without it the BEAM emits a "redefining
# module" warning every `mix credo` run.
if Code.ensure_loaded?(Credo.Check) and not Code.ensure_loaded?(Crank.Check.TurnPurity) do
  defmodule Crank.Check.TurnPurity do
    @moduledoc """
    Credo check that flags impure calls inside `turn/3` clause bodies.

    Warning-level early signal — runs at editor save time / `mix credo` time.
    The `@before_compile` hook in `Crank.Check.CompileTime` covers the same
    ground at compile time and produces hard `CompileError`s; both share the
    blacklist via `Crank.Check.Blacklist`.

    Suppression: source-adjacent `# crank-allow:` comments (Layer A; see
    `Crank.Suppressions`).
    """

    use Credo.Check,
      base_priority: :high,
      category: :design,
      explanations: [
        check: """
        `turn/3` must be a pure function. Side effects inside `turn/3` break
        the hexagonal architecture boundary: they require infrastructure to run
        tests, and they make the domain model depend on adapters.

        Move side effects to adapters attached via telemetry, or declare them
        as `wants/2` entries for `Crank.Server` to execute.

        See the Hexagonal Architecture guide for the boundary contract, and the
        Transitions and guards guide for what `turn/3` clauses should contain.

        To suppress a specific instance with reason:

            # crank-allow: CRANK_PURITY_004
            # reason: dev-only debug timestamp; never reached in production
            @debug_now DateTime.utc_now()
        """
      ]

    alias Crank.Check.Blacklist
    alias Crank.Errors
    alias Crank.Suppressions
    alias Credo.IssueMeta

    @impl Credo.Check
    def run(%SourceFile{} = source_file, params) do
      issue_meta = IssueMeta.for(source_file, params)
      source = SourceFile.source(source_file)
      {suppressions, meta} = Suppressions.parse(source)

      # Codex review #28 (2026-05-08): meta_violations describe the
      # suppression syntax itself and cannot be silenced by the table
      # they're part of. They're carried through `visit/5` so that
      # CRANK_META_* issues only fire on files containing a
      # `use Crank` defmodule — otherwise heredoc-encoded test fixtures
      # or documentation snippets that mention `# crank-allow:` would
      # produce spurious issues despite no real suppression being
      # active in those contexts.
      source_file
      |> Credo.Code.prewalk(&visit(&1, &2, source_file, suppressions, meta, issue_meta))
    end

    defp build_meta_issues(meta_violations, issue_meta) do
      Enum.map(meta_violations, fn %{code: code, line: line, message: message} ->
        format_issue(issue_meta,
          message: "[#{code}] #{message}",
          line_no: line,
          trigger: code
        )
      end)
    end

    # ── Visitor ─────────────────────────────────────────────────────────────

    # Only inspect defmodule blocks that `use Crank`.
    defp visit({:defmodule, _meta, [_name, [do: body]]} = ast, issues, source_file, suppressions, meta, issue_meta) do
      if uses_crank?(body) do
        meta_issues = build_meta_issues(meta, issue_meta)
        new_issues = collect_turn_issues(body, source_file, suppressions, issue_meta)
        {ast, issues ++ meta_issues ++ new_issues}
      else
        {ast, issues}
      end
    end

    defp visit(ast, issues, _source_file, _suppressions, _meta, _issue_meta), do: {ast, issues}

    # ── `use Crank` detector ────────────────────────────────────────────────

    defp uses_crank?({:__block__, _, stmts}), do: Enum.any?(stmts, &uses_crank?/1)
    defp uses_crank?({:use, _, [{:__aliases__, _, [:Crank]} | _]}), do: true
    defp uses_crank?({:use, _, [{:__aliases__, _, [:Crank, :Domain, :Pure]} | _]}), do: true
    defp uses_crank?(_), do: false

    # ── `turn/3` clause walker ──────────────────────────────────────────────

    defp collect_turn_issues({:__block__, _, stmts}, source_file, suppressions, issue_meta) do
      Enum.flat_map(stmts, &collect_turn_issues(&1, source_file, suppressions, issue_meta))
    end

    defp collect_turn_issues({:def, _meta, [{:turn, _, args}, [do: body]]}, source_file, suppressions, issue_meta)
         when length(args) == 3 do
      find_impure_calls(body, source_file, suppressions, issue_meta)
    end

    # Also walk `def` clauses inside `Crank.Domain.Pure` modules (every public
    # function in a domain-pure module is subject to the same blacklist).
    defp collect_turn_issues({:def, _meta, [{_fun, _, _args}, [do: body]]}, source_file, suppressions, issue_meta) do
      if Process.get(:__crank_domain_pure_walk__, false) do
        find_impure_calls(body, source_file, suppressions, issue_meta)
      else
        []
      end
    end

    defp collect_turn_issues(_, _source_file, _suppressions, _issue_meta), do: []

    # ── Per-call AST walk ───────────────────────────────────────────────────

    defp find_impure_calls(ast, source_file, suppressions, issue_meta) do
      {_, issues} =
        Macro.prewalk(ast, [], fn node, acc ->
          case Blacklist.match_call(node) do
            {:violation, code, message, doc_url} ->
              {node, accumulate(node, code, message, doc_url, acc, source_file, suppressions, issue_meta)}

            nil ->
              {node, acc}
          end
        end)

      Enum.reverse(issues)
    end

    defp accumulate(node, code, message, doc_url, acc, source_file, suppressions, issue_meta) do
      line = call_line(node)
      violation = Errors.build(code, location: %{file: source_file.filename, line: line}, fix_category: message)

      if Suppressions.suppressed?(violation, suppressions) do
        suppression = Map.get(suppressions, line)
        if suppression, do: Suppressions.emit_suppression_telemetry(violation, suppression)
        acc
      else
        issue =
          format_issue(issue_meta,
            message: "[#{code}] #{message}",
            line_no: line,
            trigger: trigger_text(node, doc_url)
          )

        [issue | acc]
      end
    end

    defp call_line({{:., meta, _}, _, _}), do: meta[:line]
    defp call_line({_fun, meta, _args}) when is_list(meta), do: meta[:line]
    defp call_line(_), do: nil

    defp trigger_text(_node, doc_url), do: "see #{doc_url}"
  end
end
