#!/usr/bin/env bash
# Project-specific system packages and toolchain. Runs as root during
# `docker build`, after the generic Dockerfile installs the infra layer.
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
    curl \
    xz-utils
rm -rf /var/lib/apt/lists/*

# Install Nix and bake a seed tarball. The seed is unpacked into a durable,
# project-scoped `nix` volume by setup-env first-run. Override NIX_VERSION /
# NIX_INSTALLER_SHA256 above the call to pin a different release.
. /usr/local/lib/devcontainer/nix-seed.sh
nix_build_install
