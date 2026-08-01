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

## Conventions

- Shell scripts use `set -euo pipefail`. Scripts in `dev/` are extensionless; libraries in `lib/` use `.sh`.
- Shellcheck is configured with `--severity=warning` and `disable=SC2155` (see `.shellcheckrc`).
- Python targets 3.12, formatted by ruff with 120 char line length (see `ruff.toml`).
- Commit messages follow conventional commits: `fix:`, `feat:`, `ci:`, etc.
- Gitignore model: `.gitignore` is untracked (it ignores itself; per-checkout), and `.gitignore.template` is the tracked source of durable patterns. `dev/setup-worktree` copies the main checkout's live `.gitignore` into each worktree (git opens it `O_NOFOLLOW`, so it must be a copy, not a symlink), falling back to `.gitignore.template` when the live file is missing. Durable ignore patterns go in the template; the live file may carry personal extras.
- When targeting a specific dependency group, use `uv sync --group dev`, not `--dev` (legacy alias removed in uv 0.7.x+).
- When creating a new project overlay, strip inherited packages and config for tools the target project doesn't use — don't leave dead weight from the source overlay.
- Linter versions live in three paired sources of truth: `.pre-commit-config.yaml` (host commit-time hooks), `projects/devcontainer/install-system.sh` (in-container linters), and `.github/workflows/lint.yml` (CI). Bump ruff, yamllint, and hadolint in all three together; `tests/test-lint-config-sync.sh` guards against drift.

## Architecture invariants

Load-bearing cross-file facts, each with the test that enforces it (or marked unenforced).

- Every file `COPY`'d into an image must appear in `image_config_files()` in `dev/devcontainer`, or edits silently never trigger a rebuild (tests/test-image-fingerprint.sh).
- Compose-interpolated build args must go through `emit_build_args()` and never encode paths-as-identity, or identical worktrees stop sharing images (tests/test-image-fingerprint.sh).
- Lock discipline: per-worktree lock on fd 9, repo-scoped build lock on fd 8; any backgrounded helper must be spawned with `9>&-` or it holds the worktree lock forever (unenforced).
- `sanitize_name()` in `lib/git.sh` has three consumers that must agree: `dev/devcontainer`, `dev/init`, and a Python re-implementation in `dev/devcontainer-sessions` (tests/test-sanitize-names.sh, tests/test-devcontainer-sessions.sh).
- Naming contracts are parsed back apart downstream: compose project `<project>-dev-<worktree>`, volume suffix `_claude-home`, host log dir `-devcontainer-<compose-project>` — renaming any breaks `dev/devcontainer-sessions` (partially tested: tests/test-devcontainer-sessions.sh).
- The Claude Code version pinned in the root `Dockerfile` ARG and `nix/base/pkgs/claude-code.nix` must match; bump via `dev/bump-claude-code` (tests/test-claude-code-pin-sync.sh).
- `NIX_VERSION` and `NIX_INSTALLER_SHA256` in `lib/nix-seed.sh` are a coupled pair; bump via `dev/bump-nix` (tests/test-bump-nix.sh).
- The unset-list in `lib/claude-code-token-env.sh` mirrors `HIGHER_PRECEDENCE_ENV` in `setup-claude.py` (tests/test-token-env-snippet.sh).
- The `BASE_IMAGE` pin line in `nix/base/compose.nix-base.yml` must stay byte-anchored to the grep in `ensure_nix_base()` in `dev/devcontainer` (tests/test-nix-base-pin.sh).
- The `.dockerignore` `lib/` allowlist must cover every `COPY lib/...` in both Dockerfiles (tests/test-dockerignore-lib-allowlist.sh).
- Linter pins live in three places — see Conventions above (tests/test-lint-config-sync.sh).
- The classic-arg detection regex in `overlay_sets_classic_args()` in `dev/devcontainer` must match the root `Dockerfile`'s classic-only ARG list (tests/test-classic-args-sync.sh).
- Completion command lists (bash/zsh/fish) and `show_usage` must match the dispatch case in `dev/devcontainer` (tests/test-completions-sync.sh).
- Compose file order in `dc()` is load-bearing: the nix-base override is appended after the project override so its `build.dockerfile` wins; host-mounts override generation must run before the first `dc` call (unenforced).
- Nix base image and nix seed volume are mutually exclusive — a `:/nix` mount shadows the baked store (routing enforced in `dev/devcontainer`).
- `.claude` is symlinked from every worktree to the main checkout — audit logs and session stubs are shared, so `clean` affects all worktrees (unenforced).

## ADRs

Design decisions live in `docs/adr/`. A PR that changes a recorded decision must amend the ADR in the same PR. When you hit a design fork, draft the amendment — options, trade-offs, and a recommendation — rather than asking an open question. Current records: ADR-0001 (private credential seeding), ADR-0002 (setup-token env delivery), and nix/base/README.md "Design decisions" for the base-image record.

## Autonomy & escalation

Fix review findings, CI failures, and lint without asking when the fix preserves the change's design intent. Stop only for design forks — public interfaces, recorded design decisions (see ADRs), auth/identity semantics — and bring 2-3 concrete options with a recommendation, never an open question. Review hard rules: verify every finding against the code before reporting it; never post to GitHub without being asked; never read live credential files — reason from code.
