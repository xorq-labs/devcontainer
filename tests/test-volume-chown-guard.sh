#!/usr/bin/env bash
# Tests for the guarded mount-point chown (lib/volume-perms.sh, driven by
# chown_mount_points in dev/devcontainer). Exercises the GUARD DECISION and the
# bind/volume DISPATCH in isolation — no docker, no root, no real volume — by
# sourcing the shipped lib and stubbing `chown` on PATH so every invocation is
# recorded instead of performed. `stat` is NOT stubbed: the ownership probe runs
# for real against temp dirs the suite owns.
#
# Modelling the two states without root: the guard compares owner/group NAMES,
# so a name that cannot match any real owner ("$MISMATCH_OWNER") models a fresh
# root-owned volume, and "$(id -un)"/"$(id -gn)" models one a previous cold
# start already chowned. That holds whether or not the suite itself runs as
# root (CI may).
#
# What is asserted:
#   1. the guard decision (needs / does not need the recursive chown)
#   2. a mismatched mount point -> `chown -R` runs (fresh volume still repaired)
#   3. a matching mount point   -> `chown -R` is SKIPPED (the cold-start win)
#      while the O(depth) ancestor chowns still run unconditionally
#   4. ancestor walking stops at the home prefix and never leaves it
#   5. `chown -R` is post-order, the invariant the guard rests on: an interrupted
#      run leaves the mount point unchowned, so it can't be read as completed
#   6. bind/volume dispatch: a bind gets its daemon-created ancestors repaired
#      but is never DISPATCHED into the recursive branch, a volume still gets
#      both, an unknown kind gets nothing
#   7. the ANCESTOR WALK never lands a chown on a bind mount point or on
#      anything under one, including when one bind nests inside another
#      (DEV_MAIN_GIT inside DEV_MAIN_TREE, and the deeper host-mounts.txt
#      shape) — those paths are the host side of the mount. The RECURSIVE
#      branch is not covered by any of that and the suite says so: a bind
#      nested under a volume is still reached, pinned as current behaviour
#      (#115)
#   8. the compose query emits kind-qualified volume AND bind targets, checked
#      by running dev/devcontainer's own python snippet against a document
#   9. the dev/devcontainer driver line still matches the lib's function
#  10. both image routes ship the transcript bind's parent, created AND then
#      chowned, so the daemon never has to create it as root — the half of
#      #106 the ancestor walk cannot cover, because an entry path that skips
#      setup() (VS Code "Reopen in Container") never runs the walk at all. The
#      directory is derived from docker-compose.yml, not written down here.
#      This reads Dockerfile TEXT, a proxy: whether the BUILT image ships the
#      directory writable needs a daemon and is typed `ci:`
#      (dev/check-image-mount-parents). What this suite holds of that half is
#      the workflow<->tool coupling — both build workflows must invoke the
#      checker, and the checker must derive the path rather than restate it.
#
# Verified (ADR-0005 §2), fourteen mutations. Counts and assertion names below are
# transcribed from the runs — see the METHOD note at the end, because three
# earlier versions of this record were wrong.
#   1. mount_point_targets' filter reverted to the pre-#106 `type == "volume"`
#      — 3 red: "the compose query emits BIND targets too (the #106 fix)", the
#      kind-set anti-vacuity assertion (the generic extraction finds no
#      `in (...)` tuple at all), and the kind-set comparison. Item 8 is the
#      only thing that sees the compose query; everything else drives the lib.
#   2. the `_vp_is_protected` check dropped from dev_chown_ancestors — 6 red,
#      all in item 7.
#   3. the `bind)` dispatch arm routed to dev_chown_volume_targets — 1 red,
#      "a bind target is never recursed into". NOT the deep-nesting assertions:
#      they are line-anchored on `<owner> <path>` and this mutation logs
#      `-R <owner> <path>`, a different whole line. Coverage for this mutation
#      is exactly one assertion, which is worth knowing before relying on it.
#   4. the `_vp_never_chown=""` reset deleted, leaking the exclusion set into a
#      later direct dev_chown_volume_targets call — 1 red, "a direct
#      volume-targets call does not inherit protections". That assertion was
#      FAIL-OPEN as first written (assert_contains with a needle that is a
#      PREFIX of the recursive line): it passed with the leak live and the
#      suite stayed at 41/0. Found in review, not by me.
#   5. the under-a-bind arm of _vp_is_protected removed, leaving exact-match
#      only — 1 red, "a directory INSIDE a bind is not chowned (not just the
#      mount point)".
#   6. the ancestor walk changed to `break` at a protected bind instead of
#      skipping past it — 1 red, "the walk continues PAST a protected bind to
#      the dirs above it". That assertion was ALSO fail-open until this round:
#      it read the log of a call where the protected bind was itself an
#      argument, so its own walk chowned everything above it and the assertion
#      passed either way. It now drives dev_chown_ancestors directly with a
#      hand-filled exclusion set. (Skip and break are outcome-equivalent for
#      every input reachable through dev_chown_mount_points, so this pins a
#      documented behaviour rather than fixing a live bug.)
#   7. the whole `bind)` dispatch arm deleted — 3 red, including the kind-set
#      comparison, which is what proves that guard derives both sides rather
#      than restating a vocabulary.
#   8. `/projects` dropped from the root Dockerfile's mkdir, back to the
#      pre-#106 `mkdir -p ... /home/vscode/.claude` — 2 red, both in item 10.
#      Two rather than one because the chown probe reports nothing once the
#      mkdir is gone: there is no creation for a later chown to cover.
#   9. the nix tail build's RUN deleted entirely — 2 red, the same pair for
#      that route. The routes are checked independently, so neither mutation
#      is masked by the other file being correct.
#  10. that RUN's `&& chown` dropped, leaving only the mkdir — 1 red, "chowns
#      it AFTER creating it". This is the one that pays for the ordering logic
#      in `precreated`: both Dockerfiles chown -R /home/vscode ABOVE these
#      lines, so a coverage test that ignored position would read that remap
#      as ownership and stay green on an image shipping the dir root-owned.
#  11. the compose target moved to .claude/transcripts/<key> with both
#      Dockerfiles left alone — 4 red, and the failure names print
#      `/home/vscode/.claude/transcripts`, which is what shows the expectation
#      is read out of compose rather than restated in the assertions.
#  12. the checker's step deleted from docker-build.yml — 1 red. The two
#      workflows are asserted separately, so silently dropping the check from
#      one route cannot hide behind the other still running it.
#  13. the checker's derivation replaced by the hardcoded literal it derives —
#      1 red, "does not hardcode the directory it checks". Note what this
#      mutation does NOT break: the checker still passes against today's
#      images, which is exactly why a literal there would go unnoticed until
#      the mount moved.
#  14. the checker made non-executable — 1 red. `run: dev/check-image-mount-parents`
#      execs it directly, so a lost mode bit is a CI failure with a confusing
#      message; this is the #129 shape, caught hermetically.
#
# METHOD: measure each mutation in a FRESH copy of the tree, and transcribe the
# numbers from the run rather than reasoning about them. Three earlier versions
# of this record were wrong — counts inflated, and one mutation credited with
# reds belonging to another.
#
# What is established: hand-measured counts taken from a single scratch copy
# reused across mutations disagreed with counts re-measured one-copy-per-
# mutation, and the latter reproduce. What is NOT established is why the reused
# copy drifted: an earlier draft of this note blamed `git checkout` failing to
# restore in a `cp -a` copy of a linked worktree, and that does not reproduce —
# the copy's gitdir resolves and the restore works. Something else in that loop
# accumulated state. The prescription stands on the reproducibility of the
# fresh-copy numbers, not on the diagnosis.
#
# tests/mutation-coverage automates this (fresh copy per mutation, plus it
# flags a mutation that changed nothing). It is not in this tree — it ships on
# the branch behind PR #124.
#   (mutation runs 2026-08-04; items 8-14 on 2026-08-10, fresh copy each)
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

# run <owner> <group> <home-prefix> <target>... — clear the log, then drive the lib.
run() {
    : >"$CHOWN_LOG"
    dev_chown_volume_targets "$@"
}

log() { cat "$CHOWN_LOG"; }

echo "=== mount-point chown guard tests ==="

# ---- 1. the guard decision ----
home="$tmp/home/vscode"
mount="$home/.cache/uv"
mkdir -p "$mount"
# The group the suite's dirs actually get — usually $(id -gn), but a setgid
# parent can override it, so read it back rather than assume.
MYGRP="$(stat -c %G "$mount")"

assert_true "mount point not owned by target -> needs the recursive chown" \
    dev_volume_chown_needed "$mount" "$MISMATCH_OWNER" "$MISMATCH_OWNER"
assert_false "mount point already owned by target -> recursion not needed" \
    dev_volume_chown_needed "$mount" "$ME" "$MYGRP"
assert_true "owner matches but group does not -> still needed" \
    dev_volume_chown_needed "$mount" "$ME" "$MISMATCH_OWNER"
assert_false "missing mount point -> nothing needed" \
    dev_volume_chown_needed "$tmp/absent" "$MISMATCH_OWNER" "$MISMATCH_OWNER"
assert_false "a FILE at the mount path -> nothing needed (dirs only)" \
    dev_volume_chown_needed "$DEV_BASE/lib/volume-perms.sh" "$MISMATCH_OWNER" "$MISMATCH_OWNER"

# ---- 2. fresh volume: the recursion still runs ----
run "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$home" "$mount"
assert_contains "fresh volume -> chown -R on the mount point" \
    "-R $MISMATCH_OWNER:$MISMATCH_OWNER $mount" "$(log)"

# ---- 3. already-chowned volume: the recursion is SKIPPED ----
# The whole point of the guard: setup() re-runs on every cold start, and this is
# where the multi-minute walk over a large cache volume used to be spent.
run "$ME" "$MYGRP" "$home" "$mount"
assert_not_contains "already-owned volume -> no chown -R (walk skipped)" \
    "-R" "$(log)"
assert_contains "ancestor chown still runs (unguarded, O(depth))" \
    "$ME:$MYGRP $home/.cache" "$(log)"

# ---- 4. ancestor walk is scoped to the home prefix ----
# Only $home/.cache is strictly under $home; the walk must stop before $home
# itself and never reach its parents.
assert_eq "ancestors: exactly the dirs strictly under the home prefix" \
    "$ME:$MYGRP $home/.cache" "$(log)"
# Line-anchored: "$home" is a prefix of "$home/.cache", so a substring check
# would match the legitimate ancestor chown.
assert_false "the home prefix itself is never chowned" \
    grep -qxF "$ME:$MYGRP $home" "$CHOWN_LOG"
assert_false "nothing above the home prefix is chowned" \
    grep -qxF "$ME:$MYGRP $tmp/home" "$CHOWN_LOG"

# A workspace-style target (parent outside the home prefix, e.g. a venv volume
# mounted inside the bind-mounted host workspace): no ancestor may be touched.
ws="$tmp/workspaces/proj/.venv"
mkdir -p "$ws"
run "$ME" "$MYGRP" "$home" "$ws"
assert_eq "target outside the home prefix -> no ancestor chowns at all" "" "$(log)"

# A missing target: no recursion (guard says no) and no ancestors under home.
run "$ME" "$MYGRP" "$home" "$tmp/absent-volume"
assert_eq "missing target outside home prefix -> no chowns at all" "" "$(log)"

# Empty entries are skipped rather than chowning the process's cwd.
run "$ME" "$MYGRP" "$home" "" ""
assert_eq "empty target entries are skipped" "" "$(log)"

# Multiple targets in one call: each is judged on its own mount point.
other="$home/.cache/other"
mkdir -p "$other"
run "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$home" "$mount" "$other"
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

# ---- 6. bind vs volume dispatch: a bind is never recursed into ----
# The daemon creates a mount target's missing parents as root for binds exactly
# as for volumes (~/.claude/projects, hosting the transcript bind under the
# claude-home volume), so those ancestors must be repaired. Recursing into the
# target itself must NOT happen for a bind: the walk would cross into the host
# side and rewrite ownership there.
#
# Both cases use MISMATCH_OWNER so the guard would ALLOW the recursion — the
# bind case therefore proves dispatch, not a guard that happened to skip.
run_mp() {
    : >"$CHOWN_LOG"
    dev_chown_mount_points "$@"
}

mp_home="$tmp/mp/vscode"
mp_target="$mp_home/.claude/projects/-devcontainer-x"
mkdir -p "$mp_target"

run_mp "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "bind:$mp_target"
assert_not_contains "a bind target is never recursed into" "-R " "$(log)"
# Line-anchored: this needle is a strict PREFIX of the bind-target line
# ("… /projects" vs "… /projects/-devcontainer-x"), so assert_contains passes
# on a mutant that chowns the target instead of its parent — verified. Third
# instance of that trap in this file; the neighbours below are anchored for the
# same reason.
assert_true "a bind target's daemon-created parent is chowned" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $mp_home/.claude/projects" "$CHOWN_LOG"
assert_false "a bind target itself is not chowned" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $mp_target" "$CHOWN_LOG"

run_mp "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "volume:$mp_target"
assert_contains "a volume target still gets the recursive chown" \
    "-R $MISMATCH_OWNER:$MISMATCH_OWNER $mp_target" "$(log)"
# Line-anchored for the same reason as the direct-call assertion at the end of
# item 7: the recursive line `-R <owner> <mp_target>` contains this needle as a
# substring, so assert_contains here would pass with the ancestor walk removed.
assert_true "a volume target's ancestors are still chowned" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $mp_home/.claude/projects" "$CHOWN_LOG"

# An unrecognised kind must fall through to nothing: the recursive branch is the
# destructive one, so a mount type the lib has not been taught about (tmpfs,
# npipe, cluster) must not reach it by default.
run_mp "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "tmpfs:$mp_target"
assert_eq "an unknown mount kind is skipped entirely" "" "$(log)"

# An entry with no kind separator at all is skipped for the same reason.
run_mp "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "$mp_target"
assert_eq "an unqualified target (no <kind>: prefix) is skipped" "" "$(log)"

# ---- 7. a bind mount point is never chowned, however it is reached ----
# docker-compose.yml mounts DEV_MAIN_TREE and DEV_MAIN_GIT at their HOST paths,
# and <tree>/.git nests inside <tree>. On a host whose checkout lives under the
# container home prefix (a host user named `vscode`; Codespaces), walking up
# from the .git bind reaches the worktree bind — which is the host side of a
# mount, i.e. the user's real repo directory. It must be skipped, while the
# walk continues past it to the container-side dirs above.
tree="$mp_home/repos/proj"
gitdir="$tree/.git"
mkdir -p "$gitdir"

run_mp "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "bind:$tree" "bind:$gitdir"
assert_false "a nested bind's parent bind is never chowned" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $tree" "$CHOWN_LOG"

# "Continues past" needs the protected bind to NOT be in the argument list —
# otherwise its own walk chowns everything above it and the assertion passes
# whether the walk skips or breaks. Verified: mutating the skip to a `break`
# left the suite fully green before this was rewritten. So drive the walk
# directly with a hand-filled exclusion set naming a bind that is not an
# argument.
: >"$CHOWN_LOG"
# shellcheck disable=SC2154  # _vp_nl comes from the sourced lib above; building
# the set with the lib's own delimiter is the point — a literal newline here
# would stop tracking it if the lib ever changed delimiters.
_vp_never_chown="$_vp_nl$tree$_vp_nl"
dev_chown_ancestors "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "$gitdir"
_vp_never_chown=""
assert_true "the walk continues PAST a protected bind to the dirs above it" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $mp_home/repos" "$CHOWN_LOG"
assert_false "...while still not chowning the protected bind itself" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $tree" "$CHOWN_LOG"

# Protection is order-independent: the bind targets are collected in a first
# pass, so it holds whichever order compose emits them in.
run_mp "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "bind:$gitdir" "bind:$tree"
assert_false "protection does not depend on argument order" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $tree" "$CHOWN_LOG"
# Paired positive: without it the negative above passes on an empty log, so a
# run that chowned NOTHING would read as a protected one (the #95-#97 shape).
assert_contains "reversed order still repairs the container-side ancestor" \
    "$MISMATCH_OWNER:$MISMATCH_OWNER $mp_home/repos" "$(log)"

# A bind nesting TWO levels under another bind: the intermediate directory is
# inside the outer bind, so it is host-side even though it is not itself a mount
# point. An exact-match-only protection would chown it. Not reachable from
# docker-compose.yml (which nests one level, <tree>/.git under <tree>) but
# reachable from host-mounts.txt, which takes arbitrary <host>:<container>.
deep_outer="$mp_home/data"
deep_inner="$deep_outer/secrets/keys"
mkdir -p "$deep_inner"
run_mp "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" \
    "bind:$deep_outer" "bind:$deep_inner"
assert_false "a directory INSIDE a bind is not chowned (not just the mount point)" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $deep_outer/secrets" "$CHOWN_LOG"
assert_false "the outer bind mount point is still not chowned" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $deep_outer" "$CHOWN_LOG"

# Same for a volume nested inside a bind (a venv volume under the worktree):
# the volume is recursed into, its bind parent still is not.
venv="$tree/.venv"
mkdir -p "$venv"
run_mp "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "bind:$tree" "volume:$venv"
assert_contains "a volume nested in a bind is still recursed into" \
    "-R $MISMATCH_OWNER:$MISMATCH_OWNER $venv" "$(log)"
assert_false "a volume's ancestor walk also skips the bind mount point" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $tree" "$CHOWN_LOG"

# The SHIPPED direction, pinned honestly: a bind nested UNDER a volume is still
# reached by the recursion. `chown -R` has no mount awareness, and
# _vp_never_chown is consulted by dev_chown_ancestors alone, so the recursive
# branch descends through the bind — the claude-home / transcript-bind topology.
# This asserts what the code DOES, not what it should do; #115 tracks the fix
# and this assertion is its red-to-green target. Item 7's other cases cover the
# opposite nesting (a volume under a bind), which is the safe one — without this
# the suite would read as having covered both.
#
# What it actually observes, stated plainly: `chown` is STUBBED here, so this
# witnesses the unpruned `chown -R` being INVOKED on a volume that contains a
# bind — not the descent itself, which a stub cannot see. That invocation is the
# observable proxy, and it is sufficient as a red-to-green target: both
# candidate #115 fixes flip it (a pruned `find` emits no `-R` line at all).
assert_contains "a volume containing a bind still gets the unpruned chown -R (#115)" \
    "-R $MISMATCH_OWNER:$MISMATCH_OWNER $mp_home/.claude" "$(
        : >"$CHOWN_LOG"
        dev_chown_mount_points "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" \
            "volume:$mp_home/.claude" "bind:$mp_target"
        log
    )"

# The protection is scoped to the dispatching call: dev_chown_volume_targets is
# still a usable entry point on its own and must not inherit a stale exclusion
# set from a previous dev_chown_mount_points call.
run "$MISMATCH_OWNER" "$MISMATCH_OWNER" "$mp_home" "$venv"
# grep -qxF, NOT assert_contains: "$tree" is a PREFIX of "$venv", so a substring
# check is satisfied by the recursive line `-R <owner> <tree>/.venv` and passes
# even when the exclusion set leaks — the very leak this asserts against.
# (Mutation: delete the `_vp_never_chown=""` reset and the substring form stays
# green at 41/0. The line-anchored form goes red. Same trap the ancestor-walk
# assertions above already avoid.)
assert_true "a direct volume-targets call does not inherit protections" \
    grep -qxF "$MISMATCH_OWNER:$MISMATCH_OWNER $tree" "$CHOWN_LOG"

# ---- 8. the compose query emits kind-qualified volume AND bind targets ----
# Derived, not restated: the python snippet is lifted out of mount_point_targets
# in dev/devcontainer and run against a synthetic `docker compose config`
# document, so a narrowed filter there fails HERE rather than only in a
# container. `dc config` itself needs docker, which this suite does not have —
# the snippet is the part that can be run hermetically.
# `|| true` so an extraction that yields nothing reaches the anti-vacuity
# assertion below. Without it a failing pipeline exits nonzero through this
# substitution and `set -e` kills the suite AT THE ASSIGNMENT — the failure
# channel becomes an undiagnosed abort, and the assertion written for exactly
# that case never runs.
query="$(awk "/python3 -c '\$/{f=1; next} f && /^'\$/{exit} f" "$DEV_BASE/dev/devcontainer" || true)"
assert_true "the compose-query snippet was extracted from dev/devcontainer" \
    test -n "$query"

compose_json='{"services": {"app": {"volumes": [
    {"type": "volume", "source": "claude-home", "target": "/home/vscode/.claude"},
    {"type": "bind", "source": "/host/logs", "target": "/home/vscode/.claude/projects/-k"},
    {"type": "tmpfs", "target": "/home/vscode/.claude/shell-snapshots"},
    {"type": "volume", "source": "no-target"}
]}}}'
emitted="$(printf '%s' "$compose_json" | python3 -c "$query")"
assert_contains "the compose query emits volume targets, kind-qualified" \
    "volume:/home/vscode/.claude" "$emitted"
assert_contains "the compose query emits BIND targets too (the #106 fix)" \
    "bind:/home/vscode/.claude/projects/-k" "$emitted"
assert_not_contains "the compose query skips mount kinds the lib cannot dispatch" \
    "tmpfs:" "$emitted"
assert_not_contains "the compose query skips a mount with no target" \
    "no-target" "$emitted"

# The mount kinds the query emits and the kinds the lib dispatches on are a
# two-file coupling, so per the repo convention it gets a drift guard — and a
# DERIVED one (ADR-0005): both sides are parsed out of their own source rather
# than restated here. A kind emitted but not dispatched is silently skipped; a
# kind dispatched but never emitted is dead code.
# Both sides are parsed GENERICALLY — no vocabulary is written down here.
# Enumerating the known kinds (volume|bind|tmpfs|npipe|cluster) made this a
# third restatement: Compose's `image` mount type (v2.35+) was absent from it,
# so a filter gaining "image" with no dispatcher arm would be invisible to both
# extractions and the sets would stay equal. `|| true` so an extraction that
# matches nothing reaches the anti-vacuity assertions below instead of aborting
# the suite at the assignment.
emitted_kinds="$(printf '%s\n' "$query" | grep -oE 'in \([^)]*\)' |
    grep -oE '"[a-z]+"' | tr -d '"' | sort -u | tr '\n' ' ' || true)"
dispatched_kinds="$(sed -n '/^dev_chown_mount_points()/,/^}/p' "$DEV_BASE/lib/volume-perms.sh" |
    grep -oE '^[[:space:]]+[a-z]+\)$' |
    tr -d ' )' | sort -u | tr '\n' ' ' || true)"
assert_true "the compose query's kind set was parsed out of dev/devcontainer" \
    test -n "$emitted_kinds"
assert_true "the dispatcher's kind set was parsed out of lib/volume-perms.sh" \
    test -n "$dispatched_kinds"
assert_eq "every kind the query emits is a kind the lib dispatches on" \
    "$emitted_kinds" "$dispatched_kinds"

# ---- 9. the dev/devcontainer driver line matches the lib ----
# chown_mount_points injects the lib into the container and appends this
# exact line; a rename on either side would otherwise fail only at runtime.
driver='dev_chown_mount_points vscode vscode /home/vscode "$@"'
assert_true "dev/devcontainer drives the lib's function with (vscode, vscode, /home/vscode, \$@)" \
    grep -qF "$driver" "$DEV_BASE/dev/devcontainer"

# The injected script must be valid POSIX sh and must pick the mount points out
# of "$@" — the `sh -c <script> <argv0> <args...>` convention the caller relies
# on. Composed here the same way chown_mount_points composes it.
script="$(cat "$DEV_BASE/lib/volume-perms.sh")
$driver"
assert_true "injected script parses as POSIX sh" sh -n -c "$script"

: >"$CHOWN_LOG"
sh -c "$script" volume-perms "volume:/home/vscode/.cache/uv"
# assert_contains, not assert_eq: the guard probes the REAL /home/vscode/.cache/uv,
# so on a machine where that path exists with a non-vscode owner a chown -R line
# is also (correctly) logged. Only the unconditional ancestor chown is
# environment-independent.
assert_contains "injected script: mount points arrive in \"\$@\" and resolve under /home/vscode" \
    "vscode:vscode /home/vscode/.cache" "$(log)"

# ---- 10. both image routes pre-create the transcript bind's parent ----
# The ancestor walk repairs that directory after the daemon has created it as
# root; shipping it in the image means it is never root-owned to begin with,
# which is the only thing that covers an entry path that never runs setup()
# (VS Code "Reopen in Container", a bare `docker compose up`). Two images build
# that path, so this is a three-file coupling — compose plus both Dockerfiles.
#
# DERIVED, not restated (ADR-0005): the directory is read out of
# docker-compose.yml as the parent of the one mount target that interpolates
# DEV_CONTAINER_PROJECT_KEY — that variable is what makes the target a
# per-project subdirectory — so moving or renaming the transcript mount moves
# this guard with it instead of leaving it asserting a stale literal.
echo "--- transcript bind parent pre-created in both image routes ---"

bind_target="$(awk '/^[[:space:]]*target:[[:space:]]/ && /DEV_CONTAINER_PROJECT_KEY/ {print $2}' \
    "$DEV_BASE/docker-compose.yml")"
assert_eq "exactly one compose target interpolates DEV_CONTAINER_PROJECT_KEY" \
    1 "$(printf '%s' "$bind_target" | grep -c . || true)"
# Cut at the interpolation and drop the trailing slash: the key is the leaf, so
# what remains is the parent the daemon would otherwise create.
bind_parent="${bind_target%%\$\{*}"
bind_parent="${bind_parent%/}"
assert_true "the transcript bind's parent derives to a path under /home/vscode" \
    bash -c '[[ "$1" == /home/vscode/?* ]]' _ "$bind_parent"

# precreated <dockerfile> <path> — prints `mkdir` when some mkdir creates
# <path>, and `chown` when a LATER command gives it to the container user,
# directly or by -R on an ancestor. Ordering is load-bearing and is why this
# does not just grep for two words: BOTH Dockerfiles chown -R /home/vscode
# ABOVE these lines (the UID remap), and a chown that runs before the mkdir
# cannot own a directory that does not exist yet. Reading it as coverage would
# leave the guard passing on an image whose dir ships root-owned — precisely
# the state being guarded against.
precreated() {
    python3 - "$1" "$2" <<'PY'
import re, sys

# Join continuations first, as tests/lib/dockerfile.sh does, so a wrapped RUN
# is one string. Commands are cut at &&, || and ; so one RUN's argv cannot bleed
# into the next command's.
text = open(sys.argv[1]).read().replace("\\\n", " ")
path = sys.argv[2]

def operands(cmd):
    return [w.strip('"\'') for w in cmd.split()[1:] if not w.startswith("-")]

mkdir_at = next((m.start() for m in re.finditer(r"mkdir[^&|;\n]*", text)
                 if path in operands(m.group(0))), None)
if mkdir_at is None:
    sys.exit(0)
print("mkdir")

for m in re.finditer(r"chown[^&|;\n]*", text):
    if m.start() < mkdir_at:
        continue
    words = m.group(0).split()
    recursive = any(w.startswith("-") and "R" in w for w in words)
    for target in (t.rstrip("/") for t in operands(m.group(0))[1:]):
        if target == path or (recursive and (path + "/").startswith(target + "/")):
            print("chown")
            sys.exit(0)
PY
}

for dockerfile in "$DEV_BASE/Dockerfile" "$DEV_BASE/nix/base/Dockerfile.nix-default"; do
    route="${dockerfile#"$DEV_BASE/"}"
    coverage="$(precreated "$dockerfile" "$bind_parent")"
    assert_contains "$route creates $bind_parent" "mkdir" "$coverage"
    assert_contains "$route chowns it AFTER creating it" "chown" "$coverage"
done

# Anti-vacuity: a parser that answered "mkdir" for anything would pass both
# routes above while checking nothing.
assert_eq "the parser reports nothing for a path no Dockerfile creates" \
    "" "$(precreated "$DEV_BASE/Dockerfile" "$bind_parent-absent")"

# Everything above reads Dockerfile TEXT, which is a proxy for what the built
# image ships. The fact itself needs a daemon, so it is typed `ci:` and lives in
# dev/check-image-mount-parents, invoked by both build workflows. That
# workflow<->tool coupling is what this suite can hold: a checker no job runs is
# not a guard, which is the #83 shape (a step nobody owned, duly undone).
checker="$DEV_BASE/dev/check-image-mount-parents"
assert_true "the ci: half exists and is executable" test -x "$checker"
for workflow in docker-build.yml nix-base.yml; do
    assert_true "$workflow runs dev/check-image-mount-parents on the image it built" \
        grep -q 'dev/check-image-mount-parents ' "$DEV_BASE/.github/workflows/$workflow"
done
# The checker must DERIVE the directory as this suite does, not restate it: a
# hardcoded literal there is a fourth encoding that goes stale silently, since
# nothing would fail until the mount moved AND someone noticed the check was
# asserting the old path.
assert_false "the checker does not hardcode the directory it checks" \
    grep -qF "$bind_parent" "$checker"

finish
