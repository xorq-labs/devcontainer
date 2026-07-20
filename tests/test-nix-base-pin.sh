#!/usr/bin/env bash
# Guard: the committed Nix-base pin plumbing holds together.
#
# ensure_nix_base() in dev/devcontainer extracts the pinned BASE_IMAGE default
# out of nix/base/compose.nix-base.yml with a grep anchored on the compose
# interpolation. A reformat of that line (like the pin-file reformat
# tests/test-bump-claude-code.sh guards against) would break the pull path at
# runtime with no build-time signal — so assert the anchor matches the real
# file, the extracted ref is a digest-pinned ghcr image, and the compose
# file's dockerfile path exists. Keep the grep pattern here byte-identical to
# the one in dev/devcontainer.
set -euo pipefail

PASS=0 FAIL=0

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

assert_match() {
    local label="$1" regex="$2" value="$3"
    if [[ "$value" =~ $regex ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected to match: $regex"
        echo "    actual:            $value"
        FAIL=$((FAIL + 1))
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
nixcompose="$DEV_BASE/nix/base/compose.nix-base.yml"

echo "--- nix-base pin plumbing (committed files) ---"

[ -f "$nixcompose" ] || { echo "  FAIL: $nixcompose not found"; exit 1; }

# Same anchor as ensure_nix_base() — keep in sync by hand.
ref="$(grep -oP '\$\{DEV_NIX_BASE_IMAGE:-\K[^}]+' "$nixcompose" || true)"

assert_match "BASE_IMAGE default extracted by the ensure_nix_base anchor" \
    '^.+$' "$ref"
assert_match "pin is a digest-pinned ghcr image" \
    '^ghcr\.io/[a-z0-9./-]+@sha256:[0-9a-f]{64}$' "$ref"
assert_eq "exactly one interpolation in the compose file" \
    "1" "$(grep -cF '${DEV_NIX_BASE_IMAGE:-' "$nixcompose")"

dockerfile="$(grep -oP '^\s*dockerfile:\s*\K\S+' "$nixcompose" || true)"
assert_eq "compose points at the nix-base tail Dockerfile" \
    "nix/base/Dockerfile.nix-default" "$dockerfile"
assert_eq "the tail Dockerfile exists at that path" \
    "true" "$([ -f "$DEV_BASE/$dockerfile" ] && echo true || echo false)"

# config_files() hashes the lock for local-build staleness; it must exist.
assert_eq "flake.lock exists (hashed by config_files)" \
    "true" "$([ -f "$DEV_BASE/nix/base/flake.lock" ] && echo true || echo false)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
