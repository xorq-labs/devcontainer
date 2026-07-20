#!/usr/bin/env bash
# Project-specific in-container setup. Runs inside the container as user
# vscode, invoked by dev/devcontainer.
#
# Subcommands:
#   first-run        — initial dependency install + dev tooling (after build)
#   sync-if-needed   — re-sync deps if lockfiles are newer than stamps
set -euo pipefail

cmd="${1:-first-run}"

case "$cmd" in
    first-run)
        # Nix: unpack the build-time seed into the durable `nix` volume, restore
        # the profile symlink, merge host nix.conf (sandbox off — the container
        # is the sandbox), and source the profile. Shared logic lives in
        # lib/nix-seed.sh, COPYd to /usr/local/lib/devcontainer by the root
        # Dockerfile. (Empty volume -> fresh extract; a volume from an older
        # image -> overlay fresh paths with --skip-old-files.)
        . /usr/local/lib/devcontainer/nix-seed.sh
        nix_seed_volume

        # Source cargo env for this session
        . "$HOME/.cargo/env"

        echo "Installing Python dependencies..."
        uv sync --all-extras --all-groups
        touch .venv/.last-sync

        echo "Installing desktop (pnpm) dependencies..."
        if [ -d desktop ]; then
            (cd desktop && pnpm install)
            touch desktop/node_modules/.last-sync
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
        uv run pre-commit install || true

        _bashrc_marker="# xorq-desktop-setup"
        if ! grep -qF "$_bashrc_marker" ~/.bashrc 2>/dev/null; then
            cat >> ~/.bashrc <<BASH
$_bashrc_marker
eval "\$(direnv hook bash)"
. "\$HOME/.cargo/env"
BASH
            if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
                echo '. "$HOME/.nix-profile/etc/profile.d/nix.sh"' >> ~/.bashrc
            fi
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

        if [ -f .envrcs/.envrc.user.template ] && [ ! -e .envrcs/.envrc.user ] && [ ! -L .envrcs/.envrc.user ]; then
            cp .envrcs/.envrc.user.template .envrcs/.envrc.user
        fi
        ;;
    sync-if-needed)
        . "$HOME/.cargo/env" 2>/dev/null || true

        if [ -f uv.lock ]; then
            lock_mtime="$(stat -c %Y uv.lock)"
            stamp_mtime="$(stat -c %Y .venv/.last-sync 2>/dev/null || echo 0)"
            if [ "$lock_mtime" -gt "$stamp_mtime" ]; then
                uv sync --all-extras --all-groups
                touch .venv/.last-sync
            fi
        fi

        if [ -f desktop/pnpm-lock.yaml ]; then
            lock_mtime="$(stat -c %Y desktop/pnpm-lock.yaml)"
            stamp_mtime="$(stat -c %Y desktop/node_modules/.last-sync 2>/dev/null || echo 0)"
            if [ "$lock_mtime" -gt "$stamp_mtime" ]; then
                (cd desktop && pnpm install)
                touch desktop/node_modules/.last-sync
            fi
        fi
        ;;
    *)
        echo "usage: setup-env [first-run|sync-if-needed]" >&2
        exit 1
        ;;
esac
