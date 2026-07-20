#!/usr/bin/env bash
set -euo pipefail

# Docker CLI + compose plugin, and the apt repo they come from. The CLI drives
# the host daemon through the socket bridged in compose.override.yml
# (docker-outside-of-docker) — e.g. building/loading the nix-default spike;
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

# Nix: single-user install baked into a seed tarball at build time, unpacked
# into a durable, project-scoped `nix` volume by setup-env first-run. This is
# the spike branch dogfooding its own nix-default design — it lets us build
# spike/nix-default from inside the container. Override NIX_VERSION /
# NIX_INSTALLER_SHA256 (see lib/nix-seed.sh) before the call to pin a release.
. /usr/local/lib/devcontainer/nix-seed.sh
nix_build_install
