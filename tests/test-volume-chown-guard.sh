#!/usr/bin/env bash
# Tests for the guarded named-volume chown (lib/volume-perms.sh, driven by
# chown_named_volume_targets in dev/devcontainer). Exercises the GUARD DECISION
# in isolation — no docker, no root, no real volume — by sourcing the shipped lib
# and stubbing `chown` on PATH so every invocation is recorded instead of
# performed. `stat` is NOT stubbed: the ownership probe runs for real against
# temp dirs the suite owns.
#
# Modelling the two states without root: the guard compares owner NAMES, so a
# name that cannot match any real owner ("$MISMATCH_OWNER") models a fresh
# root-owned volume, and "$(id -un)" models one a previous cold start already
# chowned. That holds whether or not the suite itself runs as root (CI may).
#
# What is asserted:
#   1. the guard decision (needs / does not need the recursive chown)
#   2. a mismatched mount point -> `chown -R` runs (fresh volume still repaired)
#   3. a matching mount point   -> `chown -R` is SKIPPED (the cold-start win)
#      while the O(depth) ancestor chowns still run unconditionally
#   4. ancestor walking stops at the home prefix and never leaves it
#   5. `chown -R` is post-order, the invariant the guard rests on: an interrupted
#      run leaves the mount point unchowned, so it can't be read as completed
#   6. the dev/devcontainer driver line still matches the lib's function
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

# --- chown stub: records argv, changes nothing. -------------------------------
bin="$tmp/bin"
mkdir -p "$bin"
export CHOWN_LOG="$tmp/chown-argv"
cat >"$bin/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CHOWN_LOG"
exit 0
EOF
chmod +x "$bin/chown"
export PATH="$bin:$PATH"

ME="$(id -un)"
MISMATCH_OWNER="no-such-owner-$$"

# shellcheck source=/dev/null
. "$DEV_BASE/lib/volume-perms.sh"

# run <owner> <home-prefix> <target>... — clear the log, then drive the lib.
run() {
    : >"$CHOWN_LOG"
    dev_chown_volume_targets "$@"
}

log() { cat "$CHOWN_LOG"; }

echo "=== named-volume chown guard tests ==="

# ---- 1. the guard decision ----
home="$tmp/home/vscode"
mount="$home/.cache/uv"
mkdir -p "$mount"

assert_true "mount point not owned by target -> needs the recursive chown" \
    dev_volume_chown_needed "$mount" "$MISMATCH_OWNER"
assert_false "mount point already owned by target -> recursion not needed" \
    dev_volume_chown_needed "$mount" "$ME"
assert_false "missing mount point -> nothing needed" \
    dev_volume_chown_needed "$tmp/absent" "$MISMATCH_OWNER"
assert_false "a FILE at the mount path -> nothing needed (dirs only)" \
    dev_volume_chown_needed "$DEV_BASE/lib/volume-perms.sh" "$MISMATCH_OWNER"

# ---- 2. fresh volume: the recursion still runs ----
run "$MISMATCH_OWNER" "$home" "$mount"
assert_contains "fresh volume -> chown -R on the mount point" \
    "-R $MISMATCH_OWNER:$MISMATCH_OWNER $mount" "$(log)"

# ---- 3. already-chowned volume: the recursion is SKIPPED ----
# The whole point of the guard: setup() re-runs on every cold start, and this is
# where the multi-minute walk over a large cache volume used to be spent.
run "$ME" "$home" "$mount"
assert_not_contains "already-owned volume -> no chown -R (walk skipped)" \
    "-R" "$(log)"
assert_contains "ancestor chown still runs (unguarded, O(depth))" \
    "$ME:$ME $home/.cache" "$(log)"

# ---- 4. ancestor walk is scoped to the home prefix ----
# Only $home/.cache is strictly under $home; the walk must stop before $home
# itself and never reach its parents.
assert_eq "ancestors: exactly the dirs strictly under the home prefix" \
    "$ME:$ME $home/.cache" "$(log)"
# Line-anchored: "$home" is a prefix of "$home/.cache", so a substring check
# would match the legitimate ancestor chown.
assert_false "the home prefix itself is never chowned" \
    grep -qxF "$ME:$ME $home" "$CHOWN_LOG"
assert_false "nothing above the home prefix is chowned" \
    grep -qxF "$ME:$ME $tmp/home" "$CHOWN_LOG"

# A workspace-style target (parent outside the home prefix, e.g. a venv volume
# mounted inside the bind-mounted host workspace): no ancestor may be touched.
ws="$tmp/workspaces/proj/.venv"
mkdir -p "$ws"
run "$ME" "$home" "$ws"
assert_eq "target outside the home prefix -> no ancestor chowns at all" "" "$(log)"

# A missing target: no recursion (guard says no) and no ancestors under home.
run "$ME" "$home" "$tmp/absent-volume"
assert_eq "missing target outside home prefix -> no chowns at all" "" "$(log)"

# Empty entries are skipped rather than chowning the process's cwd.
run "$ME" "$home" "" ""
assert_eq "empty target entries are skipped" "" "$(log)"

# Multiple targets in one call: each is judged on its own mount point.
other="$home/.cache/other"
mkdir -p "$other"
run "$MISMATCH_OWNER" "$home" "$mount" "$other"
assert_contains "multiple targets: first still recursed" \
    "-R $MISMATCH_OWNER:$MISMATCH_OWNER $mount" "$(log)"
assert_contains "multiple targets: second still recursed" \
    "-R $MISMATCH_OWNER:$MISMATCH_OWNER $other" "$(log)"

# ---- 5. `chown -R` is post-order (the invariant the guard rests on) ----
# If chown -R chowned the top directory FIRST, an interrupted run would leave a
# user-owned mount point over a still-root-owned tree and the guard would skip
# the repair forever. Post-order means the mount point is chowned LAST, so an
# interrupted run is retried on the next cold start. Asserted against the real
# chown (not the stub) via -v traversal order on a tree the suite owns; the
# chown is a no-op ("retained"), only the order matters.
order_root="$tmp/order/top"
mkdir -p "$order_root/sub"
touch "$order_root/sub/file"
real_chown=""
for c in /usr/bin/chown /bin/chown; do
    [ -x "$c" ] && { real_chown="$c"; break; }
done
order_lines=()
[ -n "$real_chown" ] && mapfile -t order_lines < <("$real_chown" -Rv "$ME" "$order_root")
if [ "${#order_lines[@]}" -eq 0 ]; then
    _fail "chown -R traversal order observable" \
        "no verbose output from a real chown (looked in /usr/bin, /bin)"
else
    assert_contains "chown -R visits the top directory LAST (post-order)" \
        "'$order_root'" "${order_lines[-1]}"
    assert_contains "chown -R visits a child BEFORE the top directory" \
        "'$order_root/sub/file'" "${order_lines[0]}"
fi

# ---- 6. the dev/devcontainer driver line matches the lib ----
# chown_named_volume_targets injects the lib into the container and appends this
# exact line; a rename on either side would otherwise fail only at runtime.
driver='dev_chown_volume_targets vscode /home/vscode "$@"'
assert_true "dev/devcontainer drives the lib's function with (vscode, /home/vscode, \$@)" \
    grep -qF "$driver" "$DEV_BASE/dev/devcontainer"

# The injected script must be valid POSIX sh and must pick the mount points out
# of "$@" — the `sh -c <script> <argv0> <args...>` convention the caller relies
# on. Composed here the same way chown_named_volume_targets composes it.
script="$(cat "$DEV_BASE/lib/volume-perms.sh")
$driver"
assert_true "injected script parses as POSIX sh" sh -n -c "$script"

: >"$CHOWN_LOG"
sh -c "$script" volume-perms "/home/vscode/.cache/uv"
assert_eq "injected script: mount points arrive in \"\$@\" and resolve under /home/vscode" \
    "vscode:vscode /home/vscode/.cache" "$(log)"

finish
