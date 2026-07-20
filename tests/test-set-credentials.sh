#!/usr/bin/env bash
# Tests for the container-side credential installer used by
# `devcontainer set-credentials`. Exercises lib/install-claude-credentials.sh
# directly against a fake filesystem — no docker required. The installer is the
# piece with the real risk: it must replace the shared-mount *symlink* without
# writing through to the shared file, swap atomically, and never strand a temp.
set -euo pipefail

PASS=0 FAIL=0

assert() {
    local label="$1"
    shift
    if "$@"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        FAIL=$((FAIL + 1))
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
INSTALLER="$DEV_BASE/lib/install-claude-credentials.sh"
OWNER="$(id -un):$(id -gn)"

_cleanup_dirs=()
cleanup() {
    for d in "${_cleanup_dirs[@]}"; do rm -rf "$d" 2>/dev/null || true; done
}
trap cleanup EXIT

# Build a fake ~/.claude with the real shared-mount layout: a private live path
# that is a *relative* symlink into a shared credentials/ dir (as the container
# ships it). Prints the sandbox root.
make_sandbox() {
    local root
    root="$(mktemp -d)"
    _cleanup_dirs+=("$root")
    mkdir -p "$root/credentials"
    printf '%s' '{"token":"SHARED-do-not-touch"}' >"$root/credentials/.credentials.json"
    ln -s credentials/.credentials.json "$root/.credentials.json"
    printf '%s' "$root"
}

echo "=== set-credentials installer tests ==="

# ---- valid JSON: private file replaces the symlink, shared file untouched ----
root="$(make_sandbox)"
dest="$root/.credentials.json"
printf '%s' '{"token":"PRIVATE-abc"}' | sh "$INSTALLER" "$dest" "$OWNER"

is_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
assert "dest is now a regular file, not a symlink" is_regular_file "$dest"
assert "dest holds the streamed private token" \
    [ "$(cat "$dest")" = '{"token":"PRIVATE-abc"}' ]
assert "shared file was NOT written through" \
    [ "$(cat "$root/credentials/.credentials.json")" = '{"token":"SHARED-do-not-touch"}' ]
assert "dest is mode 600" [ "$(stat -c %a "$dest")" = 600 ]
assert "no .cred.* temp left behind" \
    [ -z "$(find "$root" -maxdepth 1 -name '.cred.*' -print -quit)" ]

# ---- invalid JSON: existing credentials untouched, no temp, non-zero exit ----
root="$(make_sandbox)"
dest="$root/.credentials.json"
rc=0
printf 'not json at all' | sh "$INSTALLER" "$dest" "$OWNER" >/dev/null 2>&1 || rc=$?

assert "invalid JSON exits non-zero" [ "$rc" -ne 0 ]
is_symlink() { [ -L "$1" ]; }
assert "invalid JSON leaves dest as the original symlink" is_symlink "$dest"
assert "invalid JSON does not disturb the shared file" \
    [ "$(cat "$root/credentials/.credentials.json")" = '{"token":"SHARED-do-not-touch"}' ]
assert "invalid JSON leaves no .cred.* temp behind" \
    [ -z "$(find "$root" -maxdepth 1 -name '.cred.*' -print -quit)" ]

# ---- second install overwrites a prior private file (idempotent re-point) ----
root="$(make_sandbox)"
dest="$root/.credentials.json"
printf '%s' '{"token":"first"}' | sh "$INSTALLER" "$dest" "$OWNER"
printf '%s' '{"token":"second"}' | sh "$INSTALLER" "$dest" "$OWNER"
assert "re-install replaces the private file in place" \
    [ "$(cat "$dest")" = '{"token":"second"}' ]

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
