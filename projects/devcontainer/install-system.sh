#!/usr/bin/env bash
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
    shellcheck \
    direnv

# hadolint (Dockerfile linter)
HADOLINT_VERSION=2.12.0
arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64) hadolint_arch=x86_64 ;;
    arm64) hadolint_arch=arm64 ;;
    *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${hadolint_arch}" \
    -o /usr/local/bin/hadolint
chmod +x /usr/local/bin/hadolint

# Docker CLI + compose plugin (linting only — no daemon, no socket)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y --no-install-recommends \
    docker-ce-cli \
    docker-compose-plugin

rm -rf /var/lib/apt/lists/*

# Python linters
pip install --no-cache-dir --break-system-packages ruff yamllint
