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
  @spec apply(Turns.t(), timeout()) :: apply_result()
  def apply(%Turns{} = turns, timeout \\ 5_000) do
    steps = Turns.to_list(turns)
    do_apply(steps, %{}, %{}, %{}, timeout)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Core loop
  # ──────────────────────────────────────────────────────────────────────────

  defp do_apply([], results, monitors, _ref_steps, _timeout) do
    demonitor_all(monitors)
    {:ok, results}
  end

  defp do_apply([{name, machine_res, event_res} | rest], results, monitors, ref_steps, timeout) do
    # Drain any late `:DOWN` for refs we already saw alive. The
    # 25ms window in `check_for_down/1` covers the common case;
    # under heavy scheduler load `:DOWN` can land between turns.
    # Catching it here doesn't change attribution (the proper fix
    # is the v2.1 reply-contract change tracked in ROADMAP) but
    # emits `[:crank, :server_turns, :late_down]` telemetry so
    # projects can quantify residual race rate.
    drain_late_down(ref_steps)

    server = resolve(machine_res, results)
    validate_server!(server, name)
    event = resolve(event_res, results)
    {ref, monitors} = ensure_monitor(server, monitors)

    try do
      reading = Crank.Server.turn(server, event, timeout)

      case check_for_down(ref) do
        nil ->
          # Server is alive (or any :DOWN for it arrives beyond the window,
          # which would only happen for causes unrelated to this turn).
          ref_steps = Map.put(ref_steps, ref, %{step: name, server: server})
          do_apply(rest, Map.put(results, name, reading), monitors, ref_steps, timeout)

        reason ->
          # Turn delivered the reading, but the server stopped as a
          # consequence (e.g., stop_and_reply).
          demonitor_all(monitors)
          {:error, name, reason, Map.put(results, name, reading)}
      end
    catch
      :exit, exit_reason ->
        # Pre-existing death, timeout, or crash without reply.
        demonitor_all(monitors)
        {:error, name, {:server_exit, exit_reason}, results}
    end
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

  # Lazily monitor each unique server. Duplicate-target steps reuse the ref.
  defp ensure_monitor(server, monitors) do
    case Map.get(monitors, server) do
      nil ->
        ref = Process.monitor(server)
        {ref, Map.put(monitors, server, ref)}

      ref ->
        {ref, monitors}
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

  defp demonitor_all(monitors) do
    Enum.each(monitors, fn {_server, ref} ->
      Process.demonitor(ref, [:flush])
    end)
  end
end
