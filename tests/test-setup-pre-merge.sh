#!/usr/bin/env bash
# Tests for `setup-worktree --pre-merge <ref>`: once upstream starts tracking a
# path a worktree holds as a setup-worktree copy or symlink, `git merge` either
# refuses (path not ignored) or silently replaces it (path ignored). The step
# clears what the merge would recreate losslessly and backs up the rest.
# Runs against disposable git repos — no docker.
#
# Seen failing on 06b9444 (no --pre-merge): 19 of 45 red — (a)'s merge refused,
# (b)'s merge exited 0 with the local content gone and no backup.
#
# Verified (ADR-0005 §2), fresh copy of the tree per mutation, 2026-11-15
# (45 assertions):
#   FORM-ONLY (must stay green, same assertion count):
#     a. the copy loop's `is_tracked ... && continue` as an `if` -> green, 45.
#     b. the --pre-merge dedupe `[[ -v ... ]] && continue` as an `if` -> green, 45.
#   SEMANTIC (must go red), each written in a form the author did not write:
#     c. copy loop: `is_tracked` line commented out -> red (tracked copy recorded).
#     d. link_from_main: `is_tracked` line commented out -> red.
#     e. the `backup_path "$_blocker"` call commented out -> red (content lost).
#     f. the into-main prefix changed to `$main/nonexistent/` -> red (a link
#        into main is backed up, not removed).
#     g. merge_blocker: `[ -L ... ] ||` dropped -> red, and main's own
#        notes/todo is moved out through the symlinked directory.
#     h. the manifest filter's `&& continue 2` turned into `&& :` -> red.
#     i. same_as_ref forced to an unknown mode -> red (identical copy backed up).
#     j. merge_blocker's `is_tracked` line commented out -> red (a tracked
#        ancestor is backed up).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SETUP="$DEV_BASE/dev/setup-worktree"
CLEANUP="$DEV_BASE/dev/cleanup-worktree"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# Which paths are ignored decides which way git fails, so no host config may
# decide it: no global excludesFile, no system gitconfig.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# ---------- setup: a worktree cut before upstream tracks its copies ----------
MAIN_TREE="$(new_repo "$TMPDIR_ROOT/fakerepo")"
# A tracked file that upstream turns into a directory: that is git's to merge.
printf 'conf\n' > "$MAIN_TREE/kept.conf"
git -C "$MAIN_TREE" add kept.conf
git -C "$MAIN_TREE" commit -qm "track kept.conf"
mkdir -p "$MAIN_TREE/.devcontainer" "$MAIN_TREE/.envrcs" "$MAIN_TREE/notes"
printf '%s\n' '.envrcs/.env.*' '.envrcs/.envrc.user' '.envrcs/.envrc.mine' \
    > "$MAIN_TREE/.devcontainer/worktree-copies.txt"
printf '%s\n' '.envrcs/.envrc.user.kenn' 'notes' > "$MAIN_TREE/.envrcs/.worktree-symlinks"
# .envrc.user and .envrc.mine are ignored here; the others are not.
printf '%s\n' .gitignore .claude/ .devcontainer/ .envrcs/.worktree-manifest \
    .envrcs/.worktree-symlinks .envrcs/.envrc.user .envrcs/.envrc.mine \
    > "$MAIN_TREE/.gitignore"
printf 'SERVER=example.invalid\n' > "$MAIN_TREE/.envrcs/.env.local.template"
printf 'source_env main\n' > "$MAIN_TREE/.envrcs/.envrc.user"
printf 'mine\n' > "$MAIN_TREE/.envrcs/.envrc.mine"
printf 'use kenn\n' > "$MAIN_TREE/.envrcs/.envrc.user.kenn"
printf 'main notes\n' > "$MAIN_TREE/notes/todo"

# Two worktrees, one per case, so a refused merge in one cannot mask the other.
new_wt() {
    git -C "$MAIN_TREE" worktree add -q "$1" -b "$(basename "$1")" main
    (cd "$1" && "$SETUP") >/dev/null
}
WT_A="$TMPDIR_ROOT/wt-a"
WT_B="$TMPDIR_ROOT/wt-b"
new_wt "$WT_A"
new_wt "$WT_B"
# The developer's local edits, which upstream knows nothing about.
printf 'source_env main\nexport TOKEN=placeholder-local-secret\n' > "$WT_B/.envrcs/.envrc.user"
printf 'stray\n' > "$WT_B/.envrcs/.env.stray"

assert_true "precondition: identical copy is present" test -f "$WT_A/.envrcs/.env.local.template"
assert_true "precondition: symlink into main is present" test -L "$WT_A/.envrcs/.envrc.user.kenn"
assert_false "precondition: identical copy is not ignored" \
    git -C "$WT_A" check-ignore -q .envrcs/.env.local.template
assert_false "precondition: symlink is not ignored" \
    git -C "$WT_A" check-ignore -q .envrcs/.envrc.user.kenn
assert_true "precondition: differing copy is ignored" \
    git -C "$WT_B" check-ignore -q .envrcs/.envrc.user

# upstream_branch <name> <path> <content> ... — a commit on top of main that
# starts tracking each path (content `--remove`: stops tracking it). Plumbing, so the main checkout's working files and
# index are never touched.
upstream_branch() {
    local name="$1" sha
    shift
    export GIT_INDEX_FILE="$TMPDIR_ROOT/$name.index"
    git -C "$MAIN_TREE" read-tree main
    while [ "$#" -gt 0 ]; do
        if [ "$2" = --remove ]; then
            git -C "$MAIN_TREE" update-index --force-remove -- "$1"
        else
            sha="$(printf '%s' "$2" | git -C "$MAIN_TREE" hash-object -w --stdin)"
            git -C "$MAIN_TREE" update-index --add --cacheinfo "100644,$sha,$1"
        fi
        shift 2
    done
    sha="$(git -C "$MAIN_TREE" write-tree)"
    unset GIT_INDEX_FILE
    git -C "$MAIN_TREE" update-ref "refs/heads/$name" \
        "$(git -C "$MAIN_TREE" commit-tree "$sha" -p main -m "track $name")"
}
upstream_branch up-a \
    .envrcs/.env.local.template $'SERVER=example.invalid\n' \
    .envrcs/.envrc.user.kenn $'use kenn\n' \
    notes/todo $'upstream notes\n' \
    kept.conf --remove \
    kept.conf/inner $'inner\n'
upstream_branch up-b \
    .envrcs/.envrc.user $'source_env upstream\n' \
    .envrcs/.envrc.mine $'upstream mine\n'

# pre_merge_then_merge <wt> <ref> — sets $out (the step's output) and $merge_rc.
pre_merge_then_merge() {
    local rc=0
    out="$(cd "$1" && "$SETUP" --pre-merge "$2" 2>&1)" || rc=$?
    assert_eq "--pre-merge $2 exits 0" "0" "$rc"
    merge_rc=0
    git -C "$1" merge -q --no-edit "$2" >/dev/null 2>&1 || merge_rc=$?
}

# ---------- (a) un-ignored identical copy + symlinks into main ----------
echo "--- (a) un-ignored: the merge goes through without hand deletion ---"
pre_merge_then_merge "$WT_A" up-a
assert_eq "merge succeeds without hand deletion" "0" "$merge_rc"
assert_eq "identical copy is upstream's file" "SERVER=example.invalid" \
    "$(cat "$WT_A/.envrcs/.env.local.template")"
assert_false "symlink replaced by the tracked file" test -L "$WT_A/.envrcs/.envrc.user.kenn"
assert_false "symlinked directory replaced by the tracked one" test -L "$WT_A/notes"
assert_not_contains "a tracked ancestor is left to git" "kept.conf" "$out"
assert_eq "and git merged it" "inner" "$(cat "$WT_A/kept.conf/inner")"
assert_eq "main's file behind the symlink untouched" "use kenn" \
    "$(cat "$MAIN_TREE/.envrcs/.envrc.user.kenn")"
assert_eq "main's file behind the symlinked directory untouched" "main notes" \
    "$(cat "$MAIN_TREE/notes/todo")"
assert_false "nothing lossless is backed up" \
    test -e "$(git -C "$WT_A" rev-parse --absolute-git-dir)/setup-worktree-backup"

# ---------- (b) ignored copy that differs from upstream's ----------
echo "--- (b) ignored: a differing copy survives the merge ---"
pre_merge_then_merge "$WT_B" up-b
assert_eq "merge succeeds" "0" "$merge_rc"
assert_eq "worktree takes upstream's file" "source_env upstream" "$(cat "$WT_B/.envrcs/.envrc.user")"
backup_root="$(git -C "$WT_B" rev-parse --absolute-git-dir)/setup-worktree-backup"
shopt -s nullglob
backups=("$backup_root"/*)
assert_eq "one backup set" "1" "${#backups[@]}"
_set="${backups[0]:-/nonexistent}"
assert_eq "local content backed up" \
    "$(printf 'source_env main\nexport TOKEN=placeholder-local-secret')" \
    "$(cat "$_set/.envrcs/.envrc.user" 2>/dev/null)"
assert_eq "an unedited copy that differs from upstream is backed up too" "mine" \
    "$(cat "$_set/.envrcs/.envrc.mine" 2>/dev/null)"
assert_contains "names the backed-up copy" "backed up .envrcs/.envrc.user" "$out"
assert_not_contains "never prints copy content" "placeholder-local-secret" "$out"
assert_eq "an untracked file upstream does not track is left alone" "stray" \
    "$(cat "$WT_B/.envrcs/.env.stray")"
assert_eq "main's copy source untouched" "source_env main" "$(cat "$MAIN_TREE/.envrcs/.envrc.user")"

# ---------- manifest: tracked paths are not setup-worktree's ----------
# cleanup-worktree restores a tracked `copy` entry with `git checkout --`, which
# would discard an edit to a file upstream now owns.
echo "--- manifest ---"
# manifest_has <wt> <path> — an entry for exactly <path>, whatever its action.
manifest_has() { cut -f2 "$1/.envrcs/.worktree-manifest" | grep -Fxq -- "$2"; }
for _p in .envrcs/.env.local.template .envrcs/.envrc.user.kenn notes; do
    assert_false "(a) manifest drops cleared $_p" manifest_has "$WT_A" "$_p"
done
for _p in .envrcs/.envrc.user .envrcs/.envrc.mine; do
    assert_false "(b) manifest drops cleared $_p" manifest_has "$WT_B" "$_p"
done
assert_true "(b) manifest keeps what was not cleared" manifest_has "$WT_B" .gitignore
(cd "$WT_A" && "$SETUP") >/dev/null
for _p in .envrcs/.env.local.template .envrcs/.envrc.user.kenn notes; do
    assert_false "a plain run records no tracked $_p" manifest_has "$WT_A" "$_p"
done
assert_true "a plain run still records an untracked copy" manifest_has "$WT_A" .envrcs/.envrc.user

echo "--- --pre-merge: idempotent, and refuses a bad ref ---"
out="$(cd "$WT_B" && "$SETUP" --pre-merge up-b 2>&1)" || true
assert_not_contains "nothing left to clear" "backed up" "$out"
backups=("$backup_root"/*)
assert_eq "no new backup set" "1" "${#backups[@]}"
rc=0
(cd "$WT_B" && "$SETUP" --pre-merge no-such-ref) >/dev/null 2>&1 || rc=$?
assert_eq "unknown ref exits 2" "2" "$rc"
rc=0
(cd "$WT_B" && "$SETUP" --pre-merge) >/dev/null 2>&1 || rc=$?
assert_eq "missing ref exits 2" "2" "$rc"

echo "--- cleanup-worktree after the merge ---"
cleanup_wt() { (cd "$MAIN_TREE" && "$CLEANUP" "$1") 2>&1; }
assert_true "cleanup wt-a exits 0" cleanup_wt "$WT_A"
# wt-b still holds the developer's own untracked file, which no step made.
rc=0
out="$(cleanup_wt "$WT_B")" || rc=$?
assert_eq "cleanup refuses over the developer's own file" "1" "$rc"
assert_contains "names it" ".envrcs/.env.stray" "$out"
rm "$WT_B/.envrcs/.env.stray"
assert_true "cleanup wt-b exits 0" cleanup_wt "$WT_B"
assert_eq "main's notes survive cleanup" "main notes" "$(cat "$MAIN_TREE/notes/todo")"
assert_eq "main's kenn file survives cleanup" "use kenn" "$(cat "$MAIN_TREE/.envrcs/.envrc.user.kenn")"

finish
