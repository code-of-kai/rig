defmodule Crank.Property.ExamplesPurityTest do
  @moduledoc """
  Dogfooding: every example FSM in `test/support/examples.ex` is run under
  `Crank.PropertyTest.assert_pure_turn/3` so the runtime tracing layer
  exercises pure paths through them.

  These are *positive* property tests — they assert that the examples
  exhibit no transitive impurity. Negative fixtures (impure variants
  expected to fail) live alongside the per-code violation tests.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Crank.Generators
  import Crank.PropertyTest

  @moduletag :property
  # Each iteration goes through the BEAM trace API (serialised by
  # `Crank.PurityTrace.Coordinator` for thread-safety). Slow CI
  # runners need more headroom than ExUnit's default 60s; bumping
  # to 180s avoids spurious flakes. Local typically completes well
  # under the default.
  @moduletag timeout: 180_000

  # Property runs deliberately small — runtime tracing is heavy. The static
  # layer + the unit tests in property_test_test.exs already give us deep
  # coverage of the trace machinery; here we want each example exercised
  # once per property iteration.
  @max_runs 30
  @max_seq 20

  describe "Crank.Examples.Door" do
    property "every event sequence is pure" do
      check all(events <- door_event_sequence(@max_seq), max_runs: @max_runs) do
        machine = Crank.new(Crank.Examples.Door)
        # Door raises FunctionClauseError on unhandled events; filter to
        # reachable sequences before tracing.
        safe_events = filter_reachable_door_events(events, machine)

        if safe_events != [] do
          assert %Crank{} = assert_pure_turn(machine, safe_events, timeout: 2_000)
        end
      end
    end
  end

  describe "Crank.Examples.Turnstile" do
    property "every event sequence is pure" do
      check all(events <- turnstile_event_sequence(@max_seq), max_runs: @max_runs) do
        machine = Crank.new(Crank.Examples.Turnstile)
        assert %Crank{} = assert_pure_turn(machine, events, timeout: 2_000)
      end
    end
  end

  describe "Crank.Examples.VendingMachine" do
    property "every event sequence is pure" do
      check all(events <- vending_machine_event_sequence(@max_seq), max_runs: @max_runs) do
        machine = Crank.new(Crank.Examples.VendingMachine, price: 100)
        safe = filter_vending_reachable(events, machine)

        if safe != [] do
          assert %Crank{} = assert_pure_turn(machine, safe, timeout: 2_000)
        end
      end
    end
  end

  describe "Crank.Examples.Order" do
    property "every event sequence is pure" do
      check all(events <- order_event_sequence(@max_seq), max_runs: @max_runs) do
        machine = Crank.new(Crank.Examples.Order)
        assert %Crank{} = assert_pure_turn(machine, events, timeout: 2_000)
      end
    end
  end

  describe "Crank.Examples.Submission" do
    property "every event sequence is pure" do
      check all(events <- submission_event_sequence(@max_seq), max_runs: @max_runs) do
        machine = Crank.new(Crank.Examples.Submission)
        assert %Crank{} = assert_pure_turn(machine, events, timeout: 2_000)
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp vending_machine_event_sequence(max_length) do
    StreamData.list_of(
      StreamData.one_of([
        StreamData.tuple({StreamData.constant(:coin), StreamData.integer(1..200)}),
        StreamData.tuple({StreamData.constant(:select), StreamData.member_of([:cola, :chips])}),
        StreamData.constant(:dispensed),
        StreamData.constant(:refund)
      ]),
      min_length: 1,
      max_length: max_length
    )
  end

  defp filter_reachable_door_events(events, initial_machine) do
    {_, accepted} =
      Enum.reduce(events, {initial_machine, []}, fn event, {m, acc} ->
        try do
          {Crank.turn(m, event), [event | acc]}
        rescue
          FunctionClauseError -> {m, acc}
        end
      end)

    Enum.reverse(accepted)
  end

  defp filter_vending_reachable(events, initial_machine) do
    {_, accepted} =
      Enum.reduce(events, {initial_machine, []}, fn event, {m, acc} ->
        try do
          {Crank.turn(m, event), [event | acc]}
        rescue
          FunctionClauseError -> {m, acc}
        end
      end)

    Enum.reverse(accepted)
  end
end
