#!/usr/bin/env bash
# Project-specific system packages and toolchain. Runs as root during
# `docker build`, after the generic Dockerfile installs the infra layer.
set -euo pipefail

# Install Nix and bake a seed tarball. The seed is unpacked into a durable,
# project-scoped `nix` volume by setup-env first-run. Override NIX_VERSION /
# NIX_INSTALLER_SHA256 above the call to pin a different release.
# curl + xz (which nix_build_install uses to fetch and unpack the installer) are
# already present in the MS devcontainer base this runs on — no apt step needed.
# On a pre-baked Nix base, nix_build_install detects the populated /nix/store and
# skips entirely (see lib/nix-seed.sh).
. /usr/local/lib/devcontainer/nix-seed.sh
nix_build_install
