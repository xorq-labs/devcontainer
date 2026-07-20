#!/usr/bin/env bash
# Guard: the two committed Claude Code version pins must agree.
#
# `dev/bump-claude-code` keeps them in sync when run, and tests/test-bump-claude-code.sh
# exercises that tool in a sandbox. But nothing asserted the *real* committed
# files match right now — a hand edit to one pin that skips the bump tool would
# ship drift undetected. This test asserts the invariant directly on the tree:
#
#   Dockerfile:                       ARG CLAUDE_CODE_VERSION=<v>
#   spike/nix-default/pkgs/claude-code.nix:   version = "<v>";
#
# Anchors mirror the grep/sed anchors in dev/bump-claude-code, so a reformat that
# would break the tool's sync fails loudly here too (empty match -> fail).
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

assert_nonempty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (empty — anchor missed? file moved?)"
        FAIL=$((FAIL + 1))
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
dockerfile="$DEV_BASE/Dockerfile"
nix_pin="$DEV_BASE/spike/nix-default/pkgs/claude-code.nix"

echo "--- claude-code pin sync (committed files) ---"

[ -f "$dockerfile" ] || { echo "  FAIL: Dockerfile not found at $dockerfile"; exit 1; }
[ -f "$nix_pin" ] || { echo "  FAIL: Nix pin not found at $nix_pin"; exit 1; }

docker_version="$(grep -m1 -oP '^ARG CLAUDE_CODE_VERSION=\K.*' "$dockerfile" || true)"
nix_version="$(grep -m1 -oP '^\s*version = "\K[^"]*' "$nix_pin" || true)"

assert_nonempty "Dockerfile ARG CLAUDE_CODE_VERSION found" "$docker_version"
assert_nonempty "Nix pin version found" "$nix_version"
assert_eq "Dockerfile and Nix pin agree" "$docker_version" "$nix_version"

echo ""
echo "Dockerfile: $docker_version    Nix pin: $nix_version"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
