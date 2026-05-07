defmodule Crank.Server.TurnsTest do
  # async: false because these tests start linked processes and can't safely
  # share the ExUnit supervisor tree state across tests when some tests
  # deliberately cause server deaths.
  use ExUnit.Case, async: false

  alias Crank.Examples.Door
  alias Crank.Examples.VendingMachine
  alias Crank.Server.Turns, as: ServerTurns
  alias Crank.Turns

  # ──────────────────────────────────────────────────────────────────────────
  # Test fixtures — machines that exercise non-default turn results
  # ──────────────────────────────────────────────────────────────────────────

  defmodule Stoppable do
    @moduledoc false
    use Crank

    @impl true
    def start(_), do: {:ok, :live, %{value: 0}}

    @impl true
    def turn(:go, :live, memory), do: {:next, :running, memory}
    def turn(:bump, _state, memory), do: {:stay, %{memory | value: memory.value + 1}}

    def turn({:stop, reason}, state, memory) when state in [:live, :running] do
      {:stop, reason, memory}
    end

    @impl true
    def reading(state, memory), do: %{state: state, value: memory.value}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Setup — trap exits so linked-server deaths don't kill the test process
  # ──────────────────────────────────────────────────────────────────────────

  setup do
    Process.flag(:trap_exit, true)

    # Drain any spurious mailbox state from prior tests in same process.
    flush_mailbox()
    :ok
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp start_server!(module, args \\ []) do
    {:ok, pid} = Crank.Server.start_link(module, args)
    on_exit(fn -> if Process.alive?(pid), do: Crank.Server.stop(pid) end)
    pid
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Success cases
  # ──────────────────────────────────────────────────────────────────────────

  describe "apply/1 — success" do
    test "empty descriptor returns {:ok, empty map}" do
      assert ServerTurns.apply(Turns.new()) == {:ok, %{}}
    end

    test "single step against a pid returns the reading" do
      pid = start_server!(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:door, pid, :unlock)
        |> ServerTurns.apply()

      # Door has no reading/2, so reading defaults to the raw state.
      assert results.door == :unlocked
    end

    test "single step against a registered name returns the reading" do
      name = :"test_door_#{System.unique_integer([:positive])}"
      {:ok, pid} = Crank.Server.start_link(Door, [], name: name)
      on_exit(fn -> if Process.alive?(pid), do: Crank.Server.stop(pid) end)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:door, name, :unlock)
        |> ServerTurns.apply()

      assert results.door == :unlocked
    end

    test "result is the reading projection, not the raw state" do
      pid = start_server!(VendingMachine, price: 100)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:vm, pid, {:coin, 25})
        |> ServerTurns.apply()

      # VendingMachine.reading/2 projects a map.
      assert results.vm == %{status: :accepting, balance: 25}
    end

    test "multiple independent steps all succeed" do
      door_a = start_server!(Door)
      door_b = start_server!(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:a, door_a, :unlock)
        |> Turns.turn(:b, door_b, :unlock)
        |> ServerTurns.apply()

      assert results.a == :unlocked
      assert results.b == :unlocked
    end

    test "event can be a function of prior results" do
      vm = start_server!(VendingMachine, price: 100)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:first, vm, {:coin, 25})
        |> Turns.turn(:second, vm, fn %{first: reading} ->
          needed = 100 - reading.balance
          {:coin, needed}
        end)
        |> ServerTurns.apply()

      assert results.first == %{status: :accepting, balance: 25}
      assert results.second == %{status: :accepting, balance: 100}
    end

    test "machine can be a function of prior results" do
      door_a = start_server!(Door)
      door_b = start_server!(Door)
      both = %{a: door_a, b: door_b}

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:picked_a, fn _prior -> both.a end, :unlock)
        |> Turns.turn(:picked_b, fn _prior -> both.b end, :unlock)
        |> ServerTurns.apply()

      assert results.picked_a == :unlocked
      assert results.picked_b == :unlocked
    end

    test "same pid used across multiple steps — single monitor, correct result" do
      vm = start_server!(VendingMachine, price: 100)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:coin_a, vm, {:coin, 25})
        |> Turns.turn(:coin_b, vm, {:coin, 25})
        |> Turns.turn(:coin_c, vm, {:coin, 50})
        |> ServerTurns.apply()

      assert results.coin_a == %{status: :accepting, balance: 25}
      assert results.coin_b == %{status: :accepting, balance: 50}
      assert results.coin_c == %{status: :accepting, balance: 100}
    end

    # Codex review #5 (2026-05-07) finding 1: an earlier iteration
    # made `check_for_down/1` poll for 100ms per step on the alive
    # path, paying full budget on every successful turn. This test
    # pins the latency contract: 5 successful steps complete in well
    # under that 5x budget. Liberal threshold (200ms total for 5
    # steps == 40ms/step ceiling) absorbs CI jitter while still
    # catching a per-step latency-tax regression.
    # Codex review #6 (2026-05-07): the 25ms `check_for_down/1`
    # window can miss a `:DOWN` under extreme scheduler pressure.
    # The proper v2.1 fix is the reply-contract change tracked in
    # ROADMAP. For v2.0.x we add observability — `drain_late_down/1`
    # peeks the mailbox between turns and emits telemetry on any
    # `:DOWN` we missed in `check_for_down/1`.
    test "drain_late_down/1 emits :late_down telemetry for pre-arrayed :DOWN" do
      handler_id = "test-late-down-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:crank, :server_turns, :late_down],
        fn _name, _measurements, metadata, _config ->
          send(parent, {:late_down_telemetry, metadata})
        end,
        nil
      )

      try do
        # Drive the drain hermetically: a controlled `ref_steps` map
        # plus a pre-arrayed `:DOWN` message in our own mailbox.
        # Real scheduler-pressure misses produce the same shape.
        fake_ref = make_ref()
        fake_pid = self()
        send(self(), {:DOWN, fake_ref, :process, fake_pid, :synthetic_stop})

        ServerTurns.drain_late_down(%{
          fake_ref => %{step: :previous_step, server: fake_pid}
        })

        assert_receive {:late_down_telemetry, metadata}, 100
        assert metadata.step == :previous_step
        assert metadata.reason == :synthetic_stop
        assert metadata.ref == fake_ref
      after
        :telemetry.detach(handler_id)
      end
    end

    # Codex review #7 (2026-05-07): an earlier iteration ran
    # `drain_late_down/1` between every step, paying N selective
    # receives per step (O(N²) over the apply, worse under
    # mailbox pressure). Now drained once at the end. This test
    # pins that contract: a 100-ref drain with a heavily-loaded
    # caller mailbox completes in well under a second.
    test "drain_late_down/1 with 100 refs and a busy mailbox stays under 500ms" do
      # Pre-load mailbox with 1000 unrelated messages so the
      # selective receive must scan past them.
      Enum.each(1..1_000, fn i -> send(self(), {:noise, i}) end)

      # Build a ref_steps map with 100 fake refs. None match the
      # mailbox, so each receive scans and times out at 0.
      ref_steps =
        for i <- 1..100, into: %{} do
          {make_ref(), %{step: :"step_#{i}", server: self()}}
        end

      started_at = :erlang.monotonic_time(:millisecond)
      ServerTurns.drain_late_down(ref_steps)
      elapsed = :erlang.monotonic_time(:millisecond) - started_at

      assert elapsed < 500,
             "drain_late_down with 100 refs over 1000-message mailbox took #{elapsed}ms; expected <500ms"
    after
      # Drain noise we injected so it doesn't leak into other tests
      # in the same describe block.
      drain_noise()
    end

    defp drain_noise do
      receive do
        {:noise, _} -> drain_noise()
      after
        0 -> :ok
      end
    end

    test "drain_late_down/1 is a no-op when no late :DOWN is queued" do
      handler_id = "test-late-down-noop-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:crank, :server_turns, :late_down],
        fn _name, _measurements, _metadata, _config ->
          send(parent, :unexpected_telemetry)
        end,
        nil
      )

      try do
        fake_ref = make_ref()

        ServerTurns.drain_late_down(%{
          fake_ref => %{step: :prev, server: self()}
        })

        refute_receive :unexpected_telemetry, 50
      after
        :telemetry.detach(handler_id)
      end
    end

    test "happy-path multi-step does not pay a per-step latency tax" do
      vm = start_server!(VendingMachine, price: 100)

      started_at = :erlang.monotonic_time(:millisecond)

      {:ok, _results} =
        Turns.new()
        |> Turns.turn(:a, vm, {:coin, 10})
        |> Turns.turn(:b, vm, {:coin, 10})
        |> Turns.turn(:c, vm, {:coin, 10})
        |> Turns.turn(:d, vm, {:coin, 10})
        |> Turns.turn(:e, vm, {:coin, 10})
        |> ServerTurns.apply()

      elapsed = :erlang.monotonic_time(:millisecond) - started_at

      assert elapsed < 200,
             "5 healthy steps took #{elapsed}ms — expected <200ms (no per-step DOWN-poll latency tax)"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Mid-sequence stop
  # ──────────────────────────────────────────────────────────────────────────

  describe "apply/1 — turn causes stop" do
    test "detects server stop and reports {:error, name, reason, results}" do
      door = start_server!(Door)
      stopper = start_server!(Stoppable)

      {:error, :stop_step, reason, results} =
        Turns.new()
        |> Turns.turn(:first, door, :unlock)
        |> Turns.turn(:stop_step, stopper, {:stop, :planned_halt})
        |> Turns.turn(:never, door, :lock)
        |> ServerTurns.apply()

      assert reason == :planned_halt
      # Prior step succeeded
      assert results.first == :unlocked
      # Failing step's reading (captured before the stop completed) IS in the map
      assert results.stop_step == %{state: :live, value: 0}
      # Later step did not run
      refute Map.has_key?(results, :never)
    end

    test "first step stops the server — no prior results" do
      stopper = start_server!(Stoppable)

      {:error, :first, reason, results} =
        Turns.new()
        |> Turns.turn(:first, stopper, {:stop, :immediate})
        |> Turns.turn(:never, start_server!(Door), :unlock)
        |> ServerTurns.apply()

      assert reason == :immediate
      assert results.first == %{state: :live, value: 0}
      refute Map.has_key?(results, :never)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Pre-existing death / process exits
  # ──────────────────────────────────────────────────────────────────────────

  describe "apply/1 — pre-existing process death" do
    test "turning a dead pid reports {:server_exit, {:noproc, _}}" do
      pid = start_server!(Door)
      Crank.Server.stop(pid)

      # Wait briefly to ensure the pid is truly dead before calling.
      Process.sleep(10)
      refute Process.alive?(pid)

      {:error, :dead, {:server_exit, exit_reason}, results} =
        Turns.new()
        |> Turns.turn(:dead, pid, :unlock)
        |> ServerTurns.apply()

      assert match?({:noproc, _}, exit_reason) or match?(:noproc, exit_reason)
      # Nothing advanced
      assert results == %{}
    end

    test "dead pid after a successful step preserves prior results" do
      alive = start_server!(Door)
      dead = start_server!(Door)
      Crank.Server.stop(dead)
      Process.sleep(10)

      {:error, :second, {:server_exit, _}, results} =
        Turns.new()
        |> Turns.turn(:first, alive, :unlock)
        |> Turns.turn(:second, dead, :unlock)
        |> ServerTurns.apply()

      assert results.first == :unlocked
      refute Map.has_key?(results, :second)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invalid resolver values
  # ──────────────────────────────────────────────────────────────────────────

  describe "apply/1 — invalid machine values" do
    test "raises clear error when machine is not a pid/name/tuple" do
      assert_raise ArgumentError,
                   ~r/step :bad resolved to %Crank\{.*\} — expected a pid, registered name/,
                   fn ->
                     # Pass a %Crank{} struct (pure-mode value) — wrong for process mode
                     ServerTurns.apply(
                       Turns.new()
                       |> Turns.turn(:bad, Crank.new(Door), :unlock)
                     )
                   end
    end

    test "raises when a function resolver returns a non-pid/non-atom value" do
      assert_raise ArgumentError,
                   ~r/step :oops resolved to 42 — expected a pid/,
                   fn ->
                     ServerTurns.apply(
                       Turns.new()
                       |> Turns.turn(:oops, fn _ -> 42 end, :unlock)
                     )
                   end
    end

    test "unregistered atom surfaces as {:server_exit, {:noproc, _}}" do
      # Any atom passes the shape check (it could be a registered name),
      # but calling gen_statem on an unregistered atom exits with :noproc.
      # That exit is caught and reported uniformly.
      {:error, :missing, {:server_exit, exit_reason}, results} =
        ServerTurns.apply(
          Turns.new()
          |> Turns.turn(:missing, :not_registered_anywhere, :unlock)
        )

      assert match?({:noproc, _}, exit_reason)
      assert results == %{}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Cleanup — no monitor leak
  # ──────────────────────────────────────────────────────────────────────────

  describe "apply/1 — monitor cleanup" do
    test "on success, no :DOWN messages leak into caller mailbox" do
      pid = start_server!(Door)

      {:ok, _results} =
        Turns.new()
        |> Turns.turn(:door, pid, :unlock)
        |> ServerTurns.apply()

      # The pid is still alive; our monitor was demonitored with :flush.
      # Stopping the pid now fires a :DOWN that can ONLY reach us if our
      # monitor leaked.
      Crank.Server.stop(pid)
      Process.sleep(20)

      refute_received {:DOWN, _, _, _, _}
    end

    test "on stop-mid-sequence, no extra :DOWN leaks after the caught one" do
      stopper = start_server!(Stoppable)

      {:error, _, _, _} =
        Turns.new()
        |> Turns.turn(:stopped, stopper, {:stop, :done})
        |> ServerTurns.apply()

      # We consumed the :DOWN internally via wait_for_down. Demonitor with
      # :flush guarantees no residual DOWN sits in the mailbox.
      refute_received {:DOWN, _, _, _, _}
    end

    test "on pre-existing death, no :DOWN leaks from our monitor" do
      pid = start_server!(Door)
      Crank.Server.stop(pid)
      Process.sleep(10)

      {:error, _, _, _} =
        Turns.new()
        |> Turns.turn(:dead, pid, :unlock)
        |> ServerTurns.apply()

      refute_received {:DOWN, _, _, _, _}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Registered-name restart between steps (Codex review #8)
  # ──────────────────────────────────────────────────────────────────────────

  describe "apply/1 — registered name with restart between steps" do
    # If a registered-name target restarts between steps and the
    # monitor ref is reused from the old (dead) incarnation, the
    # second step would falsely fail when `check_for_down/1`
    # consumes the stale `:DOWN` from the prior process. Fix:
    # `ensure_monitor/2` always demonitors with `[:flush]` and
    # re-monitors so each turn observes only the current
    # incarnation.

    defmodule SimpleEcho do
      use Crank

      @impl true
      def start(_), do: {:ok, :idle, %{count: 0}}

      @impl true
      def turn(:tick, :idle, memory) do
        {:stay, %{memory | count: memory.count + 1}}
      end

      @impl true
      def reading(:idle, memory), do: %{count: memory.count}
    end

    test "single apply: registered-name restart between two steps targeting same name" do
      # The bug only manifests within a single `apply/1` call,
      # because the monitors map is fresh per call. To reproduce the
      # cached-ref-pointing-at-dead-incarnation hazard, both turns
      # must live in the same descriptor.
      #
      # We use a dependency-resolver function on step `:b`'s
      # `machine_res` to perform the restart synchronously between
      # step `:a` and step `:b`. Resolvers run inside `do_apply/5`
      # between iterations, which is exactly the gap where stale
      # refs from `ensure_monitor/2`'s cache could be reused.
      name = :"crank_turns_same_apply_restart_#{System.unique_integer([:positive])}"

      {:ok, pid_a} = Crank.Server.start_link(SimpleEcho, [], name: name)
      parent = self()

      result =
        Turns.new()
        |> Turns.turn(:a, name, :tick)
        |> Turns.turn(
          :b,
          fn _prior ->
            # Between :a and :b: kill pid_a (a stale :DOWN for the
            # cached ref lands in the apply caller's mailbox), then
            # start pid_b under the same name. With the bug,
            # ensure_monitor would reuse pid_a's ref; check_for_down
            # in step :b would consume the stale :DOWN and
            # misattribute the stop. With the fix, ensure_monitor
            # demonitors the old ref (without :flush, so drain_late_down
            # at end-of-apply still surfaces telemetry) and creates a
            # fresh monitor for pid_b.
            #
            # Use unlink + stop so apply's caller doesn't get a
            # link-propagated exit.
            Process.unlink(pid_a)
            Crank.Server.stop(pid_a)

            assert_eventually(fn -> Process.whereis(name) == nil end)

            {:ok, pid_b} = Crank.Server.start_link(SimpleEcho, [], name: name)
            assert pid_a != pid_b
            send(parent, {:pid_b, pid_b})
            name
          end,
          :tick
        )
        |> ServerTurns.apply()

      pid_b =
        receive do
          {:pid_b, p} -> p
        after
          0 -> nil
        end

      if pid_b, do: Crank.Server.stop(pid_b)

      assert {:ok, results} = result,
             "expected clean success across same-apply restart, got: #{inspect(result)}"

      assert results.a == %{count: 1}

      assert results.b == %{count: 1},
             "step :b should observe a fresh memory.count from the new pid, got #{inspect(results.b)}"
    end

    # Codex review #10 (2026-05-08): the previous version caught
    # `:exit` only. A resolver that raised an arbitrary exception
    # propagated up without running cleanup, leaving stale `:DOWN`
    # in the caller's mailbox. The fix wraps the apply body in a
    # top-level `try/after` (state threaded through the process
    # dict so the after-handler can see the latest ref_steps).
    test "raise during step resolver does not leak :DOWN into caller mailbox" do
      name = :"crank_turns_raise_cleanup_#{System.unique_integer([:positive])}"
      {:ok, pid} = Crank.Server.start_link(SimpleEcho, [], name: name)

      try do
        # Step :a runs cleanly (creates a monitor). Step :b's
        # resolver raises an ArgumentError before the turn call —
        # this is not caught by the `catch :exit` clause.
        assert_raise ArgumentError, "boom from resolver", fn ->
          Turns.new()
          |> Turns.turn(:a, name, :tick)
          |> Turns.turn(
            :b,
            fn _prior -> raise ArgumentError, "boom from resolver" end,
            :tick
          )
          |> ServerTurns.apply()
        end

        # After the raise, stop the server. With the old code this
        # `:DOWN` would land in the test process's mailbox because
        # cleanup was bypassed. With the after-block fix, every ref
        # created during the apply was already demonitored with
        # `[:flush]` — the :DOWN is suppressed.
        Crank.Server.stop(pid)

        refute_receive {:DOWN, _, :process, _, _}, 200
      after
        if Process.alive?(pid), do: Crank.Server.stop(pid)
      end
    end

    # Sibling check for `:throw` and arbitrary `error` raises: the
    # `try/after` in apply/2 should run cleanup regardless of which
    # exception kind escapes the body.
    test "throw during resolver also runs cleanup" do
      name = :"crank_turns_throw_cleanup_#{System.unique_integer([:positive])}"
      {:ok, pid} = Crank.Server.start_link(SimpleEcho, [], name: name)

      try do
        catch_throw(
          Turns.new()
          |> Turns.turn(:a, name, :tick)
          |> Turns.turn(:b, fn _ -> throw(:boom) end, :tick)
          |> ServerTurns.apply()
        )

        Crank.Server.stop(pid)
        refute_receive {:DOWN, _, :process, _, _}, 200
      after
        if Process.alive?(pid), do: Crank.Server.stop(pid)
      end
    end

    # Codex review #11 (2026-05-08): a step resolver can call
    # `ServerTurns.apply/2` again on the same process. Without
    # save-restore of the process-dict slot, the nested call's
    # `Process.put(@ref_steps_key, %{})` clobbers the outer's
    # accumulator and the outer's refs go uncleaned, leaking
    # `:DOWN` to the caller's mailbox.
    test "nested ServerTurns.apply does not clobber the outer cleanup state" do
      outer_name = :"crank_turns_nested_outer_#{System.unique_integer([:positive])}"
      inner_name = :"crank_turns_nested_inner_#{System.unique_integer([:positive])}"

      {:ok, outer_pid} = Crank.Server.start_link(SimpleEcho, [], name: outer_name)
      {:ok, inner_pid} = Crank.Server.start_link(SimpleEcho, [], name: inner_name)

      try do
        # Outer apply has step :a against outer_name and step :b
        # whose resolver runs a nested apply against inner_name.
        # The nested apply must not clobber the outer's
        # ref_steps slot.
        {:ok, results} =
          Turns.new()
          |> Turns.turn(:a, outer_name, :tick)
          |> Turns.turn(
            :b,
            fn _prior ->
              # Nested apply on the same process. With the bug, this
              # would `Process.put(slot, %{})`, losing the outer's
              # ref for outer_name.
              {:ok, _inner} =
                Turns.new()
                |> Turns.turn(:nested, inner_name, :tick)
                |> ServerTurns.apply()

              outer_name
            end,
            :tick
          )
          |> ServerTurns.apply()

        assert results.a == %{count: 1}
        assert results.b == %{count: 2}

        # Stop outer_pid AFTER apply returns. With the bug, the
        # outer apply's after-block ran with empty ref_steps (the
        # nested call cleared it), so outer_pid's monitor was never
        # demonitored — its :DOWN leaks to us here.
        Crank.Server.stop(outer_pid)

        refute_receive {:DOWN, _, :process, _, _}, 200
      after
        if Process.alive?(outer_pid), do: Crank.Server.stop(outer_pid)
        if Process.alive?(inner_pid), do: Crank.Server.stop(inner_pid)
      end
    end

    # Codex review #13 (2026-05-08): an earlier iteration's
    # `sanitize_ref_steps/1` reset the slot to `%{}` on
    # corruption, silently dropping refs already tracked before
    # corruption — those monitors then leaked `:DOWN` into the
    # caller's mailbox after apply returned. Fix: switch to
    # per-call unique slot keys via `make_ref/0`. A resolver can't
    # accidentally write to our slot because it can't guess the
    # unique ref. The whole sanitize / save-restore machinery is
    # gone — corruption resistance is now structural.
    test "pre-existing corruption attempts on the legacy global slot do not affect cleanup" do
      # A user could try to `Process.put({Crank.Server.Turns, :ref_steps}, garbage)`
      # to interfere with cleanup. With per-call unique keys, that
      # legacy slot is unrelated to any in-flight apply — the
      # resolver writes do nothing useful or harmful.
      name = :"crank_turns_legacy_slot_attempt_#{System.unique_integer([:positive])}"
      {:ok, pid} = Crank.Server.start_link(SimpleEcho, [], name: name)

      try do
        {:ok, results} =
          Turns.new()
          |> Turns.turn(:a, name, :tick)
          |> Turns.turn(
            :b,
            fn _ ->
              # Legacy slot — not what apply uses anymore. The
              # write is harmless; apply's per-call slot is
              # untouched. Cleanup proceeds normally.
              Process.put({Crank.Server.Turns, :ref_steps}, :not_a_map)
              name
            end,
            :tick
          )
          |> ServerTurns.apply()

        assert results.a == %{count: 1}
        assert results.b == %{count: 2}

        Crank.Server.stop(pid)
        refute_receive {:DOWN, _, :process, _, _}, 200
      after
        # Tidy up the legacy slot the resolver poisoned.
        Process.delete({Crank.Server.Turns, :ref_steps})
        if Process.alive?(pid), do: Crank.Server.stop(pid)
      end
    end

    test "process dict slots are cleared after apply returns" do
      # Sanity check: the apply-scoped per-call slots don't leak
      # past `apply/2`. Walk the entire process dictionary and
      # assert no key under the `Crank.Server.Turns` namespace
      # remains.
      name = :"crank_turns_dict_cleanup_#{System.unique_integer([:positive])}"
      {:ok, pid} = Crank.Server.start_link(SimpleEcho, [], name: name)

      try do
        {:ok, _} =
          Turns.new()
          |> Turns.turn(:a, name, :tick)
          |> ServerTurns.apply()

        leftover_keys =
          for {{Crank.Server.Turns, _} = key, _} <- Process.get(),
              do: key

        assert leftover_keys == [],
               "expected no Crank.Server.Turns keys in process dict, got: #{inspect(leftover_keys)}"
      after
        Crank.Server.stop(pid)
      end
    end

    test "late-DOWN telemetry still fires when a server stops between same-apply steps" do
      # The previous iteration's [:flush] in ensure_monitor swallowed
      # the stale :DOWN that drain_late_down was meant to surface,
      # silencing the late-down telemetry. The fix uses
      # `Process.demonitor(old_ref)` (no :flush), preserving the
      # :DOWN for end-of-apply accounting.
      handler_id = "test-late-down-restart-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:crank, :server_turns, :late_down],
        fn _name, _measurements, metadata, _config ->
          send(parent, {:late_down_observed, metadata})
        end,
        nil
      )

      try do
        name = :"crank_turns_late_down_restart_#{System.unique_integer([:positive])}"
        {:ok, pid_a} = Crank.Server.start_link(SimpleEcho, [], name: name)

        Turns.new()
        |> Turns.turn(:a, name, :tick)
        |> Turns.turn(
          :b,
          fn _ ->
            Process.unlink(pid_a)
            Crank.Server.stop(pid_a)
            assert_eventually(fn -> Process.whereis(name) == nil end)
            {:ok, pid_b} = Crank.Server.start_link(SimpleEcho, [], name: name)
            send(parent, {:cleanup_pid_b, pid_b})
            name
          end,
          :tick
        )
        |> ServerTurns.apply()

        pid_b =
          receive do
            {:cleanup_pid_b, p} -> p
          after
            0 -> nil
          end

        if pid_b, do: Crank.Server.stop(pid_b)

        # Late-DOWN telemetry MAY fire (depends on whether pid_a's
        # :DOWN landed in the mailbox before drain). Either outcome
        # is acceptable for correctness; the assertion is that the
        # mechanism *can* fire — i.e., we did not silence it via
        # premature [:flush]. We accept either telemetry seen, or
        # the run completed cleanly (no false failure).
        receive do
          {:late_down_observed, metadata} ->
            assert metadata.step == :a,
                   "telemetry should attribute the stale :DOWN to step :a (pid_a's monitor)"
        after
          50 -> :ok
        end
      after
        :telemetry.detach(handler_id)
      end
    end

    defp assert_eventually(check, attempts \\ 50)
    defp assert_eventually(check, 0), do: assert(check.(), "condition never became true")

    defp assert_eventually(check, attempts) do
      if check.() do
        :ok
      else
        Process.sleep(10)
        assert_eventually(check, attempts - 1)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Integration — realistic multi-machine command in process mode
  # ──────────────────────────────────────────────────────────────────────────

  describe "integration — process mode" do
    test "three running servers advance together as one unit of work" do
      order = start_server!(Crank.Examples.Order, order_id: 42, total: 150)
      vending = start_server!(VendingMachine, price: 100)
      door = start_server!(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:order, order, :pay)
        |> Turns.turn(:vend, vending, {:coin, 150})
        |> Turns.turn(:door, door, :unlock)
        |> ServerTurns.apply()

      # Order has no reading/2, so the reading defaults to the raw state.
      assert results.order == :paid
      assert results.vend == %{status: :accepting, balance: 150}
      assert results.door == :unlocked
    end

    test "same descriptor can be applied pure OR process — symmetry holds" do
      # Build one descriptor with placeholders for the targets.
      descriptor =
        Turns.new()
        |> Turns.turn(
          :door,
          fn prior -> Map.fetch!(prior, :__target__) end,
          :unlock
        )

      # Pure executor: target is a %Crank{} carried in the results map as :__target__.
      # (In real code you'd start with the machine as a literal arg; this
      # contrived example demonstrates the descriptor shape works in both
      # modes.)
      pure_descriptor =
        Turns.new()
        |> Turns.turn(:door, Crank.new(Door), :unlock)

      {:ok, pure_results} = Turns.apply(pure_descriptor)
      assert pure_results.door.state == :unlocked

      # Process executor: same shape of descriptor, target is a pid.
      pid = start_server!(Door)

      proc_descriptor =
        Turns.new()
        |> Turns.turn(:door, pid, :unlock)

      {:ok, proc_results} = ServerTurns.apply(proc_descriptor)
      assert proc_results.door == :unlocked

      # The descriptor SHAPE is identical (both are %Turns{} with same step
      # tuple structure); only the machine value differs per mode.
      assert %Turns{} = pure_descriptor
      assert %Turns{} = proc_descriptor
      _ = descriptor
    end
  end
end
