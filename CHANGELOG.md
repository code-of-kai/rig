# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-05-04 — Layered purity enforcement

This release operationalises the pure-core discipline through a layered enforcement system: compile-time call-site checks, post-compile topology checks delegated to [Boundary](https://github.com/sasa1977/boundary), runtime tracing under property tests, and type-level guards. Every violation has a stable code in `Crank.Errors.Catalog` and a per-code doc page under `guides/violations/`.

### Requirements

- **OTP 26+ is now required.** `Crank.PurityTrace` uses `:trace.session_create/3` and the surrounding session-scoped tracing API, which only exists in OTP 26+. `Crank.Application` raises `CRANK_SETUP_002` at boot if running on OTP < 26. CI matrix runs only OTP 26+. See [`CRANK_SETUP_002`](guides/violations/CRANK_SETUP_002.md).
- **Boundary becomes a hard dependency.** Crank ships with `{:boundary, "~> 0.10"}` so the topology layer is always available. New projects run `mix crank.gen.config` (one-time setup, idempotent) to wire `:crank` into `compilers:`, write the starter Boundary config, and amend `.credo.exs`. See [`CRANK_SETUP_001`](guides/violations/CRANK_SETUP_001.md) and the [Boundary setup guide](guides/boundary-setup.md).

### Added — by stage

- **Foundation (Stage 1).** `Crank.Errors`, `Crank.Errors.Catalog` (22 frozen v1 codes), `Crank.Errors.Violation`, `Crank.Check.Blacklist` (single source of truth for the call-site blacklist, shared between Credo and `@before_compile`), `Crank.Suppressions` (Layer A parser + telemetry).
- **OTP guard (Stage 2).** `Crank.Application` boots with the OTP 26+ check, starts `Crank.TaskSupervisor` for Mode B worker tasks.
- **Static call-site checks (Stage 4).** `Crank.Check.TurnPurity` (Credo, warning-level) and `Crank.Check.CompileTime` (`@before_compile`, hard `CompileError`) are wired into `use Crank`. Both share the blacklist via `Crank.Check.Blacklist`. Source-adjacent `# crank-allow:` comments suppress per Layer A. See [`CRANK_PURITY_001..006`](guides/violations/index.md#call-site-purity-layer-a--source-comment-suppressible).
- **Topology layer (Stages 3, 5, 6).** `Crank.BoundaryIntegration` translates Boundary diagnostics into `Crank.Errors.Violation` structs. `Crank.Domain.Pure` marker module tags first-party helpers as part of the domain. `mix crank.gen.config` writes the starter Boundary config with the `:domain`/`:infrastructure` cut and the third-party classification template. See [`CRANK_DEP_001..003`](guides/violations/index.md#topology-layer-b--boundary-config-suppressible).
- **Runtime layer (Stage 7).** `Crank.PurityTrace` runs `turn/3` in an isolated OTP 26 trace session and reports any blacklist match anywhere in the dynamic call graph. `Crank.PropertyTest.assert_pure_turn/3` integrates this with StreamData so every property test becomes a purity test. See [`CRANK_PURITY_007`](guides/violations/CRANK_PURITY_007.md), [`CRANK_RUNTIME_001`](guides/violations/CRANK_RUNTIME_001.md), [`CRANK_RUNTIME_002`](guides/violations/CRANK_RUNTIME_002.md), [`CRANK_TRACE_001`](guides/violations/CRANK_TRACE_001.md), [`CRANK_TRACE_002`](guides/violations/CRANK_TRACE_002.md).
- **Server resource limits (Stage 8).** `Crank.Server.start_link/3` accepts `:resource_limits`. Mode A applies `:max_heap_size` to the gen_statem. Mode B (`turn_timeout` set) spawns workers under `Crank.TaskSupervisor` with kill-on-timeout via `Task.shutdown(:brutal_kill)` — the only sound preemption pattern on the BEAM for non-yielding callbacks.
- **Type layer (Stage 6).** Macro form `use Crank, states: [...], memory: M` declares the closed state union, generates the typespecs, rejects function/module values in memory or state types at compile time when the memory module's typespec is fetchable (`CRANK_TYPE_002`; the check is best-effort under unfavourable compilation order — when the typespec isn't yet on disk for the host module's `@after_compile` hook, the check is skipped and `[:crank, :typing, :memory_check_deferred]` telemetry fires. A deterministic second-pass via `mix crank.check` is tracked on [ROADMAP](ROADMAP.md)). Warns on returns outside the declared union (`CRANK_TYPE_003`). Links Elixir's native struct-update field rejection into the catalog (`CRANK_TYPE_001`). See the [typing-state-and-memory guide](guides/typing-state-and-memory.md).
- **CI gate and setup task (Stage 9).** `mix crank.check` wraps `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, the Boundary check, and the property-test suite into one command. Exits non-zero on any failure with structured output. `mix crank.gen.config` is the one-time setup task that wires `:crank` into `compilers:`, drops a starter `boundary.exs` template, amends `.credo.exs`, and prints the recommended CI snippet to stdout. Idempotent.
- **Documentation (Stages 10, 11).** Per-code doc pages for every violation under `guides/violations/`. Four new guides: [boundary-setup](guides/boundary-setup.md), [property-testing](guides/property-testing.md), [typing-state-and-memory](guides/typing-state-and-memory.md), [suppressions](guides/suppressions.md). [ROADMAP.md](ROADMAP.md) covers forward-looking work and known gaps.
- **Dogfooding and final coverage (Stages 12, 13).** Every example FSM in `test/support/examples.ex` (`Door`, `Turnstile`, `VendingMachine`, `Order`, `Submission`) runs under `Crank.PropertyTest.assert_pure_turn/3` to exercise the runtime tracing layer end-to-end. `test/fixtures/violations/<CODE>.{exs,txt}` holds one fixture per frozen catalog code; `test/crank/errors/violation_fixtures_test.exs` enforces coverage. End-to-end integration tests under `test/integration/` stage real consumer projects depending on Crank by path and assert the full compile pipeline produces the expected diagnostics.
- **`CRANK_PURITY_002` detection.** The `@before_compile` hook now flags `_ = local_call(...)` discards inside `turn/3` — a static signal that the call exists for side effects, which the blacklist alone cannot reach when the call is local. Suppression follows the standard Layer A `# crank-allow:` mechanism.

### Suppression — three layers, three mechanisms

Each layer observes violations differently, so suppression is layer-specific by design:

- **Layer A (source comments).** `# crank-allow: CODE` followed by `# reason: ...` immediately above the offending line. Silences AST-level violations.
- **Layer B (Boundary config).** `:exceptions` entry naming the from/to module pair plus `reason:`. Silences topology violations.
- **Layer C (programmatic `:allow` opt).** `{module, function, arity, reason: "..."}` entries on `Crank.PropertyTest.assert_pure_turn/3`. Silences runtime trace observations.

Cross-layer attempts (`# crank-allow: CRANK_DEP_001` in source) raise `CRANK_META_004` with a pointer to the right mechanism. See the [Suppressions guide](guides/suppressions.md).

### Known gaps (non-detectable in v1)

The plan defines a precise detection matrix; classes outside it are explicit:

- Trust in third-party library purity (universal floor across all static-purity disciplines).
- Deliberate sabotage of markers.
- Untested code paths for runtime-only categories.
- Compile-time configuration leakage (`Application.compile_env`).
- Reduction-budget enforcement in `Crank.PurityTrace` v1 — `:erlang.system_monitor/2` is VM-global and incompatible with parallel test execution. Tracked on the [ROADMAP](ROADMAP.md).

## [1.1.0] - 2026-04-22

### Added

- `Crank.Wants` — composable builder over `c:Crank.wants/2` tuple types. Pipe-friendly API (`new/0`, `timeout/3`, `timeout/4`, `cancel/2`, `send/3`, `telemetry/4`, `next/2`, `only_if/3`, `merge/2`) produces plain want lists without changing the wire format. Enables shared effect policies across machines.
- `Crank.Turns` — Ecto.Multi analogue for state machines. Pure `%Crank.Turns{}` descriptor accumulates named turns against `%Crank{}` machines, with function-resolved dependencies on prior results. `Crank.Turns.apply/1` executes pure; best-effort sequential, returns `{:ok, results}` or `{:error, name, reason, advanced_so_far}`. `{:stopped_input, reason}` wraps pre-stopped inputs.
- `Crank.Server.Turns` — process-mode executor for the same descriptor. Operates against pids, registered names, or `{name, node}` tuples via `Crank.Server.turn/2`. Uses monitor-based stop detection (`Process.monitor/1` + `:erlang.yield/0` + bounded `receive`) because `Process.alive?/1` is unreliable during `:gen_statem` termination cleanup. `{:server_exit, exit_reason}` wraps caught call exits.

### Fixed

- Typedoc for `{:send, dest, message}` now documents `dest :: pid() | atom() | {atom(), node()}`, matching `Kernel.send/2` and the Server's existing runtime behavior. No behavioral change.

## [1.0.0] - 2026-04-22

Major breaking redesign: Crank is now opinionated Moore, not Mealy. Effects are declared on state arrival (`wants/2`), not on transitions. The API is smaller, the vocabulary is consistent across pure and process modes, and the Moore discipline is enforced structurally — `turn/3` cannot attach effects to edges because the return type has no actions field.

### Changed — breaking

- **Transition callback renamed** `handle/3` / `handle_event/4` → `turn/3`. One callback, no precedence rules, no event type argument.
- **Init callback renamed** `init/1` → `start/1`.
- **State-entry callback replaced**: `on_enter/3` removed. In its place, `wants/2` declares what a state wants on arrival. The signature is `wants(state, memory)` — no old-state argument.
- **New callback** `reading/2` (optional) — what outside callers observe. `Crank.Server.turn/2` auto-replies with this projection.
- **Return shape from `turn/3`** is pure state: `{:next, state, memory}`, `{:stay, memory}`, `:stay`, `{:stop, reason, memory}`. No actions list. Effects move to `wants/2`.
- **Struct renamed** `%Crank.Machine{}` → `%Crank{}`. `Crank.Machine` module removed. Field `data` renamed to `memory`. Field `effects` renamed to `wants`. Field `status` renamed to `engine` with values `:running | {:off, reason}`.
- **User verb renamed** `crank/2` → `turn/2` (and `crank!/2` → `turn!/2`, `can_crank?/2` → `can_turn?/2`). Added `can_turn!/2`. Library name stays Crank.
- **Server API renamed**: `Crank.Server.call/3` → `turn/3` (auto-replies with `reading/2`). `Crank.Server.start_from_snapshot/2` → `Crank.Server.resume/2`. Added `Crank.Server.reading/2` for read-only projection.
- **Persistence simplified**: `from_snapshot/1` and `resume/3` collapsed into a single `resume/1` taking a snapshot map.
- **Want types**: the vocabulary of effects is now `{:after, ms, event}`, `{:next, event}`, `{:send, dest, msg}`, `{:telemetry, name, measurements, metadata}`. Named timeouts, postpone, hibernate, and `:state_timeout` no longer have a direct surface (state timeouts are what `:after` compiles to; other gen_statem escape hatches can be added later if requested).

### Added

- Moore discipline enforced structurally — `turn/3` has no way to declare effects on an edge.
- `can_turn!/2` — asserts a transition is valid, raises if not.
- `reading/2` — canonical projection for external observation. Both `Crank.reading/1` and `Crank.Server.turn/2` use it.
- `Crank.Server.reading/1` — read-only query of current reading. Does not call `turn/3`.
- `engine` field distinguishes the machine's domain state from its lifecycle flag.

### Removed

- `handle_event/4` callback.
- `on_enter/3` callback.
- Actions on transitions (4-tuple `{:next_state, state, data, actions}` return).
- Event type argument — all events arrive at `turn/3` with the same signature.
- `Crank.Machine` module (struct folded into `Crank`).

## [0.3.1] - 2026-04-10

### Added

- `Crank.can_crank?/2` — check whether an event would be handled in the current state without attempting the transition. Returns `true` or `false`. Stopped machines always return `false`.

### Fixed

- Documentation warnings: removed auto-linked references to hidden internal modules, fixed broken cross-document link in the hexagonal architecture guide.

## [0.3.0] - 2026-04-08

### Added

- `Crank.snapshot/1` — captures a machine's module, state, and data as a plain map, ready to serialize and persist.
- `Crank.from_snapshot/1` — rebuilds a machine from a snapshot map without calling `init/1`.
- `Crank.resume/3` — same as `from_snapshot/1` with positional arguments (`module`, `state`, `data`).
- `Crank.Server.start_from_snapshot/2` and `start_from_snapshot/4` — start a supervised `gen_statem` process from a snapshot without calling `module.init/1`.
- `[:crank, :resume]` telemetry event — emitted whenever a machine is restored via `from_snapshot/1`, `resume/3`, or `start_from_snapshot/2`.
- `on_enter/3` suppression on resume — resumed machines do not fire the state-enter callback, because they are resuming, not entering a state for the first time.
- Persistence section in the README covering all three storage strategies: snapshot-per-transition, event sourcing, and hybrid.
- Documentation-wide Feynman-style clarity pass: every `@moduledoc`, `@doc`, and `@typedoc` rewritten for concrete-before-abstract explanations, inline jargon definitions, and shorter single-job paragraphs.

### Changed

- The Server adapter now carries a `suppress_next_enter` flag to support the resume path.
- Hexagonal architecture guide restructured: opens with a working persistence adapter in 20 lines, then explains the pattern.
- README restructured: show working code first, explain after, convince third, reference last.

## [0.2.0] - 2026-04-07

### Added

- `handle/3` callback — simplified signature that drops `event_type`. Primary callback for business logic that works in both pure and process contexts.
- `handle_event/4` takes precedence when both callbacks are defined, enabling mixed usage with a one-line catch-all delegation.
- Runtime dispatch in `Crank.crank/2` and the Server adapter — prefers `handle_event/4` if exported, falls back to `handle/3`.
- Validation accepts `handle/3` or `handle_event/4` (at least one required).
- Error messages reference the correct callback name (`handle/3` vs `handle_event/4`).

### Changed

- `handle_event/4` is now an optional callback (was required). Modules can implement `handle/3` instead.
- `@optional_callbacks` updated to `[handle: 3, handle_event: 4, on_enter: 3]`.
- README rewritten with vending machine example throughout (5 states: Idle, Accepting, Dispensing, MakingChange, OutOfStock).
- README restructured around domain-driven design vocabulary: domain model, domain events, anemic model, making illegal states unrepresentable, hexagonal architecture.
- "Why not just use GenServer?" section leads with the simplicity argument: Crank's pure mode is simpler than GenServer.
- Hexagonal architecture guide rewritten with why-first approach and vending machine examples.
- DESIGN.md updated for `handle/3` callback and vending machine struct-per-state examples.
- Package description updated with "finite state machine (FSM)" search terms.

## [0.1.0] - 2026-04-01

### Added

- `Crank` behaviour with `init/1`, `handle_event/4`, and optional `on_enter/3` callbacks
- `Crank.Machine` struct — pure state machine as data, with parameterized `t(state, data)` type
- `Crank.crank/2` and `Crank.crank!/2` — pure transition functions, pipeline-friendly
- `Crank.new/2` — constructor with module validation
- `Crank.Server` — thin `:gen_statem` adapter with zero extra callbacks
- Server adapter — internal gen_statem implementation
- `Crank.StoppedError` — raised when cranking a stopped machine
- Effects as data — actions stored in `machine.effects`, never executed in pure core
- Telemetry — `[:crank, :transition]` events emitted by Server on every state change
- Arity-4 `handle_event(event_type, event_content, state, data)` — same argument order as gen_statem's `handle_event_function` mode
- Event type passthrough — Server passes gen_statem event types directly to callbacks
- `:internal` event type for pure transitions
- Module validation at init (both `Crank.new/2` and the Server adapter's init)
- Invalid callback return detection with clear error messages
- `Crank.Examples.Door` — minimal example (4 states, 4 events)
- `Crank.Examples.Turnstile` — total example (2 states, 2 events, all combinations handled)
- `Crank.Examples.Order` — complex example (5 states, 8 events, effects, on_enter)
- 19 property-based tests across ~80M random cranks
- 6 doctests on all public API functions
- Full `@type`, `@spec`, and `@typedoc` coverage for Elixir's type future
