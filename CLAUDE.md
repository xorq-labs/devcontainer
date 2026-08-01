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
- `lib/` — shared bash libraries sourced by dev/ scripts (`git.sh`, `host-bridge.sh`, `host-mounts.sh`, `list-file.sh`)
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
`.claude/agents/` in git; per-subdir state symlinks), and nix/base/README.md
"Design decisions" for the base-image record.

## Invariants

The load-bearing cross-file facts, one line each, with the drift guard that
enforces it in parentheses (`—` = unenforced; add a guard if you touch it).

- Every Dockerfile `COPY` source from the default context is hashed by
  `image_config_files()` in `dev/devcontainer`, or edits to it silently reuse
  a stale image (`tests/test-image-fingerprint.sh`).
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
  byte-anchored to the grep in `ensure_nix_base()` in `dev/devcontainer`
  (`tests/test-nix-base-pin.sh`).
- Nix base image and nix seed volume are mutually exclusive — a `:/nix` mount
  shadows the baked store (routing enforced in `dev/devcontainer`).
- The Claude Code version is pinned twice: `Dockerfile` ARG
  `CLAUDE_CODE_VERSION` and `nix/base/pkgs/claude-code.nix`; bump via
  `dev/bump-claude-code` (`tests/test-claude-code-pin-sync.sh`).
- `NIX_VERSION` and `NIX_INSTALLER_SHA256` in `lib/nix-seed.sh` are a coupled
  pair; bump via `dev/bump-nix` (`tests/test-bump-nix.sh`).
- Linter pins (ruff, yamllint, hadolint) live in exactly two places —
  `.pre-commit-config.yaml` (which CI also consumes, via the single
  `pre-commit` job in `.github/workflows/lint.yml`) and
  `projects/devcontainer/install-system.sh`; bump both together
  (`tests/test-lint-config-sync.sh`).
- `.github/workflows/lint.yml` must stay a single `pre-commit run --all-files`
  gate: a per-linter job re-introduces a third, hand-kept version set and can
  disagree with the hooks on identical code (—).
- Container-side root logic lives in `lib/*.sh` and is INJECTED per run via
  `dc exec ... sh -c "$script" <argv0> <args...>` — a runtime input: no
  rebuild, no fingerprint entry unless it is also COPYed
  (`tests/test-volume-chown-guard.sh` pins the volume-perms driver line).
- `setup()` runs on EVERY cold start (gated only on `is_running`), so its
  steps must be idempotent and cheap. The named-volume chown is guarded by one
  owner+group stat, sound because `chown -R` is post-order: an interrupted
  walk leaves the mount point root-owned and retries next start
  (`tests/test-volume-chown-guard.sh`).
- Lock discipline: per-worktree lock on fd 9, repo-scoped build lock on fd 8;
  any helper backgrounded inside the locked region must be spawned with
  `9>&-` or it holds the worktree lock forever (—).
- Compose file order in `dc()` is load-bearing: the nix-base override is
  appended after the project override so its `build.dockerfile` wins;
  host-mounts override generation must run before the first `dc` call (—).
- Compose host-dir mounts on a `DEV_*` variable use `${VAR:?}`, with the
  export guaranteed by `dev/devcontainer`; a `:-/dev/null` default is allowed
  only where `/dev/null` is a legitimate value (`DEV_DOCKER_SOCK`). The
  `${HOME}`-rooted mounts are the deliberate exception — they read the ambient
  value, not a `dev/devcontainer` export (—).
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
- Completion command lists (bash/zsh/fish) and `show_usage` must match the
  dispatch case in `dev/devcontainer` (`tests/test-completions-sync.sh`).
- The worktree manifest format written by `dev/setup-worktree`
  (`<action>\t<path>`, plus a legacy bare-path form) is parsed by
  `dev/cleanup-worktree`; the two must change in lockstep (—).

## Conventions

- Shell scripts use `set -euo pipefail`. Scripts in `dev/` are extensionless; libraries in `lib/` use `.sh`.
- Shellcheck is configured with `--severity=warning` and `disable=SC2155` (see `.shellcheckrc`).
- Python targets 3.12, formatted by ruff with 120 char line length (see `ruff.toml`).
- Commit messages follow conventional commits: `fix:`, `feat:`, `ci:`, etc.
- Gitignore model: `.gitignore` is untracked (it ignores itself; per-checkout), and `.gitignore.template` is the tracked source of durable patterns. `dev/setup-worktree` copies the main checkout's live `.gitignore` into each worktree (git opens it `O_NOFOLLOW`, so it must be a copy, not a symlink), falling back to `.gitignore.template` when the live file is missing. Durable ignore patterns go in the template; the live file may carry personal extras. Claude Code state is ignored via `.claude/*` plus `!.claude/agents/` — never a bare `.claude` entry, which would ignore the directory itself and block re-inclusion of the tracked agent definitions (ADR-0003).
- When targeting a specific dependency group, use `uv sync --group dev`, not `--dev` (legacy alias removed in uv 0.7.x+).
- When creating a new project overlay, strip inherited packages and config for tools the target project doesn't use — don't leave dead weight from the source overlay.
- Linter versions live in two paired sources of truth: `.pre-commit-config.yaml` (host commit-time hooks, and CI — `.github/workflows/lint.yml` is a single `pre-commit run --all-files` job with no pins of its own) and `projects/devcontainer/install-system.sh` (in-container bare binaries, for editor integrations and ad-hoc runs). Bump ruff, yamllint, and hadolint in both together; `tests/test-lint-config-sync.sh` guards against drift.
- Any convention that spans two files gets a drift-guard test when it is introduced (existing examples: `tests/test-claude-code-pin-sync.sh`, `tests/test-lint-config-sync.sh`, `tests/test-classic-args-sync.sh`, `tests/test-completions-sync.sh`, `tests/test-dockerignore-lib-allowlist.sh`). A convention only its author knows about will drift.
