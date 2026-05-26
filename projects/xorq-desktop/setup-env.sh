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
        # Nix: seed durable /nix volume from build-time tarball.
        # Empty volume → fresh extract. Populated volume from an older image
        # → overlay the new seed (--skip-old-files preserves user-installed
        # paths; content-addressed store makes overlays safe). Version stamp
        # avoids re-running the overlay on every first-run.
        if [ ! -d /nix/store ]; then
            echo "Seeding Nix store into volume..."
            tar xf /nix-seed.tar -C /
            cp /nix-seed.version /nix/.seed-version
        elif [ ! -f /nix/.seed-version ] || ! cmp -s /nix-seed.version /nix/.seed-version; then
            echo "Nix seed version differs from volume — overlaying new paths..."
            tar xf /nix-seed.tar --skip-old-files -C /
            cp /nix-seed.version /nix/.seed-version
        fi
        # Restore profile symlink (lost when container is recreated from image)
        if [ ! -e "$HOME/.nix-profile" ]; then
            ln -sf "/nix/var/nix/profiles/per-user/$(id -un)/profile" "$HOME/.nix-profile"
        fi
        # Merge host nix config with container overrides (sandbox off — container is the sandbox)
        if [ ! -f "$HOME/.config/nix/nix.conf" ]; then
            mkdir -p "$HOME/.config/nix"
            [ -f "$HOME/.config/nix-host/nix.conf" ] && grep -v '^sandbox' "$HOME/.config/nix-host/nix.conf" > "$HOME/.config/nix/nix.conf"
            printf 'sandbox = false\nfilter-syscalls = false\n' >> "$HOME/.config/nix/nix.conf"
            for f in "$HOME/.config/nix-host"/*; do
                [ "$(basename "$f")" = "nix.conf" ] && continue
                ln -sf "$f" "$HOME/.config/nix/$(basename "$f")"
            done
        fi
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"

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
            if ! grep -q 'GIT_CONFIG_KEY_0=core.hooksPath' ~/.bashrc 2>/dev/null; then
                cat >> ~/.bashrc <<BASH
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0="${_hooks_dir}"
BASH
            fi
        fi

        echo "Installing pre-commit hooks..."
        uv run pre-commit install 2>/dev/null || true

        if ! grep -q "direnv hook bash" ~/.bashrc 2>/dev/null; then
            echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
        fi

        if ! grep -q '.cargo/env' ~/.bashrc 2>/dev/null; then
            echo '. "$HOME/.cargo/env"' >> ~/.bashrc
        fi

        if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ] \
           && ! grep -q 'nix.sh' ~/.bashrc 2>/dev/null; then
            echo '. "$HOME/.nix-profile/etc/profile.d/nix.sh"' >> ~/.bashrc
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
