#!/usr/bin/env bash
# Project-specific in-container setup. Runs inside the container as user
# vscode, invoked by dev/devcontainer.
#
# Subcommands:
#   first-run        — initial dependency install + dev tooling (after build)
#   sync-if-needed   — re-sync deps if the lockfile is newer than the stamp
set -euo pipefail

cmd="${1:-first-run}"

case "$cmd" in
    first-run)
        . "$HOME/.cargo/env"

        echo "Installing Python dependencies..."
        uv sync --all-extras --all-groups
        touch .venv/.last-sync

        # Build the native extension if not already present
        if ! compgen -G "python/xorq_datafusion/_internal/*.so" > /dev/null 2>&1; then
            echo "Building native extension (maturin develop)..."
            uv run maturin develop --release
        fi

        # Worktrees inherit core.hooksPath from the main repo's .git/config;
        # pre-commit refuses to install when it's set. Override via env vars
        # (highest git-config precedence) to the worktree's own hooks dir.
        if git config core.hooksPath >/dev/null 2>&1; then
            _hooks_dir="$(git rev-parse --git-dir)/hooks"
            export GIT_CONFIG_COUNT=1
            export GIT_CONFIG_KEY_0=core.hooksPath
            export GIT_CONFIG_VALUE_0="${_hooks_dir}"
        fi

        echo "Installing pre-commit hooks..."
        uv run pre-commit install 2>/dev/null || true

        _bashrc_marker="# xorq-datafusion-setup"
        if ! grep -qF "$_bashrc_marker" ~/.bashrc 2>/dev/null; then
            cat >> ~/.bashrc <<BASH
$_bashrc_marker
eval "\$(direnv hook bash)"
. "\$HOME/.cargo/env"
BASH
            if [ -n "${GIT_CONFIG_COUNT:-}" ]; then
                cat >> ~/.bashrc <<BASH
export GIT_CONFIG_COUNT=$GIT_CONFIG_COUNT
export GIT_CONFIG_KEY_0=$GIT_CONFIG_KEY_0
export GIT_CONFIG_VALUE_0=$GIT_CONFIG_VALUE_0
BASH
            fi
        fi

        mkdir -p ~/.config/direnv
        cat > ~/.config/direnv/direnv.toml <<TOML
[whitelist]
prefix = ["${PWD}"]
TOML
        ;;
    sync-if-needed)
        . "$HOME/.cargo/env" 2>/dev/null || true

        [ -f uv.lock ] || exit 0
        lock_mtime="$(stat -c %Y uv.lock)"
        stamp_mtime="$(stat -c %Y .venv/.last-sync 2>/dev/null || echo 0)"
        if [ "$lock_mtime" -gt "$stamp_mtime" ]; then
            uv sync --all-extras --all-groups
            touch .venv/.last-sync
        fi
        ;;
    *)
        echo "usage: setup-env [first-run|sync-if-needed]" >&2
        exit 1
        ;;
esac
