#!/usr/bin/env bash
# Guard: the committed Nix-base pin plumbing holds together.
#
# ensure_nix_base() in dev/devcontainer extracts the pinned BASE_IMAGE default
# out of nix/base/compose.nix-base.yml with a grep anchored on the compose
# interpolation. A reformat of that line (like the pin-file reformat
# tests/test-bump-claude-code.sh guards against) would break the pull path at
# runtime with no build-time signal.
#
# The anchor has four encodings: ensure_nix_base()'s grep, dev/bump-nix-base's
# grep, dev/bump-nix-base's sed rewrite, and this suite. Until #95 this suite
# RESTATED the grep ("keep it byte-identical by hand") and therefore checked
# only the compose-file side: changing ensure_nix_base()'s pattern broke the
# runtime pull path while every suite stayed green — one-directional, and the
# proven fail-open of the ADR-0005 baseline (§4-A).
#
# Each production anchor is now EXTRACTED from its own source and EXECUTED
# against the real compose file, so both sides are read and neither is
# restated. Drift in either direction goes red.
#
# Verified (ADR-0005 §2), two mutations, both green before this change:
#   1. §4-A's mutation — ensure_nix_base()'s grep changed from
#      `DEV_NIX_BASE_IMAGE:-` to `DEV_NIX_BASE_IMG:-`, breaking only the
#      runtime pull path — now fails 5 assertions starting with
#      "ensure_nix_base()'s grep pattern extracted from dev/devcontainer".
#   2. dev/bump-nix-base's sed anchor drifted the same way, grep left intact —
#      now fails "the sed dev/bump-nix-base runs rewrites the digest in place"
#      (the rewrite silently no-ops, leaving the old digest).
#   (mutation runs 2026-08-03)
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
devcontainer="$DEV_BASE/dev/devcontainer"
bump="$DEV_BASE/dev/bump-nix-base"

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

echo "--- nix-base pin plumbing (committed files) ---"

for f in "$nixcompose" "$devcontainer" "$bump"; do
    [ -f "$f" ] || { echo "  FAIL: $f not found"; exit 1; }
done

# The `grep -oP '<pattern>'` a script actually runs against the pin file. Only
# lines naming the interpolated var qualify, so unrelated greps can't be picked
# up by position. `|| true` so a no-match yields the empty string and the
# assertion below REPORTS it — without it, pipefail aborts the suite with a
# nonzero exit and no diagnostic, which is red but useless.
anchor_from() {
    grep -F 'DEV_NIX_BASE_IMAGE' "$1" | grep -oP "grep -oP '\K[^']+" | head -1 || true
}

dc_anchor="$(anchor_from "$devcontainer")"
bump_anchor="$(anchor_from "$bump")"
assert_nonempty "ensure_nix_base()'s grep pattern extracted from dev/devcontainer" "$dc_anchor"
assert_nonempty "dev/bump-nix-base's grep pattern extracted" "$bump_anchor"

# Execute the pattern dev/devcontainer really runs. This is the direction #95
# was missing: if that grep drifts off the pin line, this yields nothing.
ref="$(grep -oP "$dc_anchor" "$nixcompose" || true)"
bump_ref="$(grep -oP "$bump_anchor" "$nixcompose" || true)"

assert_match "the grep dev/devcontainer executes finds the pin" '^.+$' "$ref"
assert_eq "dev/bump-nix-base reads the same value as dev/devcontainer" "$ref" "$bump_ref"
assert_match "pin is a digest-pinned ghcr image" \
    '^ghcr\.io/[a-z0-9./-]+@sha256:[0-9a-f]{64}$' "$ref"
assert_eq "exactly one interpolation in the compose file" \
    "1" "$(grep -cF '${DEV_NIX_BASE_IMAGE:-' "$nixcompose")"

# The fourth encoding: bump-nix-base's sed rewrite. Extract the expression it
# runs, point it at a known digest, and require it to actually move the pin —
# a sed anchored on a stale line format silently rewrites nothing.
sed_expr="$(grep -oP '^sed -i "\K[^"]+' "$bump" | head -1)"
assert_nonempty "dev/bump-nix-base's sed expression extracted" "$sed_expr"
fake_digest="sha256:$(printf 'a%.0s' $(seq 64))"
cp "$nixcompose" "$tmp/compose.yml"
sed -i "${sed_expr//\$\{new\}/$fake_digest}" "$tmp/compose.yml"
rewritten="$(grep -oP "$dc_anchor" "$tmp/compose.yml" || true)"
assert_eq "the sed dev/bump-nix-base runs rewrites the digest in place" \
    "${ref%@*}@$fake_digest" "$rewritten"

dockerfile="$(grep -oP '^\s*dockerfile:\s*\K\S+' "$nixcompose" || true)"
assert_eq "compose points at the nix-base tail Dockerfile" \
    "nix/base/Dockerfile.nix-default" "$dockerfile"
assert_true "the tail Dockerfile exists at that path" \
    test -f "$DEV_BASE/$dockerfile"

# image_config_files() hashes the lock for local-build staleness; it must exist.
assert_true "flake.lock exists (hashed by image_config_files)" \
    test -f "$DEV_BASE/nix/base/flake.lock"

finish
