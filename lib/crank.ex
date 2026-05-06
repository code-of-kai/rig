defmodule Crank do
  @moduledoc """
  A Moore-style state machine as pure data. Same module works in two modes:
  `Crank.turn/2` advances a `%Crank{}` struct with no process; `Crank.Server`
  runs the same callbacks inside `:gen_statem`. See the README for the guide.
  """

  alias Crank.Domain.Pure
  alias Crank.Typing

  @typedoc "A machine. Five fields: `module`, `state`, `memory`, `wants`, `engine`."
  @type t :: %__MODULE__{
          module: module(),
          state: term(),
          memory: term(),
          wants: [want()],
          engine: :running | {:off, term()}
        }

  @typedoc "A side effect a state declares on entry. Interpreted by `Crank.Server`; inert data in pure mode."
  @type want ::
          {:after, non_neg_integer(), event :: term()}
          | {:after, name :: term(), non_neg_integer(), event :: term()}
          | {:cancel, name :: term()}
          | {:send, dest :: pid() | atom() | {atom(), node()}, message :: term()}
          | {:telemetry, event_name :: [atom()], measurements :: map(), metadata :: map()}
          | {:next, event :: term()}

  @typedoc "What `c:turn/3` returns. Pure state computation; no effects."
  @type turn_result ::
          {:next, new_state :: term(), new_memory :: term()}
          | {:stay, new_memory :: term()}
          | :stay
          | {:stop, reason :: term(), new_memory :: term()}

  @typedoc "A portable snapshot: module, state, memory. Plain map, serializable."
  @type snapshot :: %{module: module(), state: term(), memory: term()}

  defstruct [:module, :state, :memory, wants: [], engine: :running]

  # ──────────────────────────────────────────────────────────────────────────
  # Behaviour callbacks
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Starts the machine. Called once by `new/2`. Returns the initial state and memory."
  @callback start(args :: term()) ::
              {:ok, state :: term(), memory :: term()}
              | {:stop, reason :: term()}

  @doc "Transitions the machine. Pure: returns where to go next, never effects."
  @callback turn(event :: term(), state :: term(), memory :: term()) :: turn_result()

  @doc """
  Declares what the state wants on arrival. Must be pure and total — raising
  inside `wants/2` crashes the process. Optional; defaults to `[]`.

  Want types:

  - `{:after, ms, event}` — anonymous state timeout. Fires `event` after `ms`
    milliseconds if the state hasn't changed. Auto-cancels on state-value change.
    Only one anonymous state timeout per state; setting a new one replaces any
    pending.
  - `{:after, name, ms, event}` — named generic timeout. Multiple concurrent
    named timeouts are allowed. Not auto-cancelled on state change; cancel
    explicitly with `{:cancel, name}`.
  - `{:cancel, name}` — cancel a named timeout. No-op if no such timer runs.
  - `{:next, event}` — inject an internal event, processed before any queued
    external event. Use for decomposing one logical transition into two steps.
    **Not** for multi-step workflow orchestration — that belongs in a separate
    Crank module acting as a saga between aggregates.
  - `{:send, dest, message}` — send `message` to `dest` (pid or registered
    name). Fire-and-forget; no delivery verification, no retry. Fires
    synchronously during action-list construction, before the state transition
    commits. Prefer registered names over raw pids for testability.
  - `{:telemetry, event_name, measurements, metadata}` — emit a telemetry
    event.
  """
  @callback wants(state :: term(), memory :: term()) :: [want()]

  @doc """
  Projects the machine for outside observers. Called by `reading/1` and by
  `Crank.Server.turn/2` to form the reply. Optional; defaults to returning
  the raw state.

  Must be pure and total. Raising inside `reading/2` during a `Crank.Server.turn/2`
  call crashes the gen_statem mid-transition — the caller sees an exit and the
  supervisor restarts. Treat this callback as part of the error kernel.
  """
  @callback reading(state :: term(), memory :: term()) :: term()

  @optional_callbacks wants: 2, reading: 2

  # ──────────────────────────────────────────────────────────────────────────
  # Using macro — child_spec for supervision trees
  # ──────────────────────────────────────────────────────────────────────────

  defmacro __using__(opts) do
    boundary_opts = Pure.build_boundary_opts(opts)

    states = expand_states(Keyword.get(opts, :states), __CALLER__)
    memory_struct = expand_alias(Keyword.get(opts, :memory), __CALLER__)

    state_type_ast = Typing.build_state_type(states)
    memory_type_ast = Typing.build_memory_type(memory_struct)
    state_union_attr_ast = Typing.build_state_union_attribute(states)
    memory_module_attr_ast = Typing.build_memory_module_attribute(memory_struct)

    quote location: :keep do
      @behaviour Crank

      # Persistent marker (Mix.Tasks.Compile.Crank reads this via
      # `module.__info__(:attributes)`) so the topology post-processor
      # can identify Crank-domain modules and emit `CRANK_DEP_002` for
      # references into unclassified first-party helpers.
      Module.register_attribute(__MODULE__, :__crank_domain__, persist: true)
      @__crank_domain__ true

      # Topology layer (Phase 1.4): tag this module as a `:domain` Boundary
      # so the post-compile graph check (via `Mix.Tasks.Compile.Crank` →
      # Boundary) rejects cross-boundary references to infrastructure modules.
      # See `Crank.Domain.Pure` for the parallel marker for non-FSM helpers.
      use Boundary, unquote(boundary_opts)

      # Compile-time purity enforcement: capture turn/3 clause bodies as they
      # are defined, then walk them in @before_compile to flag impure calls.
      # Suppression honours # crank-allow: comments per Crank.Suppressions.
      @on_definition Crank.Check.CompileTime
      @before_compile Crank.Check.CompileTime
      Module.register_attribute(__MODULE__, :__crank_turn_bodies__, accumulate: false)

      # Typing layer (Phase 1.7): when `states:` and/or `memory:` are passed,
      # generate the corresponding typespecs and register an additional
      # @before_compile hook that validates turn/3 returns against the
      # declared state union (CRANK_TYPE_003).
      Module.register_attribute(__MODULE__, :__crank_state_union__, accumulate: false)
      Module.register_attribute(__MODULE__, :__crank_memory_module__, accumulate: false)
      unquote(state_union_attr_ast)
      unquote(memory_module_attr_ast)
      unquote(state_type_ast)
      unquote(memory_type_ast)
      @before_compile Crank.Typing

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {Crank.Server, :start_link, [__MODULE__, args, []]},
          restart: unquote(Keyword.get(opts, :restart, :permanent)),
          shutdown: unquote(Keyword.get(opts, :shutdown, 5_000))
        }
      end

      defoverridable child_spec: 1
    end
  end

  # Expand `:states` opt — accepts either a list of alias ASTs (from quoted
  # `[Idle, Active]`) or a list of atom modules; returns a list of resolved
  # module atoms. Returns nil when input is nil.
  defp expand_states(nil, _caller), do: nil
  defp expand_states([], _caller), do: []

  defp expand_states(states, caller) when is_list(states) do
    Enum.map(states, &expand_alias(&1, caller))
  end

  defp expand_alias(nil, _caller), do: nil

  defp expand_alias(atom, _caller) when is_atom(atom), do: atom

  defp expand_alias({:__aliases__, _, _} = alias_ast, caller) do
    Macro.expand(alias_ast, caller)
  end

  defp expand_alias(other, _caller), do: other

  # ──────────────────────────────────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Creates a new machine. Calls `c:start/1`, fires `c:wants/2` for the initial state.

      iex> Crank.Examples.Door |> Crank.new() |> Map.get(:state)
      :locked
  """
  @spec new(module(), term()) :: t()
  def new(module, args \\ []) do
    validate_module!(module)

    case module.start(args) do
      {:ok, state, memory} ->
        %__MODULE__{
          module: module,
          state: state,
          memory: memory,
          wants: wants_for(module, state, memory)
        }

      {:stop, reason} ->
        raise ArgumentError,
              "#{inspect(module)}.start/1 returned {:stop, #{inspect(reason)}}"

      other ->
        raise ArgumentError,
              "#{inspect(module)}.start/1 returned invalid result: #{inspect(other)}"
    end
  end

  @doc """
  Advances the machine by one event. Returns a new `%Crank{}`.

      iex> Crank.Examples.Door |> Crank.new() |> Crank.turn(:unlock) |> Map.get(:state)
      :unlocked
  """
  @spec turn(t(), event :: term()) :: t()
  def turn(%__MODULE__{engine: {:off, reason}} = machine, event) do
    raise Crank.StoppedError,
      module: machine.module,
      state: machine.state,
      event: event,
      reason: reason
  end

  def turn(%__MODULE__{} = machine, event) do
    machine.module.turn(event, machine.state, machine.memory)
    |> apply_turn(machine)
  end

  @doc """
  Like `turn/2`, but raises if the transition stops the machine.

      iex> Crank.Examples.Door |> Crank.new() |> Crank.turn!(:unlock) |> Map.get(:state)
      :unlocked
  """
  @spec turn!(t(), event :: term()) :: t()
  def turn!(%__MODULE__{} = machine, event) do
    case turn(machine, event) do
      %__MODULE__{engine: {:off, reason}} = stopped ->
        raise Crank.StoppedError,
          module: stopped.module,
          state: stopped.state,
          event: event,
          reason: reason

      running ->
        running
    end
  end

  @doc """
  Returns `true` if the machine would handle this event in its current state.
  Stopped machines always return `false`.

      iex> machine = Crank.new(Crank.Examples.Door)
      iex> Crank.can_turn?(machine, :unlock)
      true
      iex> Crank.can_turn?(machine, :open)
      false
  """
  @spec can_turn?(t(), event :: term()) :: boolean()
  def can_turn?(%__MODULE__{engine: {:off, _}}, _event), do: false

  def can_turn?(%__MODULE__{module: module, state: state, memory: memory}, event) do
    module.turn(event, state, memory)
    true
  rescue
    e in FunctionClauseError ->
      # Only a FCE raised from `module.turn/3` itself counts as "cannot turn."
      # A FCE from a helper called by turn/3 is a genuine bug; reraise it.
      if e.module == module and e.function == :turn and e.arity == 3 do
        false
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc "Asserts the machine would handle this event. Raises `FunctionClauseError` if not."
  @spec can_turn!(t(), event :: term()) :: :ok
  def can_turn!(%__MODULE__{} = machine, event) do
    if can_turn?(machine, event) do
      :ok
    else
      raise FunctionClauseError,
        module: machine.module,
        function: :turn,
        arity: 3
    end
  end

  @doc """
  Returns the machine's current reading — the projection of `(state, memory)`
  declared by `c:reading/2`. Defaults to the raw state if the callback is
  not implemented.

      iex> Crank.Examples.Door |> Crank.new() |> Crank.reading()
      :locked
  """
  @spec reading(t()) :: term()
  def reading(%__MODULE__{module: module, state: state, memory: memory}) do
    if function_exported?(module, :reading, 2) do
      module.reading(state, memory)
    else
      state
    end
  end

  @doc """
  Captures a snapshot of the machine: module, state, memory. Plain map,
  serializable, portable across `from_snapshot`-style rebuilds.

      iex> machine = Crank.Examples.Door |> Crank.new() |> Crank.turn(:unlock)
      iex> Crank.snapshot(machine)
      %{module: Crank.Examples.Door, state: :unlocked, memory: %{}}
  """
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{module: module, state: state, memory: memory}) do
    %{module: module, state: state, memory: memory}
  end

  @doc """
  Rebuilds a machine from a snapshot. Does not call `c:start/1` or
  `c:wants/2` — the machine is resuming, not entering. Emits `[:crank, :resume]`.

      iex> snap = %{module: Crank.Examples.Door, state: :unlocked, memory: %{}}
      iex> Crank.resume(snap).state
      :unlocked
  """
  @spec resume(snapshot()) :: t()
  def resume(%{module: module, state: state, memory: memory}) do
    validate_module!(module)

    :telemetry.execute(
      [:crank, :resume],
      %{system_time: System.system_time()},
      %{module: module, state: state, memory: memory}
    )

    %__MODULE__{
      module: module,
      state: state,
      memory: memory,
      wants: wants_for(module, state, memory)
    }
  end

  def resume(other) do
    raise ArgumentError,
          "Crank.resume/1 expected a snapshot map with :module, :state, :memory keys, got: #{inspect(other)}"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────────────────────────────────

  defp apply_turn({:next, state, memory}, machine) do
    %{machine | state: state, memory: memory, wants: wants_for(machine.module, state, memory)}
  end

  defp apply_turn({:stay, memory}, machine) do
    %{machine | memory: memory, wants: wants_for(machine.module, machine.state, memory)}
  end

  defp apply_turn(:stay, machine) do
    %{machine | wants: wants_for(machine.module, machine.state, machine.memory)}
  end

  defp apply_turn({:stop, reason, memory}, machine) do
    %{
      machine
      | memory: memory,
        engine: {:off, reason},
        wants: wants_for(machine.module, machine.state, memory)
    }
  end

  defp apply_turn(invalid, %__MODULE__{module: module, state: state}) do
    raise ArgumentError,
          "#{inspect(module)}.turn/3 in state #{inspect(state)} " <>
            "returned invalid result: #{inspect(invalid)}"
  end

  defp wants_for(module, state, memory) do
    if function_exported?(module, :wants, 2),
      do: module.wants(state, memory),
      else: []
  end

  defp validate_module!(module) do
    Code.ensure_loaded(module)

    unless function_exported?(module, :turn, 3) do
      raise ArgumentError,
            "#{inspect(module)} does not implement the Crank behaviour (missing turn/3)"
    end

    :ok
  end
end
