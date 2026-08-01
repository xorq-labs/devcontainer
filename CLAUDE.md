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

## Design decisions: ADRs

Design decisions live in `docs/adr/` (numbered per-repo; cross-repo references
are qualified by repo name). A PR that changes an ADR-recorded decision amends
the ADR in the same PR — doc and code land together or not at all. When an
agent hits a design fork mid-PR, it drafts the ADR amendment (options,
trade-offs, recommendation) and pushes it for review rather than blocking on
an interactive question.

## Invariants

The load-bearing cross-file facts, one line each, with the drift guard that
enforces it in parentheses (`—` = unenforced; add a guard if you touch it).

- Every Dockerfile `COPY` source from the default context is hashed by
  `image_config_files()` in `dev/devcontainer`, or edits to it silently reuse
  a stale image (`tests/test-image-fingerprint.sh`).
- The staleness hash = image inputs PLUS runtime-only inputs (host mounts); it
  drives the recreate prompt and can differ from the image tag
  (`tests/test-image-fingerprint.sh`).
- The nix route builds `nix/base/Dockerfile.nix-default` and never hashes the
  root Dockerfile — hashing it there over-invalidates nix images (#53) (—).
- `.dockerignore` denies `lib/` wholesale and re-includes an allowlist; every
  default-context `COPY lib/...` in EITHER Dockerfile needs a matching
  `!lib/...` line (`tests/test-dockerignore-lib-allowlist.sh`).
- The two Dockerfiles mirror each other's COPY block for shared libs
  (setup-claude, audit-hook, git.sh, token-env); a lib shipped on one route
  only breaks the other at runtime (fingerprint + dockerignore guards catch
  most, not all, of this).
- The Claude Code version is pinned twice: `Dockerfile` ARG
  `CLAUDE_CODE_VERSION` and `nix/base/pkgs/claude-code.nix`
  (`tests/test-claude-code-pin-sync.sh`).
- Container-side root logic lives in `lib/*.sh` and is INJECTED per run via
  `dc exec ... sh -c "$script" <argv0> <args...>` — a runtime input: no
  rebuild, no fingerprint entry unless it is also COPYed
  (`tests/test-volume-chown-guard.sh` pins the volume-perms driver line).
- `setup()` runs on EVERY cold start (gated only on `is_running`), so its
  steps must be idempotent and cheap. The named-volume chown is guarded by one
  owner+group stat, sound because `chown -R` is post-order: an interrupted
  walk leaves the mount point root-owned and retries next start
  (`tests/test-volume-chown-guard.sh`).
- Compose host-dir mounts use `${VAR:?}` with the export guaranteed by
  `dev/devcontainer`; a `:-/dev/null` default is allowed only where
  `/dev/null` is a legitimate value (`DEV_DOCKER_SOCK`) (—).
- Setup-token resolution (ADR-0002): `set-token` override > `/run/secrets`
  Compose secret > host store; unusable (unreadable/empty) tiers fall through
  (`tests/test-claude-token.sh`).
- Profile resolution: `DEV_CLAUDE_PROFILE` > the container record seeding
  pinned (`~/.claude/.active-profile`) > the host `active-profile` marker;
  seeding re-resolves fresh (env > marker) and re-pins, so launches always
  agree with the last seed (`tests/test-claude-token.sh`).
- The token-env snippet strips higher-precedence auth env ONLY when it injects
  a token, and its unset-list must equal `setup-claude.py`'s
  `HIGHER_PRECEDENCE_ENV` (`tests/test-token-env-snippet.sh`).
- `dev/init` never touches files it skips as pre-existing; `--nix` refuses
  files that diverged from the defaults baseline without `--force`
  (`tests/test-init-nix.sh`).

## Conventions

- Shell scripts use `set -euo pipefail`. Scripts in `dev/` are extensionless; libraries in `lib/` use `.sh`.
- Shellcheck is configured with `--severity=warning` and `disable=SC2155` (see `.shellcheckrc`).
- Python targets 3.12, formatted by ruff with 120 char line length (see `ruff.toml`).
- Commit messages follow conventional commits: `fix:`, `feat:`, `ci:`, etc.
- `.gitignore.template` defines patterns for per-worktree gitignored files; `setup-worktree` copies it as `.gitignore` into each worktree.
- When targeting a specific dependency group, use `uv sync --group dev`, not `--dev` (legacy alias removed in uv 0.7.x+).
- When creating a new project overlay, strip inherited packages and config for tools the target project doesn't use — don't leave dead weight from the source overlay.
- Linter versions live in two paired sources of truth: `.pre-commit-config.yaml` (host commit-time hooks) and `projects/devcontainer/install-system.sh` (in-container linters). Bump ruff, yamllint, and hadolint in both together so host and container agree.
- Any convention that spans two files gets a drift-guard test when it is introduced (existing examples: `tests/test-dockerignore-lib-allowlist.sh`, the COPY-source check in `tests/test-image-fingerprint.sh`, `tests/test-claude-code-pin-sync.sh`, the unset-list guard in `tests/test-token-env-snippet.sh`). A convention only its author knows about will drift.
