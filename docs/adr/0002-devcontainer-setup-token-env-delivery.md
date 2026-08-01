# ADR-0002: Setup-token delivery by environment injection

- Status: Proposed
- Date: 2026-07-28
- Implemented by: this PR (devcontainer)
- Related: **claude-profile ADR-0003** — long-lived setup-token profiles (the
  second credential type this ADR consumes). **devcontainer ADR-0001** —
  private-token credential isolation, whose file-seeding model this ADR runs
  *alongside*, not in place of. (ADR numbers are per-repo; cross-repo references
  are qualified by repo name.)

## Context

devcontainer ADR-0001 gives each container its own private OAuth credential:
`setup-claude` copies `credentials/<profile>.json` from the read-only host
profile store into `~/.claude/.credentials.json`, and any `claude` invocation in
the container reads it off disk. File seeding is **launch-agnostic** — it does
not matter how or by whom `claude` is started.

claude-profile ADR-0003 adds a second credential type: a long-lived
`claude setup-token` bearer, stored as `credentials/<profile>.token`, that claude
consumes from the **environment** as `CLAUDE_CODE_OAUTH_TOKEN` and never from a
file. A container cannot deliver it the ADR-0001 way, and naively routing it
through `set-credentials` fails twice: the JSON installer rejects a raw bearer,
and even if written, claude would not read a bearer from `.credentials.json`.

Two properties of env delivery drive every decision here:

- **It is per-process, not ambient.** Only the invocation that inherited
  `CLAUDE_CODE_OAUTH_TOKEN` is authenticated. The container has many claude entry
  points — the `devcontainer claude` wrapper, VS Code integrated terminals /
  "Reopen in Container", a raw `dc exec bash` then `claude`, MCP servers,
  background agents. Injecting at only one of them silently leaves the rest
  unauthenticated (or falls through to an ambient API key and gets API-billed).
- **It sits below several higher-precedence sources.** claude's order is
  `ANTHROPIC_API_KEY > ANTHROPIC_AUTH_TOKEN > CLAUDE_CODE_OAUTH_TOKEN > file`,
  above which also sit cloud-provider routing (`CLAUDE_CODE_USE_BEDROCK` /
  `_VERTEX`), the endpoint redirect `ANTHROPIC_BASE_URL`, and the `apiKeyHelper`
  settings.json hook. In a container these are exactly the values likely to be
  ambient (baked image env, `project.env` → compose `environment:`, CI secrets,
  an enterprise Bedrock/Vertex toggle). Any one would **silently** outrank the
  token with no error. Only the four-way env order is empirically pinned
  (claude v2.1.215); the rest is from docs.

## Decision

Deliver a setup-token by **environment injection**, resolved from a single
source and applied at every claude entry point.

- **Resolver (one source of truth).** `setup-claude token-path` prints the
  container-side token file a launch should read, or exits non-zero. Order: an
  explicit `set-token` override (`~/.claude/.oauth-token`) first, then a
  Docker/Compose file-based secret (`/run/secrets/claude_code_oauth_token`, the
  sanctioned mountless transport), else the read-only host store
  (`~/.claude-host/credentials/<profile>.token`, profile from
  `DEV_CLAUDE_PROFILE`, else the container record seeding pinned at
  `~/.claude/.active-profile`, else the host `active-profile` marker — the
  record exists because launches never inherit the per-exec
  `DEV_CLAUDE_PROFILE`, and without it a launch could inject a different
  profile's token than seeding installed; both seeding paths write the record,
  and they differ in whether they READ it — see the amendment below). The store copy
  is read **live, never seeded** — a host-side delete takes effect on the next
  launch (this matters: a setup-token has **no CLI revoke**, so deletion is the
  only revoke; see Consequences).
- **The token-env snippet** (`lib/claude-code-token-env.sh`) reads that path into
  `CLAUDE_CODE_OAUTH_TOKEN` and, only when a token is selected, `unset`s every
  higher-precedence env source. Reading the value at use time (not baking it)
  keeps the raw bearer out of image metadata / `docker inspect`. It is a no-op
  for OAuth profiles.
- **Applied at every entry point.** Sourced from `/etc/profile.d` (login shells)
  and `/etc/bash.bashrc` (interactive non-login shells) via the Dockerfile, and
  explicitly by the `devcontainer claude` wrapper (`dc exec` inherits neither).
- **`apiKeyHelper` is handled out of band.** `setup_settings` rebuilds the
  container `settings.json` from scratch and never copies `apiKeyHelper` from the
  host, so there is nothing to strip at launch. (If that ever changes, the
  snippet would need a `--settings` override.)
- **`seed_credentials` tolerates a token-only profile.** A profile with a
  `.token` but no `.json` seeds no credential file (there is nothing to seed);
  it sets the onboarding prefs and notes that the token is injected at launch.
  A profile with both materials still seeds the OAuth `.json` (ADR-0001 default);
  the token is used only for a `--token`-style launch. This is the container face
  of ADR-0003 coexistence.
- **Mountless runtimes (CI / Codespaces).** With no `.claude-host` mount, prefer
  Docker's sanctioned secret transport: a **Compose file-based secret** mounted
  at `/run/secrets/claude_code_oauth_token` (tmpfs, `0400`, absent from
  `docker inspect`), sourced from a masked CI variable —

      services:
        app:
          secrets: [claude_code_oauth_token]
      secrets:
        claude_code_oauth_token:
          environment: CLAUDE_CODE_OAUTH_TOKEN   # masked CI var on the host

  The resolver reads it (`docker-compose.yml` carries this block commented out).
  `devcontainer set-token <file>|-` remains the fallback
  for runtimes without Compose control: it validates a raw bearer
  (`lib/install-claude-token.sh` — non-empty, single line, no whitespace; a JSON
  blob is rejected) and writes it `0600` to `~/.claude/.oauth-token`, which as a
  manual override wins even over a configured secret. Both are fed by
  `claude-profile export-to <p> --token -`. In the simplest CI case neither is
  needed: the runner sets `-e CLAUDE_CODE_OAUTH_TOKEN` directly on the
  `docker run`/`exec` process (ADR-0003's blessed path) — see the relaxation
  below.

- **Delivery is construct-only in the shell; verify lives in launch wrappers.**
  The token-env snippet builds a clean env (inject the token, drop the
  higher-precedence sources) but does not verify the resulting auth: a shell-init
  export sets the env once for every process, so a per-launch preflight has no
  home there, and it leans instead on the from-scratch `settings.json` rebuild
  (no `apiKeyHelper` to inherit). A verify step — confirming the token actually
  authenticated, which catches a precedence tier a future claude adds that the
  strip-list does not yet drop — belongs in a wrapping launcher (claude-profile's
  `run`/`session`; and the `devcontainer claude` wrapper, where it is now
  available OFF by default and gated behind `DEV_CLAUDE_VERIFY=1` — a per-launch
  network round-trip is a real cost — with the probe overridable via
  `DEV_CLAUDE_VERIFY_CMD` since the cheapest auth probe is claude-version
  dependent), mirroring the claude-profile side's construct-then-verify delivery.

## The no-persist relaxation (deliberate, recorded, and narrow)

claude-profile ADR-0003 states the token is *"never written to a shell profile,
`project.env`, or any persistent file."* This relaxation is narrower than it
first looks, because it is only needed for **one** of the entry points:

- **CI / non-interactive: no relaxation.** The runner sets
  `-e CLAUDE_CODE_OAUTH_TOKEN` per process (or feeds a Compose secret) — no
  persisted export. This is ADR-0003's own blessed CI path.
- **The `devcontainer claude` wrapper: no persisted state.** It sources the
  snippet for that one `dc exec` and execs — nothing is written to a profile.
- **Interactive ad-hoc shells (a VS Code terminal, `dc exec bash`): the actual
  exception.** These are the launches that inherit no injected env, so the
  snippet is sourced from `/etc/profile.d` and `/etc/bash.bashrc` — which *is*
  persisting an export into the container's shell environment.

That one carve-out is deliberate and container-scoped, not a silent divergence.
It is forced by claude reading `CLAUDE_CODE_OAUTH_TOKEN` **from the environment**
(there is no `..._FILE` variant), so an interactive shell must export *something*;
Docker's file-based secrets improve where the bytes rest but cannot remove the
final file→env step. It is accepted because the container is single-user and
disposable, already accepts `/proc/<pid>/environ` same-uid exposure as a
documented boundary (ADR-0003 Consequences), and the raw token already sits in
plaintext at `0600` on the read-only mount or on tmpfs. **Nothing here writes a
token to the host shell profile or `project.env`** — the rule stays intact
host-side. The claude-profile side is asked only to clarify that its no-persist
rule is host-scoped and to acknowledge this container-scoped exception (a
one-line carve-out in ADR-0003), not to loosen the rule.

## Consequences

- Every claude launch in the container — wrapper, VS Code terminal, raw shell —
  sees the token, without a seeded file and without a shared credential inode.
  N containers, one read-only file, zero reconciliation.
- Because selection is by env precedence, the container must be kept **clean of
  higher-precedence sources**. The snippet strips them for token launches, but an
  ambient one a user exports *after* shell init, or a future `apiKeyHelper` in
  the rebuilt settings, would win. `devcontainer token-doctor` flags a present
  higher-precedence source (env, or a hand-added `apiKeyHelper` in settings.json)
  under an active token profile — run it when a launch routes unexpectedly. It
  inspects the container's ambient env baseline (a plain `dc exec`), so it sees
  what a non-wrapper launch would inherit.
- **No CLI revoke → deletion is the only revoke.** Reading the store token live
  (not seeding a copy) means a host-side `delete`/`rename` of the `.token` takes
  effect on the next launch. A lingering `set-token` file (`~/.claude/.oauth-token`)
  is the one persisted copy and must be removed to revoke in that container.
- **Precedence is version-pinned.** Only the four-way env order was empirically
  swept; the cloud/base-url tiers are cleared defensively. The strip-list carries
  a **re-verify-on-`claude`-upgrade** obligation (noted in the snippet).
- The ADR-0001 OAuth path is untouched and remains the default; this ADR adds a
  credential type, it does not retire one. Remote Control / connectors, which a
  setup-token cannot establish, stay on the OAuth material.

## Amendment (2026-08-01): which seeding path reads the record

**Status: Accepted.** Clarifies §Resolver; no behavior recorded elsewhere changes.

The original text — "seeding re-resolves fresh, env > marker, and re-pins" —
was written when only `fix-credentials` seeded-and-pinned, so "seeding" meant
the deliberate re-seed. It is ambiguous now that the per-entry setup path also
records, and the two paths cannot share one rule: the per-entry path runs on
**every** `up`/`exec`/`claude` (via `ensure_up`), where launches forward an
empty `DEV_CLAUDE_PROFILE`.

The record is therefore **written by both paths but read by only one**:

- **Per-entry setup** (`setup-claude` with no subcommand) resolves with the
  record tier ACTIVE. A pin survives ordinary commands; `DEV_CLAUDE_PROFILE`
  still outranks it and re-pins.
- **Explicit re-seed** (`seed-credentials`, i.e. `devcontainer fix-credentials`)
  resolves with the record tier EXCLUDED — the record must not feed the
  resolution that rewrites it, or a stale pin would re-seed itself forever and
  a host profile switch would never take.

Rejected: excluding the record on both paths (a plain `exec` would silently
re-point the container to the host marker, undoing an explicit pin and, for a
token-only profile whose marker is absent, clearing the pin and dropping the
launch to ambient auth — the API-billed fallthrough §Context warns about);
honoring it on both (a container could never be re-pointed without deleting
the record by hand, making `fix-credentials --profile` inert).

Guarded by `tests/test-claude-seed.sh` (durability of a pin across a plain
entry, env override, and empty-resolution retention) and
`tests/test-claude-token.sh` (re-seed re-points from the marker).

## Options considered

- **A — env injection at every entry point (chosen).** Matches how claude
  actually consumes the token; the only option that covers non-wrapper launches.
- **B — patch only `devcontainer claude`.** Rejected: leaves VS Code terminals,
  raw shells, MCP servers, and agents unauthenticated — the trap that demos green
  and fails in real use.
- **C — write the token into `.credentials.json` and reuse `set-credentials`.**
  Rejected: a raw bearer is not JSON (the installer rejects it) and claude reads
  the token from the environment, not that file.
- **D — bake the token into compose `environment:`.** Rejected: leaks the raw
  bearer into `docker inspect` / image metadata and does not track a host-side
  delete. The snippet reads the file at launch instead.
