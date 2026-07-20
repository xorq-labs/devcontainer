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

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

# The harness has no regex asserter; keep a thin one wired to its counters.
assert_match() {
    local label="$1" regex="$2" value="$3"
    if [[ "$value" =~ $regex ]]; then
        _pass "$label"
    else
        _fail "$label" "expected to match: $regex" "actual:            $value"
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
assert_true "the tail Dockerfile exists at that path" \
    test -f "$DEV_BASE/$dockerfile"

# config_files() hashes the lock for local-build staleness; it must exist.
assert_true "flake.lock exists (hashed by config_files)" \
    test -f "$DEV_BASE/nix/base/flake.lock"

finish
