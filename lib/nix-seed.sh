#!/usr/bin/env bash
# Shared Nix seed helpers for project overlays that want a build-time-installed,
# runtime-volume-backed Nix store.
#
# Design: /nix is populated during `docker build`, tarred into an image-baked
# seed, and the live tree dropped (keeps the image small). At first run the seed
# is unpacked into the durable, project-scoped `nix` volume. A checksum stamp of
# the seed lets a newer image overlay fresh store paths onto an older volume.
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
# sha256 of the seed tarball (a checksum, not a Nix version); compared against
# the volume's stamp on first run to decide whether to overlay fresh paths.
NIX_SEED_SHA_FILE="${NIX_SEED_SHA_FILE:-/nix-seed.sha256}"
# Root the seed unpacks into; empty means "/" (the container root). Overridable
# so the seed logic can be exercised against a scratch dir in tests.
NIX_SEED_ROOT="${NIX_SEED_ROOT:-}"

# build time (root, during docker build): single-user install, tar a seed,
# stamp its sha, and drop the live /nix tree.
nix_build_install() {
    curl -LsSf "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" -o /tmp/nix-install.sh
    echo "${NIX_INSTALLER_SHA256}  /tmp/nix-install.sh" | sha256sum -c -
    mkdir -p /nix && chown vscode:vscode /nix
    su - vscode -c 'sh /tmp/nix-install.sh --no-daemon'
    rm /tmp/nix-install.sh
    tar cf "$NIX_SEED_TAR" -C / nix
    sha256sum "$NIX_SEED_TAR" | cut -d' ' -f1 > "$NIX_SEED_SHA_FILE"
    rm -rf /nix
}

# Merge the host's read-only nix.conf into the container's, stripping any
# `sandbox` setting (the container *is* the sandbox) and forcing it off. Other
# host config files (registry.json, etc.) are symlinked through. No-op if the
# container already has a nix.conf. Operates purely on $HOME, so it is unit-testable.
nix_write_conf() {
    local host="$HOME/.config/nix-host" conf="$HOME/.config/nix"
    [ -f "$conf/nix.conf" ] && return 0
    mkdir -p "$conf"
    if [ -f "$host/nix.conf" ]; then
        # Match only the `sandbox` key (allowing nix.conf's leading indent),
        # not sibling keys like `sandbox-paths`. `|| true`: grep exits 1 when
        # every line is filtered out, which would trip `set -e` — we append the
        # sandbox lines anyway.
        grep -vE '^[[:space:]]*sandbox[[:space:]]*=' "$host/nix.conf" > "$conf/nix.conf" || true
    fi
    printf 'sandbox = false\nfilter-syscalls = false\n' >> "$conf/nix.conf"
    [ -d "$host" ] || return 0
    for f in "$host"/*; do
        [ -e "$f" ] || continue
        [ "$(basename "$f")" = "nix.conf" ] && continue
        ln -sf "$f" "$conf/$(basename "$f")"
    done
}

# runtime (vscode, first-run): unpack the seed into the durable volume, restore
# the profile symlink, merge host nix.conf (sandbox off — the container is the
# sandbox), then source the profile.
nix_seed_volume() {
    local nix="${NIX_SEED_ROOT}/nix"
    if [ ! -d "$nix/store" ]; then
        echo "Seeding Nix store into volume..."
        tar xf "$NIX_SEED_TAR" -C "${NIX_SEED_ROOT:-/}"
        # Stamp only after extraction: a partial `tar xf` aborts here under
        # `set -e` before the stamp lands, so the next run re-overlays it.
        cp "$NIX_SEED_SHA_FILE" "$nix/.seed-sha256"
    elif [ ! -f "$nix/.seed-sha256" ] || ! cmp -s "$NIX_SEED_SHA_FILE" "$nix/.seed-sha256"; then
        echo "Nix seed differs from volume — overlaying new paths..."
        tar xf "$NIX_SEED_TAR" --skip-old-files -C "${NIX_SEED_ROOT:-/}"
        cp "$NIX_SEED_SHA_FILE" "$nix/.seed-sha256"
    fi
    if [ ! -e "$HOME/.nix-profile" ]; then
        ln -sf "$nix/var/nix/profiles/per-user/$(id -un)/profile" "$HOME/.nix-profile"
    fi
    nix_write_conf
    # Guard: the profile may be absent if seeding failed; sourcing a missing
    # file would abort first-run under `set -e`.
    if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    fi
}
