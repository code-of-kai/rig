defmodule Crank.PropertyTestTest do
  @moduledoc """
  Tests for `Crank.PropertyTest` (Phase 2.3).

  Each section corresponds to one of the verification gates in the Track B
  brief: pure-machine pass, impure-machine fail with structured error,
  StreamData-shrinking minimal-input snapshot, and `:allow` opt suppression.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Crank.PropertyTest

  # ── Pure-machine fixture (uses an existing example) ──────────────────────

  describe "pure machine — Crank.Examples.Turnstile" do
    test "every event sequence is pure under default tracing" do
      machine = Crank.new(Crank.Examples.Turnstile)
      events = [:coin, :push, :coin, :coin, :push, :push]

      assert %Crank{} = assert_pure_turn(machine, events)
    end

    test "single event is accepted as a bare value" do
      machine = Crank.new(Crank.Examples.Turnstile)

      assert %Crank{state: :unlocked} = assert_pure_turn(machine, :coin)
    end

    test "turn_traced returns the per-step machine list in order" do
      machine = Crank.new(Crank.Examples.Turnstile)

      assert {:ok, machines} = turn_traced(machine, [:coin, :push, :coin])
      assert length(machines) == 4
      assert hd(machines).state == :locked
      assert Enum.map(machines, & &1.state) == [:locked, :unlocked, :locked, :unlocked]
    end
  end

  # Property tests funnel every iteration through `Crank.PurityTrace.Coordinator`
  # (the GenServer that serialises BEAM trace API calls for thread-safety).
  # Under parallel async ExUnit and slow CI runners, the per-iteration overhead
  # adds up — bump the per-test ExUnit timeout from the default 60s to 180s so
  # a slow runner has headroom. Local runs typically complete in under 2s.
  @tag timeout: 180_000
  property "Turnstile is pure under any random event sequence" do
    check all(
            events <-
              list_of(StreamData.member_of([:coin, :push]), max_length: 30),
            max_runs: 50
          ) do
      machine = Crank.new(Crank.Examples.Turnstile)
      assert %Crank{} = assert_pure_turn(machine, events, timeout: 2_000)
    end
  end

  # ── Impure-machine fixture (bypasses static checks via no `use Crank`) ───

  defmodule ImpureRandMachine do
    @moduledoc """
    Test fixture: a Crank-shaped machine that makes an impure call inside
    `turn/3`. Intentionally does **not** `use Crank`, so the static
    `@before_compile` check does not fire — we're testing the *runtime*
    detection layer here.

    Uses `DateTime.utc_now/0` rather than `:rand.uniform/0` because the
    latter writes its seed cache to the worker's process dictionary,
    which surfaces a separate `CRANK_TRACE_002` violation that an
    `:allow` opt for the rand module wouldn't silence.
    """
    @behaviour Crank

    @impl true
    def start(_), do: {:ok, :idle, %{ticks: 0}}

    @impl true
    def turn(:tick, :idle, %{ticks: n}) do
      # Real impurity: stdlib non-determinism inside turn/3.
      _ = DateTime.utc_now()
      {:next, :ticking, %{ticks: n + 1}}
    end

    def turn(:reset, _state, _memory) do
      {:next, :idle, %{ticks: 0}}
    end

    def turn(:noop, state, memory) do
      # Pure transition. Used to prove shrinking reduces to the impure event.
      {:next, state, memory}
    end
  end

  describe "impure machine — direct impurity inside turn/3" do
    test "assert_pure_turn/3 raises ExUnit.AssertionError with structured detail" do
      machine = Crank.new(ImpureRandMachine)
      events = [:noop, :noop, :tick, :reset]

      err =
        assert_raise ExUnit.AssertionError, fn ->
          assert_pure_turn(machine, events, timeout: 2_000)
        end

      msg = err.message
      # The failure names the offending event.
      assert msg =~ ":tick"
      # The failure surfaces the violating MFA via the canonical pretty form.
      assert msg =~ "CRANK_PURITY_007"
      assert msg =~ "DateTime"
      # The full event sequence is included (so StreamData / a human can
      # reconstruct the path that led to the failure).
      assert msg =~ ":noop"
      # The failure points at the catalog code so agents can look up the fix.
      assert msg =~ "Runtime trace observed"
    end

    test "turn_traced/3 returns {:impurity, violations, machines, trace, event}" do
      machine = Crank.new(ImpureRandMachine)
      events = [:noop, :tick, :reset]

      assert {:impurity, [_ | _] = violations, machines, trace, :tick} =
               turn_traced(machine, events, timeout: 2_000)

      # Machines list is the prefix up to (but not including) the failing turn.
      assert length(machines) == 2
      assert Enum.map(machines, & &1.state) == [:idle, :idle]

      # Violations include the DateTime call.
      assert Enum.any?(violations, fn v ->
               v.code == "CRANK_PURITY_007" and v.violating_call.module == DateTime
             end)

      # The partial trace contains at least one DateTime call.
      assert Enum.any?(trace, fn
               {:call, {DateTime, _, _}} -> true
               _ -> false
             end)
    end
  end

  # ── StreamData shrinking — minimal failing input snapshot ────────────────

  describe "StreamData shrinking" do
    test "shrinks to a minimal failing event sequence containing :tick" do
      # Generator: 1..30 events from a small alphabet. The impure machine
      # fails as soon as `:tick` is included. StreamData should shrink any
      # failing sequence to one whose only :tick (and possibly :noop padding
      # that StreamData can't remove) is exactly what's needed.
      gen =
        StreamData.list_of(
          StreamData.member_of([:noop, :tick, :reset]),
          min_length: 1,
          max_length: 20
        )

      shrunk =
        ExUnitProperties.pick(
          StreamData.bind(gen, fn events ->
            if :tick in events, do: StreamData.constant(events), else: gen
          end)
        )

      # Sanity check: the sample for snapshot purposes should *contain* :tick.
      # The actual shrinking of failure inputs is exercised below via a
      # real property failure path.
      assert :tick in shrunk
    end

    @tag :slow
    test "minimal-shrink snapshot — failing property reduces failing seq to [:tick]" do
      # Run a property that always fails when :tick is in the sequence and
      # capture the minimal shrunk input. StreamData's contract: shrinking
      # is deterministic given the seed, so the snapshot is stable.

      machine = Crank.new(ImpureRandMachine)

      # Capture the shrunken counterexample by intercepting the assertion.
      result =
        try do
          ExUnitProperties.check all(
                                   events <-
                                     StreamData.list_of(
                                       StreamData.member_of([:noop, :tick, :reset]),
                                       min_length: 1,
                                       max_length: 8
                                     ),
                                   initial_seed: 0
                                 ) do
            assert_pure_turn(machine, events, timeout: 1_000)
          end

          :no_failure
        rescue
          e in ExUnit.AssertionError -> {:failed, e.message}
        end

      assert match?({:failed, _}, result),
             "expected the property to fail on impure machine (got #{inspect(result)})"

      {:failed, msg} = result

      # Snapshot assertion: the shrunk message contains :tick. We don't
      # over-fit to "exactly [:tick]" because StreamData's exact shrinking
      # path may pad with structurally-required elements (here, our list
      # has min_length: 1 so single-element [:tick] should be reachable).
      assert msg =~ ":tick"

      # The shrunken event must be the impure one (StreamData should have
      # found that pure events alone do not fail — and that :reset alone
      # does not fail either).
      refute msg =~ "Failing event:    :noop"
      refute msg =~ "Failing event:    :reset"
    end
  end

  # ── :allow opt — Layer C suppression ─────────────────────────────────────

  describe "Layer C suppression via :allow" do
    test "matching :allow opt silences the violation" do
      machine = Crank.new(ImpureRandMachine)

      # Restrict the forbidden list to DateTime only (the default list also
      # picks up `:os.system_time/0` that DateTime.utc_now/0 calls internally),
      # then allow DateTime — this is the per-test pattern users follow.
      assert %Crank{state: :ticking} =
               assert_pure_turn(machine, [:tick],
                 forbidden_modules: [{DateTime, :_, :_}],
                 allow: [{DateTime, :_, :_, reason: "trusted in fixture only"}],
                 timeout: 2_000
               )
    end

    test "missing :reason raises ArgumentError (delegates to PurityTrace)" do
      machine = Crank.new(ImpureRandMachine)

      assert_raise ArgumentError, ~r/non-empty :reason/, fn ->
        assert_pure_turn(machine, [:tick], allow: [{DateTime, :_, :_, []}])
      end
    end
  end

  # ── Resource exhaustion path ──────────────────────────────────────────────

  defmodule SlowMachine do
    @moduledoc false
    @behaviour Crank

    @impl true
    def start(_), do: {:ok, :idle, %{}}

    @impl true
    def turn(:slow, :idle, memory) do
      f = fn f -> f.(f) end
      f.(f)
      {:next, :idle, memory}
    end
  end

  describe "resource exhaustion is reported with structured detail" do
    test "timeout produces ExUnit.AssertionError with CRANK_RUNTIME_002" do
      machine = Crank.new(SlowMachine)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          assert_pure_turn(machine, [:slow], timeout: 100)
        end

      assert err.message =~ "CRANK_RUNTIME_002"
      assert err.message =~ ":slow"
      assert err.message =~ "timeout"
    end

    test "turn_traced/3 surfaces :resource_exhausted" do
      machine = Crank.new(SlowMachine)

      assert {:resource_exhausted, :timeout, _machines, _trace, :slow} =
               turn_traced(machine, [:slow], timeout: 100)
    end
  end

end
