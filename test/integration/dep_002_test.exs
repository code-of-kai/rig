defmodule Crank.Integration.Dep002Test do
  @moduledoc """
  End-to-end test for `CRANK_DEP_002` — unmarked first-party helper
  called from a Crank-domain module.

  Stages a consumer mix project where:
    * a `use Crank` module references a first-party helper
    * the helper is plain Elixir (no `use Crank.Domain.Pure`, no
      `use Boundary`)

  Expected: `mix compile` surfaces `CRANK_DEP_002` naming the helper.
  This was the documented-but-unreachable code path that the second
  Codex review surfaced; the test pins the emission so a regression
  removes the diagnostic visibly.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  test "domain calls unmarked first-party helper -> CRANK_DEP_002" do
    crank_root = Path.expand(Path.join(__DIR__, "../.."))
    project_dir = stage_project!(crank_root)

    on_exit(fn -> archive_dir(project_dir) end)

    {get_output, get_exit} =
      System.cmd("mix", ["deps.get"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert get_exit == 0, "mix deps.get failed: #{get_output}"

    {compile_output, _exit_code} =
      System.cmd("mix", ["compile", "--force"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert compile_output =~ "[CRANK_DEP_002]",
           "expected CRANK_DEP_002 in compile output, got:\n#{compile_output}"

    assert compile_output =~ "UnmarkedHelper",
           "expected UnmarkedHelper named in the diagnostic, got:\n#{compile_output}"
  end

  defp stage_project!(crank_root) do
    dir = Path.join(System.tmp_dir!(), "crank_dep_002_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule TestApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :test_app_dep_002,
          version: "0.1.0",
          elixir: "~> 1.15",
          compilers: [:crank] ++ Mix.compilers(),
          deps: [{:crank, path: #{inspect(crank_root)}}]
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """)

    # The unmarked helper — plain Elixir, no `use Crank.Domain.Pure`,
    # no `use Boundary`. This is the situation CRANK_DEP_002 names.
    File.write!(Path.join([dir, "lib", "unmarked_helper.ex"]), """
    defmodule UnmarkedHelper do
      def add(a, b), do: a + b
    end
    """)

    # The Crank-domain module that calls the unmarked helper.
    File.write!(Path.join([dir, "lib", "calling_domain.ex"]), """
    defmodule CallingDomain do
      use Crank

      @impl true
      def start(_), do: {:ok, :idle, %{value: 0}}

      @impl true
      def turn({:bump, x, y}, :idle, memory) do
        {:stay, %{memory | value: UnmarkedHelper.add(x, y)}}
      end
    end
    """)

    dir
  end

  defp archive_dir(dir) do
    archive_root = Path.join(System.tmp_dir!(), "crank_integration_archive")
    File.mkdir_p!(archive_root)
    target = Path.join(archive_root, Path.basename(dir))
    _ = File.rename(dir, target)
    :ok
  end
end
