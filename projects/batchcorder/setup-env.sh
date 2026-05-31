#!/usr/bin/env bash
# Project-specific in-container setup. Runs inside the container as user
# vscode, invoked by dev/devcontainer.
#
# Subcommands:
#   first-run        — initial dependency install + extension build + dev tooling
#   sync-if-needed   — re-sync deps if lockfiles are newer than the stamp
#
# batchcorder builds a Rust PyO3 extension into the venv with maturin. We sync
# Python deps (which includes maturin from the dev group), then `maturin develop`
# to compile and install the extension. Editing the *Rust source* still needs a
# manual `uv run maturin develop --uv` — sync-if-needed only rebuilds on lockfile
# changes, not arbitrary source edits.
set -euo pipefail

cmd="${1:-first-run}"

# rustup installs to ~/.cargo; put cargo/maturin on PATH for this script.
. "$HOME/.cargo/env" 2>/dev/null || true

case "$cmd" in
    first-run)
        echo "Installing Python dependencies..."
        uv sync --no-install-project --group dev
        touch .venv/.last-sync

        # Skip the (slow) extension build if a compiled module is already present.
        # `maturin develop` writes it into python/batchcorder/, which lives on the
        # bind-mounted workspace and so survives container recreation — a fresh
        # checkout has none and gets built. This is a pure file test on purpose:
        # an `import` probe via `uv run` would auto-build the project (defeating
        # the skip), and the abi3 wheel stays loadable across CPython minor
        # versions, so a persisted .so is safe after an image rebuild. Editing
        # Rust source still needs a manual `maturin develop` (or the `mdev` alias).
        if compgen -G "python/batchcorder/*.so" >/dev/null; then
            echo "Rust extension already built (python/batchcorder/*.so present) — skipping maturin develop."
        else
            echo "Building the Rust extension (maturin develop)..."
            uv run maturin develop --uv
        fi

        echo "Installing pre-commit hooks..."
        uv run pre-commit install 2>/dev/null || true

        _bashrc_marker="# batchcorder-setup"
        if ! grep -qF "$_bashrc_marker" ~/.bashrc 2>/dev/null; then
            cat >> ~/.bashrc <<BASH
$_bashrc_marker
. "\$HOME/.cargo/env"
export UV_NO_SYNC=1
# Rebuild the PyO3 extension after editing Rust source (sync-if-needed only
# rebuilds on uv.lock changes, not arbitrary src/*.rs edits).
alias mdev='uv run maturin develop --uv'
BASH
        fi
        ;;
    sync-if-needed)
        [ -f uv.lock ] || exit 0
        lock_mtime="$(stat -c %Y uv.lock)"
        stamp_mtime="$(stat -c %Y .venv/.last-sync 2>/dev/null || echo 0)"
        if [ "$lock_mtime" -gt "$stamp_mtime" ]; then
            uv sync --no-install-project --group dev
            uv run maturin develop --uv
            touch .venv/.last-sync
        fi
        ;;
    *)
        echo "usage: setup-env [first-run|sync-if-needed]" >&2
        exit 1
        ;;
esac
