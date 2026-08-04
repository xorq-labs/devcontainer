# Devcontainer infrastructure repo

Reusable dev container setup with worktree support, project overlays, and host credential bridging. All scripts are bash (in `dev/` and `lib/`) with Python for `setup-claude.py` and `audit-report.py`.

## Setup (host, one-time)

```bash
cp .envrcs/.envrc.user.uv .envrcs/.envrc.user
direnv allow
uv tool install pre-commit
```

This installs pre-commit into `.tools/bin/` (project-local, not `~/.local/bin`). The git hook at `dev/hooks/pre-commit` is symlinked into `.git/hooks/` automatically by direnv (via `symlink_hooks` in `lib/git.sh`). Do not run `pre-commit install` — it will overwrite the custom hook.

## Pre-commit hooks

Commits run shellcheck, ruff, yamllint, and hadolint via pre-commit. Config is in `.pre-commit-config.yaml`. To run manually:

```bash
pre-commit run --all-files
```

## Testing

Suites live in `tests/*.sh` and share a harness (`tests/lib/harness.sh`:
assert helpers, PASS/FAIL accounting, disposable repos). Run the whole suite
(the same entry point CI uses) with `tests/run-all`, or run one on its own:

```bash
bash tests/run-all
bash tests/test-resolve-list-cleanup.sh
```

## Repo layout

- `dev/` — user-facing scripts: `devcontainer`, `new-worktree`, `setup-worktree`, `cleanup-worktree`, `init`
- `lib/` — shared bash libraries sourced by dev/ scripts (`git.sh`, `host-bridge.sh`, `host-mounts.sh`, `list-file.sh`, `command-table.sh`) plus `command-table.tsv`, the declarative `devcontainer` command surface
- `defaults/` — fallback project overlay (used when no project-specific overlay matches)
- `projects/<name>/` — project-specific overlays (install-system.sh, setup-env.sh, compose.override.yml, worktree-*.txt)
- `.envrcs/` — direnv fragments; `.envrc.user` and `.envrc.secrets` are gitignored per-developer files

## Autonomy & escalation (agent working agreement)

When fixing review findings, CI failures, or lint complaints, proceed without
asking as long as the fix preserves the change's design intent. Stop and ask
ONLY when a fix would change a public interface, an ADR-recorded decision, or
auth/identity semantics — and then present 2–3 concrete options with a
recommendation, not an open question. Where possible, draft the decision as an
ADR amendment pushed to the PR (see "Design decisions" below) so approval can
happen asynchronously by editing text.

Review hard rules regardless of context: verify every finding against the code
before reporting it; never post to GitHub unless asked; never read live
credential files — reason from code.

## Design decisions: ADRs

Design decisions live in `docs/adr/` (numbered per-repo; cross-repo references
are qualified by repo name). A PR that changes an ADR-recorded decision amends
the ADR in the same PR — doc and code land together or not at all. When an
agent hits a design fork mid-PR, it drafts the ADR amendment (options,
trade-offs, recommendation) and pushes it for review rather than blocking on
an interactive question. Current records: ADR-0001 (private credential
seeding), ADR-0002 (setup-token env delivery), ADR-0003 (tracking
`.claude/agents/` in git; per-subdir state symlinks), ADR-0005 (guard
taxonomy: type the guard, prove it fails, derive over restate; ADR-0004 is
reserved by #81), and nix/base/README.md
"Design decisions" for the base-image record.

## Invariants

The load-bearing cross-file facts, one line each, with the drift guard that
enforces it in parentheses, typed per ADR-0005: `test:` (hermetic suite check),
`tool:` (the fact lives outside the tree; a tool that refuses to write a bad
value is the guard), `ci:` (needs a runner or the network), `structural`
(generated, cannot drift), or `unguarded: <why>` (deliberate, reason
mandatory). Annotations compose with `;` when a fact is guarded at two layers
(`tool: dev/bump-x; test: tests/test-bump-x.sh`). Legacy `—` = not yet typed —
type it when you touch it; a bare `(tests/test-x.sh)` citation predates the
taxonomy and reads as `test:`.

- Every Dockerfile `COPY` source — default context AND the `--from=project`
  overlay context — is hashed by `image_config_files()` in `dev/devcontainer`,
  or edits to it silently reuse a stale image. The guard proves this per
  source by editing the file and requiring a new fingerprint; it used to be
  textual containment against the function's source text, which a comment
  naming the path satisfied while the file went genuinely unhashed (#97)
  (`test: tests/test-image-fingerprint.sh`).
- Compose-interpolated build args must go through `emit_build_args()` and
  never encode paths-as-identity, or identical worktrees stop sharing images
  (`tests/test-image-fingerprint.sh`).
- The staleness hash = image inputs PLUS runtime-only inputs (host mounts); it
  drives the recreate prompt and can differ from the image tag
  (`tests/test-image-fingerprint.sh`).
- The nix route builds `nix/base/Dockerfile.nix-default` and never hashes the
  root Dockerfile — hashing it there over-invalidates nix images (#53)
  (`tests/test-image-fingerprint.sh`).
- `.dockerignore` denies `lib/` wholesale and re-includes an allowlist; every
  default-context `COPY lib/...` in EITHER Dockerfile needs a matching
  `!lib/...` line (`tests/test-dockerignore-lib-allowlist.sh`).
- The two Dockerfiles mirror each other's COPY block for shared libs
  (setup-claude, audit-hook, git.sh, token-env); a lib shipped on one route
  only breaks the other at runtime (fingerprint + dockerignore guards catch
  most, not all, of this).
- The classic-arg detection regex in `overlay_sets_classic_args()` in
  `dev/devcontainer` must match the root `Dockerfile`'s classic-routing ARG set
  (`tests/test-classic-args-sync.sh`).
- The `BASE_IMAGE` pin line in `nix/base/compose.nix-base.yml` must stay
  byte-anchored to the grep in `ensure_nix_base()` in `dev/devcontainer`. That
  anchor now has FOUR encodings: that grep, the same grep plus the sed rewrite
  pattern in `dev/bump-nix-base`, and a fourth copy in
  `tests/test-bump-nix-base.sh` — reformat the line and two of the four go
  stale. The guard extracts each production pattern from its own source and
  runs it against the real pin line; it used to restate the grep and check
  only the compose side, so drift in `ensure_nix_base()` broke the runtime
  pull path with every suite green (#95)
  (`test: tests/test-nix-base-pin.sh; test: tests/test-bump-nix-base.sh`).
- Move the pinned base digest with `dev/bump-nix-base`, never by hand: it is
  the only thing checking that the digest is a manifest LIST. A per-arch digest
  (`sha-<short>-amd64`, printed by `imagetools inspect` directly beneath the
  list digest) builds fine on its own arch and breaks every other one. No
  offline test can catch that — it needs the registry — so the tool is the
  guard, and `tests/test-bump-nix-base.sh` guards the tool. Its read-only flags
  differ like `bump-hadolint`'s: `--check` reports (exit 0 whether or not the
  pin is current), `--verify` gates (non-zero on a bad pin OR an unreachable
  registry).
- Nix base image and nix seed volume are mutually exclusive — a `:/nix` mount
  shadows the baked store, so `overlay_has_seed_volume()` routes seed overlays
  to the classic Dockerfile and `ensure_nix_base()` refuses the forced
  combination (`unguarded`: "routing enforced in `dev/devcontainer`" names the
  SUT, not a guard, and no suite covers the decision —
  `tests/test-classic-args-sync.sh` deliberately scopes itself to the sibling
  helper's body so it cannot validate this regex by accident. A
  fixture-overlay test of the routing decision is feasible and simply
  unwritten; the risk is accepted because the forced path fails loudly
  (`ensure_nix_base` prints an explicit refusal) and the auto path's failure
  needs a real build to surface at all).
- `NIX_USER` in `lib/nix-seed.sh` owns the profile path every nix overlay
  repeats as `EXTRA_PATH: "/home/<NIX_USER>/.nix-profile/bin"` (compose can't
  read the bash var), `templates/nix/` included, so a rename there strands the
  copies and nix-seeded containers lose their tools from `PATH`
  (test: tests/test-nix-user-sync.sh).
- Publishing the Nix base does not deliver it: consumers build on the
  `BASE_IMAGE` digest in `nix/base/compose.nix-base.yml`, so a publish without
  a repin reaches nobody. The `pin` job in `.github/workflows/nix-base.yml`
  proposes that bump after every `main` publish by running `dev/bump-nix-base`
  — the workflow↔tool coupling (the job invokes the tool; the tool exits 0 when
  already pinned, which is what makes the job a quiet no-op) is guarded by
  `tests/test-bump-nix-base.sh`. Nothing owned this step before and it duly
  went undone: the pin sat on #41's digest through every later publish, leaving
  #70's fix live on ghcr and unreachable (#83).
- `nix/base/compose.nix-base.yml` is excluded from `nix-base.yml`'s trigger
  paths even though `nix/base/**` would match it: the pin is an output of a
  publish, not an input to one, so merging a pin bump must not set off another
  hour-long two-arch republish of byte-identical layers
  (`tests/test-nix-base-trigger-paths.sh`).
- Those same trigger paths must cover every tail-build input — default-context
  `COPY` sources in `nix/base/Dockerfile.nix-default`, the `--build-context`
  dir the `--from=project` COPYs read, and `.dockerignore`, which is no COPY
  source but filters the repo-root context the tail build uses — and `push`
  must equal `pull_request`. The
  workflow's own header states this rule and it drifted anyway —
  `lib/claude-code-token-env.sh` was COPYed, allowlisted in `.dockerignore` and
  hashed by `image_config_files()`, but unlisted here (#86), so a PR touching
  only that file skipped the tail build that exists to verify it. Nothing
  failed; the verification just never ran
  (`tests/test-nix-base-trigger-paths.sh`).
- `docker-build.yml`'s trigger paths hand-mirror the same input classes for
  the classic build — the root `Dockerfile`'s default-context `COPY` sources,
  the `--build-context` dir the `--from=project` COPYs read, and
  `.dockerignore` — with `push` equal to `pull_request`. The list omitted
  `.dockerignore` (#92), so a deny pattern newly matching a COPY source could
  merge green with no classic build run
  (test: `tests/test-docker-build-trigger-paths.sh`).
- `nix/base/flake.nix`'s `Env` hand-maintains PATH and no other variable *of
  the base's* (it also sets `HOME` and `SSL_CERT_FILE`, additions
  `check-env-drift.sh` explicitly allows):
  `streamLayeredImage` merges the MS base's config per-variable, so `LANG`,
  `PYTHON_*`, `PIPX_*` and `NVM_*` track an `msBaseDigest` repin on their own —
  but a per-variable merge picks a winner rather than concatenating, so the
  flake's PATH must prepend the infra profile AND keep every base component
  verbatim behind it or python/pip/pipx fall off PATH in the built image.
  `nix/base/check-env-drift.sh` catches both rots (a stale hand copy after a
  repin, and a nixpkgs bump that changes the merge) by inspecting the pinned
  base's `Config.Env` against the built image's and failing on any lost PATH
  component or var (ci: nix-base.yml#build, the "Env drift check" step — it
  needs docker, the loaded image and a pull of the pinned base, so it cannot
  be hermetic).
- The Claude Code version is pinned twice: `Dockerfile` ARG
  `CLAUDE_CODE_VERSION` and `nix/base/pkgs/claude-code.nix`; bump via
  `dev/bump-claude-code` (`tests/test-claude-code-pin-sync.sh`).
- `NIX_VERSION` and `NIX_INSTALLER_SHA256` in `lib/nix-seed.sh` are a coupled
  pair; bump via `dev/bump-nix` (`tests/test-bump-nix.sh`).
- `HADOLINT_VERSION` and BOTH per-arch checksums (`HADOLINT_SHA256_AMD64`,
  `HADOLINT_SHA256_ARM64`) in `projects/devcontainer/install-system.sh` are a
  coupled triple, and the `.pre-commit-config.yaml` hadolint rev is a fourth
  value that must equal the version; bump all four via `dev/bump-hadolint`
  (`tests/test-bump-hadolint.sh`). No test can verify a checksum — that needs
  the release artifact — so the tool is the coupling: it downloads both arch
  binaries and rewrites everything in one run, or writes nothing. The arm64
  sha in particular had no guard at all, and a half-bump breaks the arm64
  container build at `sha256sum -c` while the tree stays green.
  Its two read-only flags are not interchangeable: `--check` is a report
  (current vs latest, no download, always exits 0 — the shape `bump-nix` and
  `bump-claude-code` use), `--verify` is the gate (fetches the committed
  version's release, checks both per-arch checksums, non-zero on a mismatch
  OR on a failed fetch). Use `--verify` when you want an answer you can gate
  on; `--check` never fails.
- Linter pins (ruff, yamllint, hadolint) live in exactly two places —
  `.pre-commit-config.yaml` (which CI also consumes, via the single
  `pre-commit` job in `.github/workflows/lint.yml`) and
  `projects/devcontainer/install-system.sh`; bump both together
  (`tests/test-lint-config-sync.sh`).
- `.github/workflows/lint.yml` must stay a single `pre-commit run --all-files`
  gate: a per-linter job re-introduces a third, hand-kept version set and can
  disagree with the hooks on identical code (`unguarded`: the consequence with
  teeth — a second set of pins — is already covered, since
  `tests/test-lint-config-sync.sh` owns the two remaining pin files and dropped
  its old three-way `lint.yml` assertions when that job set went away. What is
  left is a shape rule over a 36-line workflow that only a deliberate edit can
  break, and the only mechanical form of it (assert the job list) restates the
  file at rung 3 and would go red on any legitimate step added around the
  gate).
- `.github/workflows/test.yml` must likewise stay a single `bash tests/run-all`
  step — the twin of the rule above, and the reason a newly added suite runs
  without touching CI: `tests/run-all` globs `tests/*.sh` (and fails on an
  empty glob), so the enumeration lives there and nowhere else. A CI job that
  lists suites itself becomes a second, hand-kept list that silently omits new
  ones (`unguarded`: same shape as `lint.yml` — a ban on adding a second
  runner, checkable only by restating a 22-line workflow at rung 3; the loss it
  prevents is bounded because the glob, not the workflow, enumerates suites).
- Container-side root logic lives in `lib/*.sh` and is INJECTED per run via
  `dc exec ... sh -c "$script" <argv0> <args...>` — a runtime input: no
  rebuild, no fingerprint entry unless it is also COPYed (test:
  `tests/test-volume-chown-guard.sh` pins the volume-perms driver line).
- `setup()` runs on EVERY cold start (gated only on `is_running`), so its
  steps must be idempotent and cheap. The named-volume chown is guarded by one
  owner+group stat, sound because `chown -R` is post-order: an interrupted
  walk leaves the mount point root-owned and retries next start
  (test: `tests/test-volume-chown-guard.sh`).
- Mount-point ownership repair is dispatched on the compose mount TYPE: a
  `volume` gets the guarded recursive chown plus its ancestors, a `bind` gets
  ancestors ONLY, anything else gets nothing. The dispatcher never routes a
  bind INTO the recursive branch, and the ANCESTOR WALK never chowns a bind
  mount point nor anything under one — it can reach both,
  which `docker-compose.yml` really does arrange (`DEV_MAIN_GIT` nests inside
  `DEV_MAIN_TREE`, both bound at their host paths) — though only when the HOST
  checkout sits under the container home prefix, which is not exotic: this
  repo's own main checkout is `/home/vscode/repos/github/devcontainer`.
  Everything at or below a bind mount point is the host side. Binds cannot
  simply be excluded from the walk instead: the daemon creates a bind target's
  missing parents as root exactly as it does a volume's, and that is what left
  `~/.claude/projects` unwritable (#106)
  (test: `tests/test-volume-chown-guard.sh`).
- Those two sentences are about the DISPATCHER and the ANCESTOR WALK. Neither
  says a bind is never recursed into, because it is: `chown -R` rooted at a
  volume has no mount awareness and descends through any bind nested under
  that volume — the transcript bind inside `claude-home`, i.e. the #106
  topology itself (`unguarded`: predates the ancestor-walk work and is latent
  only incidentally — both images pre-create `~/.claude` user-owned and
  `setup_claude` re-chowns the top every up, so the guard's precondition (a
  volume root not already user-owned) is not normally met. Closing it means
  replacing `chown -R` with a pruned `find`, which also rewrites the
  post-order rationale the cold-start guard rests on — filed as #115 with the
  options. `-xdev` is the tempting variant and is worse: it stops at every
  filesystem boundary, changing behaviour for reasons unrelated to this
  invariant. The suite pins the current, unsafe behaviour rather than
  asserting the safe one).
- The chown driver reads mount points from `dc config`, so the compose query in
  `mount_point_targets` decides what the lib ever sees; the query itself needs
  docker, but the python snippet inside it is lifted out and run against a
  synthetic config document (test: `tests/test-volume-chown-guard.sh`).
- Lock discipline: per-worktree lock on fd 9, repo-scoped build lock on fd 8;
  any helper backgrounded inside the locked region must be spawned with
  `9>&-` or it holds the worktree lock forever (`test:
  tests/test-image-reuse.sh` covers the fd-8 half — it runs the real
  `ensure_image()` body with a real `flock` and genuinely races two processes,
  asserting the lock plus the in-lock double-check collapse them to one build;
  `unguarded`: the `9>&-` rule on fd 9 has none. The three call sites
  (`setup_{ssh,gpg,x11}_forward`) each fork a long-lived `socat` against a host
  socket, so observing the leak needs a real host bridge, and the static form —
  deciding which source lines are "backgrounded inside the locked region" — is
  the fail-open shell-parser shape ADR-0005 warns about. Accepted because all
  three sites sit together in `ensure_up`, inline with the comment stating the
  rule).
- Compose file order in `dc()` is load-bearing: the nix-base override is
  appended after the project override so its `build.dockerfile` wins;
  host-mounts override generation must run before the first `dc` call
  (`unguarded`: both halves are orderings *within* `dev/devcontainer`, not two
  files that can disagree, so neither has a cheap hermetic form — which
  override wins is docker compose's merge semantics, answerable only by a real
  `docker compose config`, and "no `dc` call above this line" means statically
  deciding which lines can reach `dc`, the fail-open parser shape again.
  Asymmetric risk, accepted differently: a wrong file order surfaces at the
  next build as the wrong Dockerfile, while a `dc` call hoisted above
  `generate_host_mounts_override` is silent by construction — which is why
  that one carries its rule as an inline comment at the call site).
- Compose host-dir mounts on a `DEV_*` variable use `${VAR:?}`, with the
  export guaranteed by `dev/devcontainer`; a `:-/dev/null` default is allowed
  only where `/dev/null` is a legitimate value (`DEV_DOCKER_SOCK`). The
  `${HOME}`-rooted mounts are the deliberate exception — they read the ambient
  value, not a `dev/devcontainer` export (`unguarded`: mechanically greppable,
  but only against a hand-kept exception list (`DEV_DOCKER_SOCK`'s legitimate
  `:-/dev/null`, the two `${HOME}` mounts), which is a second copy of the very
  judgment being guarded. Accepted because the omission is not silent: compose
  interpolates the empty string and dies on the spec — `invalid spec: :/x:
  empty section between colons` — so `:?` buys a named error, not the
  difference between working and broken).
- `sanitize_name()` in `lib/git.sh` has three consumers that must agree:
  `dev/devcontainer`, `dev/init`, and a Python re-implementation in
  `dev/devcontainer-sessions` (`tests/test-sanitize-names.sh`,
  `tests/test-devcontainer-sessions.sh`).
- Naming contracts are parsed back apart downstream: compose project
  `<project>-dev-<worktree>`, volume suffix `_claude-home`, host log dir
  `-devcontainer-<compose-project>` — renaming any breaks
  `dev/devcontainer-sessions` (partially tested:
  `tests/test-devcontainer-sessions.sh`).
- A worktree's `.claude` is a real directory (tracked content like
  `.claude/agents/` lives in it) with only `container-audit/` and
  `container-sessions/` symlinked to the main checkout — audit logs and
  session stubs are shared, so `clean` affects all worktrees; pre-ADR-0003
  worktrees still carry a whole-directory symlink that every consumer must
  keep tolerating (`tests/test-worktree-claude-layout.sh`).
- `devcontainer clean` must delete the shared state through the link AND
  always recreate the emptied directory: run from the main checkout or a
  legacy worktree it deletes the very directory sibling new-layout worktrees
  link to, and skipping the recreate leaves them dangling
  (`tests/test-worktree-claude-layout.sh` lifts the block out and runs it on
  all three layouts).
- `cleanup-worktree`'s pre-flight compares `git status` paths against manifest
  entries, so it must ask for `--untracked-files=all`: git's default collapses
  a wholly-untracked `.claude/` to one entry that matches no manifest path
  (`tests/test-worktree-claude-layout.sh`).
- ADR-0003's re-inclusion must hold in the LIVE `.gitignore` of every
  checkout: a path under `.claude/agents/` must not be ignored, or `git add`
  on a new agent definition silently stages nothing (#91). The live file is
  untracked — outside the tree — so the guard is a functional
  `git check-ignore` probe at commit time, `dev/check-gitignore-agents`,
  wired as a local pre-commit hook, plus a non-blocking warning in
  `dev/setup-worktree` at the moment the main checkout's copy propagates
  (tool: dev/check-gitignore-agents;
  test: tests/test-gitignore-agents-reinclusion.sh). Harness-created session
  worktrees under `.claude/worktrees/` never run setup-worktree and may lack
  a `.gitignore` entirely (unguarded: ephemeral and harness-managed; nothing
  authors agent files there, and the commit-time hook still fires if one
  does).
- Setup-token resolution (ADR-0002): `set-token` override > `/run/secrets`
  Compose secret > host store; unusable (unreadable/empty) tiers fall through
  (`tests/test-claude-token.sh`).
- Profile resolution: `DEV_CLAUDE_PROFILE` > the container record seeding
  pinned (`~/.claude/.active-profile`) > the host `active-profile` marker;
  seeding re-resolves fresh (env > marker) and re-pins, so launches always
  agree with the last seed (`tests/test-claude-token.sh`,
  `tests/test-claude-seed.sh`).
- The token-env snippet strips higher-precedence auth env ONLY when it injects
  a token, and its unset-list must equal `setup-claude.py`'s
  `HIGHER_PRECEDENCE_ENV` (`tests/test-token-env-snippet.sh`).
- `dev/init` never touches files it skips as pre-existing; `--nix` refuses
  files that diverged from the defaults baseline without `--force`
  (`tests/test-init-nix.sh`).
- The `devcontainer` command surface has ONE source: `lib/command-table.tsv`
  (read and validated by `lib/command-table.sh`). `show_usage` in
  `dev/devcontainer` and the bash/zsh/fish scripts emitted by
  `dev/devcontainer-completions` are all GENERATED from it, so those four
  encodings can no longer disagree — no test is needed for that, it is
  structural. What is guarded is the one pair still hand-written at both ends
  (dispatch arms == table rows), plus table well-formedness, the generated
  scripts parsing in their target shell, and every table name actually
  reaching all three of them — generation makes the lists agree with each
  other, not with the table (`structural`; `test:
  tests/test-completions-sync.sh` for the hand-written pair). That dispatch
  parse must fail closed: it reads arms by strict shape, and until #96 an arm
  in any other shape (`[[ ... == ... ]]`, a quoted case pattern) silently left
  the set, so a command could bypass the table with the suite green — the #86
  parser shape recurring inside a guard. Unclassified early-region `$1` tests
  and a case-arm/`;;` count mismatch are now failures.
  The table is read at generation time only: `install-completions` and the
  Nix package redirect the generator's stdout to a file, so an installed
  completion script has no runtime dependency on the repo.
- The `arg-type` vocabulary is a four-file convention: `ok_type` in
  `lib/command-table.sh`, the doc block in `lib/command-table.tsv`, and one
  `case "${types[$n]}"` block per shell in `dev/devcontainer-completions`. A
  value known to the validator but to no generator emits no wiring, silently
  (`tests/test-completions-sync.sh` builds a synthetic one-command-per-type
  table and requires non-empty, distinct wiring in all three shells).
- Because generation can now fail (a malformed table), writing a generated
  completion must be atomic: `dev/install-completions` renders to a temp file
  and renames, never redirecting into the installed file
  (`tests/test-completions-sync.sh`).
- The worktree manifest format written by `dev/setup-worktree`
  (`<action>\t<path>`, plus a legacy bare-path form) is parsed by
  `dev/cleanup-worktree`; the two must change in lockstep (`test:
  tests/test-worktree-claude-layout.sh` round-trips the live format end to end
  — the real `setup-worktree` writes the manifest, literal `symlink\t<path>`
  lines are asserted on it, and the real `cleanup-worktree` then replays it on
  all three layouts; `unguarded`: the legacy bare-path branch, which has no
  producer left in the tree, so no round-trip can reach it and only a
  hand-built fixture would).
- Main-only state (`project.env`, the `dev/` scripts, the hook symlink targets)
  is resolved with `dev_main_tree()` in `lib/git.sh`, never `git rev-parse
  --show-toplevel`, which inside a linked worktree returns that worktree.
  Consumers: `dev/devcontainer`, `dev/init`, `dev/new-worktree`,
  `dev/setup-worktree`, `dev/cleanup-worktree`, and `install_hooks()` in
  `lib/git.sh` itself; the surviving `--show-toplevel` calls in `dev/` are
  deliberate "where am I now" reads, each paired with a `dev_main_tree()` call
  in the same script (the two git hooks want the current tree by definition)
  (`unguarded`: which resolver a new call site needs is a judgment about
  intent, not a fact two files can disagree on — a grep-level guard would have
  to ban a call that is correct at all six of its current sites. The suites
  reach it only indirectly, by running the scripts from inside a real
  worktree).

## Conventions

- Shell scripts use `set -euo pipefail`. Scripts in `dev/` are extensionless; libraries in `lib/` use `.sh`.
- Shellcheck is configured with `--severity=warning` and `disable=SC2155` (see `.shellcheckrc`).
- Python targets 3.12, formatted by ruff with 120 char line length (see `ruff.toml`).
- Commit messages follow conventional commits: `fix:`, `feat:`, `ci:`, etc.
- A PR that resolves an issue puts `Closes #N` in its **body** (not just the title). Citing the number in prose does not close anything: #54 was titled "…(#53)" and #53 stayed open for two weeks after it shipped, while #35 was independently re-solved by #71 because nobody knew it was open. An issue list that never drains stops being read, and a fixed-but-open issue is worse than no issue — it sends the next reader after work that is already done.
- Gitignore model: `.gitignore` is untracked (it ignores itself; per-checkout), and `.gitignore.template` is the tracked source of durable patterns. `dev/setup-worktree` copies the main checkout's live `.gitignore` into each worktree (git opens it `O_NOFOLLOW`, so it must be a copy, not a symlink), falling back to `.gitignore.template` when the live file is missing. Durable ignore patterns go in the template; the live file may carry personal extras. Claude Code state is ignored via `.claude/*` plus `!.claude/agents/` — never a bare `.claude` entry, which would ignore the directory itself and block re-inclusion of the tracked agent definitions (ADR-0003). Because the live file is untracked, drift from the template is caught at commit time by `dev/check-gitignore-agents`, a functional `git check-ignore` probe (see the invariant; #91).
- Adding a `devcontainer` subcommand: add the dispatch arm in `dev/devcontainer`, add a row to `lib/command-table.tsv`. That is the whole workflow — the usage text, the bash/zsh/fish word lists, their descriptions, and the per-command argument wiring are all generated from the row. Never hand-edit a command list in `dev/devcontainer-completions` or the Commands block of `show_usage`.
- When targeting a specific dependency group, use `uv sync --group dev`, not `--dev` (legacy alias removed in uv 0.7.x+).
- When creating a new project overlay, strip inherited packages and config for tools the target project doesn't use — don't leave dead weight from the source overlay.
- Linter versions live in two paired sources of truth: `.pre-commit-config.yaml` (host commit-time hooks, and CI — `.github/workflows/lint.yml` is a single `pre-commit run --all-files` job with no pins of its own) and `projects/devcontainer/install-system.sh` (in-container bare binaries, for editor integrations and ad-hoc runs). Bump ruff, yamllint, and hadolint in both together; `tests/test-lint-config-sync.sh` guards against drift. hadolint additionally carries two per-arch checksums in `install-system.sh` that no test can verify — bump it with `devcontainer bump-hadolint` rather than by hand, and use `devcontainer bump-hadolint --verify` to confirm the committed checksums really are the release's.
- Any convention that spans two files gets a drift-guard test when it is introduced (existing examples: `tests/test-claude-code-pin-sync.sh`, `tests/test-lint-config-sync.sh`, `tests/test-classic-args-sync.sh`, `tests/test-completions-sync.sh`, `tests/test-dockerignore-lib-allowlist.sh`). A convention only its author knows about will drift.
- Guards follow ADR-0005. Type every new invariant's guard (see the Invariants header for the vocabulary). When adding or materially changing a guard, break the invariant once, watch the guard go red, and record the mutation in the test's header comment. Prefer generating the second copy from the first, then deriving the expectation by parsing the source of truth at check time; restate-and-compare is the fallback, not the default.
- A structural audit (the `structural-auditor` agent) is closed only when each surviving shape is filed as an issue, landed in a PR, or recorded as an accepted `unguarded:` invariant — a report is not a disposal. An audit finding that dies in its conversation is the fixed-but-open issue problem in a new costume.
