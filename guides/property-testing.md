# Property testing

This guide describes the canonical Crank pattern for verifying purity: pure-mode `Crank.turn/2` paired with StreamData and runtime tracing. Every property test becomes a purity test for free.

> The runtime-tracing helpers documented here (`Crank.PurityTrace`, `Crank.PropertyTest.assert_pure_turn/3`) ship with Track B of the purity-enforcement plan. The compile-time call-site checks already live in `main` (commit `ecc0618`). The pattern below is the contract; once Track B lands, the same code will execute end-to-end.

## What property testing buys you

Crank's enforcement story has three layers:

1. **Static call-site checks** — Credo (warning) and `@before_compile` (error) walk every `turn/3` body and reject calls to known-impure modules.
2. **Topology checks** — Boundary rejects domain → infrastructure references at the dependency-graph level.
3. **Runtime tracing** — `Crank.PurityTrace` watches every call from inside the running turn and reports any blacklist match anywhere in the dynamic call graph.

The first two are static. They miss everything that depends on values computed at runtime — dynamic dispatch, calls into helpers whose body the static checks don't see, and side effects buried two levels deep in third-party code.

The third closes that gap *for tested execution paths*. Property tests dramatically expand "tested" — generating hundreds or thousands of event sequences from a small generator definition. Combine the two and you get high-coverage runtime verification with little additional code.

## The canonical pattern

```elixir
defmodule MyApp.OrderMachineTest do
  use ExUnit.Case
  use ExUnitProperties

  alias MyApp.OrderMachine

  property "order machine stays pure across arbitrary event sequences" do
    check all events <- list_of(order_event(), max_length: 50) do
      machine = Crank.new(OrderMachine, tenant_id: "test-tenant")

      Crank.PropertyTest.assert_pure_turn(machine, events)
    end
  end

  defp order_event do
    one_of([
      tuple({constant(:add_item), item()}),
      constant(:price),
      constant(:place),
      constant(:cancel)
    ])
  end

  defp item do
    fixed_map(%{
      sku: string(:alphanumeric, min_length: 1),
      qty: positive_integer()
    })
  end
end
```

Read it top-down: a generator produces an arbitrary list of order events, the test starts a fresh machine, and `assert_pure_turn/3` runs the sequence under a trace. If any event triggers an impure call — directly in `turn/3` or transitively — the test fails with a `Crank.Errors.Violation` naming the call, the path, and the offending event.

## What `assert_pure_turn/3` does

```elixir
@spec assert_pure_turn(Crank.t(), term() | [term()], keyword()) :: Crank.t()
def assert_pure_turn(machine, events, opts \\ [])
```

The helper:

1. Spawns a worker process under `Crank.TaskSupervisor` (the supervisor `Crank.Application` already starts on boot).
2. Creates an isolated trace session via `:trace.session_create/3` (OTP 26+).
3. Sets trace patterns for every entry in `Crank.Check.Blacklist` (the same source of truth as the static layer).
4. Runs the events through `Crank.turn/2` synchronously inside the worker.
5. Collects the trace and asserts no impure calls were observed.
6. Tears down the session unconditionally in an `ensure` block.
7. Returns the final `%Crank{}` so the caller can chain assertions on state and memory.

Each call is independent. Parallel property tests do not interfere with each other — the OTP 26+ session API guarantees per-call isolation. *(This is verified by the concurrency-stress test that ships with Track B.)*

## Reading a failure

When `assert_pure_turn/3` fails, the failure message is a `Crank.Errors` pretty-printed violation:

```
error: [CRANK_PURITY_007] Crank purity-enforcement violation
  test/my_app/order_machine_test.exs:14

  Why: remove the impurity from the helper or move it behind a Crank.Domain.Pure marker
  Context: trace observed :erlang.unique_integer/0 via MyApp.IdGen.next/0

  Fix: telemetry-as-want or wants/2 declaration
    Wrong:
      MyApp.IdGen.next()    # calls :erlang.unique_integer
    Right:
      Sample the ID at the boundary; pass it via the event payload.

  See: https://hexdocs.pm/crank/CRANK_PURITY_007.html
```

The relevant pieces:

- **The code** (`CRANK_PURITY_007`) tells you which discipline was broken; click through to the doc page for the full treatment.
- **The context** names the specific impure call observed, plus the helper module that called it. This is the path the trace recorded.
- **The shrunk input** appears below in StreamData's standard failure block — the minimal event sequence that still triggers the impurity.

## Determinism and shrinking

StreamData is deterministic on its seed: same seed, same generator, same input sequence. Crank's contract is that the *verdict* and the *shrunk input* are equally deterministic across runs. Trace contents (timestamps, intermediate frames, scheduler-dependent ordering) are not asserted — those vary between runs and would produce flaky CI without improving the signal.

If you see different shrunk inputs across runs in a single test, that's a bug to report. If you see different verdicts (sometimes pass, sometimes fail), there's a genuine non-determinism somewhere in your code — that's the whole reason the discipline exists.

## Per-machine generator patterns

For machines whose events depend on the current state, build a stateful generator. The standard pattern interleaves a generator step with a turn step:

```elixir
property "vending machine stays pure under realistic flows" do
  check all script <- vending_script() do
    machine = Crank.new(MyApp.VendingMachine, price: 100)
    Crank.PropertyTest.assert_pure_turn(machine, script)
  end
end

defp vending_script do
  bind(integer(0..10), fn count ->
    list_of(vending_event(), length: count)
  end)
end

defp vending_event do
  one_of([
    tuple({constant(:coin), integer(5..100)}),
    tuple({constant(:select), string(:alphanumeric, min_length: 2, max_length: 3)}),
    constant(:dispensed),
    constant(:refund)
  ])
end
```

Note the script is a flat list — the property test feeds it through `Crank.turn/2` which handles unhandled events by raising `FunctionClauseError`, just like in production. If your generator can produce events your machine doesn't handle, that's a meaningful test outcome: either add the clause or constrain the generator to valid events.

## Trapping unhandled events

Sometimes a property's purpose is to verify that the *handled* events all stay pure, and you don't care about whether unhandled ones crash. Wrap the call:

```elixir
property "all handled events keep the machine pure" do
  check all event <- order_event() do
    machine = Crank.new(MyApp.OrderMachine, tenant_id: "t")

    if Crank.can_turn?(machine, event) do
      Crank.PropertyTest.assert_pure_turn(machine, [event])
    end
  end
end
```

`Crank.can_turn?/2` checks whether the event would match a clause without actually firing it. Skipping unhandled events keeps the property focused on purity rather than coverage.

## Negative fixtures

Every catalog code has at least one negative fixture in `test/fixtures/violations/` that *should* fire it. These exist for two reasons:

1. **Snapshot tests** of `Crank.Errors.format_pretty/1` use them to verify the error rendering is stable.
2. **Integration tests** of `mix crank.check` use them to verify CI gates fail on real violations.

If you're contributing a new check, add the negative fixture alongside the new code. The catalog test (`test/crank/errors/catalog_test.exs`) enforces that every code has both a doc page and a fixture path.

## Programmatic suppression (Layer C)

Some violations are deliberate. A `Decimal.add/2` call is impure under the strictest reading (the Decimal library uses process-dict to track precision settings) but for almost everyone it counts as pure. The Layer C `:allow` opt silences specific calls without changing the test's purity contract:

```elixir
Crank.PropertyTest.assert_pure_turn(machine, events,
  allow: [
    {Decimal, :_, :_, reason: "trusted pure dependency"},
    {SomeLib, :pure_helper, 2, reason: "verified pure in upstream issue #42"}
  ]
)
```

Each entry is `{module, function, arity, opts}`; `:_` matches any value. The `:reason` opt is required — see [Suppressions](suppressions.md) for the full mechanism.

Layer C suppressions are scoped per-call. They do not leak into other tests, do not modify global state, and emit `[:crank, :suppression]` telemetry so projects can audit how often each suppression fires.

## Aliased infra modules (`MyApp.Repo`, `MyApp.Mailer`, …)

The default `:forbidden_modules` list is derived from `Crank.Check.Blacklist` and covers the canonical names (`Repo`, `Ecto`, `HTTPoison`, `Tesla`, `Finch`, `Req`, `Swoosh`, `Bamboo`, `Mailer`, `Oban`, `Logger`, `File`). If your app uses an aliased module (`MyApp.Repo` instead of `Repo`), the runtime trace doesn't see it by default — trace patterns are per-loaded-module-atom, not name-prefix.

Two ways to close this gap:

1. **Rely on Boundary** (preferred). Configure `:third_party_impure` in your project's `:boundary` keyword. Boundary's compile-time check rejects domain → `MyApp.Repo` references topologically, so the runtime trace doesn't have to catch every site.

2. **Extend the runtime list per test**:

```elixir
Crank.PropertyTest.assert_pure_turn(machine, events,
  forbidden_modules:
    Crank.PurityTrace.default_forbidden_targets() ++ [MyApp.Repo, MyApp.Mailer]
)
```

The static call-site checks (`Crank.Check.TurnPurity` and `Crank.Check.CompileTime`) match by string-prefix, so they catch `MyApp.Repo` without configuration. Only the runtime layer needs the explicit aliasing.

## Resource limits

`assert_pure_turn/3` runs the worker with a heap cap and a timeout. Defaults: 10MB heap, 1000ms timeout. Override per call:

```elixir
Crank.PropertyTest.assert_pure_turn(machine, events,
  max_heap_size: 200_000_000,
  timeout: 30_000
)
```

If the worker blows past either limit, the test fails with `CRANK_RUNTIME_001` (heap) or `CRANK_RUNTIME_002` (timeout). For tight loops, the timeout path uses `Task.shutdown(:brutal_kill)` to kill the worker from outside — same-process timers can't preempt non-yielding code.

## Putting it together

Every Crank example FSM ships with an `assert_pure_turn` property test. The pattern below scales to any machine:

```elixir
defmodule MyApp.OrderMachineTest do
  use ExUnit.Case
  use ExUnitProperties

  property "order machine stays pure across arbitrary event sequences" do
    check all events <- list_of(order_event(), max_length: 100) do
      MyApp.OrderMachine
      |> Crank.new(tenant_id: "tenant-#{:rand.uniform(1000)}")
      |> Crank.PropertyTest.assert_pure_turn(events)
    end
  end

  property "order totals never go negative" do
    check all events <- list_of(order_event(), max_length: 100) do
      machine =
        MyApp.OrderMachine
        |> Crank.new(tenant_id: "test")
        |> Crank.PropertyTest.assert_pure_turn(events)

      assert is_nil(machine.memory.total) or Decimal.compare(machine.memory.total, 0) != :lt
    end
  end
end
```

Two properties: purity, and a domain invariant. Same generator. Same machine. Same setup cost.

## See also

- [Hexagonal Architecture](hexagonal-architecture.md) — the boundary that makes pure tests possible.
- [Suppressions](suppressions.md) — Layer C in detail.
- [Boundary setup](boundary-setup.md) — the topology layer property testing complements.
- Violation pages: [CRANK_PURITY_007](violations/CRANK_PURITY_007.md), [CRANK_RUNTIME_001](violations/CRANK_RUNTIME_001.md), [CRANK_RUNTIME_002](violations/CRANK_RUNTIME_002.md), [CRANK_TRACE_001](violations/CRANK_TRACE_001.md), [CRANK_TRACE_002](violations/CRANK_TRACE_002.md).
