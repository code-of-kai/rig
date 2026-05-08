defmodule Crank.Check.CompileTimeTest do
  use ExUnit.Case, async: true

  describe "@before_compile hook on `use Crank`" do
    test "pure module compiles cleanly" do
      module_source = """
      defmodule CompileTimeTest.Pure do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          {:next, :active, memory}
        end

        @impl true
        def turn(_event, :active, memory) do
          {:stay, memory}
        end
      end
      """

      assert {{:module, CompileTimeTest.Pure, _, _}, _} = Code.eval_string(module_source)
    after
      :code.purge(CompileTimeTest.Pure)
      :code.delete(CompileTimeTest.Pure)
    end

    test "module with Repo.insert! inside turn/3 fails to compile with CRANK_PURITY_001" do
      module_source = """
      defmodule CompileTimeTest.ImpureRepo do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          _ = Repo.insert!(%{foo: :bar})
          {:next, :active, memory}
        end
      end
      """

      assert_raise CompileError, ~r/CRANK_PURITY_001/, fn ->
        Code.eval_string(module_source)
      end
    end

    # Phoenix-convention namespaced Repo: `MyApp.Repo.insert!` should
    # also fail compile. Without the terminal-segment match in
    # `Crank.Check.Blacklist`, this would silently pass.
    test "module with MyApp.Repo.insert! inside turn/3 fails to compile with CRANK_PURITY_001" do
      module_source = """
      defmodule CompileTimeTest.ImpureMyAppRepo do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          _ = MyApp.Repo.insert!(%{foo: :bar})
          {:next, :active, memory}
        end
      end
      """

      assert_raise CompileError, ~r/CRANK_PURITY_001/, fn ->
        Code.eval_string(module_source)
      end
    end

    test "module with MyApp.Mailer.deliver inside turn/3 fails to compile with CRANK_PURITY_001" do
      module_source = """
      defmodule CompileTimeTest.ImpureMyAppMailer do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          _ = MyApp.Mailer.deliver(%{to: "x@example.com"})
          {:next, :active, memory}
        end
      end
      """

      assert_raise CompileError, ~r/CRANK_PURITY_001/, fn ->
        Code.eval_string(module_source)
      end
    end

    test "module with DateTime.utc_now/0 inside turn/3 fails with CRANK_PURITY_004" do
      module_source = """
      defmodule CompileTimeTest.ImpureNonDeterminism do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          now = DateTime.utc_now()
          {:next, :active, Map.put(memory, :now, now)}
        end
      end
      """

      assert_raise CompileError, ~r/CRANK_PURITY_004/, fn ->
        Code.eval_string(module_source)
      end
    end

    test "module with Logger.info inside turn/3 fails with CRANK_PURITY_003" do
      module_source = """
      defmodule CompileTimeTest.ImpureLogger do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          Logger.info("transitioning")
          {:next, :active, memory}
        end
      end
      """

      assert_raise CompileError, ~r/CRANK_PURITY_003/, fn ->
        Code.eval_string(module_source)
      end
    end

    test "module with `# crank-allow:` suppresses the violation and compiles cleanly" do
      # Suppression parsing reads the source file from disk via env.file,
      # so this fixture must live on disk (not eval_string-inline).
      module_source = """
      defmodule CompileTimeTest.SuppressedImpurity do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          # crank-allow: CRANK_PURITY_004
          # reason: integration test fixture; production sets via event payload
          now = DateTime.utc_now()
          {:next, :active, Map.put(memory, :now, now)}
        end
      end
      """

      path = Path.join(System.tmp_dir!(), "crank_suppression_test_#{:erlang.unique_integer([:positive])}.ex")
      File.write!(path, module_source)

      try do
        modules = Code.compile_file(path)
        assert is_list(modules)
        assert {CompileTimeTest.SuppressedImpurity, _bytecode} =
                 Enum.find(modules, fn {m, _} -> m == CompileTimeTest.SuppressedImpurity end)
      after
        File.rm(path)
        :code.purge(CompileTimeTest.SuppressedImpurity)
        :code.delete(CompileTimeTest.SuppressedImpurity)
      end
    end

    test "malformed suppression (missing reason) fails compile with CRANK_META_001" do
      # Codex review #28 (2026-05-08): meta-violations were parsed by
      # `Suppressions.parse/1` but discarded by both compile-time and
      # Credo paths. The catalog documented CRANK_META_001..004 but no
      # check actually enforced them, so a malformed suppression
      # silently accepted broken syntax. Now compile_time.ex prepends
      # meta_violations to its violations list and raises on the first
      # one — same pipeline as substantive violations.
      module_source = """
      defmodule CompileTimeTest.MalformedSuppression do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          # crank-allow: CRANK_PURITY_004
          # NOTE: missing required `# reason:` line — should fire CRANK_META_001
          now = DateTime.utc_now()
          {:next, :active, Map.put(memory, :now, now)}
        end
      end
      """

      path = Path.join(System.tmp_dir!(), "crank_meta_test_#{:erlang.unique_integer([:positive])}.ex")
      File.write!(path, module_source)

      try do
        assert_raise CompileError, ~r/CRANK_META_001/, fn ->
          Code.compile_file(path)
        end
      after
        File.rm(path)
      end
    end

    test "wrong-layer suppression (CRANK_DEP_*) fails compile with CRANK_META_004" do
      module_source = """
      defmodule CompileTimeTest.WrongLayerSuppression do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          # crank-allow: CRANK_DEP_001
          # reason: trying to suppress topology code at source layer
          {:next, :active, memory}
        end
      end
      """

      path = Path.join(System.tmp_dir!(), "crank_meta_test_#{:erlang.unique_integer([:positive])}.ex")
      File.write!(path, module_source)

      try do
        assert_raise CompileError, ~r/CRANK_META_004/, fn ->
          Code.compile_file(path)
        end
      after
        File.rm(path)
      end
    end

    test "non-Crank module is not subject to the check" do
      module_source = """
      defmodule CompileTimeTest.NotACrank do
        def some_function(memory) do
          now = DateTime.utc_now()
          Map.put(memory, :now, now)
        end
      end
      """

      assert {{:module, CompileTimeTest.NotACrank, _, _}, _} = Code.eval_string(module_source)
    after
      :code.purge(CompileTimeTest.NotACrank)
      :code.delete(CompileTimeTest.NotACrank)
    end

    test "calls outside turn/3 in a Crank module are not flagged (only turn/3 bodies checked)" do
      # The @before_compile hook checks turn/3 clause bodies. Other functions
      # in a `use Crank` module are not domain-pure unless the module is also
      # marked `Crank.Domain.Pure` (Stage 5). This test pins the v4-corrected
      # scope: 1.3 is local-to-turn/3 only.
      module_source = """
      defmodule CompileTimeTest.OnlyTurnIsChecked do
        use Crank

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory) do
          {:next, :active, memory}
        end

        # This function is NOT inside turn/3 and NOT marked domain-pure,
        # so it should not be flagged by @before_compile.
        def helper_function do
          DateTime.utc_now()
        end
      end
      """

      assert {{:module, CompileTimeTest.OnlyTurnIsChecked, _, _}, _} = Code.eval_string(module_source)
    after
      :code.purge(CompileTimeTest.OnlyTurnIsChecked)
      :code.delete(CompileTimeTest.OnlyTurnIsChecked)
    end
  end
end
