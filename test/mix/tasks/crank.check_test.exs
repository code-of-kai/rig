defmodule Mix.Tasks.Crank.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Crank.Check

  describe "check_setup/1" do
    test "fails with CRANK_SETUP_001 when :crank not in :compilers" do
      Mix.Project.push(__MODULE__.NoCompilerProject, "fake/mix.exs")

      try do
        capture_io(fn -> assert {:error, 1, "CRANK_SETUP_001"} = Check.check_setup([]) end)
      after
        Mix.Project.pop()
      end
    end

    test "fails with CRANK_SETUP_002 when synthetic OTP < minimum" do
      Mix.Project.push(__MODULE__.WiredProject, "fake/mix.exs")

      try do
        capture_io(fn ->
          assert {:error, 1, "CRANK_SETUP_002"} = Check.check_setup(otp_release: 25)
        end)
      after
        Mix.Project.pop()
      end
    end

    test "passes when :crank is wired and OTP >= minimum" do
      Mix.Project.push(__MODULE__.WiredProject, "fake/mix.exs")

      try do
        assert :ok = Check.check_setup(otp_release: 26)
      after
        Mix.Project.pop()
      end
    end

    # Codex review #25 (2026-05-08): the previous check_setup only
    # validated `:crank in compilers` membership, accepting projects
    # that appended `:crank` AFTER `:elixir`/`:app` — which causes
    # `Mix.Tasks.Compile.Crank`'s `after_compiler` hooks to register
    # too late and topology enforcement to be silently inert.
    test "fails with CRANK_SETUP_001 when :crank is positioned after :elixir" do
      Mix.Project.push(__MODULE__.AppendedAfterElixirProject, "fake/mix.exs")

      try do
        capture_io(fn ->
          assert {:error, 1, "CRANK_SETUP_001"} = Check.check_setup([])
        end)
      after
        Mix.Project.pop()
      end
    end

    test "fails with CRANK_SETUP_001 when :crank is positioned after :app" do
      Mix.Project.push(__MODULE__.AppendedAfterAppProject, "fake/mix.exs")

      try do
        capture_io(fn ->
          assert {:error, 1, "CRANK_SETUP_001"} = Check.check_setup([])
        end)
      after
        Mix.Project.pop()
      end
    end

    test "passes when :crank is positioned correctly (prepend pattern)" do
      Mix.Project.push(__MODULE__.PrependedProject, "fake/mix.exs")

      try do
        assert :ok = Check.check_setup(otp_release: 26)
      after
        Mix.Project.pop()
      end
    end
  end

  defmodule WiredProject do
    def project do
      [
        app: :wired,
        version: "0.1.0",
        compilers: [:crank | Mix.compilers()]
      ]
    end
  end

  defmodule NoCompilerProject do
    def project do
      [
        app: :unwired,
        version: "0.1.0"
      ]
    end
  end

  defmodule AppendedAfterElixirProject do
    def project do
      [
        app: :appended_elixir,
        version: "0.1.0",
        compilers: [:elixir, :crank, :app]
      ]
    end
  end

  defmodule AppendedAfterAppProject do
    def project do
      [
        app: :appended_app,
        version: "0.1.0",
        # The bad-docs pattern: `Mix.compilers() ++ [:crank]`
        compilers: [:elixir, :app, :crank]
      ]
    end
  end

  defmodule PrependedProject do
    def project do
      [
        app: :prepended,
        version: "0.1.0",
        compilers: [:crank, :elixir, :app]
      ]
    end
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
