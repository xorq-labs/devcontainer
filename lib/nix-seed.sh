#!/usr/bin/env bash
# Shared Nix seed helpers for project overlays that want a build-time-installed,
# runtime-volume-backed Nix store.
#
# Design: /nix is populated during `docker build`, tarred into an image-baked
# seed, and the live tree dropped (keeps the image small). At first run the seed
# is unpacked into the durable, project-scoped `nix` volume. A version stamp lets
# a newer image overlay fresh store paths onto an older volume.
#
# Sourced from two phases:
#   - an overlay's install-system.sh (build time, as root) -> nix_build_install
#   - an overlay's setup-env.sh first-run (runtime, as vscode) -> nix_seed_volume
#
# Version/sha and seed paths are env-var defaults: an overlay overrides them by
# setting the variable before sourcing/calling. version+sha stay coupled on
# purpose — `sha256sum -c` fails loudly if a version is bumped without its
# matching checksum.
NIX_VERSION="${NIX_VERSION:-2.28.3}"
NIX_INSTALLER_SHA256="${NIX_INSTALLER_SHA256:-46b8d7165dceb471f4346366b3a93f1009407b99729b843b8664918f4cc800a0}"
NIX_SEED_TAR="${NIX_SEED_TAR:-/nix-seed.tar}"
NIX_SEED_VERSION_FILE="${NIX_SEED_VERSION_FILE:-/nix-seed.version}"

# build time (root, during docker build): single-user install, tar a seed,
# stamp its sha, and drop the live /nix tree.
nix_build_install() {
    curl -LsSf "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" -o /tmp/nix-install.sh
    echo "${NIX_INSTALLER_SHA256}  /tmp/nix-install.sh" | sha256sum -c -
    mkdir -p /nix && chown vscode:vscode /nix
    su - vscode -c 'sh /tmp/nix-install.sh --no-daemon'
    rm /tmp/nix-install.sh
    tar cf "$NIX_SEED_TAR" -C / nix
    sha256sum "$NIX_SEED_TAR" | cut -d' ' -f1 > "$NIX_SEED_VERSION_FILE"
    rm -rf /nix
}

# runtime (vscode, first-run): unpack the seed into the durable volume, restore
# the profile symlink, merge host nix.conf (sandbox off — the container is the
# sandbox), then source the profile.
nix_seed_volume() {
    if [ ! -d /nix/store ]; then
        echo "Seeding Nix store into volume..."
        tar xf "$NIX_SEED_TAR" -C /
        cp "$NIX_SEED_VERSION_FILE" /nix/.seed-version
    elif [ ! -f /nix/.seed-version ] || ! cmp -s "$NIX_SEED_VERSION_FILE" /nix/.seed-version; then
        echo "Nix seed differs from volume — overlaying new paths..."
        tar xf "$NIX_SEED_TAR" --skip-old-files -C /
        cp "$NIX_SEED_VERSION_FILE" /nix/.seed-version
    fi
    if [ ! -e "$HOME/.nix-profile" ]; then
        ln -sf "/nix/var/nix/profiles/per-user/$(id -un)/profile" "$HOME/.nix-profile"
    fi
    if [ ! -f "$HOME/.config/nix/nix.conf" ]; then
        mkdir -p "$HOME/.config/nix"
        if [ -f "$HOME/.config/nix-host/nix.conf" ]; then
            grep -v '^sandbox' "$HOME/.config/nix-host/nix.conf" > "$HOME/.config/nix/nix.conf"
        fi
        printf 'sandbox = false\nfilter-syscalls = false\n' >> "$HOME/.config/nix/nix.conf"
        if [ -d "$HOME/.config/nix-host" ]; then
            for f in "$HOME/.config/nix-host"/*; do
                [ -e "$f" ] || continue
                [ "$(basename "$f")" = "nix.conf" ] && continue
                ln -sf "$f" "$HOME/.config/nix/$(basename "$f")"
            done
        fi
    fi
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
}
