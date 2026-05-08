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
  # Process-dictionary key namespace for the accumulating ref_steps
  # map. The actual slot key is `{@ref_steps_key, call_key}` where
  # `call_key` is a fresh `make_ref/0` per `apply/2` invocation.
  #
  # Why a unique per-call key:
  #
  # 1. **Re-entrancy.** A resolver function inside `do_apply/4` can
  #    call `Crank.Server.Turns.apply/2` again on the same process.
  #    Each call gets its own unique slot — no save/restore dance,
  #    no inner clobbering the outer.
  #
  # 2. **Corruption resistance.** Resolver code is arbitrary. A
  #    resolver cannot accidentally write to our slot because it
  #    cannot guess the unique `make_ref/0` we're keying with. A
  #    deliberately malicious resolver could iterate the process
  #    dict and find our key, but per the Crank threat model
  #    deliberate sabotage is out of scope (`unsafePerformIO`-
  #    equivalents exist in every static system).
  #
  # 3. **No global slot to leak.** When apply/2 returns, the slot
  #    is deleted. Nothing of ours remains in the process dict.
  #
  # The state has to live in the process dict (not in function
  # args) because `try/after` cleanup needs access to it after a
  # recursive frame has been unwound by an exception of any kind
  # (`:exit`, `:error`, `:throw`); function locals from deep
  # frames are gone by then.
  @ref_steps_key {__MODULE__, :ref_steps}

  @spec apply(Turns.t(), timeout()) :: apply_result()
  def apply(%Turns{} = turns, timeout \\ 5_000) do
    steps = Turns.to_list(turns)
    call_key = make_ref()
    slot = {@ref_steps_key, call_key}
    Process.put(slot, %{})

    try do
      do_apply(steps, %{}, %{}, call_key, timeout)
    after
      # Cleanup is best-effort and decomposed: drain, flush, and
      # slot-delete each run independently so one failure doesn't
      # block the others. The unique per-call key (see
      # `@ref_steps_key` doc) makes accidental slot corruption
      # structurally impossible; the per-step `safe_run/2` wrapping
      # is defense-in-depth against unanticipated raises in
      # `:trace`-related code or BIF edge cases.
      #
      # Failures are NOT silently swallowed: each catch emits
      # `[:crank, :server_turns, :cleanup_failure]` telemetry with
      # the failing step's label, exception kind, reason, and
      # stacktrace. Projects monitoring that event can detect
      # mailbox-hygiene compromises that the return value can't
      # otherwise express.
      #
      # The wrapping does NOT defend against deliberate sabotage
      # (a resolver iterating `Process.get/0`, finding the unique
      # key, and mutating the value). That's out of scope per the
      # Crank threat model — see `plans/purity-enforcement.md`.
      ref_steps = Process.get(slot, %{})
      safe_run(:drain_late_down, fn -> drain_late_down(ref_steps) end)
      safe_run(:flush_all_refs, fn -> flush_all_refs(ref_steps) end)
      Process.delete(slot)
    end
  end

  @doc """
  Runs `fun` and reports any exception via
  `[:crank, :server_turns, :cleanup_failure]` telemetry instead of
  letting it propagate. Returns `:ok` regardless.

  Public so tests can drive the helper directly with a raising
  function and verify telemetry fires; in production it's only
  called from `apply/2`'s after-block.
  """
  @spec safe_run(atom(), (-> any())) :: :ok
  def safe_run(label, fun) when is_atom(label) and is_function(fun, 0) do
    fun.()
    :ok
  rescue
    e -> emit_cleanup_failure(label, :error, e, __STACKTRACE__)
  catch
    kind, reason -> emit_cleanup_failure(label, kind, reason, __STACKTRACE__)
  end

  # Emit `[:crank, :server_turns, :cleanup_failure]` with bounded,
  # structured metadata. We intentionally do NOT include the raw
  # exception term or full stacktrace: stacktraces commonly embed
  # caller arguments (which can carry user data), and downstream
  # telemetry handlers often forward metadata into APMs/logs.
  # Redacting at the source — exception module + truncated message
  # + top stack frames — preserves the diagnostic value (you still
  # know what failed and where) without arbitrary payload export.
  defp emit_cleanup_failure(label, kind, reason, stacktrace) do
    :telemetry.execute(
      [:crank, :server_turns, :cleanup_failure],
      %{},
      %{
        label: label,
        kind: kind,
        exception_module: exception_module(kind, reason),
        message: bounded_message(kind, reason),
        top_frames: top_stack_frames(stacktrace, 5)
      }
    )

    :ok
  end

  defp exception_module(:error, %{__struct__: mod}), do: mod
  defp exception_module(:throw, _reason), do: :throw
  defp exception_module(:exit, _reason), do: :exit
  defp exception_module(_, _), do: :unknown

  @max_message_chars 500

  defp bounded_message(:error, exception) do
    truncate(Exception.message(exception), @max_message_chars)
  rescue
    _ -> ""
  end

  defp bounded_message(:throw, reason), do: truncate(inspect(reason), @max_message_chars)
  defp bounded_message(:exit, reason), do: truncate(inspect(reason), @max_message_chars)
  defp bounded_message(_, reason), do: truncate(inspect(reason), @max_message_chars)

  defp truncate(s, max_bytes) when byte_size(s) <= max_bytes, do: s

  # Codex review #20 (2026-05-08): `binary_part/3` cuts at byte
  # boundaries and would produce invalid UTF-8 if the cut landed
  # mid-codepoint. Telemetry handlers serialising metadata to
  # JSON/log sinks crash on invalid UTF-8, and Telemetry then
  # detaches the failing handler — killing the very observability
  # the cleanup_failure event was meant to provide.
  #
  # Walk codepoints, accumulating until the next one would exceed
  # the byte budget. Output is always valid UTF-8 by construction.
  defp truncate(s, max_bytes) do
    truncate_to_bytes(s, max_bytes, <<>>) <> "…"
  end

  defp truncate_to_bytes(<<>>, _max, acc), do: acc

  defp truncate_to_bytes(<<c::utf8, rest::binary>>, max, acc) do
    candidate = <<acc::binary, c::utf8>>

    if byte_size(candidate) > max do
      acc
    else
      truncate_to_bytes(rest, max, candidate)
    end
  end

  # Fallback for malformed UTF-8: stop at whatever's already valid.
  defp truncate_to_bytes(_invalid_remainder, _max, acc), do: acc

  @doc """
  Truncates an Erlang stacktrace to the top `count` frames and
  normalises each frame to a plain map shape suitable for
  inclusion in telemetry metadata.

  Erlang's stacktrace entry spec admits two shapes:

    * `{Module, Function, Arity | Args, Location}` — named
      function call frame.
    * `{Fun, Arity | Args, Location}` — anonymous function call
      frame.

  Pattern-matches both and falls back to a generic shape for
  anything outside the spec so telemetry emission cannot raise
  on a stacktrace entry it doesn't recognise.

  Public for direct testing of the redaction layer.
  """
  @spec top_stack_frames([term()], non_neg_integer()) :: [map()]
  def top_stack_frames(stacktrace, count) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(count)
    |> Enum.map(&format_frame/1)
  end

  defp format_frame({mod, fun, arity_or_args, location})
       when is_atom(mod) and is_atom(fun) and is_list(location) do
    %{
      module: mod,
      function: fun,
      arity: normalize_arity(arity_or_args),
      file: Keyword.get(location, :file),
      line: Keyword.get(location, :line)
    }
  end

  # Use `:erlang.fun_info/2` (per-field) rather than the 1-arg
  # form. The 1-arg form returns the full info keyword list,
  # which includes `{:env, captures}` for local funs and so
  # materializes the captured environment even if we only read
  # `:module` and `:name`. A fun capturing a large binary would
  # allocate a copy on every cleanup-failure emission — the
  # exact path that needs to stay lean.
  #
  # Per-field calls return only the requested atom value
  # (`{:module, mod}` and `{:name, atom}` — no env, no other
  # captures), preserving diagnostic value without the
  # closure environment.
  defp format_frame({fun, arity_or_args, location})
       when is_function(fun) and is_list(location) do
    %{
      module: fun_info_value(fun, :module),
      function: fun_info_value(fun, :name),
      arity: normalize_arity(arity_or_args),
      file: Keyword.get(location, :file),
      line: Keyword.get(location, :line)
    }
  end

  defp format_frame(_other) do
    %{module: nil, function: nil, arity: nil, file: nil, line: nil}
  end

  defp fun_info_value(fun, key) do
    case :erlang.fun_info(fun, key) do
      {^key, value} -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_arity(arity_or_args) when is_list(arity_or_args), do: length(arity_or_args)
  defp normalize_arity(arity) when is_integer(arity), do: arity
  defp normalize_arity(_), do: nil

  # ──────────────────────────────────────────────────────────────────────────
  # Core loop
  # ──────────────────────────────────────────────────────────────────────────

  defp do_apply([], results, _monitors, _call_key, _timeout) do
    {:ok, results}
  end

  defp do_apply([{name, machine_res, event_res} | rest], results, monitors, call_key, timeout) do
    server = resolve(machine_res, results)
    validate_server!(server, name)
    event = resolve(event_res, results)
    {ref, monitors} = ensure_monitor(server, monitors)
    track_ref(call_key, ref, name, server)

    try do
      reading = Crank.Server.turn(server, event, timeout)

      case check_for_down(ref) do
        nil ->
          # Server is alive (or any :DOWN for it arrives beyond the window,
          # which would only happen for causes unrelated to this turn).
          do_apply(rest, Map.put(results, name, reading), monitors, call_key, timeout)

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

  # Append a ref to the per-call ref_steps map. The slot is keyed
  # by `call_key` (a `make_ref/0` unique to this `apply/2`
  # invocation), so concurrent / nested apply calls on the same
  # process can't clobber each other.
  defp track_ref(call_key, ref, step, server) do
    slot = {@ref_steps_key, call_key}
    current = Process.get(slot, %{})
    Process.put(slot, Map.put(current, ref, %{step: step, server: server}))
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
