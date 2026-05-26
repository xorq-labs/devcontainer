#!/usr/bin/env bash
set -euo pipefail

# Docker apt repo (linting only — no daemon, no socket)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y --no-install-recommends \
    shellcheck \
    direnv \
    docker-ce-cli \
    docker-compose-plugin
rm -rf /var/lib/apt/lists/*

# hadolint (Dockerfile linter)
HADOLINT_VERSION=2.12.0
HADOLINT_SHA256_AMD64=56de6d5e5ec427e17b74fa48d51271c7fc0d61244bf5c90e828aab8362d55010
HADOLINT_SHA256_ARM64=5798551bf19f33951881f15eb238f90aef023f11e7ec7e9f4c37961cb87c5df6
arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64) hadolint_arch=x86_64; hadolint_sha=$HADOLINT_SHA256_AMD64 ;;
    arm64) hadolint_arch=arm64;  hadolint_sha=$HADOLINT_SHA256_ARM64 ;;
    *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${hadolint_arch}" \
    -o /usr/local/bin/hadolint
echo "$hadolint_sha  /usr/local/bin/hadolint" | sha256sum -c -
chmod +x /usr/local/bin/hadolint

# Python linters (pip ships in the base image)
RUFF_VERSION=0.15.14
YAMLLINT_VERSION=1.38.0
PRE_COMMIT_VERSION=4.6.0
pip install --no-cache-dir --break-system-packages \
    "ruff==${RUFF_VERSION}" \
    "yamllint==${YAMLLINT_VERSION}" \
    "pre-commit==${PRE_COMMIT_VERSION}"
