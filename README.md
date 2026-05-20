<p align="center">
  <img src="assets/logo.jpg" alt="Crank" width="200">
</p>

# Crank

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`Crank.turn(machine, event)` — a pure function call that advances a state machine. No process required. Promote to a supervised `:gen_statem` when needed. Same module, no rewrite.

Crank is opinionated: it is a **Moore** state machine library. Outputs are a function of the state, not of the edge that arrived there.

## Quick start

```elixir
defmodule MyApp.VendingMachine do
  use Crank

  @impl true
  def start(opts) do
    {:ok, :idle, %{price: opts[:price] || 100, balance: 0, selection: nil}}
  end

  # Transitions are pure state computation. No effects, ever.
  @impl true
  def turn({:coin, amount}, :idle, memory) do
    {:next, :accepting, %{memory | balance: amount}}
  end

  def turn({:coin, amount}, :accepting, memory) do
    {:stay, %{memory | balance: memory.balance + amount}}
  end

  def turn({:select, item}, :accepting, %{balance: b, price: p} = memory)
      when b >= p do
    {:next, :dispensing, %{memory | selection: item}}
  end

  def turn(:dispensed, :dispensing, memory) do
    {:next, :idle, %{memory | balance: 0, selection: nil}}
  end

  # Effects live on states. Timeouts attach to the state that has them,
  # not to the edge that arrived at them.
  @impl true
  def wants(:accepting, _memory), do: [{:after, 60_000, :timeout_refund}]
  def wants(:dispensing, _memory), do: [{:after, 5_000, :jam}]
  def wants(_state, _memory), do: []

  # What outside callers see. Pure projection of (state, memory).
  @impl true
  def reading(:idle, _memory), do: %{status: :idle}
  def reading(:accepting, memory), do: %{status: :accepting, balance: memory.balance}
  def reading(:dispensing, memory), do: %{status: :dispensing, item: memory.selection}
end
```

### Pure usage

No process, no setup, no cleanup:

```elixir
machine =
  MyApp.VendingMachine
  |> Crank.new(price: 75)
  |> Crank.turn({:coin, 25})
  |> Crank.turn({:coin, 50})
  |> Crank.turn({:select, "A3"})

machine.state         #=> :dispensing
machine.wants         #=> [{:after, 5_000, :jam}]
Crank.reading(machine) #=> %{status: :dispensing, item: "A3"}
```

### Process usage

Same module. Supervised `:gen_statem` with real timers and telemetry:

```elixir
{:ok, pid} = Crank.Server.start_link(MyApp.VendingMachine, price: 75)
Crank.Server.turn(pid, {:coin, 25})
#=> %{status: :accepting, balance: 25}

Crank.Server.reading(pid)
#=> %{status: :accepting, balance: 25}
```

`Crank.Server.turn/2` advances the machine and replies with the new reading. `Crank.Server.reading/1` projects without advancing. Same module, different caller.

## The vocabulary

| Term | Meaning |
|---|---|
| **`turn/3`** | The transition callback you write. Pure state computation. |
| **`wants/2`** | What the state declares on arrival. Timeouts, sends, telemetry, internal events. Optional. |
| **`reading/2`** | What outside callers observe. Projection of `(state, memory)`. Optional. |
| **`memory`** | Cross-state data carried through every turn. |
| **`state`** | Current state. Any term — atom, struct, tagged tuple. |
| **`engine`** | Lifecycle: `:running` or `{:off, reason}`. |

The user's verb is `turn` in both modes — `Crank.turn/2` in pure mode, `Crank.Server.turn/2` in process mode. The library is called Crank because you're cranking a machine; the verb for the operation is `turn` for consistency with the callback.

## The struct

After each `turn/2`, the returned `%Crank{}` has five fields:

- `module` — the callback module.
- `state` — the current state.
- `memory` — data carried across states.
- `wants` — what the current state declares, stored as inert data.
- `engine` — `:running` or `{:off, reason}`.

`machine.wants` is a materialised cache of the `wants/2` callback. The library guarantees the invariant `machine.wants == module.wants(machine.state, machine.memory)` after `new/2`, after every `turn/2` (regardless of `:next`, `:stay`, or `:stop`), and after `resume/1`. The pure core never executes wants; `Crank.Server` interprets the declared list on every `{:next, ...}` arrival.

## Return values from `turn/3`

```
{:next, new_state, new_memory}     # move to a different state
{:stay, new_memory}                # same state, updated memory
:stay                              # nothing changes
{:stop, reason, new_memory}        # shut down the machine
```

No action tuples. No effects. `turn/3` is pure state computation; this is the structural enforcement of the Moore discipline. For how these return values connect to UML transition theory — trigger, guard, effect, source state — see the [Transitions and guards guide](guides/transitions-and-guards.md).

## Want types

`wants/2` returns a list of these:

| Want | Effect |
|---|---|
| `{:after, ms, event}` | Anonymous state timeout. Fire `event` after `ms` if the state hasn't changed. One per state; auto-cancels on state-value change. |
| `{:after, name, ms, event}` | Named generic timeout. Multiple may run concurrently. Cancelled explicitly with `{:cancel, name}`. |
| `{:cancel, name}` | Cancel a named timeout. No-op if no such timer runs. |
| `{:next, event}` | Inject an internal event, processed before any queued external event. |
| `{:send, dest, message}` | Send `message` to `dest` (pid, registered name, or `{name, node}`). Fire-and-forget. |
| `{:telemetry, name, measurements, metadata}` | Emit a telemetry event. |

## Moore, not Mealy

Crank is opinionated about the *shape* of its state machines. Two classical shapes exist:

- **Moore machine**: the output is a label on the state. `output = f(state)`. You arrive at a state; the state speaks.
- **Mealy machine**: the output is a label on the transition. `output = f(event, state)`. The edge fires; the output is produced by the transition itself.

Crank is Moore. `turn/3` computes state. `wants/2` declares effects on arrival at a state. You cannot attach an effect to an edge — the API does not provide the hook.

### Why Moore

Moore machines are easier to reason about because the question *"what does this state do?"* has a single answer you can read in one place. In Mealy, the same question requires scanning every transition that arrives at that state and assembling the pieces.

The most successful stateful abstraction in Elixir, **Phoenix LiveView**, is Moore-shaped. `handle_event/3` updates `socket.assigns` (pure state change). `render/1` projects the UI from assigns — `render = f(assigns)`, with no access to the event that caused the assigns to change. The UI is a function of state, full stop. That discipline is a large part of why LiveView is ergonomic: the rendering question reduces to *"given this state, what should be on screen?"*

### A speculation on `gen_statem`

`:gen_statem` is the standard-library state machine in OTP. It is powerful and well-built, but has never achieved the popularity of `GenServer` in the Elixir community. One plausible reason: its default grain is Mealy. A transition clause returns `{:next_state, NewState, Data, Actions}` — the actions list is an edge-attached emission. To read what a state does on arrival, you scan the handlers that transition *into* it. The state-enter callback mode exists, but it is opt-in and the documentation treats it as advanced.

A library that makes Moore the only option — where the question *"what does this state do?"* maps to one `wants/2` clause and one `reading/2` clause — may be closer to what most Elixir developers actually want from a state machine abstraction. Crank is an attempt to test that hypothesis.

## Why Crank exists

Business logic is states and transitions. A customer is `:prospect`, `:active`, `:churning`, `:dormant`. A policy is `:quoted`, `:bound`, `:active`, `:lapsed`. A submission is `:received`, `:validating`, `:eligible`, `:declined`. Business rules are transition rules: *"can't bind without quoting first,"* *"when the underwriter approves, move to eligible."*

Every business rule answers: given this state and this event, what happens next? That is the definition of a finite state machine. The question is whether the state machine is explicit in the code or hidden inside a GenServer with scattered `%{status: ...}` pattern matches.

A GenServer with `handle_call` clauses that check `state.status` is an implicit state machine. A Crank module is an explicit one. Both encode the same rules; one is readable.

`:gen_statem` exists in OTP but is rarely reached for because its Mealy grain makes reading and writing more expensive than `GenServer` with a status atom. Crank separates state-machine logic from process concerns (same module runs pure or supervised) and enforces Moore discipline structurally.

## How Crank compares to GenServer

José Valim's consistent advice: start simple, promote to complex when needed. Plain functions before GenServer. GenServer before `:gen_statem`.

Pure mode is **machine-as-data**: a `%Crank{}` is plain immutable data, like `%Date{}` — no PID, no mailbox, no lifecycle. It lives in whatever process holds it: a Phoenix request, a LiveView, a test, an `Enum.reduce`. Every line of Elixir still runs in *some* process; what pure mode removes is a process *dedicated to the machine*. `Crank.Server` is **machine-as-process**: one `:gen_statem` per machine, with mailbox, real timers, supervision. Same callback module, different holder.

```
machine-as-data  (Crank.turn/2)
       ↓  promotion when you need supervision, timeouts, telemetry
machine-as-process  (Crank.Server)
```

## Struct-per-state

The standard Elixir approach uses one struct with a `:status` atom and every field present in every state. That is what DDD calls an *anemic domain model* — the shape does not encode the rules.

Crank supports an alternative: each state is its own struct.

```elixir
defmodule Idle,       do: defstruct []
defmodule Accepting,  do: defstruct [:balance]
defmodule Dispensing, do: defstruct [:balance, :selection]
```

A `%Dispensing{}` cannot have a `change` field because the struct does not define one. Pattern-matching on the struct type gives the state and its data in one destructure:

```elixir
def turn({:select, item}, %Accepting{balance: b}, memory) when b >= memory.price do
  {:next, %Dispensing{balance: b, selection: item}, memory}
end
```

State-specific data lives in the struct. Cross-cutting concerns live in `memory`. Elixir's set-theoretic type system will eventually check these unions at compile time; `Crank.Examples.Submission` is designed for that. The `when b >= memory.price` guard in the example above is a UML guard in Elixir clothing — see the [Transitions and guards guide](guides/transitions-and-guards.md) for the full treatment.

## Telemetry

`Crank.Server` emits four events automatically:

- **`[:crank, :start]`** when a fresh machine boots, with `%{module, state, memory}`.
- **`[:crank, :resume]`** when a machine is restored from a snapshot, with `%{module, state, memory}`.
- **`[:crank, :transition]`** on every state change, with `%{module, from, to, event, memory}`.
- **`[:crank, :exception]`** when `turn/3` raises, throws, or exits, with `%{module, state, event, memory, kind, reason, stacktrace}`. Emitted before the error re-raises and terminates the process.

Wants can also emit user-defined telemetry via `{:telemetry, name, measurements, metadata}`.

## Persistence

`%Crank{}` is a plain immutable struct. Persisting it is writing a map; restoring it is reading one.

```elixir
# Capture
snapshot = Crank.snapshot(machine)
#=> %{module: MyApp.VendingMachine, state: :accepting, memory: %{...}}

# Restore (pure)
machine = Crank.resume(snapshot)

# Restore (supervised process)
{:ok, pid} = Crank.Server.resume(snapshot)
```

Snapshots are plain maps — portable across serialization boundaries. Pure `resume/1` populates the `wants` cache per the invariant but executes nothing. `Crank.Server.resume/2` additionally re-executes wants, re-arming timers and re-emitting sends; recipients should be idempotent or the effect belongs in a saga with durable delivery state. Both emit `[:crank, :resume]` telemetry.

Event-sourcing works the same as snapshot-per-transition: attach a telemetry handler to `[:crank, :transition]`, write the event, and fold events through `Crank.turn/2` on restore.

## Coordinating multiple machines

When one machine's outcome drives another — an order completes, a payment fires, fulfillment starts — that coordination is itself a state machine. DDD calls this a *process manager* or *saga*. A saga has states (awaiting payment, awaiting fulfillment), events (payment succeeded, fulfillment completed), and transitions. That is another Crank module.

The saga doesn't contain the business logic of payment or fulfillment. It orchestrates them. Each step sends an event to another state machine and waits for the response.

State machines all the way down. The domain objects are state machines. The coordination between them is a state machine. The pattern scales because the abstraction is the same at every level.

## Testing machines that interact

A common objection to pure state machines: *"Sure, one machine in isolation is easy to test. But my real system has an order machine that triggers a payment machine that triggers a fulfillment machine. You can't test that without processes."*

You can. The interaction between machines is a function over structs. Turn both of them in one test, assert on both:

```elixir
test "payment confirmation advances the order" do
  order   = Crank.new(MyApp.Order) |> Crank.turn(:submit)
  payment = Crank.new(MyApp.Payment) |> Crank.turn({:charge, order.memory.total})

  assert payment.state == :confirmed

  order = Crank.turn(order, {:payment_confirmed, payment.memory.txn_id})
  assert order.state == :awaiting_fulfillment
end
```

Two machines. One test. No processes, no mailboxes, no `start_link`, no sleeping, no `eventually` helpers.

## Composing work

Three supplementary modules ship with Crank for composing effects and multi-machine work:

- **`Crank.Wants`** — a pipe-friendly builder over the want vocabulary. Compose shared effect policies once, reuse them across machines. Produces plain lists; zero wire-format change.
- **`Crank.Turns`** — an `Ecto.Multi` analogue for state machines. A pure descriptor that accumulates named turns against named machines, with function-resolved step dependencies. Best-effort sequential semantics, structured error shape.
- **`Crank.Server.Turns`** — the process-mode executor for the same descriptor. Operates on `Crank.Server` pids / registered names via monitor-based stop detection.

Quick taste:

```elixir
order   = Crank.new(MyApp.Order)
payment = Crank.new(MyApp.Payment)

Crank.Turns.new()
|> Crank.Turns.turn(:order, order, :submit)
|> Crank.Turns.turn(:payment, payment,
     fn %{order: o} -> {:charge, o.memory.total} end)
|> Crank.Turns.apply()
#=> {:ok, %{order: %Crank{...}, payment: %Crank{...}}}
```

The full guide — including failure shapes, pure/process symmetry, the builder surface, and the saga-vs-Turns distinction — is in the [Composing Work guide](guides/composing-work.md).

## Authorization

Authorization belongs in the application service that calls `Crank.turn/2`, not inside `turn/3`. A Crank aggregate answers *"what happens given this event?"* — not *"is this caller allowed to send this event?"* Keeping policy outside the aggregate preserves the pure-core property (same input, same output, no environment dependency) and matches the DDD convention that aggregates enforce invariants, while application services enforce access.

A typical wiring:

```elixir
def place_order(caller, order_id, event) do
  with :ok <- authorize(caller, order_id, event),
       {:ok, machine} <- load(order_id) do
    updated = Crank.turn(machine, event)
    persist(updated)
    {:ok, Crank.reading(updated)}
  end
end
```

If the machine needs to *record* the caller (for audit, for domain rules like "only the submitter can cancel"), the caller identity is part of the event payload, not a separate authorization concern: `Crank.turn(machine, {:cancel, by: user_id})`.

## Installation

```elixir
def deps do
  [
    {:crank, "~> 2.0"}
  ]
end
```

## Documentation

**To use Crank** (in order):

- [Transitions and guards](guides/transitions-and-guards.md) — how UML statechart transitions map to `turn/3` clauses and `when` guards.
- [Composing Work](guides/composing-work.md) — `Crank.Wants`, `Crank.Turns`, multi-machine work.
- [Hexagonal Architecture](guides/hexagonal-architecture.md) — wiring persistence, notifications, audit logging.

**To understand Crank** (the why):

- [DESIGN.md](DESIGN.md) — full specification and design rationale.
- [Typing state and memory](guides/typing-state-and-memory.md) — why struct-per-state, closed unions, and the macro form pay rent.
- [ROADMAP.md](ROADMAP.md) — forward-looking work and known gaps.

**Reference** (read on demand):

- [Purity enforcement](guides/purity-enforcement.md) — what the `CRANK_*` errors mean and how to suppress them.
- [CHANGELOG.md](CHANGELOG.md) — version history.

## License

MIT
