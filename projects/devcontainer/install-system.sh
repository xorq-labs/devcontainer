#!/usr/bin/env bash
set -euo pipefail

# Docker CLI + compose plugin, and the apt repo they come from. The CLI drives
# the host daemon through the socket bridged in compose.override.yml
# (docker-outside-of-docker) — e.g. building/loading the Nix base image;
# before that bridge existed it was lint-only.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y --no-install-recommends \
    shellcheck \
    direnv \
    docker-ce-cli \
    docker-compose-plugin \
    xz-utils
rm -rf /var/lib/apt/lists/*

# Nix (single-user, seeded into the project-scoped `nix` volume on first run):
# needed to work on spike/nix-default — building the flake, filling its
# fixed-output hashes, and measuring the layer delta. xz-utils above is the
# installer's tarball dependency.
. /usr/local/lib/devcontainer/nix-seed.sh
nix_build_install

# hadolint, ruff, and yamllint versions below must be kept in sync with the
# matching hook pins in .pre-commit-config.yaml at the repo root. pre-commit
# itself is the runner (not a pinned hook there), so it has no counterpart.
# hadolint (Dockerfile linter)
HADOLINT_VERSION=2.14.0
HADOLINT_SHA256_AMD64=6bf226944684f56c84dd014e8b979d27425c0148f61b3bd99bcc6f39e9dc5a47
HADOLINT_SHA256_ARM64=331f1d3511b84a4f1e3d18d52fec284723e4019552f4f47b19322a53ce9a40ed
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
