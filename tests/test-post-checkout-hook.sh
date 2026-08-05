#!/usr/bin/env bash
# Tests for dev/hooks/post-checkout: the auto-lock, and the host-form path
# rewrite that makes a container-created worktree resolvable from the host.
# Runs against disposable git repos in /tmp — no docker required.
#
# HOW THE TWO NAMESPACES ARE SIMULATED. In reality the container reaches one
# tree by two PHYSICAL paths (two bind mounts of the same host dir), and git
# reports whichever is canonical. A test cannot create a bind mount without
# root, so here the second path is a SYMLINK to the first: git reports the real
# path and the hook rewrites to the alias. That inverts which side is canonical
# relative to production, which the hook cannot observe — it only ever does
# prefix-match, substitute, check-it-resolves, write. What the inversion does
# cost is coverage of "git reported the alias", which cannot happen: git always
# reports the physical path. That is also why the doctor's container probe is
# /.dockerenv rather than a readlink comparison.
#
# Mutation recorded per ADR-0005: dropping the reachability precondition
#     [ -e "$_host_wt/.git" ] && [ -d "$_host_common" ] || exit 0
# turns the "declines when the host form is not visible" assertions red — the
# hook then writes a path that resolves in NEITHER namespace, which is strictly
# worse than the breakage it exists to prevent, and leaves nothing for
# worktree-doctor --repair to work from.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
HOOK="$DEV_BASE/dev/hooks/post-checkout"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# A repo with the hook installed, reachable as both $1 (physical, what git
# reports) and an alias symlink standing in for the host-form path.
new_hooked_repo() {
    local name="$1" repo
    repo="$(new_repo "$TMPDIR_ROOT/$name")"
    mkdir -p "$repo/.git/hooks"
    ln -sf "$HOOK" "$repo/.git/hooks/post-checkout"
    printf '%s\n' "$repo"
}

recorded_gitdir() { cat "$1/.git/worktrees/$2/gitdir"; }
recorded_dotgit()  { sed -n 's/^gitdir: //p' "$1/.git"; }

# ---------- test: on the host, nothing is rewritten ----------
# The recorded paths are already the host's. The lock must still happen.
echo "--- host: lock only, no rewrite ---"
REPO="$(new_hooked_repo hostrepo)"
DEV_HOOK_IN_CONTAINER=0 git -C "$REPO" worktree add -q --detach "$REPO/wt1" HEAD
assert_eq "gitdir keeps the real path" \
    "$REPO/wt1/.git" "$(recorded_gitdir "$REPO" wt1)"
assert_eq "worktree .git keeps the real admin path" \
    "$REPO/.git/worktrees/wt1" "$(recorded_dotgit "$REPO/wt1")"
assert_true "worktree resolves" \
    bash -c "git -C '$REPO/wt1' rev-parse --git-dir >/dev/null"
assert_true "worktree is locked" test -f "$REPO/.git/worktrees/wt1/locked"

# ---------- test: in a container, workspace-form paths are rewritten ----------
# The main case: a worktree created under the workspace mount. Both recorded
# halves must come out in host form, and the worktree must still work here.
echo "--- container: workspace form -> host form ---"
REPO="$(new_hooked_repo wsrepo)"
ALIAS="$TMPDIR_ROOT/ws-alias"
ln -s "$REPO" "$ALIAS"
mkdir -p "$REPO/.claude/worktrees"
env DEV_HOOK_IN_CONTAINER=1 \
    DEV_CONTAINER_WORKSPACE="$REPO" \
    DEV_WORKSPACE="$ALIAS" \
    git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/wt1" HEAD
assert_eq "gitdir is rewritten to host form" \
    "$ALIAS/.claude/worktrees/wt1/.git" "$(recorded_gitdir "$REPO" wt1)"
assert_eq "worktree .git is rewritten to host form" \
    "$ALIAS/.git/worktrees/wt1" "$(recorded_dotgit "$REPO/.claude/worktrees/wt1")"
assert_true "the rewritten worktree still resolves" \
    bash -c "git -C '$REPO/.claude/worktrees/wt1' rev-parse --git-dir >/dev/null"
assert_true "it resolves via the host-form path too" \
    bash -c "git -C '$ALIAS/.claude/worktrees/wt1' rev-parse --git-dir >/dev/null"
assert_true "still locked" test -f "$REPO/.git/worktrees/wt1/locked"
# The payoff: git no longer considers it prunable, so a prune in either
# namespace leaves it alone.
assert_not_contains "not prunable after the rewrite" \
    "prunable" "$(git -C "$REPO" worktree list --porcelain)"
assert_eq "prune leaves it alone" "" \
    "$(git -C "$REPO" worktree prune --dry-run --verbose 2>&1)"

# ---------- test: in a container, $HOME-form paths are rewritten ----------
# The other real form: created through the /home/<hostuser> alias, which git has
# already canonicalized to $HOME. The host home is found by locating the /home
# entry symlinked to ours, exactly as the Dockerfile sets it up.
echo "--- container: \$HOME form -> host form ---"
FAKE_HOME_ROOT="$TMPDIR_ROOT/home"
mkdir -p "$FAKE_HOME_ROOT/vscode"
# Absolute, mirroring the Dockerfile's `ln -s /home/vscode /home/$HOST_USER`.
ln -s "$FAKE_HOME_ROOT/vscode" "$FAKE_HOME_ROOT/dan"
REPO="$(new_hooked_repo home/vscode/homerepo)"
env DEV_HOOK_IN_CONTAINER=1 \
    DEV_CONTAINER_WORKSPACE="/workspaces/src-unused" \
    DEV_WORKSPACE="/unused" \
    DEV_HOOK_HOME_ROOT="$FAKE_HOME_ROOT" \
    HOME="$FAKE_HOME_ROOT/vscode" \
    git -C "$REPO" worktree add -q --detach "$REPO/wt1" HEAD
assert_eq "gitdir uses the host home prefix" \
    "$FAKE_HOME_ROOT/dan/homerepo/wt1/.git" "$(recorded_gitdir "$REPO" wt1)"
assert_eq "worktree .git uses the host home prefix" \
    "$FAKE_HOME_ROOT/dan/homerepo/.git/worktrees/wt1" "$(recorded_dotgit "$REPO/wt1")"
assert_true "resolves after the rewrite" \
    bash -c "git -C '$REPO/wt1' rev-parse --git-dir >/dev/null"

# A relative symlink must count the same: the comparison resolves both sides
# rather than matching readlink's raw text.
REL_HOME_ROOT="$TMPDIR_ROOT/relhome"
mkdir -p "$REL_HOME_ROOT/vscode"
ln -s vscode "$REL_HOME_ROOT/dan"
REPO="$(new_hooked_repo relhome/vscode/relrepo)"
env DEV_HOOK_IN_CONTAINER=1 \
    DEV_CONTAINER_WORKSPACE="/workspaces/src-unused" \
    DEV_WORKSPACE="/unused" \
    DEV_HOOK_HOME_ROOT="$REL_HOME_ROOT" \
    HOME="$REL_HOME_ROOT/vscode" \
    git -C "$REPO" worktree add -q --detach "$REPO/wt1" HEAD
assert_eq "a relative host-home symlink resolves the same" \
    "$REL_HOME_ROOT/dan/relrepo/wt1/.git" "$(recorded_gitdir "$REPO" wt1)"

# ---------- test: declines when the host form is not visible ----------
# The safety property. A path that resolves in neither namespace would be worse
# than the breakage: worktree-doctor could not even classify it as repairable.
echo "--- container: declines an unreachable host form ---"
REPO="$(new_hooked_repo unreachable)"
env DEV_HOOK_IN_CONTAINER=1 \
    DEV_CONTAINER_WORKSPACE="$REPO" \
    DEV_WORKSPACE="/nonexistent-host-form" \
    git -C "$REPO" worktree add -q --detach "$REPO/wt1" HEAD
assert_eq "gitdir is left in container form" \
    "$REPO/wt1/.git" "$(recorded_gitdir "$REPO" wt1)"
assert_eq "worktree .git is left in container form" \
    "$REPO/.git/worktrees/wt1" "$(recorded_dotgit "$REPO/wt1")"
assert_true "the worktree still works" \
    bash -c "git -C '$REPO/wt1' rev-parse --git-dir >/dev/null"
assert_true "and is still locked" test -f "$REPO/.git/worktrees/wt1/locked"

# ---------- test: declines without the host-side env ----------
# dev/devcontainer supplies DEV_WORKSPACE / DEV_CONTAINER_WORKSPACE. A container
# started another way has nothing to translate to, and must not guess.
echo "--- container: declines with no host-side env ---"
REPO="$(new_hooked_repo noenv)"
env -u DEV_WORKSPACE -u DEV_CONTAINER_WORKSPACE DEV_HOOK_IN_CONTAINER=1 \
    git -C "$REPO" worktree add -q --detach "$REPO/wt1" HEAD
assert_eq "paths untouched without env" \
    "$REPO/wt1/.git" "$(recorded_gitdir "$REPO" wt1)"
assert_true "locked anyway" test -f "$REPO/.git/worktrees/wt1/locked"

# ---------- test: the main checkout is never touched ----------
# git_dir == git_common there; rewriting would corrupt a normal clone.
echo "--- main checkout is not a worktree ---"
REPO="$(new_hooked_repo mainonly)"
env DEV_HOOK_IN_CONTAINER=1 \
    DEV_CONTAINER_WORKSPACE="$REPO" DEV_WORKSPACE="$TMPDIR_ROOT/mainonly-alias" \
    git -C "$REPO" checkout -q -b other 2>/dev/null
assert_true ".git is still a directory" test -d "$REPO/.git"
assert_false "no gitdir file was written at the top level" test -f "$REPO/.git/gitdir"
assert_true "the repo still works" \
    bash -c "git -C '$REPO' rev-parse --git-dir >/dev/null"

# ---------- test: a file checkout is ignored ----------
# $3 = 0 for file checkouts; only branch checkouts create worktrees.
echo "--- file checkout is ignored ---"
out="$(cd "$REPO" && DEV_HOOK_IN_CONTAINER=1 bash "$HOOK" HEAD HEAD 0 2>&1)"
assert_eq "hook is a no-op for file checkouts" "" "$out"

finish
