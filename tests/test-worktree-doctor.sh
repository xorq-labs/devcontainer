#!/usr/bin/env bash
# Tests for dev/worktree-doctor: the four worktree states, repair, repo
# attribution, and the in-container repair refusal. Runs against disposable git
# repos in /tmp — no docker required.
#
# Each broken state is CONSTRUCTED by editing the two path files a linked
# worktree depends on, which is what a cross-namespace `git worktree add`
# produces: the admin dir's `gitdir` file (naming the working tree's .git) and
# the working tree's `.git` file (naming the admin dir). Asserting on a state we
# built by hand only proves the classifier reads those files; the repair test is
# what proves the classification is actionable.
#
# Mutation recorded per ADR-0005: replacing the reachability test in
# dev/worktree-doctor
#     if [ -n "$_recorded" ] && [ -e "$_recorded" ] && git -C "$_wt" rev-parse ...
# with a bare
#     if [ -n "$_recorded" ]
# (i.e. trusting the recorded path, which is what consulting git's own
# `prunable` flag amounts to) turns this suite red at 7 assertions, including
# the locked-worktree case that flag cannot see.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DOCTOR="$DEV_BASE/dev/worktree-doctor"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

MAIN="$(new_repo "$TMPDIR_ROOT/mainrepo")"
# Exit-code-neutral so `out="$(run_doctor)"` cannot kill the suite under set -e:
# a non-zero exit is the doctor's normal report that problems exist. Exit codes
# are asserted separately, via assert_true/assert_false on a direct invocation.
run_doctor() { (cd "$MAIN" && "$DOCTOR" "$@" 2>&1) || true; }

# The tally line. Negative assertions go through this rather than the whole
# output: every state name appears in the tally ("0 orphaned"), so asserting
# NOT-contains against the full text would pass or fail for the wrong reason.
summary_of() { printf '%s\n' "$1" | grep -E '^[0-9]+ healthy'; }

# ---------- test: a healthy worktree ----------
echo "--- healthy ---"
git -C "$MAIN" worktree add -q --detach "$MAIN/.claude/worktrees/wt1" HEAD
out="$(run_doctor)"
assert_contains "healthy worktree is reported healthy" "healthy" "$out"
assert_contains "healthy worktree names the path" "$MAIN/.claude/worktrees/wt1" "$out"
assert_contains "no orphan reported" "0 orphaned" "$(summary_of "$out")"
assert_true "exits 0 when everything is healthy" bash -c "cd '$MAIN' && '$DOCTOR' >/dev/null 2>&1"

# ---------- test: mismatched (cross-namespace paths), then repaired ----------
# Both halves rewritten to a namespace that does not exist here — precisely the
# state a container-side `git worktree add` leaves behind on the host.
echo "--- mismatched + repair ---"
ADMIN="$MAIN/.git/worktrees/wt1"
FAKE="/nonexistent-namespace/src"
printf '%s\n' "$FAKE/.claude/worktrees/wt1/.git" >"$ADMIN/gitdir"
printf 'gitdir: %s\n' "$FAKE/.git/worktrees/wt1" >"$MAIN/.claude/worktrees/wt1/.git"

out="$(run_doctor)"
assert_contains "unreachable paths report as mismatched" "mismatched" "$out"
assert_contains "reports the recorded path" "$FAKE/.claude/worktrees/wt1/.git" "$out"
assert_contains "a mismatch is not an orphan" "0 orphaned" "$(summary_of "$out")"
assert_false "exits non-zero while a problem remains" \
    bash -c "cd '$MAIN' && '$DOCTOR' >/dev/null 2>&1"

# The load-bearing assertion: the state the doctor calls "repairable" really is.
out="$(WORKTREE_DOCTOR_IN_CONTAINER=0 run_doctor --repair)"
assert_contains "repair reports the worktree it fixed" "wt1" "$out"
out="$(run_doctor)"
assert_contains "repaired worktree is healthy again" "healthy" "$out"
assert_contains "no mismatch remains after repair" "0 mismatched" "$(summary_of "$out")"
assert_true "the repaired worktree actually works" \
    bash -c "git -C '$MAIN/.claude/worktrees/wt1' rev-parse --git-dir >/dev/null"

# ---------- test: --repair refuses inside a container ----------
# Repair records the canonical path of wherever it runs, so in a container it
# re-records a container path — the very form the host cannot resolve.
echo "--- repair refusal inside a container ---"
printf '%s\n' "$FAKE/.claude/worktrees/wt1/.git" >"$ADMIN/gitdir"
printf 'gitdir: %s\n' "$FAKE/.git/worktrees/wt1" >"$MAIN/.claude/worktrees/wt1/.git"
out="$(WORKTREE_DOCTOR_IN_CONTAINER=1 run_doctor --repair || true)"
assert_contains "refuses to repair in a container" "refusing to --repair inside a container" "$out"
assert_false "refusal exits non-zero" \
    bash -c "cd '$MAIN' && WORKTREE_DOCTOR_IN_CONTAINER=1 '$DOCTOR' --repair >/dev/null 2>&1"
assert_contains "the mismatch survives the refusal" "$FAKE" "$(run_doctor)"
out="$(WORKTREE_DOCTOR_IN_CONTAINER=1 run_doctor --repair --force)"
assert_contains "--force overrides the refusal" "repairing" "$out"

# ---------- test: orphaned (admin dir gone) ----------
echo "--- orphaned ---"
git -C "$MAIN" worktree add -q --detach "$MAIN/.claude/worktrees/wt2" HEAD
rm -rf "$MAIN/.git/worktrees/wt2"
out="$(run_doctor)"
assert_contains "a working tree with no admin dir is orphaned" "orphaned" "$out"
assert_contains "orphan names the path" "$MAIN/.claude/worktrees/wt2" "$out"
assert_contains "points at the audit tool" "worktree-audit" "$out"
# An orphan is not repairable: HEAD, index and refs went with the admin dir.
out="$(WORKTREE_DOCTOR_IN_CONTAINER=0 run_doctor --repair)"
assert_contains "repair does not claim to fix orphans" "1 orphaned" "$(summary_of "$out")"
rm -rf "$MAIN/.claude/worktrees/wt2"

# ---------- test: stale-admin (working tree gone) ----------
echo "--- stale-admin ---"
git -C "$MAIN" worktree add -q --detach "$MAIN/.claude/worktrees/wt3" HEAD
rm -rf "$MAIN/.claude/worktrees/wt3"
out="$(run_doctor)"
assert_contains "an admin dir with no working tree is stale" "stale-admin" "$out"
assert_contains "stale entry names the admin dir" "wt3" "$out"
assert_contains "points at git worktree prune" "git worktree prune" "$out"
git -C "$MAIN" worktree prune
assert_contains "prune clears the stale entry" "0 stale-admin" "$(summary_of "$(run_doctor)")"

# ---------- test: a locked, broken worktree is still reported ----------
# git suppresses `prunable` for locked worktrees, and dev/hooks/post-checkout
# locks every worktree on creation — so trusting that flag would report the
# common case as clean. The doctor tests reachability itself.
echo "--- locked worktrees are not exempt ---"
git -C "$MAIN" worktree add -q --detach "$MAIN/.claude/worktrees/wt4" HEAD
git -C "$MAIN" worktree lock "$MAIN/.claude/worktrees/wt4"
printf '%s\n' "$FAKE/.claude/worktrees/wt4/.git" >"$MAIN/.git/worktrees/wt4/gitdir"
printf 'gitdir: %s\n' "$FAKE/.git/worktrees/wt4" >"$MAIN/.claude/worktrees/wt4/.git"
assert_not_contains "git itself calls the locked break prunable" \
    "prunable" "$(git -C "$MAIN" worktree list --porcelain)"
assert_contains "the doctor still reports it" "mismatched" "$(run_doctor)"
git -C "$MAIN" worktree unlock "$MAIN/.claude/worktrees/wt4" 2>/dev/null || true
rm -rf "$MAIN/.claude/worktrees/wt4" "$MAIN/.git/worktrees/wt4"

# ---------- test: another repo's worktrees are not this repo's orphans ----------
# Sibling directories are shared ground: every repo checked out beside this one
# puts its worktrees there. Attributing a foreign broken worktree to this repo
# would send someone to delete another project's work.
echo "--- attribution across repos ---"
OTHER="$(new_repo "$TMPDIR_ROOT/otherrepo")"
git -C "$OTHER" worktree add -q --detach "$TMPDIR_ROOT/otherrepo-sibling" HEAD
rm -rf "$OTHER/.git/worktrees/otherrepo-sibling"   # orphan it, in the OTHER repo
out="$(run_doctor)"
assert_not_contains "foreign orphan is not attributed to this repo" \
    "otherrepo-sibling" "$out"
out="$(cd "$OTHER" && "$DOCTOR" 2>&1 || true)"
assert_contains "the owning repo does report it" "otherrepo-sibling" "$out"

# ---------- test: this repo's own orphaned sibling IS attributed ----------
# Same location, but the recorded admin path names this repo — that is the proof
# the attribution rule looks for.
echo "--- attribution of an own sibling ---"
git -C "$MAIN" worktree add -q --detach "$TMPDIR_ROOT/mainrepo-sibling" HEAD
rm -rf "$MAIN/.git/worktrees/mainrepo-sibling"
assert_contains "own orphaned sibling is reported" "mainrepo-sibling" "$(run_doctor)"

finish
