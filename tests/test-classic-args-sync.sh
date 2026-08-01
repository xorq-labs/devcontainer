#!/usr/bin/env bash
# Guard: the base-routing regex in dev/devcontainer tracks the Dockerfiles.
#
# overlay_sets_classic_args() forces the classic root Dockerfile when a
# project overlay overrides a build arg that only the classic route honors —
# the nix-base compose is appended last and would silently clobber it. The
# arg alternation inside its grep is hand-maintained; a new ARG added to the
# root Dockerfile (or one retired) would drift with no signal. This test
# recomputes the expected set from the committed files:
#
#   expected = ARGs declared in Dockerfile (root, classic route)
#            − (ARGs declared in nix/base/Dockerfile.nix-default
#               − ARGs pinned by nix/base/compose.nix-base.yml build args)
#
# Exclusion rule: an ARG both Dockerfiles declare is honored on either route,
# so an overlay overriding it must NOT force classic routing (USER_UID,
# USER_GID, HOST_USER, DEV_CONTAINER_WORKSPACE, EXTRA_PATH). The carve-out is
# BASE_IMAGE: Dockerfile.nix-default declares it too, but on the nix route
# the appended compose.nix-base.yml pins it (the digest-pinned base), so an
# overlay's override would be clobbered — overriding it must force classic.
# Hence args the nix-base compose itself pins are not excluded.
#
# Every extraction is anchor-guarded: an empty match fails loudly.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

# The harness has no bare non-empty asserter; this guard leans on it to prove
# the grep anchors still match (an empty capture means the anchor missed).
assert_nonempty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        _pass "$label"
    else
        _fail "$label" "empty — anchor missed? file moved?"
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
devcontainer="$DEV_BASE/dev/devcontainer"
root_df="$DEV_BASE/Dockerfile"
nix_df="$DEV_BASE/nix/base/Dockerfile.nix-default"
nix_compose="$DEV_BASE/nix/base/compose.nix-base.yml"

echo "--- classic build-arg routing sync (committed files) ---"

for f in "$devcontainer" "$root_df" "$nix_df" "$nix_compose"; do
    [ -f "$f" ] || { echo "  FAIL: $f not found"; exit 1; }
done

# The alternation inside overlay_sets_classic_args()'s
#   grep -qE '^[[:space:]]*(A|B|...)[[:space:]]*:'
# — anchored on the literal `^[[:space:]]*(` prefix, unique to that grep.
regex_args="$(grep -m1 -oP "grep -qE '\^\[\[:space:\]\]\*\(\K[A-Z0-9_|]+(?=\))" "$devcontainer" \
    | tr '|' '\n' | sort || true)"
assert_nonempty "overlay_sets_classic_args alternation extracted" "$regex_args"

# ARG names declared by each Dockerfile.
root_args="$(grep -oP '^ARG \K[A-Z0-9_]+' "$root_df" | sort -u || true)"
nix_args="$(grep -oP '^ARG \K[A-Z0-9_]+' "$nix_df" | sort -u || true)"
assert_nonempty "root Dockerfile ARG list extracted" "$root_args"
assert_nonempty "nix-default Dockerfile ARG list extracted" "$nix_args"

# Build args the nix-base compose pins (indented `NAME:` mapping keys under
# build.args — currently BASE_IMAGE, interpolated to the pinned digest).
compose_pinned="$(grep -oP '^[[:space:]]+\K[A-Z][A-Z0-9_]*(?=:)' "$nix_compose" | sort -u || true)"
assert_nonempty "nix-base compose pinned build-arg list extracted" "$compose_pinned"

# expected = root − (nix-default − compose-pinned), computed as sorted sets.
honored_on_both="$(comm -23 <(printf '%s\n' "$nix_args") <(printf '%s\n' "$compose_pinned"))"
expected="$(comm -23 <(printf '%s\n' "$root_args") <(printf '%s\n' "$honored_on_both"))"
assert_nonempty "expected classic-only arg set is non-empty" "$expected"

assert_eq "routing regex args == classic-only Dockerfile args" \
    "$expected" "$regex_args"

echo ""
echo "classic-only args: ${expected//$'\n'/ }"
finish
