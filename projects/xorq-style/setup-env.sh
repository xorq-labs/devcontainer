#!/usr/bin/env bash
# Project-specific in-container setup. Runs inside the container as user
# vscode, invoked by dev/devcontainer.
#
# Subcommands:
#   first-run        — dependency install, pre-commit hooks, and direnv wiring
#   sync-if-needed   — re-sync deps only when uv.lock is newer than the
#                      .venv/.last-sync stamp (cheap enough to run every start)
set -euo pipefail
cmd="${1:-first-run}"
case "$cmd" in
    first-run)
        echo "Installing dependencies..."
        uv sync --all-extras --all-groups
        touch .venv/.last-sync

        echo "Installing pre-commit hooks..."
        uv run pre-commit install 2>/dev/null || true

        if ! grep -q "direnv hook bash" ~/.bashrc 2>/dev/null; then
            echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
        fi

        # Whitelist the workspace so direnv loads .envrc without a manual
        # `direnv allow` in every fresh container.
        mkdir -p ~/.config/direnv
        cat > ~/.config/direnv/direnv.toml <<TOML
[whitelist]
prefix = ["${PWD}"]
TOML

        # Seed the per-developer (gitignored) .envrc.user from the tracked
        # template on first run only — never overwrite an existing one.
        if [ -f .envrcs/.envrc.user.template ] && [ ! -e .envrcs/.envrc.user ] && [ ! -L .envrcs/.envrc.user ]; then
            cp .envrcs/.envrc.user.template .envrcs/.envrc.user
        fi
        ;;
    sync-if-needed)
        [ -f uv.lock ] || exit 0
        lock_mtime="$(stat -c %Y uv.lock)"
        stamp_mtime="$(stat -c %Y .venv/.last-sync 2>/dev/null || echo 0)"
        if [ "$lock_mtime" -gt "$stamp_mtime" ]; then
            uv sync --all-extras --all-groups
            touch .venv/.last-sync
        fi
        ;;
    *) echo "usage: setup-env [first-run|sync-if-needed]" >&2; exit 1 ;;
esac
