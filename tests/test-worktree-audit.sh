#!/usr/bin/env bash
# Tests for dev/worktree-audit: the content-presence gate that has to be right
# before anything deletes an orphaned worktree. Runs against a disposable git
# repo in /tmp — no docker required.
#
# The property under test is not "the tree looks clean" but "every byte here is
# already in the object database". The two tests that matter are the pair that
# distinguishes content-matching from path-matching: a file whose path is gone
# upstream still passes if its content was ever committed, and a file whose path
# is familiar still fails if its bytes are new.
#
# Mutation recorded per ADR-0005: replacing the hash-object/cat-file presence
# check in dev/worktree-audit with a path check
#     git -C "$_root" ls-files --error-unmatch "${_f#"$_root"/}" || _missing+=(...)
# turns exactly one assertion red — "committed bytes at a novel path still
# pass". That single failure IS the invariant: a path-based audit would refuse
# to delete an orphan whose only sin is that the work moved upstream, and would
# have no answer at all for an orphan with no HEAD to resolve paths against.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
AUDIT="$DEV_BASE/dev/worktree-audit"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

MAIN="$(new_repo "$TMPDIR_ROOT/mainrepo")"
printf 'committed content\n' >"$MAIN/tracked.txt"
git -C "$MAIN" add tracked.txt
git -C "$MAIN" commit -q -m "add tracked.txt"

WT="$MAIN/.claude/worktrees/wt1"
git -C "$MAIN" worktree add -q --detach "$WT" HEAD

# Exit-code-neutral capture: a non-zero exit is the tool's verdict, not a suite
# error. Exit codes are asserted separately on direct invocations.
run_audit() { (cd "$MAIN" && "$AUDIT" "$@" 2>&1) || true; }

# ---------- test: an untouched worktree is clean ----------
# Its tracked files are exactly the committed blobs, and its own .git file — the
# one thing guaranteed never to be a tracked blob — must not count against it.
echo "--- clean worktree ---"
out="$(run_audit "$WT")"
assert_contains "clean worktree is safe to delete" "SAFE to delete" "$out"
assert_contains "reports zero missing" "0 not in git" "$out"
assert_true "exits 0 when clean" bash -c "cd '$MAIN' && '$AUDIT' '$WT' >/dev/null 2>&1"

# ---------- test: content is matched by hash, not by path ----------
# The whole point. A file at a path that exists nowhere upstream still passes
# when its bytes were committed at some point — that is what makes a clean audit
# a real safety statement about an orphan whose branch is unknowable.
echo "--- content match, novel path ---"
mkdir -p "$WT/never/seen/before"
cp "$MAIN/tracked.txt" "$WT/never/seen/before/renamed.txt"
out="$(run_audit "$WT")"
assert_contains "committed bytes at a novel path still pass" "SAFE to delete" "$out"
rm -rf "$WT/never"

# ---------- test: novel content fails, at a familiar path ----------
echo "--- novel content ---"
printf 'never committed anywhere\n' >"$WT/tracked.txt.new"
out="$(run_audit "$WT")"
assert_contains "novel content is reported" "not in git: tracked.txt.new" "$out"
assert_contains "novel content blocks deletion" "NOT safe to delete" "$out"
assert_false "exits non-zero when content is unaccounted for" \
    bash -c "cd '$MAIN' && '$AUDIT' '$WT' >/dev/null 2>&1"

# ---------- test: --delete refuses a tree it could not account for ----------
echo "--- --delete refuses unclean ---"
out="$(run_audit --delete "$WT")"
assert_contains "refuses to delete" "NOT safe to delete" "$out"
assert_true "the worktree still exists" test -d "$WT"
assert_not_contains "does not claim to have deleted" "deleted" "$out"
rm -f "$WT/tracked.txt.new"

# ---------- test: regenerable trees are skipped ----------
# Novel bytes inside a build/cache dir must not block deletion — that is where
# essentially all the disk sits, and it is reproducible by definition.
echo "--- build output is skipped ---"
mkdir -p "$WT/node_modules/pkg" "$WT/target/debug" "$WT/.pnpm-store/v10"
printf 'novel dep bytes\n' >"$WT/node_modules/pkg/index.js"
printf 'novel build bytes\n' >"$WT/target/debug/binary"
printf 'novel store bytes\n' >"$WT/.pnpm-store/v10/entry.json"
printf 'novel pyc bytes\n' >"$WT/stale.pyc"
out="$(run_audit "$WT")"
assert_contains "build output does not block deletion" "SAFE to delete" "$out"
assert_not_contains "node_modules is not listed" "node_modules" "$out"
assert_not_contains "target is not listed" "target/debug" "$out"
assert_not_contains "pyc is not listed" "stale.pyc" "$out"

# ---------- test: symlinks are not audited ----------
# Git stores a symlink as a blob of its target path, so hashing through the link
# would report false uniqueness. Documented limitation, asserted so it stays
# deliberate.
echo "--- symlinks are skipped ---"
printf 'outside the tree\n' >"$TMPDIR_ROOT/outside.txt"
ln -s "$TMPDIR_ROOT/outside.txt" "$WT/link-to-outside"
out="$(run_audit "$WT")"
assert_contains "a symlink to novel content does not block deletion" "SAFE to delete" "$out"
rm -f "$WT/link-to-outside"

# ---------- test: a live process blocks deletion ----------
# Deleting a tree someone is working in is silently destructive, and a content
# audit alone would call it safe.
echo "--- live process blocks deletion ---"
( cd "$WT" && exec sleep 30 ) &
_live_pid=$!
# Wait for the child's cwd to be observable rather than racing it.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(readlink "/proc/$_live_pid/cwd" 2>/dev/null)" = "$WT" ] && break
    sleep 0.1
done
out="$(run_audit "$WT")"
assert_contains "live process is reported" "live pid:" "$out"
assert_contains "live process blocks deletion" "NOT safe to delete" "$out"
out="$(run_audit --delete "$WT")"
assert_true "worktree survives --delete while in use" test -d "$WT"
kill "$_live_pid" 2>/dev/null || true
wait "$_live_pid" 2>/dev/null || true

# ---------- test: the listing is capped ----------
echo "--- listing cap ---"
mkdir -p "$WT/many"
for i in $(seq 1 25); do printf 'novel %s\n' "$i" >"$WT/many/f$i.txt"; done
out="$(cd "$MAIN" && WORKTREE_AUDIT_LIST_CAP=5 "$AUDIT" "$WT" 2>&1 || true)"
assert_contains "caps the listing" "and 20 more" "$out"
assert_eq "prints exactly the cap" "5" "$(printf '%s\n' "$out" | grep -c 'not in git:')"
rm -rf "$WT/many"

# ---------- test: --delete removes a clean tree ----------
# Left last: it destroys the fixture.
echo "--- --delete removes a clean tree ---"
out="$(run_audit --delete "$WT")"
assert_contains "reports the deletion" "deleted" "$out"
assert_false "the worktree is gone" test -d "$WT"

# ---------- test: a non-directory argument is an error ----------
echo "--- bad arguments ---"
out="$(run_audit "$TMPDIR_ROOT/does-not-exist")"
assert_contains "missing path is an error" "not a directory" "$out"
out="$(cd "$MAIN" && "$AUDIT" 2>&1 || true)"
assert_contains "no paths is an error" "no paths given" "$out"

finish
