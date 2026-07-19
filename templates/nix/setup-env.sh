#!/usr/bin/env bash
# Project-specific in-container setup. Runs as vscode, invoked by
# dev/devcontainer.
#
# Subcommands:
#   first-run       — initial setup after build (seed the Nix volume)
#   sync-if-needed  — re-sync deps if lockfiles are newer than stamps
set -euo pipefail

cmd="${1:-first-run}"

case "$cmd" in
    first-run)
        . /usr/local/lib/devcontainer/nix-seed.sh
        nix_seed_volume
        # Add project dependency installation below (e.g. uv sync, pnpm install).
        ;;
    sync-if-needed)
        # Add idempotent re-sync of dependencies here.
        ;;
    *)
        echo "usage: setup-env [first-run|sync-if-needed]" >&2
        exit 1
        ;;
esac
