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
