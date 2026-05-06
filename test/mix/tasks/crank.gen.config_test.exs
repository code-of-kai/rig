defmodule Mix.Tasks.Crank.Gen.ConfigTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Crank.Gen.Config

  # ── .credo.exs transformations ─────────────────────────────────────────────

  describe "update_credo_source/1 — credo file with no Crank wiring" do
    @vanilla_credo ~S"""
    %{
      configs: [
        %{
          name: "default",
          files: %{included: ["lib/"], excluded: []},
          plugins: [],
          requires: [],
          strict: false,
          parse_timeout: 5000,
          color: true,
          checks: %{
            enabled: [
              {Credo.Check.Readability.ModuleDoc, []}
            ],
            disabled: []
          }
        }
      ]
    }
    """

    test "wires Crank.Check.TurnPurity into enabled checks" do
      {new_source, change} = Config.update_credo_source(@vanilla_credo)

      assert String.contains?(new_source, "{Crank.Check.TurnPurity, []}")
      assert change != nil
    end

    test "does NOT add a requires: entry (check is loaded from compiled :crank app)" do
      {new_source, _change} = Config.update_credo_source(@vanilla_credo)

      refute String.contains?(new_source, ~s|"lib/crank/check/turn_purity.ex"|)
    end

    test "result still parses as valid Elixir" do
      {new_source, _} = Config.update_credo_source(@vanilla_credo)
      assert {:ok, _ast} = Code.string_to_quoted(new_source)
    end
  end

  describe "update_credo_source/1 — already-wired credo file" do
    @already_wired ~S"""
    %{
      configs: [
        %{
          name: "default",
          files: %{included: ["lib/"], excluded: []},
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

    test "produces no changes" do
      {new_source, change} = Config.update_credo_source(@already_wired)

      assert new_source == @already_wired
      assert change == nil
    end
  end

  # ── filesystem tests ───────────────────────────────────────────────────────

  describe "write_boundary_exs/2" do
    @tag :tmp_dir
    test "creates boundary.exs from the priv template", %{tmp_dir: tmp} do
      path = Path.join(tmp, "boundary.exs")

      [action | _] = Config.write_boundary_exs([], path)
      assert {:created, ^path, _} = action

      assert File.exists?(path)
      content = File.read!(path)
      assert String.contains?(content, "third_party_pure:")
      assert String.contains?(content, "third_party_impure:")
    end

    @tag :tmp_dir
    test "is a no-op when boundary.exs already exists", %{tmp_dir: tmp} do
      path = Path.join(tmp, "boundary.exs")
      File.write!(path, "[third_party_pure: [:decimal], third_party_impure: []]\n")

      [action | _] = Config.write_boundary_exs([], path)
      assert {:noop, ^path, _} = action

      assert File.read!(path) == "[third_party_pure: [:decimal], third_party_impure: []]\n"
    end
  end

  describe "wire_credo_exs/2" do
    @tag :tmp_dir
    test "creates a starter file when absent", %{tmp_dir: tmp} do
      path = Path.join(tmp, ".credo.exs")

      [action | _] = Config.wire_credo_exs([], path)
      assert {:created, ^path, _} = action
      assert File.exists?(path)

      content = File.read!(path)
      assert String.contains?(content, "Crank.Check.TurnPurity")
    end

    @tag :tmp_dir
    test "is a no-op when already wired", %{tmp_dir: tmp} do
      path = Path.join(tmp, ".credo.exs")

      File.write!(path, ~S"""
      %{
        configs: [
          %{
            name: "default",
            files: %{included: ["lib/"], excluded: []},
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
      """)

      original = File.read!(path)
      [action | _] = Config.wire_credo_exs([], path)
      assert {:noop, ^path, _} = action
      assert File.read!(path) == original
    end
  end

  # ── stdout snapshot ────────────────────────────────────────────────────────

  describe "mix_exs_snippet/0 — stdout block" do
    test "names :boundary and :crank deps with current major version" do
      snippet = Config.mix_exs_snippet()

      assert snippet =~ ~s|{:boundary, "~> 0.10"}|
      assert snippet =~ ~s|{:crank, "~> 2.0"}|
    end

    test "includes the :crank compiler and the :boundary classification keyword" do
      snippet = Config.mix_exs_snippet()

      assert snippet =~ "compilers: [:crank | Mix.compilers()]"
      assert snippet =~ "boundary:"
      assert snippet =~ "third_party_pure: []"
      assert snippet =~ "third_party_impure: []"
    end

    test "is plain text — no leading whitespace pollution that would break copy-paste" do
      snippet = Config.mix_exs_snippet()

      # The snippet starts with a single newline by design (separator from
      # the heading line). Lines are indented but consistently so.
      assert String.starts_with?(snippet, "\n")
      refute String.contains?(snippet, "\t")
    end
  end
end
