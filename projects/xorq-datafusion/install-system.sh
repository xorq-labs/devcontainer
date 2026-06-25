#!/usr/bin/env bash
# Project-specific system packages and language toolchain.
# Runs as root during `docker build`, after the generic Dockerfile installs
# the infrastructure layer (Node + claude-code, gh, socat, just, sops).
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    patchelf \
    direnv
rm -rf /var/lib/apt/lists/*

# uv (Python package manager)
UV_VERSION=0.7.8
UV_INSTALLER_SHA256=3e3043ca08e1156fbe18d90a1a4def3ae795418857c8f4ed3f807ffc45e51c3d
curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" -o /tmp/uv-install.sh
echo "$UV_INSTALLER_SHA256  /tmp/uv-install.sh" | sha256sum -c -
env UV_INSTALL_DIR=/usr/local/bin sh /tmp/uv-install.sh
rm /tmp/uv-install.sh

# Rust (via rustup, installed for vscode user)
RUSTUP_VERSION=1.28.1
RUSTUP_SHA256_AMD64=a3339fb004c3d0bb9862ba0bce001861fe5cbde9c10d16591eb3f39ee6cd3e7f
RUSTUP_SHA256_ARM64=c64b33db2c6b9385817ec0e49a84bcfe018ed6e328fe755c3c809580cc70ce7a
arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64) rustup_target=x86_64-unknown-linux-gnu;  rustup_sha=$RUSTUP_SHA256_AMD64 ;;
    arm64) rustup_target=aarch64-unknown-linux-gnu;  rustup_sha=$RUSTUP_SHA256_ARM64 ;;
    *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
curl -sSf "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_target}/rustup-init" \
    -o /tmp/rustup-init
echo "$rustup_sha  /tmp/rustup-init" | sha256sum -c -
chmod +x /tmp/rustup-init
su - vscode -c '/tmp/rustup-init -y --default-toolchain stable'
rm /tmp/rustup-init
