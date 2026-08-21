#!/usr/bin/env bash
# Guard: symlink_hooks() in lib/git.sh installs dev/hooks/* into the shared
# hooks dir AND removes a <hook>.legacy sibling that resolves back into
# dev/hooks/ — the state a `pre-commit install` leaves behind in this repo.
#
# Why that state is fatal rather than untidy: pre-commit renames the existing
# hook aside as <name>.legacy and installs its own. The install guard skips a
# REGULAR file, so ours comes back only once the generated hook is gone (deleted
# by hand, or an interrupted `pre-commit uninstall`) and a later pass re-links
# into the empty slot — the state this repo was found in. The leftover .legacy
# then points at OUR hook, and section 2 below builds exactly that.
# hook-impl execs it with PRE_COMMIT_RUNNING_LEGACY set, the nested run exits
# "bug: pre-commit's script is installed in migration mode", and the outer run
# fails the commit on that retcode with every hook green. It sat inert for
# months and became a hard failure only when dev/hooks/pre-commit began passing
# --hook-dir (12c15c7), which is what lets hook-impl find the sibling at all.
#
# The removal must stay NARROW: migration mode exists so a pre-existing
# third-party hook keeps running, so a foreign .legacy must survive. Both
# halves are asserted, over a hook set read out of dev/hooks/ at check time
# rather than restated here.
#
# Like the live .gitignore, the hooks dir is untracked per-clone state, so the
# repair for an already-broken clone is "the next direnv pass fixes it" rather
# than a migration.
#
# Deliberately NOT covered: pre-commit's own migration-mode logic lives outside
# this tree, so this suite asserts the state symlink_hooks leaves rather than
# modelling hook-impl. A stub of that would restate a third party's internals
# and stay green forever once pre-commit moved on.
#
# Verified (ADR-0005 §2), three mutations — the semantic pair deliberately
# pushes in OPPOSITE directions, because this guard can fail either way:
#   1. FORM-ONLY — rewrite the legacy block as an `[ ... ] && [ ... ] && rm -f`
#      one-liner instead of an `if`, and hoist `legacy=` above the re-link.
#      Green: 15 passed, 0 failed — assertion count unchanged.
#   2. SEMANTIC (under-removal), in a form this suite does not write — COMMENT
#      OUT (not delete) the `rm -f "$legacy"` line. Observed red:
#        FAIL: removes the self-referential post-checkout.legacy
#        FAIL: removes the self-referential pre-commit.legacy
#        FAIL: a .legacy in the shared dir is removed when run from a worktree
#      Results: 12 passed, 3 failed
#   3. SEMANTIC (over-removal) — drop the resolved-path test so every .legacy
#      goes unconditionally. Observed red:
#        FAIL: keeps a third-party post-checkout.legacy
#        FAIL: and does not rewrite it
#      Results: 13 passed, 2 failed
#   Mutation 3 is the one a single aimed mutation would have missed: an
#   unconditional `rm` closes the incident and quietly breaks the feature
#   migration mode exists for.
#   (mutation runs 2026-08-18)
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$DEV_BASE/lib/git.sh"

echo "--- symlink_hooks: install, and the .legacy self-reference (#12c15c7) ---"

# The hook set is the real one, read at check time — a hook added to dev/hooks/
# is covered without editing this suite.
hook_names=()
for h in "$DEV_BASE/dev/hooks/"*; do
    [ -f "$h" ] || continue
    hook_names+=("$(basename "$h")")
done
assert_true "dev/hooks/ has hooks to install" [ "${#hook_names[@]}" -gt 0 ]

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

# fixture <name> — disposable repo carrying a copy of the real dev/hooks/,
# committed so linked worktrees see it too. Echoes the repo path.
fixture() {
    local repo
    repo="$(new_repo "$tmp/$1")"
    mkdir -p "$repo/dev"
    cp -a "$DEV_BASE/dev/hooks" "$repo/dev/hooks"
    git -C "$repo" add -A >/dev/null
    git -C "$repo" -c user.email=t@t -c user.name=t commit -qm hooks
    printf '%s\n' "$repo"
}

# --- 1. a fresh checkout gets every hook, as a symlink to dev/hooks/ ---
repo="$(fixture fresh)"
symlink_hooks "$repo"
for name in "${hook_names[@]}"; do
    assert_eq "installs $name pointing at dev/hooks/$name" \
        "$repo/dev/hooks/$name" "$(readlink -f "$repo/.git/hooks/$name")"
done

# --- 2. the self-referential .legacy `pre-commit install` leaves behind ---
# Reproduced the way pre-commit makes it: the installed hook is RENAMED aside,
# so .legacy inherits whatever the live hook was — here our own symlink.
repo="$(fixture selfref)"
symlink_hooks "$repo"
for name in "${hook_names[@]}"; do
    mv "$repo/.git/hooks/$name" "$repo/.git/hooks/$name.legacy"
    printf '#!/bin/sh\nexit 0\n' >"$repo/.git/hooks/$name" # pre-commit's own
    chmod +x "$repo/.git/hooks/$name"
done
symlink_hooks "$repo"
for name in "${hook_names[@]}"; do
    assert_false "removes the self-referential $name.legacy" \
        test -e "$repo/.git/hooks/$name.legacy"
    # pre-commit's own hook stays live: the re-link above declines to clobber a
    # real file, and cleaning the .legacy is enough to make commits work again.
    assert_contains "and leaves pre-commit's own $name alone" \
        "exit 0" "$(cat "$repo/.git/hooks/$name")"
done

# --- 3. a foreign .legacy is what migration mode is FOR: it must survive ---
repo="$(fixture foreign)"
name="${hook_names[0]}"
printf '#!/bin/sh\necho third-party\n' >"$repo/.git/hooks/$name.legacy"
chmod +x "$repo/.git/hooks/$name.legacy"
foreign_before="$(cat "$repo/.git/hooks/$name.legacy")"
# and one that is a symlink, but to somewhere that is not dev/hooks/
printf '#!/bin/sh\nexit 0\n' >"$tmp/elsewhere.sh"
chmod +x "$tmp/elsewhere.sh"
# ... and one under a name we do not ship, so the loop never considers it
ln -s "$tmp/elsewhere.sh" "$repo/.git/hooks/other-hook.legacy"
symlink_hooks "$repo"
assert_true "keeps a third-party $name.legacy" test -e "$repo/.git/hooks/$name.legacy"
assert_eq "and does not rewrite it" "$foreign_before" "$(cat "$repo/.git/hooks/$name.legacy")"
assert_true "keeps a .legacy symlinked outside dev/hooks/" \
    test -e "$repo/.git/hooks/other-hook.legacy"

# --- 4. pre-existing hooks: a real file is left alone, a symlink is re-pointed ---
repo="$(fixture preexisting)"
name="${hook_names[0]}"
printf '#!/bin/sh\necho mine\n' >"$repo/.git/hooks/$name"
chmod +x "$repo/.git/hooks/$name"
ln -s /dev/null "$repo/.git/hooks/${hook_names[-1]}"
symlink_hooks "$repo"
assert_eq "does not clobber a real pre-existing $name" \
    "#!/bin/sh
echo mine" "$(cat "$repo/.git/hooks/$name")"
assert_eq "re-points a stale symlink at dev/hooks/${hook_names[-1]}" \
    "$repo/dev/hooks/${hook_names[-1]}" "$(readlink -f "$repo/.git/hooks/${hook_names[-1]}")"

# --- 5. worktrees share one hooks dir, so the cleanup reaches all of them ---
# --git-common-dir is why: from a linked worktree it names the MAIN .git, and
# the relative link target resolves against that.
repo="$(fixture worktrees)"
git -C "$repo" worktree add -q -b wt "$tmp/wt" >/dev/null 2>&1
symlink_hooks "$repo"
name="${hook_names[0]}"
mv "$repo/.git/hooks/$name" "$repo/.git/hooks/$name.legacy"
symlink_hooks "$tmp/wt"
assert_false "a .legacy in the shared dir is removed when run from a worktree" \
    test -e "$repo/.git/hooks/$name.legacy"
assert_eq "and the worktree call installs into the shared dir" \
    "$repo/dev/hooks/$name" "$(readlink -f "$repo/.git/hooks/$name")"

# --- 6. idempotent: a second pass changes nothing ---
repo="$(fixture idempotent)"
symlink_hooks "$repo"
before="$(find "$repo/.git/hooks" -maxdepth 1 \( -type f -o -type l \) -printf '%p %l\n' | sort)"
symlink_hooks "$repo"
assert_eq "a second pass is a no-op" "$before" \
    "$(find "$repo/.git/hooks" -maxdepth 1 \( -type f -o -type l \) -printf '%p %l\n' | sort)"

finish
