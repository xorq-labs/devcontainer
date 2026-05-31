#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-first-run}"
case "$cmd" in
    first-run)
        # shellcheck source=../../lib/git.sh
        source /usr/local/lib/devcontainer/git.sh
        install_hooks

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
