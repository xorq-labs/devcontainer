#!/usr/bin/env bash
# Tests for `devcontainer init --nix`: verifies the nix fragment overwrites only
# the four Nix-touched files while the invariant tail still comes from defaults.
# Runs against a disposable git repo in /tmp — no docker required.
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
DEFAULTS="$DEV_BASE/defaults"

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

# external-volumes.txt declares the nix volume.
assert_contains "external-volumes declares nix" "nix" "$(cat "$overlay/external-volumes.txt")"

# ---------- test: init --local (no --nix) leaves defaults in place ----------
echo "--- init --local (no --nix) ---"
REPO2="$(new_repo plainrepo)"
out2="$(cd "$REPO2" && "$INIT" --local 2>&1)"
overlay2="$REPO2/.devcontainer"

assert_eq "no nix fragment applied" "false" "$([[ "$out2" == *"Applying --nix fragment:"* ]] && echo true || echo false)"
assert_files_eq "install-system.sh stays defaults" "$overlay2/install-system.sh" "$DEFAULTS/install-system.sh"

# ---------- summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
