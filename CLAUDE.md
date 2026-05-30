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

```bash
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
- `.gitignore.template` defines patterns for per-worktree gitignored files; `setup-worktree` copies it as `.gitignore` into each worktree.
