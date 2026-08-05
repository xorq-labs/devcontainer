#!/usr/bin/env bash
# Tests for hook distribution into consuming projects: copy_shared_hooks, the
# _DEVCONTAINER_SHARED_HOOKS allowlist, and the install_hooks base-dir argument.
# Runs against disposable git repos in /tmp — no docker required.
#
# The gap this closes: dev/devcontainer calls install_hooks for EVERY project,
# but symlink_hooks globs the consuming repo's own dev/hooks/* and is a silent
# no-op when that directory does not exist. A project like xorq-desktop, which
# carries no dev/hooks/, therefore got neither the worktree auto-lock nor the
# host-form path rewrite — which is why it accumulated far more orphaned
# worktrees than this repo did.
#
# Distribution is an ALLOWLIST, not the contents of dev/hooks/. Distributing
# dev/hooks/pre-commit would break committing in any project that has not adopted
# pre-commit: it ends in `exec pre-commit hook-impl
# --config=.pre-commit-config.yaml`, so in a project with no such config every
# commit dies. Reproduced by hand — that hook installed into a fresh repo with no
# config, then a commit attempt:
#
#   An unexpected error has occurred: TypeError: expected str, bytes or
#   os.PathLike object, not NoneType
#   $ git log --oneline
#   fatal: your current branch 'main' does not have any commits yet
#
# That reproduction is deliberately NOT a test case: it needs pre-commit on PATH,
# which the suite must not depend on. The guard is the allowlist assertion below —
# a hook reaches a consuming project only by being named there.
#
# Copies rather than symlinks, and the reason is testable only by reading it: a
# symlink would point into the devcontainer repo, which is NOT mounted inside a
# consuming project's container, so it would dangle exactly where the hook is
# needed. The suite asserts the artifact is a real file, not a link.
#
# Two mutations recorded per ADR-0005:
#   1. iterating "$base/dev/hooks/"* instead of _DEVCONTAINER_SHARED_HOOKS
#      reddens "a non-allowlisted hook is never distributed" — the
#      commit-breaking regression above.
#   2. dropping the not-ours guard
#          if [ -e "$target" ] && [ ! -L "$target" ] && ! hook_is_managed "$target"
#      reddens "a hand-written hook is left alone" — silently destroying a
#      developer's own hook, strictly worse than the missing-hook problem this
#      exists to solve.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck source=../lib/git.sh
. "$DEV_BASE/lib/git.sh"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# A stand-in devcontainer repo shipping an allowlisted hook (post-checkout) and a
# non-allowlisted one (pre-commit), so precedence and exclusion are both
# observable. A fixture rather than the real dev/hooks/ keeps the suite from
# failing whenever a hook's contents change.
BASE="$(new_repo "$TMPDIR_ROOT/basedc")"
mkdir -p "$BASE/dev/hooks"
printf '#!/usr/bin/env bash\necho base-post-checkout\n' >"$BASE/dev/hooks/post-checkout"
printf '#!/usr/bin/env bash\necho base-pre-commit\n' >"$BASE/dev/hooks/pre-commit"
chmod +x "$BASE/dev/hooks/"*

hooks_of() { printf '%s' "$(hooks_dir_for "$1")"; }

# ---------- test: the allowlist is what it claims to be ----------
# Read the array rather than restate it: a name added in production shows up here
# as a failure demanding the safety argument the comment asks for.
echo "--- the allowlist ---"
assert_eq "only post-checkout is distributed" \
    "post-checkout" "${_DEVCONTAINER_SHARED_HOOKS[*]}"

# ---------- test: a project with no dev/hooks/ gets the allowlisted hook ----------
echo "--- consuming project with no hooks of its own ---"
PROJ="$(new_repo "$TMPDIR_ROOT/consumer")"
(cd "$PROJ" && install_hooks "$BASE")
H="$(hooks_of "$PROJ")"
assert_true "post-checkout installed" test -f "$H/post-checkout"
assert_false "installed as a real file, not a symlink" test -L "$H/post-checkout"
assert_true "executable" test -x "$H/post-checkout"
assert_true "carries the provenance marker" hook_is_managed "$H/post-checkout"
assert_contains "records its source" "dev/hooks/post-checkout" "$(cat "$H/post-checkout")"
assert_contains "keeps the shebang first" "#!/usr/bin/env bash" "$(head -1 "$H/post-checkout")"
assert_contains "body is preserved" "base-post-checkout" "$(cat "$H/post-checkout")"

# The exclusion, on the same fixture: pre-commit is present in the base repo's
# dev/hooks/ and absent from the project, and must still not be installed.
assert_false "a non-allowlisted hook is never distributed" test -e "$H/pre-commit"

# ---------- test: an allowlisted name absent from dev/hooks/ is harmless ----------
echo "--- allowlisted but missing from the base repo ---"
BASE_EMPTY="$(new_repo "$TMPDIR_ROOT/basedc-empty")"
mkdir -p "$BASE_EMPTY/dev/hooks"
printf '#!/usr/bin/env bash\necho only-pre-commit\n' >"$BASE_EMPTY/dev/hooks/pre-commit"
chmod +x "$BASE_EMPTY/dev/hooks/pre-commit"
PROJ_E="$(new_repo "$TMPDIR_ROOT/consumer-empty")"
assert_true "install_hooks succeeds with nothing to copy" \
    bash -c "cd '$PROJ_E' && . '$DEV_BASE/lib/git.sh' && install_hooks '$BASE_EMPTY'"
assert_false "and installs nothing" test -e "$(hooks_of "$PROJ_E")/post-checkout"

# ---------- test: the installed hook actually fires ----------
echo "--- the installed hook actually fires ---"
PROJ2="$(new_repo "$TMPDIR_ROOT/consumer-live")"
BASE_REAL="$(new_repo "$TMPDIR_ROOT/basedc-real")"
mkdir -p "$BASE_REAL/dev/hooks"
cp "$DEV_BASE/dev/hooks/post-checkout" "$BASE_REAL/dev/hooks/post-checkout"
chmod +x "$BASE_REAL/dev/hooks/post-checkout"
(cd "$PROJ2" && install_hooks "$BASE_REAL")
DEV_HOOK_IN_CONTAINER=0 git -C "$PROJ2" worktree add -q --detach "$PROJ2/wt1" HEAD
assert_true "the real hook auto-locked a new worktree" \
    test -f "$PROJ2/.git/worktrees/wt1/locked"

# ---------- test: the project's own hook wins ----------
# A project shipping its own copy of an allowlisted hook keeps it, as a symlink it
# can edit in place — no copy lands on top.
echo "--- the project's own hook wins ---"
PROJ3="$(new_repo "$TMPDIR_ROOT/consumer-own")"
mkdir -p "$PROJ3/dev/hooks"
printf '#!/usr/bin/env bash\necho project-post-checkout\n' >"$PROJ3/dev/hooks/post-checkout"
chmod +x "$PROJ3/dev/hooks/post-checkout"
(cd "$PROJ3" && install_hooks "$BASE")
H3="$(hooks_of "$PROJ3")"
assert_true "own hook is a symlink" test -L "$H3/post-checkout"
assert_contains "own hook wins" "project-post-checkout" "$(cat "$H3/post-checkout")"
assert_false "not overwritten by a managed copy" hook_is_managed "$H3/post-checkout"

# A project's own non-allowlisted hook is still linked: symlink_hooks handles
# everything in the project's OWN dev/hooks/, and the allowlist governs only what
# this repo pushes outward.
echo "--- a project's own non-allowlisted hook is still linked ---"
PROJ3B="$(new_repo "$TMPDIR_ROOT/consumer-own-precommit")"
mkdir -p "$PROJ3B/dev/hooks"
printf '#!/usr/bin/env bash\necho project-pre-commit\n' >"$PROJ3B/dev/hooks/pre-commit"
chmod +x "$PROJ3B/dev/hooks/pre-commit"
(cd "$PROJ3B" && install_hooks "$BASE")
H3B="$(hooks_of "$PROJ3B")"
assert_true "its own pre-commit is linked" test -L "$H3B/pre-commit"
assert_contains "and is the project's version" "project-pre-commit" "$(cat "$H3B/pre-commit")"

# ---------- test: a hand-written hook is left alone ----------
# The destructive case. A real file that is not ours must survive untouched, even
# when it occupies an allowlisted name.
echo "--- a hand-written hook is left alone ---"
PROJ4="$(new_repo "$TMPDIR_ROOT/consumer-handwritten")"
H4="$(hooks_of "$PROJ4")"
mkdir -p "$H4"
printf '#!/usr/bin/env bash\necho MINE-DO-NOT-TOUCH\n' >"$H4/post-checkout"
chmod +x "$H4/post-checkout"
(cd "$PROJ4" && install_hooks "$BASE")
assert_contains "hand-written hook survives" "MINE-DO-NOT-TOUCH" "$(cat "$H4/post-checkout")"
assert_false "and is not marked as ours" hook_is_managed "$H4/post-checkout"

# ---------- test: a stale managed copy is refreshed ----------
# A copy goes stale as soon as the source moves, and a stale hook is worse than
# an obvious absence because it looks installed.
echo "--- a managed copy is refreshed, an unchanged one is left alone ---"
PROJ5="$(new_repo "$TMPDIR_ROOT/consumer-refresh")"
(cd "$PROJ5" && install_hooks "$BASE")
H5="$(hooks_of "$PROJ5")"
before="$(stat -c %Y "$H5/post-checkout")"
(cd "$PROJ5" && install_hooks "$BASE")
assert_eq "idempotent: unchanged content is not rewritten" \
    "$before" "$(stat -c %Y "$H5/post-checkout")"
printf '#!/usr/bin/env bash\necho base-post-checkout-v2\n' >"$BASE/dev/hooks/post-checkout"
(cd "$PROJ5" && install_hooks "$BASE")
assert_contains "a moved source is picked up" \
    "base-post-checkout-v2" "$(cat "$H5/post-checkout")"
assert_true "still marked as ours" hook_is_managed "$H5/post-checkout"

# ---------- test: no base dir means the old behavior ----------
# projects/devcontainer/setup-env.sh calls install_hooks with no argument from
# inside the container, where dev/hooks/ is not in the image to copy from.
echo "--- no base dir: unchanged behavior ---"
PROJ6="$(new_repo "$TMPDIR_ROOT/consumer-nobase")"
(cd "$PROJ6" && install_hooks)
H6="$(hooks_of "$PROJ6")"
assert_false "nothing is copied without a base dir" test -e "$H6/post-checkout"

# ---------- test: the devcontainer repo does not copy onto itself ----------
# base == root there; it gets symlinks, which stay editable in place — and its own
# dev/hooks/ is linked in full, allowlist or not.
echo "--- base repo installs symlinks, not copies ---"
(cd "$BASE" && install_hooks "$BASE")
HB="$(hooks_of "$BASE")"
assert_true "own hooks are symlinked" test -L "$HB/post-checkout"
assert_false "not copied over itself" hook_is_managed "$HB/post-checkout"
assert_true "including non-allowlisted ones" test -L "$HB/pre-commit"

# ---------- test: a linked worktree resolves the shared hooks dir ----------
# --git-common-dir can come back relative in a worktree; hooks must land in the
# main checkout's .git/hooks, which every worktree shares.
echo "--- linked worktree resolves to the shared hooks dir ---"
PROJ7="$(new_repo "$TMPDIR_ROOT/consumer-wt")"
git -C "$PROJ7" worktree add -q --detach "$PROJ7/wt1" HEAD
(cd "$PROJ7/wt1" && install_hooks "$BASE")
assert_true "installed into the main checkout's hooks dir" \
    test -f "$PROJ7/.git/hooks/post-checkout"
assert_eq "worktree resolves to the same dir" \
    "$(hooks_of "$PROJ7")" "$(hooks_of "$PROJ7/wt1")"

finish
