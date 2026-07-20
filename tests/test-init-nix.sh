#!/usr/bin/env bash
# Tests for the Nix overlay support:
#   - `devcontainer init --nix` layers the fragment over defaults (file copy).
#   - lib/nix-seed.sh seed/overlay/stamp logic and the host nix.conf merge,
#     exercised against scratch dirs via NIX_SEED_ROOT / HOME overrides.
# Runs against disposable dirs in /tmp — no docker required.
set -euo pipefail

PASS=0 FAIL=0
_cleanup_dirs=()

cleanup() {
    for d in "${_cleanup_dirs[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected to contain: $needle"
        echo "    got: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected NOT to contain: $needle"
        echo "    got: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_files_eq() {
    local label="$1" a="$2" b="$3"
    if cmp -s "$a" "$b"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    files differ: $a vs $b"
        FAIL=$((FAIL + 1))
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
INIT="$DEV_BASE/dev/init"
NIX_FRAG="$DEV_BASE/templates/nix"
NIX_SEED="$DEV_BASE/lib/nix-seed.sh"
DEFAULTS="$DEV_BASE/defaults"

# Source the seed helpers once; the subshells below inherit the functions and
# override HOME / NIX_SEED_* per scenario (all read at call time).
# shellcheck disable=SC1090  # NIX_SEED is a runtime-computed path
. "$NIX_SEED"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# --- helper: fresh disposable repo + local overlay target ---
new_repo() {
    local dir="$TMPDIR_ROOT/$1"
    mkdir -p "$dir"
    git -C "$dir" init -b main --quiet
    git -C "$dir" commit --allow-empty -m "init" --quiet
    echo "$dir"
}

# ============================================================
# init --nix (file-copy behavior)
# ============================================================

# ---------- test: init --local --nix layers the fragment ----------
echo "--- init --local --nix ---"
REPO="$(new_repo nixrepo)"
out="$(cd "$REPO" && "$INIT" --local --nix 2>&1)"
overlay="$REPO/.devcontainer"

assert_contains "announces nix fragment" "Applying --nix fragment:" "$out"
assert_contains "message uses DEV_PROJECT_NAME" "\${DEV_PROJECT_NAME}-nix" "$out"

# The four nix-touched files must be byte-identical to templates/nix.
for f in install-system.sh setup-env.sh compose.override.yml external-volumes.txt; do
    assert_files_eq "nix overwrote $f" "$overlay/$f" "$NIX_FRAG/$f"
done

# The invariant tail must still come from defaults, untouched by the fragment.
for f in devcontainer.json host-mounts.txt worktree-symlinks.txt worktree-copies.txt audit-prefixes.txt; do
    assert_files_eq "tail $f from defaults" "$overlay/$f" "$DEFAULTS/$f"
done

# external-volumes.txt declares the nix volume on its own line (not merely a
# substring of a comment).
assert_eq "external-volumes has a bare 'nix' line" "true" \
    "$(grep -Eq '^nix$' "$overlay/external-volumes.txt" && echo true || echo false)"

# The compose EXTRA_PATH points at NIX_USER's profile, but compose can't read the
# bash var — they're hand-synced. Fail loudly here if they drift.
extra_path_line="$(grep -E 'EXTRA_PATH:' "$NIX_FRAG/compose.override.yml")"
assert_contains "EXTRA_PATH matches NIX_USER's home" "/home/$NIX_USER/.nix-profile" "$extra_path_line"

# ---------- test: init --local (no --nix) leaves defaults in place ----------
echo "--- init --local (no --nix) ---"
REPO2="$(new_repo plainrepo)"
out2="$(cd "$REPO2" && "$INIT" --local 2>&1)"
overlay2="$REPO2/.devcontainer"

assert_eq "no nix fragment applied" "false" "$([[ "$out2" == *"Applying --nix fragment:"* ]] && echo true || echo false)"
assert_files_eq "install-system.sh stays defaults" "$overlay2/install-system.sh" "$DEFAULTS/install-system.sh"

# ============================================================
# lib/nix-seed.sh :: nix_write_conf (host nix.conf merge)
# ============================================================

# ---------- test: no host config -> minimal sandbox-off conf ----------
echo "--- nix_write_conf (no host config) ---"
H="$TMPDIR_ROOT/confA"
mkdir -p "$H"
( export HOME="$H"; nix_write_conf )
confA="$(cat "$H/.config/nix/nix.conf")"
assert_contains "sandbox forced off" "sandbox = false" "$confA"
assert_contains "filter-syscalls off" "filter-syscalls = false" "$confA"

# ---------- test: host config merged, sandbox stripped, siblings kept ----------
echo "--- nix_write_conf (host config merge) ---"
H="$TMPDIR_ROOT/confB"
mkdir -p "$H/.config/nix-host"
# Include an indented sandbox line (nix.conf allows leading whitespace) to prove
# the strip anchors past the indent.
printf 'max-jobs = 4\nsandbox = true\n  sandbox = relaxed\nsandbox-paths = /opt/foo\n' > "$H/.config/nix-host/nix.conf"
printf '{}\n' > "$H/.config/nix-host/registry.json"
( export HOME="$H"; nix_write_conf )
confB="$(cat "$H/.config/nix/nix.conf")"
assert_contains "unrelated host key preserved" "max-jobs = 4" "$confB"
assert_not_contains "host 'sandbox = true' stripped" "sandbox = true" "$confB"
assert_not_contains "indented host 'sandbox' stripped" "sandbox = relaxed" "$confB"
assert_contains "sandbox forced off" "sandbox = false" "$confB"
# The stripping targets the exact `sandbox` key, not sibling keys.
assert_contains "sandbox-paths NOT stripped" "sandbox-paths = /opt/foo" "$confB"
assert_eq "sibling host file symlinked through" "true" \
    "$([ -L "$H/.config/nix/registry.json" ] && echo true || echo false)"

# ---------- test: host config with ONLY a sandbox line (grep -v empties it) ----------
# Regression: grep -v exits 1 when it filters every line, which would abort the
# function under `set -e` without the `|| true` guard.
echo "--- nix_write_conf (host config is only 'sandbox') ---"
H="$TMPDIR_ROOT/confC"
mkdir -p "$H/.config/nix-host"
printf 'sandbox = true\n' > "$H/.config/nix-host/nix.conf"
if ( export HOME="$H"; nix_write_conf ); then okC=true; else okC=false; fi
assert_eq "does not abort when grep empties the file" "true" "$okC"
assert_contains "sandbox forced off" "sandbox = false" "$(cat "$H/.config/nix/nix.conf")"

# ---------- test: existing container nix.conf is not overwritten ----------
echo "--- nix_write_conf (idempotent, existing conf) ---"
H="$TMPDIR_ROOT/confD"
mkdir -p "$H/.config/nix"
printf 'PRESERVE_ME\n' > "$H/.config/nix/nix.conf"
( export HOME="$H"; nix_write_conf )
confD="$(cat "$H/.config/nix/nix.conf")"
assert_contains "existing conf preserved" "PRESERVE_ME" "$confD"
assert_not_contains "not re-merged" "sandbox = false" "$confD"

# ============================================================
# lib/nix-seed.sh :: nix_seed_volume (seed / overlay / stamp)
# ============================================================

USER_NAME="$(id -un)"

# Build a fake seed tarball: a /nix tree with a store marker and a profile whose
# nix.sh touches a marker file when sourced (proves the profile source path).
make_seed() {
    local src="$1" prof
    prof="$src/nix/var/nix/profiles/per-user/$USER_NAME/profile/etc/profile.d"
    mkdir -p "$src/nix/store" "$prof"
    : > "$src/nix/store/.keep"
    printf ': > "$NIX_TEST_SOURCED"\n' > "$prof/nix.sh"
}

SEED_SRC="$TMPDIR_ROOT/seedsrc"
make_seed "$SEED_SRC"
SEED_TAR="$TMPDIR_ROOT/seed.tar"
tar cf "$SEED_TAR" -C "$SEED_SRC" nix
SEED_SHA="$TMPDIR_ROOT/seed.sha256"
echo "checksum-v1" > "$SEED_SHA"

ROOT="$TMPDIR_ROOT/seedroot"
HOMES="$TMPDIR_ROOT/seedhome"
MARKER="$TMPDIR_ROOT/sourced.marker"
mkdir -p "$ROOT" "$HOMES"

run_seed() {
    (
        export HOME="$HOMES"
        export NIX_SEED_ROOT="$ROOT"
        export NIX_SEED_TAR="$SEED_TAR"
        export NIX_SEED_SHA_FILE="$SEED_SHA"
        export NIX_USER="$USER_NAME"
        export NIX_TEST_SOURCED="$MARKER"
        nix_seed_volume
    )
}

# ---------- test: first run seeds the volume ----------
echo "--- nix_seed_volume (first run) ---"
out_seed1="$(run_seed)"
assert_contains "announces seeding" "Seeding Nix store into volume" "$out_seed1"
assert_eq "store extracted under NIX_SEED_ROOT" "true" "$([ -d "$ROOT/nix/store" ] && echo true || echo false)"
assert_files_eq "stamp copied from seed sha" "$ROOT/nix/.seed-sha256" "$SEED_SHA"
assert_eq "profile symlink created" "true" "$([ -L "$HOMES/.nix-profile" ] && echo true || echo false)"
assert_contains "symlink targets NIX_USER's per-user profile" "per-user/$USER_NAME/profile" "$(readlink "$HOMES/.nix-profile")"
assert_eq "profile nix.sh was sourced" "true" "$([ -f "$MARKER" ] && echo true || echo false)"
assert_contains "nix.conf written" "sandbox = false" "$(cat "$HOMES/.config/nix/nix.conf")"

# ---------- test: second run with matching stamp is a no-op ----------
echo "--- nix_seed_volume (idempotent, matching stamp) ---"
out_seed2="$(run_seed)"
assert_not_contains "does not re-seed" "Seeding Nix store" "$out_seed2"
assert_not_contains "does not overlay" "overlaying new paths" "$out_seed2"

# ---------- test: changed stamp overlays new paths ----------
echo "--- nix_seed_volume (stamp changed -> overlay) ---"
echo "checksum-v2" > "$SEED_SHA"
out_seed3="$(run_seed)"
assert_contains "announces overlay" "overlaying new paths" "$out_seed3"
assert_files_eq "stamp updated to new sha" "$ROOT/nix/.seed-sha256" "$SEED_SHA"

# ---------- test: missing profile does not abort first-run ----------
# The seed has a store but no profile nix.sh; the source must be guarded.
echo "--- nix_seed_volume (missing profile, guarded source) ---"
SEED_SRC2="$TMPDIR_ROOT/seedsrc-noprofile"
mkdir -p "$SEED_SRC2/nix/store"
: > "$SEED_SRC2/nix/store/.keep"
SEED_TAR2="$TMPDIR_ROOT/seed-noprofile.tar"
tar cf "$SEED_TAR2" -C "$SEED_SRC2" nix
ROOT2="$TMPDIR_ROOT/seedroot2"
HOMES2="$TMPDIR_ROOT/seedhome2"
MARKER2="$TMPDIR_ROOT/sourced2.marker"
mkdir -p "$ROOT2" "$HOMES2"
if (
    export HOME="$HOMES2"
    export NIX_SEED_ROOT="$ROOT2"
    export NIX_SEED_TAR="$SEED_TAR2"
    export NIX_SEED_SHA_FILE="$SEED_SHA"
    export NIX_USER="$USER_NAME"
    export NIX_TEST_SOURCED="$MARKER2"
    nix_seed_volume
) >/dev/null; then okG=true; else okG=false; fi
assert_eq "first-run survives a missing profile" "true" "$okG"
assert_eq "profile source skipped (no marker)" "false" "$([ -f "$MARKER2" ] && echo true || echo false)"

# ============================================================
# lib/nix-seed.sh :: Nix-base coexistence (base already ships /nix)
# ============================================================

# ---------- test: nix_build_install skips when the base provides /nix ----------
# Building Dockerfile.nix-default on the streamLayeredImage Nix base
# means /nix/store is already baked in (root-owned). The build-time installer,
# run as $NIX_USER, would hit "Permission denied" — so it must skip instead.
echo "--- nix_build_install (base already provides /nix -> skip) ---"
PREPOP="$TMPDIR_ROOT/prepop"
mkdir -p "$PREPOP/nix/store"
: > "$PREPOP/nix/store/.keep"
if out_bi="$( export NIX_SEED_ROOT="$PREPOP"; nix_build_install 2>&1 )"; then okBI=true; else okBI=false; fi
assert_eq "returns success (no install attempted)" "true" "$okBI"
assert_contains "announces skip" "already populated by the base image" "$out_bi"

# ---------- test: nix_seed_volume no-ops at runtime with no seed tar ----------
# The build-time skip produces no seed tarball; first-run must not abort trying to
# unpack a missing tar — it falls through to profile/conf setup off the baked store.
echo "--- nix_seed_volume (no seed tar -> base provides /nix) ---"
ROOT3="$TMPDIR_ROOT/seedroot3"
HOMES3="$TMPDIR_ROOT/seedhome3"
mkdir -p "$ROOT3/nix/store" "$HOMES3"
: > "$ROOT3/nix/store/.keep"
if out_ns="$(
    export HOME="$HOMES3"
    export NIX_SEED_ROOT="$ROOT3"
    export NIX_SEED_TAR="$TMPDIR_ROOT/does-not-exist.tar"
    export NIX_SEED_SHA_FILE="$SEED_SHA"
    export NIX_USER="$USER_NAME"
    nix_seed_volume 2>&1
)"; then okNS=true; else okNS=false; fi
assert_eq "survives with no seed tar" "true" "$okNS"
assert_contains "announces base-provided nix" "assuming the base image provides /nix" "$out_ns"
assert_not_contains "does not seed the volume" "Seeding Nix store" "$out_ns"
assert_contains "still writes nix.conf" "sandbox = false" "$(cat "$HOMES3/.config/nix/nix.conf")"

# ---------- summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
