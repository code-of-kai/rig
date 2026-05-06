defmodule Mix.Tasks.Crank.Gen.Config do
  @shortdoc "Wires Crank into a project's .credo.exs and Boundary config"

  @moduledoc """
  One-time setup task for adding Crank's purity-enforcement wiring to a
  project. Writes a starter `boundary.exs`, creates or amends `.credo.exs`,
  and prints the recommended `mix.exs` / CI / README snippets to stdout.

  ## What this task does

  1. **`boundary.exs`** — written at project root from the seed template
     in `priv/boundary.exs.template`. Contains commented `:third_party_pure`
     and `:third_party_impure` lists for the user to populate.
  2. **`.credo.exs`** — created with `Crank.Check.TurnPurity` wired in if
     absent, or amended (without clobbering existing checks) if present.
  3. **stdout** — prints the `mix.exs` additions (deps, `:compilers`,
     `:boundary` keyword), the CI snippet, and a recommended README
     section. The user copies these into their project manually.

  ## Why mix.exs is print-only, not auto-edited

  `mix.exs` is a hand-edited Elixir source file with project-specific
  comments, formatting, conditional logic, and macros. Real-world dep
  entries contain nested lists (`only: [:dev, :test]`) and string
  options that defeat naive regex rewriting. Round-tripping through the
  AST loses comments and formatting. Phoenix's non-greenfield generators
  (`mix phx.gen.auth`, `mix phx.gen.context`) also print rather than
  mutate; we follow the same pattern. If you want automated mix.exs
  rewriting, use a tool like `igniter` that handles the full surface
  carefully.

  ## Idempotency

  Re-running on a configured project does not change `boundary.exs` or
  `.credo.exs`. The stdout block always prints — copy what you need.

  ## Verification

  After running, paste the printed `mix.exs` block, run `mix deps.get`,
  then `mix crank.check` to gate the full discipline. Expect to fix at
  least `CRANK_DEP_003` warnings the first time you run it — that
  surfaces third-party deps that need entering into `:third_party_pure`
  or `:third_party_impure`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: [quiet: :boolean])
    quiet? = Keyword.get(opts, :quiet, false)

    actions =
      []
      |> write_boundary_exs()
      |> wire_credo_exs()

    unless quiet?, do: report(actions)
    :ok
  end

  # ── boundary.exs ───────────────────────────────────────────────────────────

  @doc false
  @spec write_boundary_exs([action()], binary()) :: [action()]
  def write_boundary_exs(actions, path \\ "boundary.exs") do
    if File.exists?(path) do
      [{:noop, path, "exists"} | actions]
    else
      template = Path.join(:code.priv_dir(:crank) |> to_string(), "boundary.exs.template")

      case File.read(template) do
        {:ok, content} ->
          File.write!(path, content)
          [{:created, path, "starter file written from priv/boundary.exs.template"} | actions]

        {:error, _} ->
          [{:missing, template, "template not found in priv/"} | actions]
      end
    end
  end

  # ── .credo.exs ─────────────────────────────────────────────────────────────

  @doc false
  @spec wire_credo_exs([action()], binary()) :: [action()]
  def wire_credo_exs(actions, path \\ ".credo.exs") do
    if File.exists?(path) do
      source = File.read!(path)
      {new_source, change} = update_credo_source(source)

      if change do
        File.write!(path, new_source)
        [{:updated, path, change} | actions]
      else
        [{:noop, path, "already wired"} | actions]
      end
    else
      File.write!(path, starter_credo_config())
      [{:created, path, "starter .credo.exs with Crank.Check.TurnPurity wired"} | actions]
    end
  end

  @doc """
  Pure transformation for `.credo.exs`. Adds `Crank.Check.TurnPurity` to
  the `enabled:` checks list. Returns `{new_source, change_description | nil}`.

  Note: the check module is loaded automatically from the compiled `:crank`
  application, so no `requires:` entry is added.
  """
  @spec update_credo_source(binary()) :: {binary(), binary() | nil}
  def update_credo_source(source) do
    new_source = ensure_credo_check(source)

    if new_source == source do
      {source, nil}
    else
      {new_source, "wired Crank.Check.TurnPurity into .credo.exs"}
    end
  end

  defp ensure_credo_check(source) do
    if String.contains?(source, "Crank.Check.TurnPurity") do
      source
    else
      Regex.replace(
        ~r/(checks:\s*%\{[^}]*?enabled:\s*\[)/s,
        source,
        "\\1\n          {Crank.Check.TurnPurity, []},",
        global: false
      )
    end
  end

  defp starter_credo_config do
    """
    %{
      configs: [
        %{
          name: "default",
          files: %{
            included: ["lib/", "test/"],
            excluded: [~r"/_build/", ~r"/deps/"]
          },
          plugins: [],
          requires: [],
          strict: false,
          parse_timeout: 5000,
          color: true,
          checks: %{
            enabled: [
              {Crank.Check.TurnPurity, []}
            ],
            disabled: []
          }
        }
      ]
    }
    """
  end

  # ── reporting ──────────────────────────────────────────────────────────────

  @typedoc "An action returned by each step in this task."
  @type action :: {:created | :updated | :noop | :missing, binary(), term()}

  defp report(actions) do
    Mix.shell().info("")
    Mix.shell().info(IO.ANSI.bright() <> "Crank wiring report" <> IO.ANSI.reset())
    Mix.shell().info("")

    for action <- Enum.reverse(actions) do
      Mix.shell().info(format_action(action))
    end

    Mix.shell().info("")
    Mix.shell().info(IO.ANSI.bright() <> "Add to your mix.exs" <> IO.ANSI.reset())
    Mix.shell().info(mix_exs_snippet())

    Mix.shell().info(IO.ANSI.bright() <> "Add this CI step to your workflow" <> IO.ANSI.reset())
    Mix.shell().info(ci_snippet())

    Mix.shell().info(IO.ANSI.bright() <> "Add this section to your README" <> IO.ANSI.reset())
    Mix.shell().info(readme_snippet())
  end

  defp format_action({:created, path, info}), do: "  created  #{path}  (#{info})"

  defp format_action({:updated, path, info}), do: "  updated  #{path}  (#{info})"
  defp format_action({:noop, path, info}), do: "  unchanged  #{path}  (#{info})"
  defp format_action({:missing, path, info}), do: "  MISSING  #{path}  (#{info})"

  @doc false
  @spec mix_exs_snippet() :: binary()
  def mix_exs_snippet do
    """

    1) Add `:boundary` and `:crank` to your `deps/0`:

           {:boundary, "~> 0.10"},
           {:crank, "~> 2.0"}

    2) Add `:crank` to the `:compilers` list inside `def project do`:

           compilers: [:crank | Mix.compilers()]

    3) Add the `:boundary` classification keyword inside `def project do`:

           boundary: [
             third_party_pure: [],
             third_party_impure: []
           ]

       (Move entries from the generated `boundary.exs` into these lists
       as you classify each dep. `boundary.exs` exists as a curated
       starter list — `mix.exs` is the live config that Boundary reads.)
    """
  end

  defp ci_snippet do
    """

        - name: Crank check
          run: mix crank.check
    """
  end

  defp readme_snippet do
    """

    ## Purity enforcement

    This project uses Crank's purity-enforcement layer. Domain modules tagged
    `use Crank` or `use Crank.Domain.Pure` are subject to:

      * Compile-time call-site checks (`Crank.Check.CompileTime`).
      * Compile-time topology checks (Boundary, via the `:crank` Mix compiler).
      * Runtime tracing in tests (`Crank.PropertyTest.assert_pure_turn/3`).

    Run `mix crank.check` to gate the full discipline. See the
    `Boundary setup` and `Suppressions` guides for configuration.
    """
  end
end
