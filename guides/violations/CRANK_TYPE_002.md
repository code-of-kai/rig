# CRANK_TYPE_002 — Function or module value in memory

## What triggers this

A typespec for `@type memory/0` (or for a state struct used in the state union) contains `function/0`, `module/0`, or any concrete function/MFA type. Crank's macro form rejects these at compile time **when the memory module's typespec is on disk for the host module's `@after_compile` hook**.

### Best-effort under compile order

If the memory module hasn't been written to BEAM bytecode by the time the host module finishes compiling (typical of cross-file forward references in a single mix project), the check is skipped at compile time and `[:crank, :typing, :memory_check_deferred]` telemetry fires. Mitigation:

1. Reorder build files so the memory module compiles first — Elixir handles this automatically when the host `alias`-imports the memory module, but raw `use Crank, memory: SomeForwardRef` may not get the right ordering.
2. Run `mix compile` twice — the second pass sees the memory module's bytecode and the check fires correctly.

A deterministic post-compile second pass via `mix crank.check` is tracked on [ROADMAP](../../ROADMAP.md) for v2.x.

```elixir
use Crank,
  states: [Idle, Running],
  memory: MyApp.PolicyMemory

defmodule MyApp.PolicyMemory do
  defstruct [:rate, :handler]
  @type t :: %__MODULE__{
    rate: integer(),
    handler: (event :: term() -> term())    # CRANK_TYPE_002
  }
end
```

*(Track A implementation: ships with the macro form in 1.7.)*

## Why it's wrong

A function value in memory is a small bomb. It can't be serialised to disk, so snapshot/resume loses it. It can't be inspected — you cannot tell from the snapshot what behaviour the machine had at that moment. It defeats the type-union exhaustiveness story (the value's identity is opaque). And it almost always comes from a misplaced abstraction: instead of carrying the function, carry the *data that selects the function*, and dispatch at the boundary.

The same applies to module values. Storing `MyApp.SomeAdapter` in memory means the adapter choice travels with the machine; it makes the machine impossible to test against a different adapter without crafting a new memory value, and it ties the snapshot to a particular module name that may rename or move.

## How to fix

### Wrong

```elixir
@type t :: %__MODULE__{
  handler: (event :: term() -> term())
}
```

### Right

```elixir
# Carry the discriminator, dispatch outside the machine:
@type t :: %__MODULE__{
  policy: :standard | :priority | :gold
}

# At the boundary:
def dispatch(event, machine) do
  result = Crank.turn(machine, event)
  case machine.memory.policy do
    :standard -> MyApp.StandardHandler.handle(result)
    :priority -> MyApp.PriorityHandler.handle(result)
    :gold     -> MyApp.GoldHandler.handle(result)
  end
end
```

For module-typed fields, store an atom tag and look up the module in a registry the application service owns. The machine sees data, not behaviour.

## How to suppress at this layer

Layer A — source-adjacent comment. Suppression here is a strong smell; prefer the redesign.

```elixir
# crank-allow: CRANK_TYPE_002
# reason: legacy callback contract; removed when migrating to telemetry-as-want
@type t :: %__MODULE__{handler: (term() -> term())}
```

## See also

- [Typing state and memory](../typing-state-and-memory.md).
- [`CRANK_TYPE_001`](CRANK_TYPE_001.md), [`CRANK_TYPE_003`](CRANK_TYPE_003.md).
- [Suppressions](../suppressions.md).
