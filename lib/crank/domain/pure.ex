defmodule Crank.Domain.Pure do
  @moduledoc """
  Marks a non-Crank helper module as part of the pure domain layer.

  `use Crank.Domain.Pure` is the parallel of `use Crank` for plain helper
  modules — modules that aren't FSMs themselves, but contain pure logic that
  domain code is allowed to call. Helpers marked with this module are subject
  to the same call-site purity enforcement as `turn/3` clauses (every public
  and private function body is walked by `Crank.Check.CompileTime`), and they
  participate in the topology check as `:domain` boundaries (Boundary refuses
  cross-boundary references from `:domain` to infrastructure modules).

  ## Example

      defmodule MyApp.PriceMath do
        use Crank.Domain.Pure

        def with_tax(amount, rate) do
          Decimal.mult(amount, Decimal.add(1, rate))
        end
      end

  ## What this gives you

    * The module is tagged as a `Boundary` with `type: :strict, deps: []`.
      Cross-boundary references from this helper to anything that isn't on
      the explicit deps list are rejected by `mix compile.crank`.
    * Every function body in the module is captured by `@on_definition` and
      walked by `Crank.Check.CompileTime` for blacklisted impure calls. A
      `Repo.insert!` inside this module fails at compile time with
      `CRANK_PURITY_001`, the same as if it had been written inside `turn/3`.
    * The `# crank-allow:` source-comment suppression mechanism applies here
      identically to `use Crank` modules.

  ## When to use this vs. `use Crank`

  Use `Crank.Domain.Pure` for any module that contains pure domain logic
  called from a Crank FSM but is not itself an FSM: pricing math, validation
  helpers, translation functions, etc. Use `use Crank` when the module *is*
  the FSM (implements `start/1`, `turn/3`).

  Marking a module with `use Crank.Domain.Pure` is a deliberate, reviewable
  declaration. Code reviewers should verify the helper actually is pure
  before accepting the marker — the marker tells static analysis to trust
  the module, but does not itself make the module pure. (See "Deliberate
  sabotage" in the Coverage model section of `purity-enforcement.md`.)

  ## Boundary deps

  By default, the module is configured with `deps: []` (no allowed external
  references at the boundary level). To allow specific dependencies, pass
  them to the `:boundary_deps` option:

      use Crank.Domain.Pure, boundary_deps: [MyApp.OtherHelper]

  All standard `Boundary` opts are passed through, so you can also do:

      use Crank.Domain.Pure, type: :relaxed
  """

  defmacro __using__(opts) do
    boundary_opts = build_boundary_opts(opts)

    quote location: :keep do
      # Persistent topology marker. `Mix.Tasks.Compile.Crank` reads this
      # via `module.__info__(:attributes)` to identify Crank-domain
      # modules and emit `CRANK_DEP_002` when they reference unclassified
      # first-party helpers.
      Module.register_attribute(__MODULE__, :__crank_domain__, persist: true)
      @__crank_domain__ true

      use Boundary, unquote(boundary_opts)

      Module.put_attribute(__MODULE__, :__crank_domain_pure__, true)

      @on_definition Crank.Check.CompileTime
      @before_compile Crank.Check.CompileTime
      Module.register_attribute(__MODULE__, :__crank_turn_bodies__, accumulate: false)
    end
  end

  @doc false
  @spec build_boundary_opts(keyword()) :: keyword()
  def build_boundary_opts(opts) do
    user_deps = Keyword.get(opts, :boundary_deps, [])
    boundary_exports = Keyword.get(opts, :boundary_exports, [])
    type = Keyword.get(opts, :type, :strict)

    extra =
      opts
      |> Keyword.drop([:boundary_deps, :boundary_exports, :type])
      |> Keyword.take([:check, :classify_to, :top_level?, :dirty_xrefs])

    # Always add `Crank` to the deps list. The `use Crank` and
    # `use Crank.Domain.Pure` macros expand into code that references
    # `Crank`, `Crank.Server`, `Crank.Check.CompileTime`, etc. Under
    # `type: :strict` Boundary would otherwise reject every one of those
    # references as a forbidden external-dep call. Naming `Crank` in deps
    # creates an implicit boundary covering every `Crank.*` submodule, so
    # the macro-injected references resolve cleanly without requiring the
    # user to think about it.
    deps_with_crank =
      if Crank in user_deps do
        user_deps
      else
        [Crank | user_deps]
      end

    [type: type, deps: deps_with_crank, exports: boundary_exports] ++ extra
  end
end
