#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-first-run}"
case "$cmd" in
    first-run)
        if [ -f .pre-commit-config.yaml ]; then
            echo "Installing pre-commit hooks..."
            pip install --no-cache-dir --break-system-packages pre-commit
            pre-commit install 2>/dev/null || true
        fi

        if ! grep -q "direnv hook bash" ~/.bashrc 2>/dev/null; then
            echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
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
        ;;
    *) echo "usage: setup-env [first-run|sync-if-needed]" >&2; exit 1 ;;
esac
