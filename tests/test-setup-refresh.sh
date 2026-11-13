#!/usr/bin/env bash
# Tests for `setup-worktree --refresh`: copies are skip-if-present, so a
# worktree keeps a stale copy of anything the main checkout later changes;
# --refresh re-copies the ones that differ, backing the old file up under the
# worktree's git admin dir. Runs against a disposable git repo — no docker.
#
# Verified (ADR-0005 §2), fresh copy of the tree per mutation, 2026-11-13
# (37 assertions):
#   FORM-ONLY (must stay green, same assertion count):
#     a. refresh_copy: the directory early return rewritten as
#        `if is_real_dir ... || ...; then return 0; fi` -> green, 37.
#   SEMANTIC (must go red), each written in a form the author did not write:
#     b. refresh_copy: comment out the `same_copy ... && return 0` line -> red
#        (unchanged .env.local reported and backed up; second refresh reports).
#     c. comment out the `-ef` early return -> red (a link into main's own
#        file is replaced by a snapshot).
#     d. is_real_dir() reduced to `[ -d "$1" ]` -> red (a symlink-to-directory
#        copy is never retargeted).
#     e. back up first, then `cp -P` straight onto the destination -> red (an
#        unreadable source leaves the work tree with no copy).
#     f. the final `exit 1` turned into `: exit 1` -> red; its twin, `-ge 0`
#        (every refresh refuses), aborts the suite at the first --refresh.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SETUP="$DEV_BASE/dev/setup-worktree"
CLEANUP="$DEV_BASE/dev/cleanup-worktree"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# ---------- setup: main checkout with an overlay copy list ----------
# The overlay lives in main's .devcontainer/, which resolve_project_dir prefers.
MAIN_TREE="$(new_repo "$TMPDIR_ROOT/fakerepo")"
printf 'tracked\n' > "$MAIN_TREE/tracked.env"
git -C "$MAIN_TREE" add tracked.env
git -C "$MAIN_TREE" commit -qm "track a file the copy list also names"
mkdir -p "$MAIN_TREE/.devcontainer" "$MAIN_TREE/.envrcs"
printf '%s\n' '.envrcs/.envrc.user' '.envrcs/.env.*' '.envrcs/link' '.envrcs/dlink' \
    '.envrcs/.envrc.mine' 'tracked.env' \
    > "$MAIN_TREE/.devcontainer/worktree-copies.txt"
printf '.gitignore\n.claude/\n.devcontainer/\n.envrcs/\n' > "$MAIN_TREE/.gitignore"
printf 'source_env one\n' > "$MAIN_TREE/.envrcs/.envrc.user"
printf 'SERVER=old.example\n' > "$MAIN_TREE/.envrcs/.env.local"
printf 'TOKEN=placeholder-secret-v1\n' > "$MAIN_TREE/.envrcs/.env.secrets"
ln -s target-a "$MAIN_TREE/.envrcs/link"
mkdir "$MAIN_TREE/.envrcs/dir-a" "$MAIN_TREE/.envrcs/dir-b"
ln -s dir-a "$MAIN_TREE/.envrcs/dlink"
printf 'mine\n' > "$MAIN_TREE/.envrcs/.envrc.mine"

WT="$TMPDIR_ROOT/wt"
git -C "$MAIN_TREE" worktree add -q "$WT" -b wt main
(cd "$WT" && "$SETUP") >/dev/null
assert_files_eq "initial setup copies .envrc.user" \
    "$MAIN_TREE/.envrcs/.envrc.user" "$WT/.envrcs/.envrc.user"

# Main moves on after the worktree was made.
printf 'source_env one\nsource_env two\n' > "$MAIN_TREE/.envrcs/.envrc.user"
printf 'TOKEN=placeholder-secret-v2\n' > "$MAIN_TREE/.envrcs/.env.secrets"
ln -sfn target-b "$MAIN_TREE/.envrcs/link"
ln -sfn dir-b "$MAIN_TREE/.envrcs/dlink"
# The developer swapped this copy for a live link to main's file.
ln -sfn "$MAIN_TREE/.envrcs/.envrc.mine" "$WT/.envrcs/.envrc.mine"
printf 'tracked, edited in main\n' > "$MAIN_TREE/tracked.env"
printf '.gitignore\n.claude/\n.devcontainer/\n.envrcs/\n*.log\n' > "$MAIN_TREE/.gitignore"

# ---------- test: without --refresh nothing existing is touched ----------
echo "--- plain run: existing copies left stale ---"
(cd "$WT" && "$SETUP") >/dev/null
assert_eq "stale .envrc.user kept" "source_env one" "$(cat "$WT/.envrcs/.envrc.user")"
assert_eq "stale secret kept" "TOKEN=placeholder-secret-v1" "$(cat "$WT/.envrcs/.env.secrets")"
assert_eq "stale symlink target kept" "target-a" "$(readlink "$WT/.envrcs/link")"
assert_false "no backup dir without --refresh" \
    test -e "$(git -C "$WT" rev-parse --absolute-git-dir)/setup-worktree-backup"

# ---------- test: --refresh replaces what differs, backs it up ----------
echo "--- --refresh: differing copies replaced ---"
out="$(cd "$WT" && "$SETUP" --refresh 2>&1)"
assert_files_eq ".envrc.user refreshed" \
    "$MAIN_TREE/.envrcs/.envrc.user" "$WT/.envrcs/.envrc.user"
assert_files_eq "secret refreshed" \
    "$MAIN_TREE/.envrcs/.env.secrets" "$WT/.envrcs/.env.secrets"
assert_true "symlink copy stays a symlink" test -L "$WT/.envrcs/link"
assert_eq "symlink copy retargeted" "target-b" "$(readlink "$WT/.envrcs/link")"
assert_eq "symlink-to-directory copy retargeted" "dir-b" "$(readlink "$WT/.envrcs/dlink")"
assert_true "link into main's own file left a link" test -L "$WT/.envrcs/.envrc.mine"
assert_not_contains "link into main's own file not reported" ".envrc.mine" "$out"
assert_files_eq ".gitignore refreshed" "$MAIN_TREE/.gitignore" "$WT/.gitignore"
assert_eq "tracked path never overwritten" "tracked" "$(cat "$WT/tracked.env")"
assert_contains "names the refreshed file" "refreshed .envrcs/.envrc.user" "$out"
assert_not_contains "unchanged .env.local not reported" ".env.local" "$out"
assert_not_contains "never prints old secret content" "placeholder-secret-v1" "$out"
assert_not_contains "never prints new secret content" "placeholder-secret-v2" "$out"

backup_root="$(git -C "$WT" rev-parse --absolute-git-dir)/setup-worktree-backup"
# nullglob: an unmatched glob would otherwise count as one backup set.
shopt -s nullglob
backups=("$backup_root"/*)
assert_eq "one backup set per run" "1" "${#backups[@]}"
assert_eq "old .envrc.user backed up" "source_env one" \
    "$(cat "${backups[0]}/.envrcs/.envrc.user")"
assert_eq "old secret backed up" "TOKEN=placeholder-secret-v1" \
    "$(cat "${backups[0]}/.envrcs/.env.secrets")"
assert_false "unchanged file not backed up" test -e "${backups[0]}/.envrcs/.env.local"
assert_true "worktree status stays clean (backups outside the work tree)" \
    test -z "$(git -C "$WT" status --porcelain --untracked-files=all)"

echo "--- --refresh: idempotent ---"
out="$(cd "$WT" && "$SETUP" --refresh 2>&1)"
assert_not_contains "second refresh reports nothing" "refreshed" "$out"
backups=("$backup_root"/*)
assert_eq "second refresh makes no new backup set" "1" "${#backups[@]}"

echo "--- --refresh: unreadable source keeps the existing copy ---"
printf 'TOKEN=placeholder-secret-v3\n' > "$MAIN_TREE/.envrcs/.env.secrets"
chmod 000 "$MAIN_TREE/.envrcs/.env.secrets"
if [ -r "$MAIN_TREE/.envrcs/.env.secrets" ]; then
    echo "  SKIP: chmod 000 does not stop reads here (root?)"
else
    rc=0
    out="$(cd "$WT" && "$SETUP" --refresh 2>&1)" || rc=$?
    assert_eq "unrefreshable copy exits 1" "1" "$rc"
    assert_eq "existing copy kept in the work tree" "TOKEN=placeholder-secret-v2" \
        "$(cat "$WT/.envrcs/.env.secrets")"
    assert_contains "names the copy it kept" "could not refresh .envrcs/.env.secrets" "$out"
    assert_false "no partial copy left beside it" \
        test -e "$WT/.envrcs/.env.secrets.setup-worktree-refresh"
    backups=("$backup_root"/*)
    assert_eq "failed refresh makes no backup set" "1" "${#backups[@]}"
    # The run continued past the copy loop: its last entries are written.
    assert_contains "manifest still complete" "$(printf 'symlink\t.claude/container-sessions')" \
        "$(cat "$WT/.envrcs/.worktree-manifest")"
fi
chmod 600 "$MAIN_TREE/.envrcs/.env.secrets"

# ---------- test: argument handling ----------
echo "--- arguments ---"
assert_eq "unknown argument exits 2" "2" \
    "$(cd "$WT" && { "$SETUP" --bogus >/dev/null 2>&1; echo $?; })"
assert_contains "--help prints usage" "Usage: setup-worktree" \
    "$(cd "$WT" && "$SETUP" --help)"

# ---------- test: cleanup-worktree round trip ----------
echo "--- cleanup-worktree after --refresh ---"
assert_true "cleanup exits 0" \
    bash -c '(cd "$1" && "$2" "$3") >/dev/null 2>&1' _ "$MAIN_TREE" "$CLEANUP" "$WT"
assert_false "worktree removed" test -d "$WT"
assert_false "backups removed with the admin dir" test -e "$backup_root"
assert_eq "main's copies untouched by cleanup" "TOKEN=placeholder-secret-v3" \
    "$(cat "$MAIN_TREE/.envrcs/.env.secrets")"

finish
