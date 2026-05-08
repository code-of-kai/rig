# Boundary setup

Crank's topology layer is delegated to [Boundary](https://github.com/sasa1977/boundary), a mature module-dependency-rules library. Boundary already ships a custom Mix compiler that runs after the standard compile, walks the module dependency graph, and rejects calls that violate declared topology rules. Crank's role is to wire it correctly — picking sensible defaults, mapping its diagnostics into the `Crank.Errors` pipeline, and making sure first-run setup doesn't drown new projects in false positives.

The fastest path is `mix crank.gen.config`. The manual path is documented below for users who want to understand what gets wired or who are integrating Crank into a project with existing Boundary configuration.

> The `mix crank.gen.config` task and the `Crank.Compiler` Mix compiler ship with the convergence work of the purity-enforcement plan. The starter Boundary config and the `Crank.BoundaryIntegration` module are part of Track A. This guide describes the contract; once those land, the commands below execute end-to-end.

## The fastest path

In a fresh Crank project:

```sh
mix crank.gen.config
```

The task is idempotent — running it again on a configured project produces no changes. It does the following:

1. Adds `{:boundary, "~> 0.10"}` (and `:crank` itself) to your `mix.exs` deps if missing.
2. Adds `:crank` to the `compilers:` list in your project config.
3. Writes a starter Boundary config in `config/boundary.exs` (or wherever your project's Boundary config lives) defining the `:domain` / `:infrastructure` cut and seeding the third-party classification table.
4. Amends `.credo.exs` to wire `Crank.Check.TurnPurity` (without clobbering existing checks).
5. Prints — but does not modify — a recommended `.github/workflows/crank-check.yml` snippet and a recommended README section for you to copy.

The README and CI snippets are not auto-edited because rewriting prose files is brittle (formatting collisions, conflict with existing content, partial overlaps with prior runs) and adds maintenance surface unrelated to purity correctness.

## What `mix.exs` ends up looking like

```elixir
defmodule MyApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :my_app,
      compilers: [:crank | Mix.compilers()],   # MUST prepend — see note below
      ...
    ]
  end

  defp deps do
    [
      {:crank, "~> 2.0"},
      {:boundary, "~> 0.10"},
      ...
    ]
  end
end
```

Adding `:crank` to `:compilers` activates the entire stack: standard compile → Boundary check → Crank's diagnostic translation. If `:crank` is missing, `mix crank.check` fails fast with `CRANK_SETUP_001` rather than letting the project silently run without topology enforcement.

### Compiler order matters

`:crank` MUST be prepended (or otherwise positioned BEFORE `:elixir` and `:app`) — `Mix.Tasks.Compile.Crank.run/1` registers `after_compiler(:elixir, ...)` and `after_compiler(:app, ...)` hooks. If `:crank` runs after those compilers, the hooks register too late and topology enforcement is silently inert for the current pass. `mix crank.check` fails with `CRANK_SETUP_001` when the order is unsafe (Codex review #25 hardening, 2026-05-08).

Use `[:crank | Mix.compilers()]` (or `[:crank] ++ Mix.compilers()`), never `Mix.compilers() ++ [:crank]`.

## What the starter Boundary config looks like

The starter is the `:domain` / `:infrastructure` cut plus the third-party classification template:

```elixir
# config/boundary.exs (or wherever you keep Boundary config)

config :my_app, Boundary,
  default_boundary: :infrastructure,
  boundaries: [
    domain: [
      deps: [],   # domain is closed; no infrastructure deps
      strict: true
    ],
    infrastructure: [
      deps: [:domain]
    ]
  ],
  third_party_pure: [
    # Apps treated as pure dependencies — calls allowed from :domain.
    # Uncomment what you actually use.
    # :decimal,
    # :money,
    # :typed_struct,
    # :nimble_parsec
  ],
  third_party_impure: [
    # Apps treated as infrastructure — calls rejected from :domain.
    :ecto,
    :ecto_sql,
    :postgrex,
    :httpoison,
    :tesla,
    :finch,
    :req,
    :swoosh,
    :bamboo,
    :oban
  ]
```

Two things to note:

- **Strict mode is on by default for `:domain`.** Any first-party module called from a domain module must itself be classified as `:domain` (typically via `use Crank.Domain.Pure`). Strict mode is the right default — see "Why strict by default" below — but you can disable it per-boundary if you're mid-migration.
- **`:elixir` is not in the third-party list.** Boundary operates at the OTP-application level. Calls into `Map`, `Enum`, `String` are not flagged by Boundary at all. Stdlib enforcement lives in the call-site (`CRANK_PURITY_001..006`) and runtime trace (`CRANK_PURITY_007`) layers — see the [Hexagonal Architecture guide](hexagonal-architecture.md).

## Why strict by default

Strict mode treats *unclassified* first-party modules as topology holes. That sounds aggressive, but it's the only mode where Crank's promise — the domain cannot reach infrastructure — is actually true.

In permissive mode, an unclassified helper module would be allowed to call infrastructure. A domain module calling that helper would route into infrastructure transparently. The diagnostic the user sees would not point at the helper, because the helper itself is unclassified; debug stories that look "I added an alias and now the build fails for an unrelated reason" are exactly what permissive mode produces.

Strict mode produces one new check (`CRANK_DEP_002`) and one one-line fix (`use Crank.Domain.Pure` on the helper). The fix is mechanical and the helper benefits — its bodies are now subject to the same call-site blacklist as `turn/3`.

For projects that are mid-migration and genuinely cannot mark every helper at once, the per-boundary `strict: false` setting is the right escape hatch. Use it deliberately, with a plan to flip back. Don't make permissive mode the default just because the migration is hard.

## Marking domain helpers

`use Crank.Domain.Pure` on a helper module:

```elixir
defmodule MyApp.OrderMath do
  use Crank.Domain.Pure

  def total(line_items) do
    Enum.reduce(line_items, Decimal.new(0), fn item, sum ->
      Decimal.add(sum, item.amount)
    end)
  end
end
```

Two effects:

1. **Boundary tag.** The module is classified as `:domain` at the Boundary level. Domain modules can call it; infrastructure dependencies are still rejected from inside it.
2. **Call-site blacklist applies to its bodies.** Every public function in the module is walked the same way `turn/3` is — calls to `Repo`, `Logger`, `:rand`, etc. are rejected at compile time.

This is the marker that closes the strict-mode hole without giving up the safety the strict mode provides.

## Adding a third-party app

Two paths into `:domain`-callable territory for a third-party library:

```elixir
# config/boundary.exs

config :my_app, Boundary,
  third_party_pure: [
    :decimal,        # added — calls into Decimal.* from :domain are now allowed
    ...
  ]
```

Or, if the library is genuinely infrastructure (it talks to a database, hits a network), classify it as `:third_party_impure` and route the truly-pure parts of your usage through a `Crank.Domain.Pure` wrapper module.

Unclassified third-party apps fire `CRANK_DEP_003`. The error message names the app and points at the classification mechanism.

## CI integration

`mix crank.check` is the canonical CI gate. It wraps the underlying tools — `mix compile --warnings-as-errors`, `mix credo --strict`, the Boundary check, and the property-test suite — into a single command that aggregates exit codes and produces structured output.

Recommended GitHub Actions snippet (printed by `mix crank.gen.config` for you to copy):

```yaml
# .github/workflows/crank-check.yml
name: crank-check
on: [push, pull_request]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: '26'
          elixir-version: '1.16'
      - run: mix deps.get
      - run: mix crank.check
```

The OTP 26 pin is required — Crank's runtime tracing layer needs `:trace.session_create/3`, which arrived in OTP 26. Older releases produce `CRANK_SETUP_002` at boot.

## Manual setup (without `mix crank.gen.config`)

If you'd rather wire things by hand:

1. Add `{:crank, "~> 2.0"}` and `{:boundary, "~> 0.10"}` to `deps`.
2. Run `mix deps.get`.
3. Add `:crank` to the `compilers:` list in `mix.exs`:

   ```elixir
   compilers: [:crank | Mix.compilers()]
   ```

4. Create `config/boundary.exs` (or your equivalent) with the starter shape above.
5. Amend `.credo.exs` to add `Crank.Check.TurnPurity` to the `:checks` list under a `:design` group with `severity: :high`. Do not regenerate from `mix credo gen.config` — that would clobber any existing custom checks.
6. Wire `mix crank.check` into your CI.

The end state is the same as the generator's output. The generator is just a convenience.

## Verifying the setup

Run `mix crank.check` on a fresh project. The command should pass with no violations. Then, as a smoke test, add a deliberate violation and confirm it fires:

```elixir
# lib/my_app/sanity_machine.ex
defmodule MyApp.SanityMachine do
  use Crank
  alias MyApp.Repo                 # CRANK_DEP_001 — should fail the check

  def start(_), do: {:ok, :idle, %{}}
  def turn(_, _, m), do: {:stay, m}
end
```

`mix crank.check` should fail with `CRANK_DEP_001` naming the offending alias. Remove the alias and the check should pass again.

## Common questions

**Can I use Boundary independently of Crank?** Yes. Boundary is a hard dependency of Crank, but Boundary's own facilities (boundary declarations on non-Crank modules, custom rules) keep working. Crank's layer just adds the `:domain` / `:infrastructure` cut and the third-party classification template on top.

**Can I have multiple `:domain` boundaries in one project?** Yes. The starter config uses one `:domain` boundary for simplicity, but Boundary supports nested or sibling boundaries. The Crank-specific tags (`use Crank`, `use Crank.Domain.Pure`) all map to the same `:domain` tag by default, but the macro takes a `:boundary` option if you want to assign a module to a specific named boundary.

**What if the topology layer reports a false positive?** First, double-check it really is one — `CRANK_DEP_002` (unmarked helper) is the most common false-positive-feeling case, and the fix is almost always `use Crank.Domain.Pure`. If the diagnostic genuinely is wrong, suppress it via the Layer B Boundary config exception (with a `:reason`), and file an issue.

## See also

- [Suppressions](suppressions.md) — Layer B mechanism in detail.
- [Hexagonal Architecture](hexagonal-architecture.md) — the discipline Boundary enforces.
- Violation pages: [CRANK_DEP_001](violations/CRANK_DEP_001.md), [CRANK_DEP_002](violations/CRANK_DEP_002.md), [CRANK_DEP_003](violations/CRANK_DEP_003.md), [CRANK_SETUP_001](violations/CRANK_SETUP_001.md).
