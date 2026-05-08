# Typing state and memory

Crank's type discipline has a single guiding insight: **the tighter your state and memory types are, the more enforcement falls out for free.** Elixir already rejects struct-update with unknown fields at compile time. Dialyzer already reports type-mismatched returns. The set-theoretic type system, expanding through 2026, will eventually check exhaustiveness on closed unions. Crank's job is to make the path of least resistance the one that activates these mechanisms; the macro form does that.

This guide walks through the discipline — what to declare, what to leave out, why the structurally-tight version pays for itself the moment any new contributor types a field name wrong.

## The default Elixir shape (anaemic)

The typical Elixir state machine carries one struct with every field that could exist in any state, plus a `:status` atom:

```elixir
defmodule MyApp.OrderState do
  defstruct [
    :status,        # :drafting | :priced | :placed | :confirmed | :cancelled
    :line_items,
    :total,
    :placed_at,
    :confirmation_number,
    :cancellation_reason
  ]
end
```

This is what Eric Evans calls an *anaemic domain model* — the shape doesn't encode the rules. A `:drafting` order can have a `confirmation_number`; a `:cancelled` order can have a `total` from before the cancel; nothing in the type system says any of this is wrong. Errors only show up at runtime, when business logic tries to read a field that "shouldn't exist in this state."

## The Crank shape (struct-per-state)

Crank's preferred shape is one struct per state, with each struct carrying only the fields valid in that state:

```elixir
defmodule Drafting do
  defstruct [:line_items]
  @type t :: %__MODULE__{line_items: [LineItem.t()]}
end

defmodule Priced do
  defstruct [:line_items, :total]
  @type t :: %__MODULE__{line_items: [LineItem.t()], total: Decimal.t()}
end

defmodule Placed do
  defstruct [:line_items, :total, :placed_at]
  @type t :: %__MODULE__{
    line_items: [LineItem.t()],
    total: Decimal.t(),
    placed_at: DateTime.t()
  }
end

defmodule Confirmed do
  defstruct [:line_items, :total, :placed_at, :confirmation_number]
end

defmodule Cancelled do
  defstruct [:line_items, :total, :reason]
end
```

A `%Drafting{}` cannot have a `confirmation_number` field because the struct doesn't define one. The compiler rejects `%Drafting{confirmation_number: "X"}` at compile time. A `%Cancelled{}` cannot accidentally drop the cancellation reason because the field exists in the struct. The shape encodes the rules.

Elixir's compiler does this work for free; Crank's only contribution at this rung is to insist (via the macro form) that every state in the union is a struct.

## The macro form

The `use Crank, ...` macro accepts two opt-in declarations that activate the type-system enforcement progressively:

```elixir
defmodule MyApp.OrderMachine do
  use Crank,
    states: [Drafting, Priced, Placed, Confirmed, Cancelled],
    memory: MyApp.OrderMemory

  @impl true
  def start(_), do: {:ok, %Drafting{line_items: []}, %MyApp.OrderMemory{}}

  @impl true
  def turn({:add_item, item}, %Drafting{line_items: items} = s, memory) do
    {:stay, %{s | line_items: [item | items]}, memory}
  end

  def turn(:price, %Drafting{line_items: items}, memory) do
    {:next, %Priced{line_items: items, total: compute_total(items)}, memory}
  end

  ...
end
```

What the macro does:

- **Generates `@type state/0`** as the union of the listed state structs (`Drafting.t() | Priced.t() | ...`). Dialyzer can now check that every `turn/3` clause's return matches the declared union.
- **Generates `@type memory/0`** referencing the named memory struct.
- **Adds a compile-time check** that every `turn/3` clause's return-tuple's second element is one of the declared states, or computes to one.
- **Rejects `function/0` and `module/0` in the typespecs** of memory or state structs.

The macro form is opt-in; manual typespecs work too.

## Memory as a typed struct

`memory` is the cross-state data that travels with every turn. The same tightening applies: declare a struct, type the fields precisely, never lean on a bare map.

```elixir
defmodule MyApp.OrderMemory do
  defstruct [:tenant_id, :customer_id, :submitted_at]

  @type t :: %__MODULE__{
    tenant_id: Ecto.UUID.t(),
    customer_id: Ecto.UUID.t(),
    submitted_at: DateTime.t() | nil
  }
end
```

Two things this buys:

1. **Field-name typos are compile errors.** `%{memory | submitted_t: now}` (note the typo) is rejected by the compiler — Elixir's struct-update semantics check field names.
2. **Dialyzer can warn on type mismatches.** Assigning `42` to `:tenant_id` (declared `Ecto.UUID.t()`) produces a Dialyzer warning.

## What not to put in state or memory

Three categories are forbidden:

```elixir
# WRONG — function value in memory
@type t :: %__MODULE__{handler: (term() -> term())}

# WRONG — module value in memory
@type t :: %__MODULE__{adapter: module()}

# WRONG — opaque PID
@type t :: %__MODULE__{worker: pid()}
```

Each of these breaks one of three guarantees:

- **Function values** can't be serialised. Snapshots lose them. The same machine restored from disk has different behaviour from the in-memory machine.
- **Module values** tie the snapshot to a particular module name. Renaming the adapter breaks restore.
- **PIDs** are process-specific. The fresh process after restart has different pids than the snapshotted machine; the value is meaningless after a restart.

For each, the fix is the same: carry the data that *selects* the function/module/process, then dispatch at the boundary where the application service knows the current runtime values.

```elixir
# RIGHT — carry the discriminator, dispatch outside the machine
@type t :: %__MODULE__{policy: :standard | :priority | :gold}

# RIGHT — store an atom tag; look up the module in a registry
@type t :: %__MODULE__{adapter: :ecto | :s3 | :null}

# RIGHT — store the pid's discoverable identity (a registered name, ID)
@type t :: %__MODULE__{worker_id: Ecto.UUID.t()}
```

## Closing state unions for exhaustiveness

Declare the closed union now (`states: [Drafting, Priced, ...]`) and you get exhaustiveness warnings on `turn/3` for free as Elixir's set-theoretic type system matures — no code change required.

## The progressive-activation principle

The type discipline is laid out so each successive choice activates more enforcement, with no jumps:

| Choice | What it activates |
|---|---|
| Atomic states (`:idle`, `:running`) | Pattern-matching only. No type help. |
| Struct-per-state (`%Idle{}`, `%Running{}`) | Field-name validation by the Elixir compiler. |
| Typespecs on each state struct | Dialyzer warnings on misuse. |
| `use Crank, states: [...], memory: M` | Closed-union return check; function/module/pid rejected in memory at compile time when the memory module's typespec is on disk for the host module's `@after_compile` hook (otherwise emits `[:crank, :typing, :memory_check_deferred]` telemetry — see [CRANK_TYPE_002](violations/CRANK_TYPE_002.md)). |
| Closed event unions (future) | Compile-time exhaustiveness on `turn/3`. |

You can stop at any rung. Crank doesn't require the macro form. But every step up adds enforcement that costs you nothing at runtime and saves a class of bugs that would otherwise show up in production.

## When to break the discipline

Two cases where the closed-shape rule legitimately bends:

1. **Bridging an external schema.** If `turn/3` consumes events from a queue whose payload schema you don't control, the event type may genuinely be open. Pattern-match on the part you care about; let the rest fall through.
2. **Migration from an anaemic model.** Mid-rewrite, a state may temporarily carry both old and new shapes. Use a `Crank.Suppressions` Layer A annotation with a reason that names the migration; remove it when the migration ships.

In both cases the suppression is deliberate and documented. Don't suppress to avoid work; suppress when the work is genuinely scheduled and the suppression is the bridge.

## See also

- [Hexagonal Architecture](hexagonal-architecture.md) — the overall boundary the type discipline supports.
- [Property testing](property-testing.md) — how the closed shape interacts with StreamData generators.
- [Boundary setup](boundary-setup.md) — the topology layer that complements type-level enforcement.
- [DESIGN.md](../DESIGN.md) — "Compiler-checked exhaustiveness (future)" and "Struct-per-state."

The catalog codes this guide is the source-of-truth for: [CRANK_TYPE_001](violations/CRANK_TYPE_001.md) (unknown struct field), [CRANK_TYPE_002](violations/CRANK_TYPE_002.md) (function/module/pid in state or memory), [CRANK_TYPE_003](violations/CRANK_TYPE_003.md) (return-state outside the declared union).
