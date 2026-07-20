#!/usr/bin/env bash
# Tests for the container-side credential installer used by
# `devcontainer set-credentials`. Exercises lib/install-claude-credentials.sh
# directly against a fake filesystem — no docker required. The installer is the
# piece with the real risk: it must replace the shared-mount *symlink* without
# writing through to the shared file, swap atomically, and never strand a temp.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
INSTALLER="$DEV_BASE/lib/install-claude-credentials.sh"
OWNER="$(id -un):$(id -gn)"

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
assert_true "dest is now a regular file, not a symlink" is_regular_file "$dest"
assert_true "dest holds the streamed private token" \
    [ "$(cat "$dest")" = '{"token":"PRIVATE-abc"}' ]
assert_true "shared file was NOT written through" \
    [ "$(cat "$root/credentials/.credentials.json")" = '{"token":"SHARED-do-not-touch"}' ]
assert_true "dest is mode 600" [ "$(stat -c %a "$dest")" = 600 ]
assert_true "no .cred.* temp left behind" \
    [ -z "$(find "$root" -maxdepth 1 -name '.cred.*' -print -quit)" ]

# ---- invalid JSON: existing credentials untouched, no temp, non-zero exit ----
root="$(make_sandbox)"
dest="$root/.credentials.json"
rc=0
printf 'not json at all' | sh "$INSTALLER" "$dest" "$OWNER" >/dev/null 2>&1 || rc=$?

assert_true "invalid JSON exits non-zero" [ "$rc" -ne 0 ]
is_symlink() { [ -L "$1" ]; }
assert_true "invalid JSON leaves dest as the original symlink" is_symlink "$dest"
assert_true "invalid JSON does not disturb the shared file" \
    [ "$(cat "$root/credentials/.credentials.json")" = '{"token":"SHARED-do-not-touch"}' ]
assert_true "invalid JSON leaves no .cred.* temp behind" \
    [ -z "$(find "$root" -maxdepth 1 -name '.cred.*' -print -quit)" ]

# ---- second install overwrites a prior private file (idempotent re-point) ----
root="$(make_sandbox)"
dest="$root/.credentials.json"
printf '%s' '{"token":"first"}' | sh "$INSTALLER" "$dest" "$OWNER"
printf '%s' '{"token":"second"}' | sh "$INSTALLER" "$dest" "$OWNER"
assert_true "re-install replaces the private file in place" \
    [ "$(cat "$dest")" = '{"token":"second"}' ]

finish
