#!/usr/bin/env bash
# Project-specific in-container setup. Runs inside the container as user
# vscode, invoked by dev/devcontainer.
#
# Subcommands:
#   first-run        — initial dependency install into the volume-backed venv
#   sync-if-needed   — re-sync deps only when uv.lock is newer than the
#                      .venv/.last-sync stamp (cheap enough to run every start)
set -euo pipefail
cmd="${1:-first-run}"
case "$cmd" in
    first-run)
        echo "Installing dependencies..."
        uv sync --all-extras --all-groups
        touch .venv/.last-sync
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
