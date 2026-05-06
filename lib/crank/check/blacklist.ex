defmodule Crank.Check.Blacklist do
  @moduledoc """
  Single source of truth for the call-site impurity blacklist.

  Used by:

    * `Crank.Check.TurnPurity` (the Credo check, Phase 1.1)
    * `Crank.Check.CompileTime` (the `@before_compile` hook, Phase 1.3)
    * `Crank.PurityTrace` (the runtime tracer, Phase 2.1)

  Each entry is a `{matcher, code, message}` tuple where `matcher` is one of:

    * `{:module, "Repo"}` — any call whose receiver alias is exactly `Repo`
      (e.g., `MyApp.Repo`, but not `Repository`)
    * `{:prefix, "Ecto"}` — any call whose receiver alias starts with `Ecto.`
      (e.g., `Ecto.Query`, `Ecto.Multi`)
    * `{:erlang, :rand}` — any call to a function in the `:rand` Erlang module
    * `{:mfa, {DateTime, :utc_now, 0}}` — exact match on module/function/arity
    * `{:mfa_any_arity, {String, :to_atom}}` — match by module/function regardless of arity
    * `{:special_form, :send}` — Elixir special form / kernel function (`send/2`)

  The list is intentionally explicit. Adding entries is non-breaking;
  removing entries requires a major version bump.
  """

  alias Crank.Errors.Catalog

  @typedoc "A single blacklist entry."
  @type entry :: %{
          required(:matcher) => matcher(),
          required(:code) => binary(),
          required(:message) => binary()
        }

  @typedoc "How a blacklist entry matches an AST call."
  @type matcher ::
          {:module, binary()}
          | {:prefix, binary()}
          | {:erlang, atom()}
          | {:mfa, {module(), atom(), non_neg_integer()}}
          | {:mfa_any_arity, {module(), atom()}}
          | {:special_form, atom()}

  @entries [
    # ── Database / external services (CRANK_PURITY_001) ─────────────────────
    %{matcher: {:module, "Repo"}, code: "CRANK_PURITY_001",
      message: "Repo.* call inside turn/3 — use telemetry-as-want for persistence"},
    %{matcher: {:prefix, "Ecto"}, code: "CRANK_PURITY_001",
      message: "Ecto.* call inside turn/3 — domain logic must not touch persistence"},
    %{matcher: {:module, "HTTPoison"}, code: "CRANK_PURITY_001",
      message: "HTTPoison call inside turn/3 — sample HTTP responses at the boundary"},
    %{matcher: {:module, "Tesla"}, code: "CRANK_PURITY_001",
      message: "Tesla call inside turn/3 — sample HTTP responses at the boundary"},
    %{matcher: {:module, "Finch"}, code: "CRANK_PURITY_001",
      message: "Finch call inside turn/3 — sample HTTP responses at the boundary"},
    %{matcher: {:module, "Req"}, code: "CRANK_PURITY_001",
      message: "Req call inside turn/3 — sample HTTP responses at the boundary"},
    %{matcher: {:prefix, "Swoosh"}, code: "CRANK_PURITY_001",
      message: "Swoosh.* call inside turn/3 — declare email via wants/2 or telemetry"},
    %{matcher: {:prefix, "Bamboo"}, code: "CRANK_PURITY_001",
      message: "Bamboo.* call inside turn/3 — declare email via wants/2 or telemetry"},
    %{matcher: {:module, "Mailer"}, code: "CRANK_PURITY_001",
      message: "Mailer call inside turn/3 — declare email via wants/2 or telemetry"},
    %{matcher: {:module, "Oban"}, code: "CRANK_PURITY_001",
      message: "Oban call inside turn/3 — declare jobs via wants/2 or telemetry"},

    # ── Logging (CRANK_PURITY_003) ──────────────────────────────────────────
    %{matcher: {:prefix, "Logger"}, code: "CRANK_PURITY_003",
      message: "Logger.* call inside turn/3 — use telemetry-as-want; attach a logging adapter at the boundary"},

    # ── Stdlib non-determinism: time (CRANK_PURITY_004) ─────────────────────
    %{matcher: {:mfa, {DateTime, :utc_now, 0}}, code: "CRANK_PURITY_004",
      message: "DateTime.utc_now/0 inside turn/3 — pass timestamps in via the event"},
    %{matcher: {:mfa, {DateTime, :utc_now, 1}}, code: "CRANK_PURITY_004",
      message: "DateTime.utc_now/1 inside turn/3 — pass timestamps in via the event"},
    %{matcher: {:mfa, {Date, :utc_today, 0}}, code: "CRANK_PURITY_004",
      message: "Date.utc_today/0 inside turn/3 — pass dates in via the event"},
    %{matcher: {:mfa, {Time, :utc_now, 0}}, code: "CRANK_PURITY_004",
      message: "Time.utc_now/0 inside turn/3 — pass times in via the event"},
    %{matcher: {:mfa, {NaiveDateTime, :utc_now, 0}}, code: "CRANK_PURITY_004",
      message: "NaiveDateTime.utc_now/0 inside turn/3 — pass timestamps in via the event"},

    # ── Stdlib non-determinism: randomness ──────────────────────────────────
    %{matcher: {:erlang, :rand}, code: "CRANK_PURITY_004",
      message: ":rand.* inside turn/3 — pass random values in via the event"},
    %{matcher: {:erlang, :random}, code: "CRANK_PURITY_004",
      message: ":random.* inside turn/3 — pass random values in via the event"},

    # ── Stdlib non-determinism: system time / unique integers ───────────────
    %{matcher: {:mfa_any_arity, {System, :os_time}}, code: "CRANK_PURITY_004",
      message: "System.os_time inside turn/3 — pass time in via the event"},
    %{matcher: {:mfa_any_arity, {System, :system_time}}, code: "CRANK_PURITY_004",
      message: "System.system_time inside turn/3 — pass time in via the event"},
    %{matcher: {:mfa_any_arity, {System, :monotonic_time}}, code: "CRANK_PURITY_004",
      message: "System.monotonic_time inside turn/3 — pass time in via the event"},
    %{matcher: {:mfa_any_arity, {:erlang, :system_time}}, code: "CRANK_PURITY_004",
      message: ":erlang.system_time inside turn/3 — pass time in via the event"},
    %{matcher: {:mfa_any_arity, {:erlang, :monotonic_time}}, code: "CRANK_PURITY_004",
      message: ":erlang.monotonic_time inside turn/3 — pass time in via the event"},
    %{matcher: {:mfa_any_arity, {:erlang, :unique_integer}}, code: "CRANK_PURITY_004",
      message: ":erlang.unique_integer inside turn/3 — pass identifiers in via the event"},

    # ── Process / ambient state (CRANK_PURITY_006) ──────────────────────────
    %{matcher: {:mfa_any_arity, {Process, :put}}, code: "CRANK_PURITY_006",
      message: "Process.put inside turn/3 — carry state through memory, never via process dict"},
    %{matcher: {:mfa_any_arity, {Process, :get}}, code: "CRANK_PURITY_006",
      message: "Process.get inside turn/3 — carry state through memory"},
    %{matcher: {:mfa_any_arity, {Process, :delete}}, code: "CRANK_PURITY_006",
      message: "Process.delete inside turn/3 — carry state through memory"},
    %{matcher: {:erlang, :ets}, code: "CRANK_PURITY_006",
      message: ":ets.* inside turn/3 — load needed values into memory at start"},
    %{matcher: {:erlang, :persistent_term}, code: "CRANK_PURITY_006",
      message: ":persistent_term.* inside turn/3 — load values into memory at start"},
    %{matcher: {:erlang, :atomics}, code: "CRANK_PURITY_006",
      message: ":atomics.* inside turn/3 — domain logic should not read shared atomics"},
    %{matcher: {:erlang, :counters}, code: "CRANK_PURITY_006",
      message: ":counters.* inside turn/3 — domain logic should not read shared counters"},

    # ── Configuration (CRANK_PURITY_006) ────────────────────────────────────
    %{matcher: {:mfa_any_arity, {Application, :get_env}}, code: "CRANK_PURITY_006",
      message: "Application.get_env inside turn/3 — pass config in via start/1"},
    %{matcher: {:mfa_any_arity, {Application, :fetch_env}}, code: "CRANK_PURITY_006",
      message: "Application.fetch_env inside turn/3 — pass config in via start/1"},
    %{matcher: {:mfa_any_arity, {Application, :fetch_env!}}, code: "CRANK_PURITY_006",
      message: "Application.fetch_env! inside turn/3 — pass config in via start/1"},

    # ── Filesystem / OS (CRANK_PURITY_006) ──────────────────────────────────
    %{matcher: {:erlang, :os}, code: "CRANK_PURITY_006",
      message: ":os.* inside turn/3 — sample environment values at the boundary"},
    %{matcher: {:prefix, "File"}, code: "CRANK_PURITY_006",
      message: "File.* inside turn/3 — file IO belongs in adapters"},
    %{matcher: {:erlang, :file}, code: "CRANK_PURITY_006",
      message: ":file.* inside turn/3 — file IO belongs in adapters"},

    # ── Code evaluation (CRANK_PURITY_006) ──────────────────────────────────
    %{matcher: {:mfa_any_arity, {Code, :eval_string}}, code: "CRANK_PURITY_006",
      message: "Code.eval_string inside turn/3 — runtime code evaluation breaks purity"},
    %{matcher: {:mfa_any_arity, {Code, :eval_quoted}}, code: "CRANK_PURITY_006",
      message: "Code.eval_quoted inside turn/3 — runtime code evaluation breaks purity"},
    %{matcher: {:mfa_any_arity, {Code, :compile_string}}, code: "CRANK_PURITY_006",
      message: "Code.compile_string inside turn/3 — runtime compilation breaks purity"},

    # ── Atom-table mutation (CRANK_TRACE_001 — runtime; flagged statically too) ─
    %{matcher: {:mfa_any_arity, {String, :to_atom}}, code: "CRANK_PURITY_006",
      message: "String.to_atom inside turn/3 — mutates the global atom table; use String.to_existing_atom/1"},
    %{matcher: {:mfa_any_arity, {:erlang, :list_to_atom}}, code: "CRANK_PURITY_006",
      message: ":erlang.list_to_atom inside turn/3 — mutates the global atom table"},
    %{matcher: {:mfa_any_arity, {:erlang, :binary_to_atom}}, code: "CRANK_PURITY_006",
      message: ":erlang.binary_to_atom inside turn/3 — mutates the global atom table"},

    # ── Identity reads (CRANK_PURITY_004) ───────────────────────────────────
    %{matcher: {:mfa, {Kernel, :make_ref, 0}}, code: "CRANK_PURITY_004",
      message: "make_ref/0 inside turn/3 — pass identifiers in via the event"},
    %{matcher: {:mfa, {Kernel, :self, 0}}, code: "CRANK_PURITY_004",
      message: "self/0 inside turn/3 — domain logic should not depend on process identity"},
    %{matcher: {:mfa, {Kernel, :node, 0}}, code: "CRANK_PURITY_004",
      message: "node/0 inside turn/3 — domain logic should not depend on node identity"},

    # ── Process communication (CRANK_PURITY_005) ────────────────────────────
    %{matcher: {:special_form, :send}, code: "CRANK_PURITY_005",
      message: "send/2 inside turn/3 — declare via wants/2 with `{:send, dest, message}`"},
    %{matcher: {:mfa_any_arity, {Process, :send_after}}, code: "CRANK_PURITY_005",
      message: "Process.send_after inside turn/3 — declare via wants/2 with `{:after, ms, event}`"},
    %{matcher: {:mfa_any_arity, {GenServer, :cast}}, code: "CRANK_PURITY_005",
      message: "GenServer.cast inside turn/3 — declare via wants/2 with `{:send, dest, message}`"},
    %{matcher: {:mfa_any_arity, {GenServer, :call}}, code: "CRANK_PURITY_005",
      message: "GenServer.call inside turn/3 — synchronous IO breaks purity; use saga pattern"},
    %{matcher: {:mfa_any_arity, {Task, :start}}, code: "CRANK_PURITY_005",
      message: "Task.start inside turn/3 — declare effect via wants/2 or telemetry adapter"},
    %{matcher: {:mfa_any_arity, {Task, :async}}, code: "CRANK_PURITY_005",
      message: "Task.async inside turn/3 — declare effect via wants/2 or telemetry adapter"},
    %{matcher: {:special_form, :spawn}, code: "CRANK_PURITY_005",
      message: "spawn inside turn/3 — declare effect via wants/2 or telemetry adapter"},
    %{matcher: {:special_form, :spawn_link}, code: "CRANK_PURITY_005",
      message: "spawn_link inside turn/3 — declare effect via wants/2 or telemetry adapter"}
  ]

  @entry_count length(@entries)

  @doc "Returns every blacklist entry."
  @spec all() :: [entry()]
  def all, do: @entries

  @doc "Returns the count of blacklist entries (for catalog/test consistency)."
  @spec count() :: non_neg_integer()
  def count, do: @entry_count

  # Resolve the runtime-traceable modules at compile time so this is a
  # constant-time lookup. Only `:module` and `:prefix` matchers
  # contribute — MFA matchers are already covered by the existing
  # `default_forbidden_targets/0` list, and `:erlang`/`:special_form`
  # matchers either map to atoms already in that list or aren't
  # traceable. Sub-namespaces (e.g. `Ecto.Query`) need to be loaded
  # for their own trace patterns to fire; we commit to the canonical
  # atoms here and let users extend via `:forbidden_modules` for
  # specific submodule coverage.
  @runtime_module_targets (Enum.map(@entries, fn
                             %{matcher: {:module, name}} -> Module.concat([name])
                             %{matcher: {:prefix, name}} -> Module.concat([name])
                             _ -> nil
                           end)
                           |> Enum.reject(&is_nil/1)
                           |> Enum.uniq())

  @doc """
  Returns the subset of blacklist entries whose matchers can be expressed
  as `:trace.function/4` patterns at runtime.

  The static blacklist matches AST nodes by string-prefix
  (`{:prefix, "Ecto"}`) and string-name (`{:module, "Repo"}`); those
  representations work for compile-time AST analysis but not for the
  BEAM trace API, which requires concrete module atoms. This function
  derives the trace-compatible subset so `Crank.PurityTrace`'s default
  forbidden list stays aligned with the static layer's policy.

  **Caveat:** prefix-matched infra modules with user-aliased names
  (`MyApp.Repo`) are not covered by this default — only the canonical
  module name (`Repo`, `Ecto`, etc.). Boundary catches the topology
  side; users who need runtime tracing of aliased modules pass them
  via `:forbidden_modules`.
  """
  @spec runtime_module_targets() :: [module()]
  def runtime_module_targets, do: @runtime_module_targets

  @doc """
  Checks whether a remote call AST node matches any blacklist entry.

  Returns `{:violation, code, message, fix_url}` or `nil`. The caller decides
  whether to wrap the result in a `Crank.Errors.Violation` (the static checks
  do; the runtime tracer does so in a different way via trace patterns).

  ## Examples

      iex> ast = quote(do: Repo.insert!(record))
      iex> Crank.Check.Blacklist.match_call(ast)
      {:violation, "CRANK_PURITY_001", "Repo.* call inside turn/3 — use telemetry-as-want for persistence", _}
  """
  @spec match_call(Macro.t()) :: {:violation, binary(), binary(), binary()} | nil
  def match_call(ast) do
    Enum.find_value(@entries, fn entry ->
      if matches?(entry.matcher, ast) do
        {:ok, catalog_entry} = Catalog.fetch(entry.code)
        {:violation, entry.code, entry.message, catalog_entry.doc_url}
      end
    end)
  end

  # ── Matcher predicates ────────────────────────────────────────────────────

  defp matches?({:module, name}, ast), do: module_name(ast) == name

  defp matches?({:prefix, name}, ast) do
    case module_name(ast) do
      nil -> false
      module -> module == name or String.starts_with?(module, name <> ".")
    end
  end

  defp matches?({:erlang, atom_name}, ast), do: erlang_module(ast) == atom_name

  defp matches?({:mfa, {Kernel, fun, arity}}, ast), do: kernel_call?(ast, fun, arity)

  defp matches?({:mfa, {mod, fun, arity}}, ast) do
    case ast do
      {{:., _, [{:__aliases__, _, parts}, ^fun]}, _, args}
      when length(args) == arity ->
        Enum.join(parts, ".") == inspect(mod)

      {{:., _, [^mod, ^fun]}, _, args} when length(args) == arity ->
        true

      _ ->
        false
    end
  end

  defp matches?({:mfa_any_arity, {mod, fun}}, ast) do
    case ast do
      {{:., _, [{:__aliases__, _, parts}, ^fun]}, _, _} ->
        Enum.join(parts, ".") == inspect(mod)

      {{:., _, [^mod, ^fun]}, _, _} ->
        true

      _ ->
        false
    end
  end

  defp matches?({:special_form, name}, ast), do: special_form?(ast, name)

  # ── AST shape helpers ─────────────────────────────────────────────────────

  defp module_name({{:., _, [{:__aliases__, _, parts}, _fun]}, _, _})
       when is_list(parts) do
    Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  defp module_name(_), do: nil

  defp erlang_module({{:., _, [erlang_atom, _fun]}, _, _})
       when is_atom(erlang_atom),
       do: erlang_atom

  defp erlang_module(_), do: nil

  defp kernel_call?({fun, _, args}, fun, arity)
       when is_atom(fun) and is_list(args) and length(args) == arity,
       do: true

  defp kernel_call?(_, _, _), do: false

  defp special_form?({name, _, args}, name) when is_atom(name) and is_list(args), do: true
  defp special_form?(_, _), do: false
end
