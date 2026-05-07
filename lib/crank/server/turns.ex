defmodule Crank.Server.Turns do
  @moduledoc """
  Process-mode executor for `%Crank.Turns{}` descriptors.

  The same descriptor that drives `Crank.Turns.apply/1` in pure mode drives
  this executor against running `Crank.Server` processes. Pid, registered
  name, or `{name, node}` tuple — whatever `Crank.Server.turn/2` accepts.

  ## Execution semantics

  Same best-effort sequential behavior as `Crank.Turns.apply/1`:

  - Steps run in order.
  - Later steps can reference prior successful results by name.
  - On the first stop (or process death), returns
    `{:error, name, reason, advanced_so_far}`.
  - On full success, returns `{:ok, results}`.

  ## Result shape differs from pure mode

  Each entry in `results` is the **reading** returned by `Crank.Server.turn/2`
  — the projection from `c:Crank.reading/2`, not a `%Crank{}` struct. Process
  mode has no access to the internal `%Crank{}`; the reply contract is the
  reading only. This mirrors the single-turn process-mode contract.

  ## How stops are detected — monitors

  Before each turn, the executor establishes a `Process.monitor/1` on the
  target server (lazily, memoized for duplicate targets across steps). After
  `Crank.Server.turn/2` returns, the executor waits briefly (a few ms) for
  a `:DOWN` message on that monitor. Erlang guarantees `:DOWN` arrives after
  the last message from the monitored process — so if the server stopped
  as a consequence of the turn (for example, `{:stop_and_reply, ...}`), the
  `:DOWN` is in-transit immediately after the reply. The small wait lets
  the VM finish delivery.

  If no `:DOWN` arrives in that window, the server is treated as alive and
  execution continues. `Process.alive?/1` is intentionally NOT used: it
  returns true during gen_statem termination cleanup, reporting "alive"
  for a process that has already replied-then-stopped.

  On completion (success or error), every monitor is demonitored with
  `[:flush]` so no `:DOWN` messages leak into the caller's mailbox.

  ## Race and exit handling

  If the server dies BEFORE the turn call can reach it (pre-existing death,
  crash during routing), `Crank.Server.turn/2` exits — this is caught and
  reported as `{:error, name, {:server_exit, exit_reason}, prior_results}`.
  The failing step's server is NOT in `advanced_so_far` because no reading
  was ever received.

  ## When to use

  Use `Crank.Server.Turns.apply/1` when you want to advance multiple running
  machines as one caller action — a user submitting an order, an operator
  issuing a command, an incoming webhook fanning out to several aggregates.
  For pure-data composition (tests, snapshots, dry runs), use
  `Crank.Turns.apply/1`.

  The descriptor is identical across modes; only the executor changes.

  ## Example

      {:ok, order_pid}    = Crank.Server.start_link(MyApp.Order, ...)
      {:ok, payment_pid}  = Crank.Server.start_link(MyApp.Payment, ...)

      Crank.Turns.new()
      |> Crank.Turns.turn(:order, order_pid, :submit)
      |> Crank.Turns.turn(:payment, payment_pid,
           fn %{order: reading} -> {:charge, reading.total} end)
      |> Crank.Server.Turns.apply()
      #=> {:ok, %{order: %{status: :submitted, ...}, payment: %{status: :charged, ...}}}
  """

  alias Crank.Turns

  @typedoc "Acceptable target for a process-mode turn."
  @type server :: GenServer.server()

  @typedoc "Map of step name → reading from `Crank.Server.turn/2`."
  @type results :: %{optional(Turns.name()) => term()}

  @typedoc "What `apply/1` returns."
  @type apply_result ::
          {:ok, results()}
          | {:error, Turns.name(), reason :: term(), results()}

  @doc """
  Executes the descriptor against running `Crank.Server` processes.

  `timeout` is passed to each `Crank.Server.turn/2` call. Defaults to 5000ms.

  Each step's `machine` must resolve to a pid, registered name, or
  `{name, node}` tuple. Dependency resolvers receive the map of prior
  readings keyed by step name.
  """
  # Process-dictionary key holding the accumulating ref_steps map
  # for the in-flight apply. We use the process dict (sparingly,
  # bounded to this function's lifetime) so the top-level
  # `try/after` can read the latest state for cleanup regardless of
  # which exception type — `:exit`, `:error`, `:throw` — escapes
  # the recursive body. Threading state via function args alone
  # cannot reach the after-handler when the deep recursion frame is
  # unwound by an exception.
  #
  # The slot is save-restored across nested calls. A resolver
  # function inside `do_apply/4` could call `Crank.Server.Turns.apply/2`
  # again on the same process; without save-restore the inner call
  # would clobber the outer accumulator and any refs the outer had
  # already tracked would never get drained or demonitored on the
  # outer's exit. `Process.put/2` returns the previous value, which
  # the after-handler restores so the outer scope sees its own
  # refs again.
  @ref_steps_key {__MODULE__, :ref_steps}

  @spec apply(Turns.t(), timeout()) :: apply_result()
  def apply(%Turns{} = turns, timeout \\ 5_000) do
    steps = Turns.to_list(turns)
    prev_ref_steps = Process.put(@ref_steps_key, %{})

    try do
      do_apply(steps, %{}, %{}, timeout)
    after
      # Nested `try/after` so the slot restore happens even if
      # `drain_late_down/1` or `flush_all_refs/1` raises. Without
      # this, a telemetry-handler exception or a corrupted slot
      # value would leave the outer apply's slot in an inconsistent
      # state and reintroduce the cross-call leakage class.
      try do
        ref_steps = sanitize_ref_steps(Process.get(@ref_steps_key))
        drain_late_down(ref_steps)
        flush_all_refs(ref_steps)
      after
        restore_ref_steps_slot(prev_ref_steps)
      end
    end
  end

  # Defensive shape check. The slot SHOULD always hold a map (set by
  # this module's own `Process.put` calls), but resolver code runs
  # in-process and could legitimately or accidentally
  # `Process.put({Crank.Server.Turns, :ref_steps}, garbage)`. Treat
  # anything non-map as "no refs to clean up" rather than crashing
  # cleanup mid-stream.
  defp sanitize_ref_steps(value) when is_map(value), do: value
  defp sanitize_ref_steps(_), do: %{}

  defp restore_ref_steps_slot(nil), do: Process.delete(@ref_steps_key)
  defp restore_ref_steps_slot(prev), do: Process.put(@ref_steps_key, prev)

  # ──────────────────────────────────────────────────────────────────────────
  # Core loop
  # ──────────────────────────────────────────────────────────────────────────

  defp do_apply([], results, _monitors, _timeout) do
    {:ok, results}
  end

  defp do_apply([{name, machine_res, event_res} | rest], results, monitors, timeout) do
    server = resolve(machine_res, results)
    validate_server!(server, name)
    event = resolve(event_res, results)
    {ref, monitors} = ensure_monitor(server, monitors)
    track_ref(ref, name, server)

    try do
      reading = Crank.Server.turn(server, event, timeout)

      case check_for_down(ref) do
        nil ->
          # Server is alive (or any :DOWN for it arrives beyond the window,
          # which would only happen for causes unrelated to this turn).
          do_apply(rest, Map.put(results, name, reading), monitors, timeout)

        reason ->
          # Turn delivered the reading, but the server stopped as a
          # consequence (e.g., stop_and_reply).
          {:error, name, reason, Map.put(results, name, reading)}
      end
    catch
      :exit, exit_reason ->
        # Pre-existing death, timeout, or crash without reply.
        {:error, name, {:server_exit, exit_reason}, results}
    end
  end

  # Append a ref to the in-flight ref_steps map held in the process
  # dict. Reading + writing keeps the apply-scoped accumulator
  # accessible to the top-level `after` handler. Reads pass
  # through `sanitize_ref_steps/1` so a resolver that corrupted
  # the slot mid-run can't crash the next track_ref call — the
  # accumulator resets to empty rather than raising BadMapError.
  defp track_ref(ref, step, server) do
    current = sanitize_ref_steps(Process.get(@ref_steps_key))
    Process.put(@ref_steps_key, Map.put(current, ref, %{step: step, server: server}))
  end

  # End-of-apply cleanup. Drains any late `:DOWN` messages that
  # arrived during the run (emitting telemetry), then flushes any
  # remaining monitor handles for every ref ever created during
  # the apply (not just the latest per server).
  #
  # Order matters: drain first (consumes & emits telemetry for
  # arrived `:DOWN`s), flush second (cleans up the monitor handles
  # for refs that were superseded mid-apply by re-monitoring).
  # Without flushing every historical ref, an old monitor whose
  # `:DOWN` arrives after `apply/2` returns would leak into the
  # caller's mailbox.
  #
  # Why end-of-apply, not between steps? Per-step draining ran a
  # selective `receive` per tracked ref before every step, which is
  # O(N) per step with N growing across the run — O(N²) over the
  # full apply, or worse with non-trivial caller mailboxes. Codex
  # review #7 flagged that as a latency cliff under load. A single
  # drain at completion produces the same telemetry visibility at
  # O(N) total cost, paid once.
  #
  # Why in `apply/2`'s `after` block, not in `do_apply/4`'s success
  # and error returns? Codex review #10 noticed that non-`:exit`
  # exceptions (a resolver function raising, `validate_server!/2`
  # raising, etc.) bypass the inner `catch :exit` clause and
  # propagate up the call stack — bypassing any cleanup expressed
  # at the do_apply level and leaking stale `:DOWN` messages into
  # the caller's mailbox. The `after` block guarantees cleanup
  # runs no matter what exception type escapes.

  defp flush_all_refs(ref_steps) do
    Enum.each(ref_steps, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
  end

  @doc """
  Non-blocking peek for `:DOWN` messages keyed by refs we've already
  observed alive. Each match emits one
  `[:crank, :server_turns, :late_down]` telemetry event; the message
  is consumed so it doesn't leak past `apply/1` even if the caller
  doesn't drain its mailbox afterward.

  Public so tests can drive the drain hermetically with a controlled
  `ref_steps` map and a pre-arrayed `:DOWN` message; in production
  it's only called by `do_apply/5` between turns.
  """
  @spec drain_late_down(%{reference() => %{step: atom(), server: term()}}) :: :ok
  def drain_late_down(ref_steps) when ref_steps == %{}, do: :ok

  def drain_late_down(ref_steps) do
    Enum.each(ref_steps, fn {ref, %{step: step, server: server}} ->
      receive do
        {:DOWN, ^ref, _, _, reason} ->
          :telemetry.execute(
            [:crank, :server_turns, :late_down],
            %{},
            %{step: step, server: server, reason: reason, ref: ref}
          )
      after
        0 -> :ok
      end
    end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers — resolution, monitoring, liveness
  # ──────────────────────────────────────────────────────────────────────────

  defp resolve(fun, results) when is_function(fun, 1), do: fun.(results)
  defp resolve(value, _results), do: value

  # Accepts pid, registered atom, or {atom, atom} for remote registered names.
  defp validate_server!(server, _name) when is_pid(server) or is_atom(server), do: :ok

  defp validate_server!({name, node}, _step_name)
       when is_atom(name) and is_atom(node),
       do: :ok

  defp validate_server!(other, name) do
    raise ArgumentError,
          "Crank.Server.Turns.apply/1: step #{inspect(name)} resolved to " <>
            "#{inspect(other)} — expected a pid, registered name, or {name, node} tuple"
  end

  # Monitor each server fresh per step. A previous version cached the
  # ref across steps targeting the same server key, but for
  # registered-name targets the underlying pid can change between
  # steps (e.g. supervisor restart) — the cached ref points at the
  # dead prior incarnation, leaks a stale `:DOWN` into the mailbox,
  # and the next step's `check_for_down/1` falsely attributes that
  # stop to the wrong (succeeding) turn.
  #
  # `Process.demonitor(old_ref)` is called WITHOUT `[:flush]`. The
  # flush variant would scrub any pending `:DOWN` for the old ref
  # from the mailbox — including the late-arriving `:DOWN` that
  # `drain_late_down/1` is meant to surface as telemetry. By NOT
  # flushing here, we deactivate the old monitor handle (no future
  # `:DOWN` signals) but leave any already-delivered `:DOWN` in
  # the mailbox for end-of-apply accounting. The mailbox is then
  # cleaned up by `flush_all_refs/1` in `finish/3` after telemetry
  # has had its chance to fire.
  #
  # Applies uniformly to pid, registered-atom, and {name, node}
  # targets. For pids the demonitor is a no-op-equivalent (pid never
  # reincarnates), but the symmetry is worth more than the saved
  # round-trip.
  defp ensure_monitor(server, monitors) do
    case Map.get(monitors, server) do
      nil ->
        ref = Process.monitor(server)
        {ref, Map.put(monitors, server, ref)}

      old_ref ->
        Process.demonitor(old_ref)
        ref = Process.monitor(server)
        {ref, Map.put(monitors, server, ref)}
    end
  end

  # Wait briefly for a :DOWN on this specific ref. Erlang's
  # monitor-ordering guarantee says :DOWN arrives after the last
  # message from the monitored process, so if the server stopped
  # during this turn (reply-then-stop), the :DOWN is in-transit
  # immediately after our call returned.
  #
  # `:erlang.yield/0` gives up scheduler time so the dying server's
  # termination can complete before we check. The single bounded
  # `receive` then either picks up the :DOWN or returns nil.
  #
  # **Why a single short wait, not a longer poll loop.** A previous
  # iteration tried a 100ms deadline polled in 20ms slices to absorb
  # extreme scheduler latency. Codex flagged that as a per-step
  # latency tax: the alive-path NEVER matches `:DOWN`, so every
  # successful turn paid the full budget — ~100ms per step in the
  # happy path, O(steps) latency on multi-step pipelines. The fix
  # is the v2.1 reply-contract change tracked in ROADMAP; for v2.0.x
  # we keep the wait short (single 25ms window, slightly above the
  # original 10ms for margin). The residual race under extreme load
  # is the price of keeping process-mode turns fast.
  #
  # Returns the exit reason if :DOWN arrived, or nil if the server is
  # alive. Messages for other refs are left in the mailbox untouched.
  @down_wait_ms 25

  defp check_for_down(ref) do
    :erlang.yield()

    receive do
      {:DOWN, ^ref, _, _, reason} -> reason
    after
      @down_wait_ms -> nil
    end
  end

end
