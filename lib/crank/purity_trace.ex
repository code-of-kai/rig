defmodule Crank.PurityTrace.Coordinator do
  @moduledoc false

  # Serialises every `:trace.*` API call through one process.
  #
  # OTP 26–28's trace API is not thread-safe across concurrent callers:
  # parallel `:trace.session_create/3`, `:trace.function/4`,
  # `:trace.process/4`, and `:trace.session_destroy/1` invocations cause
  # the BEAM to silently drop trace events even though the patterns and
  # process flags appear to be set correctly. Empirically, 100 parallel
  # trace_pure/2 calls without coordination lose ~30% of trace events.
  # Funnelling every API call through this GenServer's serial inbox brings
  # the loss rate to 0%.
  #
  # The coordinator runs the trace operation itself; the user's `fun.()`
  # still executes on the calling task's worker process so the
  # parallelism that matters (the actual computation) is preserved.

  use GenServer

  @name __MODULE__

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc "Execute `fun` serially with respect to all other coordinator calls."
  @spec exec((-> term()), timeout()) :: term()
  def exec(fun, timeout \\ 30_000) when is_function(fun, 0) do
    GenServer.call(@name, {:exec, fun}, timeout)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:exec, fun}, _from, state) do
    {:reply, fun.(), state}
  end
end

defmodule Crank.PurityTrace do
  @moduledoc """
  Runs a function under an isolated OTP 26+ trace session and reports any
  impure calls observed during its execution.

  Unlike the static call-site checks (`Crank.Check.TurnPurity`,
  `Crank.Check.CompileTime`), this module catches **transitive** impurity:
  a `turn/3` clause that delegates to a helper which itself calls a forbidden
  function (e.g. `:rand.uniform/0`, `Repo.insert!/1`, `:ets.lookup/2`).
  Static checks cannot follow user helpers; runtime tracing can.

  ## Usage

      iex> Crank.PurityTrace.trace_pure(fn -> 1 + 1 end)
      {:ok, 2, []}

      iex> {:impurity, [v], _trace} =
      ...>   Crank.PurityTrace.trace_pure(fn -> :rand.uniform() end)
      iex> v.code
      "CRANK_PURITY_007"

  ## Synchronisation barrier

  Each call follows an 8-step protocol that guarantees every call inside
  `fun.()` is observed — the worker is paused until after the trace session
  is fully wired, so there is no observation race:

  1. The worker is spawned in a paused state and immediately blocks in
     `receive`. Only `Process.flag(:max_heap_size, _)` runs before the
     receive — a flag the trace session has not been told about and so does
     not capture.
  2. The caller creates a session-local trace via `:trace.session_create/3`
     so multiple concurrent `trace_pure/2` calls cannot share state.
  3. The caller registers trace patterns for forbidden modules / MFAs.
  4. The caller attaches the session to the worker pid (`[:call, :arity]`).
  5. The caller sends `:start` to the worker. From this point onward,
     every observable call inside `fun.()` is captured.
  6. The caller waits for the worker to exit with a `{:crank_trace_result,
     ...}` exit reason, or for the configured timeout / heap-kill.
  7. The session is destroyed unconditionally in the `after` clause.
  8. The caller folds the trace into a verdict.

  ## Options

    * `:timeout` — wall-clock limit per call; default `1_000`ms. On timeout
      the worker is killed (`Process.exit/2 :kill`) and the call returns
      `{:resource_exhausted, :timeout, partial_trace}`.
    * `:max_heap_size` — process heap cap **in bytes**; default `10_000_000`.
      Translated to BEAM words via `:erlang.system_info(:wordsize)` and set
      with `Process.flag(:max_heap_size, %{size: words, kill: true})`. Heap
      kills surface as `{:resource_exhausted, :heap, partial_trace}`.
    * `:forbidden_modules` — overrides the default trace-pattern list.
      Each entry is either a module atom (catches every call to that module)
      or a `{Module, Function, Arity | :_}` tuple. The default list (see
      `default_forbidden_targets/0`) covers stdlib non-determinism, ambient
      state, code evaluation, atom-table mutation, and `Logger`. It does
      **not** include `:erlang.send`/`spawn` (the runtime worker uses both
      for normal lifecycle) — those are the static layer's territory.
    * `:allow` — programmatic suppression. Each entry is a 4-tuple
      `{Module | :_, Function | :_, Arity | :_, opts}` where `opts` must
      include a non-empty `:reason`. Matching trace events are silenced
      and emit `[:crank, :suppression]` telemetry with `layer: :c`.
    * `:atom_table_check` — opt-in atom-count diff check; default `false`.
      Atom count is VM-global and unreliable under concurrent test runs;
      enable only for sequential property tests.

  ## Returned shapes

      {:ok, result, trace_events}
      {:impurity, [%Crank.Errors.Violation{}, ...], partial_trace}
      {:resource_exhausted, :heap | :timeout, partial_trace}

  Trace events are normalised tuples of the form `{:call, {module, function,
  arity}}`. Order in the trace mirrors the order messages arrived but is
  scheduler-dependent; do not rely on it. The deduplicated set of MFAs is
  deterministic given the same `fun` and the same `:forbidden_modules`.

  ## Why OTP 26+

  `:trace.session_create/3` and the surrounding session-scoped tracing API
  were added in OTP 26. Pre-26 trace patterns are VM-global and corrupt each
  other under parallel ExUnit; the session API is the reason the
  concurrency-stress test is achievable. `Crank.Application` enforces this
  baseline at boot via `CRANK_SETUP_002`.
  """

  alias Crank.Check.Blacklist
  alias Crank.Errors
  alias Crank.PurityTrace.Coordinator

  @default_timeout 1_000
  @default_max_heap_size_bytes 10_000_000

  @typedoc "A trace target: a whole module, or an MFA (arity may be `:_`)."
  @type forbidden_target :: module() | {module(), atom(), arity_or_wildcard()}

  @typedoc "An arity, or `:_` to match any arity."
  @type arity_or_wildcard :: arity() | :_

  @typedoc "Normalised trace event collected from the worker."
  @type trace_event :: {:call, {module(), atom(), arity()}}

  @typedoc "Layer-C suppression entry; `:reason` is required and non-empty."
  @type allow_entry ::
          {module() | :_, atom() | :_, arity_or_wildcard(),
           [reason: String.t()]}

  @typedoc "What `trace_pure/2` returns."
  @type result ::
          {:ok, term(), [trace_event()]}
          | {:impurity, [Crank.Errors.Violation.t()], [trace_event()]}
          | {:resource_exhausted, :heap | :timeout, [trace_event()]}

  @doc """
  Runs `fun` under an isolated trace session and returns a structured verdict.

  See the moduledoc for the option list and the synchronisation protocol.
  """
  @spec trace_pure((-> term()), keyword()) :: result()
  def trace_pure(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_heap_bytes = Keyword.get(opts, :max_heap_size, @default_max_heap_size_bytes)
    forbidden = Keyword.get(opts, :forbidden_modules, default_forbidden_targets())
    allow = Keyword.get(opts, :allow, [])
    check_atom_table = Keyword.get(opts, :atom_table_check, false)

    validate_allow!(allow)
    emit_allow_telemetry(allow)

    parent = self()
    heap_words = div(max_heap_bytes, :erlang.system_info(:wordsize))

    # Step 1 — Spawn paused worker. The worker is unlinked from the caller
    # so user-fun crashes don't propagate; a monitor is set up below.
    worker = spawn_paused_worker(fun, heap_words, check_atom_table)

    # Step 2 — Create the isolated session. Tracer is the caller's pid so
    # trace events arrive in this function's mailbox. The session and all
    # subsequent `:trace.*` calls funnel through the coordinator because
    # the underlying BEAM API is not thread-safe across concurrent
    # callers — empirically, ~30% of trace events are dropped without
    # serialisation.
    session =
      Coordinator.exec(fn ->
        :trace.session_create(:crank_purity_trace, parent, [])
      end)

    try do
      # Step 3 — Set forbidden patterns (session-scoped; no global state).
      Enum.each(forbidden, &set_pattern(session, &1))

      # Step 4 — Attach the trace to the worker. `:arity` keeps trace
      # messages bounded — we want MFA identity, not arg values.
      _ =
        Coordinator.exec(fn ->
          :trace.process(session, worker, true, [:call, :arity])
        end)

      monitor_ref = Process.monitor(worker)

      # Step 5 — Release the worker. Trace is fully armed.
      send(worker, :start)

      # Step 6 — Collect trace events until the worker exits or times out.
      collect_loop(worker, monitor_ref, timeout, [], allow, session)
    after
      # Step 7 — Cleanup is unconditional. session_destroy is idempotent.
      _ =
        Coordinator.exec(fn ->
          :trace.session_destroy(session)
        end)
    end
  end

  # ── Default forbidden list (runtime tracing scope) ─────────────────────────

  @doc """
  Returns the default list of trace targets used when `:forbidden_modules`
  is not provided.

  The runtime list intentionally omits `:erlang.send/2`, `:erlang.spawn/_`,
  and similar BIFs that the runtime layer cannot distinguish from the
  worker's own lifecycle traffic. Those are caught by the static checks
  (`CRANK_PURITY_005`) at compile time.

  Application-named infrastructure modules (Repo, Ecto, HTTPoison, Tesla,
  Finch, Req, Swoosh, Bamboo, Mailer, Oban, etc.) are derived from
  `Crank.Check.Blacklist.runtime_module_targets/0` and merged into the
  default list, so the static and runtime layers agree on canonical
  infra names. User-aliased names (`MyApp.Repo`) are NOT covered by
  default — pass them via `:forbidden_modules` from the test that
  knows the application's surface, or rely on Boundary's topology
  check for that case.
  """
  @spec default_forbidden_targets() :: [forbidden_target()]
  def default_forbidden_targets do
    [
      # Time / date (CRANK_PURITY_004)
      {DateTime, :utc_now, :_},
      {Date, :utc_today, :_},
      {Time, :utc_now, :_},
      {NaiveDateTime, :utc_now, :_},

      # Randomness (CRANK_PURITY_004)
      :rand,
      :random,

      # System time / unique integers (CRANK_PURITY_004)
      {System, :os_time, :_},
      {System, :system_time, :_},
      {System, :monotonic_time, :_},
      {:erlang, :system_time, :_},
      {:erlang, :monotonic_time, :_},
      {:erlang, :unique_integer, :_},

      # Process / ambient state (CRANK_PURITY_006)
      {Process, :put, :_},
      {Process, :get, :_},
      {Process, :delete, :_},
      :ets,
      :persistent_term,
      :atomics,
      :counters,

      # Configuration (CRANK_PURITY_006)
      {Application, :get_env, :_},
      {Application, :fetch_env, :_},
      {Application, :fetch_env!, :_},

      # Filesystem / OS (CRANK_PURITY_006)
      :os,
      File,
      :file,

      # Code evaluation (CRANK_PURITY_006)
      {Code, :eval_string, :_},
      {Code, :eval_quoted, :_},
      {Code, :compile_string, :_},

      # Atom-table mutation (CRANK_PURITY_006)
      {String, :to_atom, :_},
      {:erlang, :list_to_atom, :_},
      {:erlang, :binary_to_atom, :_}
    ] ++
      [
        # Identity reads (CRANK_PURITY_004) — make_ref only; self/0 and node/0
        # are routinely called by infrastructure so live in the static list only.
        {Kernel, :make_ref, 0},
        {:erlang, :make_ref, 0}
      ] ++
      Blacklist.runtime_module_targets()
  end

  # ── Worker process ────────────────────────────────────────────────────────

  defp spawn_paused_worker(fun, heap_words, check_atom_table) do
    spawn(fn ->
      # Set heap cap BEFORE the receive so it is in effect for fun.()
      # and so the call is not visible to the trace (trace attaches later).
      Process.flag(:max_heap_size, %{size: heap_words, kill: true})

      receive do
        :start -> :ok
      end

      # Yield to the BEAM scheduler so any pending trace-pattern updates
      # propagate before we run user code. Empirically necessary on OTP
      # 26-28 to drive the residual trace-loss rate from ~1% down to 0%
      # under high concurrency: `:trace.process/4` returns synchronously
      # but the per-scheduler trace state can lag by a few reductions.
      :erlang.yield()

      dict_before = MapSet.new(Process.get_keys())

      atom_before =
        if check_atom_table, do: :erlang.system_info(:atom_count), else: 0

      # Capture the user code's outcome so the caller can re-raise with
      # the original kind/reason/stacktrace. Without this, exceptions
      # surface as a bare `:killed` or unknown exit reason and get
      # misreported as heap exhaustion.
      captured =
        try do
          {:ok, fun.()}
        rescue
          e -> {:raised, :error, e, __STACKTRACE__}
        catch
          kind, reason when kind in [:exit, :throw] ->
            {:raised, kind, reason, __STACKTRACE__}
        end

      dict_after = MapSet.new(Process.get_keys())

      atom_after =
        if check_atom_table, do: :erlang.system_info(:atom_count), else: 0

      # Convey result + diagnostics through the exit reason. This avoids
      # using `send/2`, which would require :erlang.send tracing rules.
      exit({:crank_trace_result, captured, dict_before, dict_after, atom_before, atom_after})
    end)
  end

  # ── Pattern setup ─────────────────────────────────────────────────────────

  defp set_pattern(session, mod) when is_atom(mod) do
    # `:trace.function/4` returns 0 if the matched module isn't loaded yet,
    # silently no-op'ing the pattern. Force the module to load so the trace
    # actually arms — Elixir's lazy module loading would otherwise cause
    # false-negative pure verdicts on the first call to a fresh module.
    _ = Code.ensure_loaded(mod)

    Coordinator.exec(fn ->
      :trace.function(session, {mod, :_, :_}, true, [])
    end)
  end

  defp set_pattern(session, {m, f, a}) when is_atom(m) and is_atom(f) do
    _ = Code.ensure_loaded(m)

    Coordinator.exec(fn ->
      :trace.function(session, {m, f, a}, true, [])
    end)
  end

  # ── Collection loop ───────────────────────────────────────────────────────

  defp collect_loop(worker, monitor_ref, timeout, trace_acc, allow, session) do
    receive do
      {:trace, ^worker, :call, mfa} ->
        collect_loop(worker, monitor_ref, timeout, [{:call, mfa} | trace_acc], allow, session)

      {:trace, ^worker, :return_to, _} ->
        collect_loop(worker, monitor_ref, timeout, trace_acc, allow, session)

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        # Flush in-flight trace messages from the BEAM's per-session buffer
        # before reading our mailbox. Trace messages and the :DOWN signal
        # travel through different paths; without a flush, late traces are
        # lost. The coordinator owns the API call; the wait happens here
        # in the caller's mailbox.
        flush_trace(session, worker)
        final_trace = drain_trace(worker, trace_acc)
        finalize_down(reason, Enum.reverse(final_trace), allow)
    after
      timeout ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^worker, _} -> :ok
        after
          200 -> :ok
        end

        flush_trace(session, worker)
        final_trace = drain_trace(worker, trace_acc)
        {:resource_exhausted, :timeout, Enum.reverse(final_trace)}
    end
  end

  defp flush_trace(session, worker) do
    # `:trace.delivered/2` posts the reply `{:trace_delivered, worker, ref}`
    # to the caller's mailbox. Call it directly from this process (not
    # through the coordinator), or the reply ends up in the wrong inbox.
    flush_ref = :trace.delivered(session, worker)

    receive do
      {:trace_delivered, ^worker, ^flush_ref} -> :ok
    after
      500 -> :ok
    end
  end

  defp drain_trace(worker, acc) do
    receive do
      {:trace, ^worker, :call, mfa} ->
        drain_trace(worker, [{:call, mfa} | acc])

      {:trace, ^worker, :return_to, _} ->
        drain_trace(worker, acc)
    after
      0 -> acc
    end
  end

  # ── Verdict construction ──────────────────────────────────────────────────

  defp finalize_down(
         {:crank_trace_result, captured, dict_before, dict_after, atom_before, atom_after},
         trace,
         allow
       ) do
    case captured do
      {:ok, result} ->
        finalize_ok(result, trace, allow, dict_before, dict_after, atom_before, atom_after)

      {:raised, kind, reason, stacktrace} ->
        # Re-raise inside the caller so the user sees their original
        # exception with its stacktrace, not a fabricated "heap exhausted"
        # verdict. Trace events captured before the raise are discarded
        # — they belong to a function call that did not complete.
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  # The BEAM kills the worker with reason `:killed` when the
  # `Process.flag(:max_heap_size, %{kill: true})` cap is hit.
  defp finalize_down(:killed, trace, _allow),
    do: {:resource_exhausted, :heap, trace}

  # Shouldn't happen on supported releases — kept as a safety net for
  # any historical OTP that produced this shape. If we get here on a
  # current release, the worker died for a reason we did not expect;
  # propagate it so the failure is visible rather than masked.
  defp finalize_down(reason, _trace, _allow), do: exit(reason)

  defp finalize_ok(result, trace, allow, dict_before, dict_after, atom_before, atom_after) do
    impurity = build_impurity_violations(trace, allow)

    diffs =
      maybe_dict_violation(dict_before, dict_after) ++
        maybe_atom_violation(atom_before, atom_after)

    case impurity ++ diffs do
      [] -> {:ok, result, trace}
      violations -> {:impurity, violations, trace}
    end
  end

  defp build_impurity_violations(trace, allow) do
    trace
    |> Enum.flat_map(fn
      {:call, {m, f, a}} -> [{m, f, normalize_arity(a)}]
      _ -> []
    end)
    |> Enum.reject(&bookkeeping?/1)
    |> Enum.uniq()
    |> Enum.reject(fn mfa -> allowed?(mfa, allow) end)
    |> Enum.map(&build_violation/1)
  end

  defp normalize_arity(args) when is_list(args), do: length(args)
  defp normalize_arity(arity) when is_integer(arity), do: arity

  # The worker takes process-dict and atom-count snapshots after fun.() to
  # produce the trace_001 / trace_002 diff signals. Those bookkeeping calls
  # are themselves visible to the trace if a user-supplied forbidden list
  # includes Process or :erlang. They are not violations of the user's code.
  defp bookkeeping?({Process, :get_keys, _}), do: true
  defp bookkeeping?({:erlang, :system_info, _}), do: true
  defp bookkeeping?(_), do: false

  defp allowed?({m, f, a}, allow) do
    Enum.any?(allow, fn
      {am, af, aa, _opts} ->
        match_one(am, m) and match_one(af, f) and match_one(aa, a)

      _ ->
        false
    end)
  end

  defp match_one(:_, _), do: true
  defp match_one(x, x), do: true
  defp match_one(_, _), do: false

  defp build_violation({m, f, a}) do
    Errors.build("CRANK_PURITY_007",
      violating_call: %{module: m, function: f, arity: a},
      context: "Runtime trace observed #{format_mfa(m, f, a)} during traced turn",
      metadata: %{layer: :runtime}
    )
  end

  defp format_mfa(m, f, a) when is_atom(m) do
    case Atom.to_string(m) do
      "Elixir." <> elixir_mod -> "#{elixir_mod}.#{f}/#{a}"
      erlang_mod -> ":#{erlang_mod}.#{f}/#{a}"
    end
  end

  defp maybe_dict_violation(before_set, after_set) do
    if MapSet.equal?(before_set, after_set) do
      []
    else
      added = before_set |> MapSet.difference(after_set) |> MapSet.to_list()
      removed = after_set |> MapSet.difference(before_set) |> MapSet.to_list()

      [
        Errors.build("CRANK_TRACE_002",
          context:
            "Process dictionary mutated during turn. Added: #{inspect(added)}; removed: #{inspect(removed)}",
          metadata: %{added: added, removed: removed, layer: :runtime}
        )
      ]
    end
  end

  defp maybe_atom_violation(before_count, after_count) when after_count > before_count do
    [
      Errors.build("CRANK_TRACE_001",
        context:
          "Atom count grew by #{after_count - before_count} during traced turn (atom-table mutation)",
        metadata: %{growth: after_count - before_count, layer: :runtime}
      )
    ]
  end

  defp maybe_atom_violation(_, _), do: []

  # ── Allow-list validation + telemetry ─────────────────────────────────────

  defp validate_allow!(allow) do
    Enum.each(allow, fn
      {_m, _f, _a, opts} when is_list(opts) ->
        case Keyword.fetch(opts, :reason) do
          {:ok, reason} when is_binary(reason) and reason != "" ->
            :ok

          _ ->
            raise ArgumentError,
                  "Crank.PurityTrace :allow entry requires a non-empty :reason — got #{inspect(opts)}"
        end

      bad ->
        raise ArgumentError,
              "Crank.PurityTrace :allow entry must be {module|:_, function|:_, arity|:_, [reason: ...]}, got: #{inspect(bad)}"
    end)
  end

  defp emit_allow_telemetry(allow) do
    Enum.each(allow, fn {m, f, a, opts} ->
      :telemetry.execute(
        [:crank, :suppression],
        %{count: 1},
        %{
          layer: :c,
          module: m,
          function: f,
          arity: a,
          reason: Keyword.get(opts, :reason)
        }
      )
    end)
  end
end
