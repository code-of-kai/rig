defmodule Crank.Suppressions do
  @moduledoc """
  Parser for **Layer A** suppression annotations: source-adjacent
  `# crank-allow:` comments that silence AST-level violations from Credo
  (Phase 1.1) and the `@before_compile` check (Phase 1.3).

  Layer B (topology) suppression lives in the Boundary configuration; Layer C
  (runtime trace) suppression is the `:allow` opt on `Crank.PropertyTest`
  and `Crank.PurityTrace`. This module concerns Layer A only.

  ## Syntax

      # crank-allow: CRANK_PURITY_004
      # reason: dev-only debug timestamp; never reached in production
      @dev_only_timestamp DateTime.utc_now()

  Multiple codes can be listed:

      # crank-allow: CRANK_PURITY_004, CRANK_PURITY_005
      # reason: integration test fixture sampling time and spawning workers
      ...

  ## Rules

    * Suppression applies to the **next non-comment code line** within 3 lines.
      Beyond that, raises `CRANK_META_003` (orphaned).
    * The `# reason:` field is **required**. Missing it raises `CRANK_META_001`.
    * Each referenced code must be in the catalog; unknown codes raise
      `CRANK_META_002`.
    * Each referenced code must be suppressible by Layer A. Codes belonging
      to topology-only or runtime-only layers raise `CRANK_META_004` with a
      pointer to the correct mechanism.
    * Suppression itself emits a `[:crank, :suppression]` telemetry event.
  """

  alias Crank.Errors.Catalog

  @typedoc """
  Suppression entry parsed from source. Maps the line of the *suppressed*
  code (not the comment) to the set of suppressed codes plus the reason.
  """
  @type suppression :: %{
          required(:codes) => MapSet.t(binary()),
          required(:reason) => binary(),
          required(:annotation_line) => non_neg_integer(),
          required(:suppressed_line) => non_neg_integer()
        }

  @typedoc "Map of suppressed-line → suppression entry."
  @type table :: %{non_neg_integer() => suppression()}

  @typedoc "A suppression-syntax violation produced during parsing."
  @type meta_violation :: %{
          required(:code) => binary(),
          required(:line) => non_neg_integer(),
          required(:message) => binary()
        }

  @typedoc "Parse result: `{table, meta_violations}`."
  @type parse_result :: {table(), [meta_violation()]}

  @max_lookahead 3

  @doc """
  Parses a source file (binary or path) and returns the suppression table
  plus any meta-level violations encountered during parsing.

  The table is keyed by the line number of the *suppressed* code (not the
  annotation), so a check that observes a violation at line N can do
  `Map.get(table, N)` to find any active suppression.
  """
  @spec parse(binary()) :: parse_result()
  def parse(source) when is_binary(source) do
    lines =
      source
      |> String.split("\n")
      |> Enum.with_index(1)

    parse_lines(lines, %{}, [])
  end

  @doc "Parses a file at the given path."
  @spec parse_file(Path.t()) :: parse_result()
  def parse_file(path) do
    path
    |> File.read!()
    |> parse()
  end

  @doc """
  Returns true if the violation is suppressed by an annotation at its line.

  The violation's `:location.line` is matched against the suppression table's
  keys. A suppression covers the violation when (a) the line matches and
  (b) the violation's code is in the suppression's code set.
  """
  @spec suppressed?(Crank.Errors.Violation.t(), table()) :: boolean()
  def suppressed?(%Crank.Errors.Violation{code: code, location: %{line: line}}, table)
      when is_integer(line) and is_map(table) do
    case Map.get(table, line) do
      nil -> false
      %{codes: codes} -> MapSet.member?(codes, code)
    end
  end

  def suppressed?(_violation, _table), do: false

  @doc """
  Converts the meta-violations returned by `parse/1` into proper
  `Crank.Errors.Violation` structs so checks can thread them through
  the same pipeline as substantive violations.

  Codex review #28 (2026-05-08): callers previously discarded the
  meta-violations list, leaving CRANK_META_001..004 cataloged but
  unreachable in normal compile/credo flows. Suppression-syntax errors
  now surface as compile or Credo issues alongside other violations.
  """
  @spec build_meta_violations(binary() | nil, [meta_violation()]) :: [Crank.Errors.Violation.t()]
  def build_meta_violations(file, meta_violations) when is_list(meta_violations) do
    Enum.map(meta_violations, fn %{code: code, line: line, message: message} ->
      Crank.Errors.build(code,
        location: %{file: file, line: line},
        context: message
      )
    end)
  end

  @doc """
  Emits a `[:crank, :suppression]` telemetry event when a suppression silences
  a violation. Called by checks immediately before they discard a suppressed
  violation, so projects can audit suppression frequency.
  """
  @spec emit_suppression_telemetry(Crank.Errors.Violation.t(), suppression()) :: :ok
  def emit_suppression_telemetry(%Crank.Errors.Violation{} = violation, %{} = suppression) do
    :telemetry.execute(
      [:crank, :suppression],
      %{count: 1},
      %{
        layer: :a,
        code: violation.code,
        reason: suppression.reason,
        file: violation.location[:file],
        line: violation.location[:line]
      }
    )
  end

  # ── Parser implementation ──────────────────────────────────────────────────

  # Layer A is allowed to suppress codes whose layer is in this set.
  @layer_a_codes MapSet.new(Catalog.suppressible_by(:layer_a))

  defp parse_lines([], table, meta_violations),
    do: {table, Enum.reverse(meta_violations)}

  defp parse_lines([{line_text, line_no} | rest], table, meta) do
    case extract_allow(line_text) do
      nil ->
        parse_lines(rest, table, meta)

      {codes_str, codes} ->
        # Found a `# crank-allow:` annotation. Look ahead for the reason
        # comment and the suppressed code line.
        case consume_annotation(rest, line_no, codes_str, codes) do
          {:ok, suppression, remaining} ->
            updated_table = Map.put(table, suppression.suppressed_line, suppression)
            parse_lines(remaining, updated_table, meta)

          {:meta_violations, additions, remaining} ->
            parse_lines(remaining, table, additions ++ meta)
        end
    end
  end

  # Looks at a line for `# crank-allow: CODE[, CODE2, ...]`. Returns the raw
  # codes-string and a list of code atoms; or nil if not present.
  defp extract_allow(line) do
    line
    |> String.trim_leading()
    |> case do
      "#" <> rest ->
        case Regex.run(~r/^\s*crank-allow:\s*(.+?)\s*$/, rest) do
          [_, codes_part] ->
            codes =
              codes_part
              |> String.split(",")
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

            {codes_part, codes}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  # Consumes the rest of an annotation: a required `# reason:` comment, then
  # the next non-comment code line within `@max_lookahead` lines.
  defp consume_annotation(lines, annotation_line, _codes_str, codes) do
    {reason_result, after_reason} = consume_reason(lines)

    case reason_result do
      {:ok, reason} ->
        finalize_with_reason(reason, after_reason, annotation_line, codes)

      :missing ->
        meta = %{
          code: "CRANK_META_001",
          line: annotation_line,
          message: "# crank-allow: annotation requires a `# reason:` comment on the next line"
        }

        {:meta_violations, [meta], after_reason}
    end
  end

  defp finalize_with_reason(reason, after_reason, annotation_line, codes) do
    case consume_target_line(after_reason, annotation_line, @max_lookahead) do
      {:ok, suppressed_line, remaining} ->
        build_suppression(codes, reason, annotation_line, suppressed_line, remaining, after_reason)

      :not_found ->
        meta = %{
          code: "CRANK_META_003",
          line: annotation_line,
          message: "# crank-allow: annotation has no following code line within #{@max_lookahead} lines"
        }

        {:meta_violations, [meta], after_reason}
    end
  end

  defp build_suppression(codes, reason, annotation_line, suppressed_line, remaining, after_reason) do
    case validate_codes(codes, annotation_line) do
      {:ok, validated_codes} ->
        suppression = %{
          codes: MapSet.new(validated_codes),
          reason: reason,
          annotation_line: annotation_line,
          suppressed_line: suppressed_line
        }

        {:ok, suppression, remaining}

      {:meta, meta_list} ->
        {:meta_violations, meta_list, after_reason}
    end
  end

  defp consume_reason([{line_text, line_no} | rest]) do
    case extract_reason(line_text) do
      nil -> {:missing, [{line_text, line_no} | rest]}
      reason -> {{:ok, reason}, rest}
    end
  end

  defp consume_reason([]), do: {:missing, []}

  defp extract_reason(line) do
    line
    |> String.trim_leading()
    |> case do
      "#" <> rest ->
        case Regex.run(~r/^\s*reason:\s*(.+?)\s*$/, rest) do
          [_, text] -> text
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Walk forward up to `remaining` lines looking for a non-blank, non-comment
  # line. Return its line number on success; `:not_found` on failure.
  defp consume_target_line([{line_text, line_no} | rest], start_line, remaining) when remaining > 0 do
    cond do
      blank?(line_text) ->
        consume_target_line(rest, start_line, remaining - 1)

      comment_only?(line_text) ->
        consume_target_line(rest, start_line, remaining - 1)

      true ->
        {:ok, line_no, rest}
    end
  end

  defp consume_target_line(_, _, 0), do: :not_found
  defp consume_target_line([], _, _), do: :not_found

  defp blank?(line), do: String.trim(line) == ""

  defp comment_only?(line) do
    case String.trim_leading(line) do
      "#" <> _ -> true
      _ -> false
    end
  end

  # Validates that every code is (a) in the catalog and (b) suppressible by
  # Layer A. Returns `{:ok, codes}` or `{:meta, meta_violations}`.
  defp validate_codes(codes, line) do
    {valid, errors} =
      Enum.reduce(codes, {[], []}, fn code, {valid_acc, error_acc} ->
        cond do
          not MapSet.member?(Catalog.codes(), code) ->
            error = %{
              code: "CRANK_META_002",
              line: line,
              message: "# crank-allow: unknown code #{inspect(code)} (not in catalog)"
            }

            {valid_acc, [error | error_acc]}

          not MapSet.member?(@layer_a_codes, code) ->
            mechanism = correct_mechanism_hint(code)

            error = %{
              code: "CRANK_META_004",
              line: line,
              message:
                "# crank-allow: cannot suppress #{code} via source comment — " <>
                  "use #{mechanism} instead"
            }

            {valid_acc, [error | error_acc]}

          true ->
            {[code | valid_acc], error_acc}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(valid)}
      _ -> {:meta, Enum.reverse(errors)}
    end
  end

  defp correct_mechanism_hint(code) do
    {:ok, entry} = Catalog.fetch(code)

    case entry.layer do
      :static_topology -> "Boundary configuration `:exceptions` entry"
      :runtime -> "the `:allow` opt on `Crank.PropertyTest.assert_pure_turn/3`"
      _ -> "the appropriate suppression mechanism for this layer"
    end
  end
end
