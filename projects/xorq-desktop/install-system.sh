#!/usr/bin/env bash
# Project-specific system packages and language toolchain.
# Runs as root during `docker build`, after the generic Dockerfile installs
# the infrastructure layer (Node + claude-code, gh, socat, just, sops).
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    direnv \
    libwebkit2gtk-4.1-dev \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev \
    libssl-dev \
    curl \
    wget \
    file \
    xz-utils \
    xauth
rm -rf /var/lib/apt/lists/*

# Nix (single-user for vscode, no daemon needed in containers).
# /nix is overlaid by a durable volume at runtime, so we tar the build-time
# install into a seed that setup-env unpacks on first run, then drop the
# live /nix tree (saves ~hundreds of MB in the final image — the tarball
# alone is enough; the volume mount provides an empty /nix at runtime).
# A sha256 of the seed is stamped into the image so setup-env can detect
# stale seeds in volumes that predate an image rebuild.
mkdir -p /nix && chown vscode:vscode /nix
su - vscode -c 'curl -L https://nixos.org/nix/install | sh -s -- --no-daemon'
tar cf /nix-seed.tar -C / nix
sha256sum /nix-seed.tar | cut -d' ' -f1 > /nix-seed.version
rm -rf /nix

# uv (Python package manager)
UV_VERSION=0.7.8
UV_INSTALLER_SHA256=3e3043ca08e1156fbe18d90a1a4def3ae795418857c8f4ed3f807ffc45e51c3d
curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" -o /tmp/uv-install.sh
echo "$UV_INSTALLER_SHA256  /tmp/uv-install.sh" | sha256sum -c -
env UV_INSTALL_DIR=/usr/local/bin sh /tmp/uv-install.sh
rm /tmp/uv-install.sh

# Rust (via rustup, installed for vscode user)
su - vscode -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'

# pnpm
npm install -g pnpm
