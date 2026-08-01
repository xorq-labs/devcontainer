#!/usr/bin/env bash
# Tests for the worktree .claude layout (ADR-0003): a real .claude directory
# with per-subdir symlinks for the shared state (container-audit,
# container-sessions), coexisting with tracked content (.claude/agents/) that
# git materializes at checkout — plus legacy whole-directory-symlink worktrees
# staying untouched. Runs against a disposable git repo in /tmp — no docker.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SETUP="$DEV_BASE/dev/setup-worktree"
CLEANUP="$DEV_BASE/dev/cleanup-worktree"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# ---------- setup: disposable repo with the REAL .gitignore.template ----------
# commit1 (branch "base"): no .claude content — pre-ADR-0003 shape.
# commit2 (branch "main"): tracked .claude/agents/test-agent.md.
MAIN_TREE="$(new_repo "$TMPDIR_ROOT/fakerepo")"
cp "$DEV_BASE/.gitignore.template" "$MAIN_TREE/.gitignore.template"
git -C "$MAIN_TREE" add .gitignore.template
git -C "$MAIN_TREE" commit -qm "add gitignore template"
git -C "$MAIN_TREE" branch base
mkdir -p "$MAIN_TREE/.claude/agents"
printf '# test agent\n' > "$MAIN_TREE/.claude/agents/test-agent.md"
git -C "$MAIN_TREE" add .claude/agents/test-agent.md
git -C "$MAIN_TREE" commit -qm "track an agent definition"

# ---------- test: the template tracks agents/ and ignores the state ----------
echo "--- .gitignore.template: agents tracked, state ignored ---"
tracked_in_main() { git -C "$MAIN_TREE" ls-files --error-unmatch "$1" >/dev/null 2>&1; }
assert_true "tracked agent file is committable (not ignored at add time)" \
    tracked_in_main .claude/agents/test-agent.md
cp "$MAIN_TREE/.gitignore.template" "$MAIN_TREE/.gitignore"
assert_true "container-audit content is ignored" \
    git -C "$MAIN_TREE" check-ignore -q .claude/container-audit/audit.jsonl
assert_true "container-sessions is ignored" \
    git -C "$MAIN_TREE" check-ignore -q .claude/container-sessions
assert_true "settings.local.json is ignored" \
    git -C "$MAIN_TREE" check-ignore -q .claude/settings.local.json
assert_true ".claude/worktrees is ignored" \
    git -C "$MAIN_TREE" check-ignore -q .claude/worktrees
assert_false "agents/ files are NOT ignored" \
    git -C "$MAIN_TREE" check-ignore -q .claude/agents/pr-reviewer.md

# ---------- test: fresh worktree (no tracked .claude on the branch) ----------
echo "--- fresh worktree: real dir + per-subdir symlinks ---"
WT1="$TMPDIR_ROOT/wt-fresh"
git -C "$MAIN_TREE" worktree add -q "$WT1" base
(cd "$WT1" && "$SETUP") >/dev/null
assert_false ".claude is not a symlink" test -L "$WT1/.claude"
assert_true ".claude is a real directory" test -d "$WT1/.claude"
assert_true "container-audit is a symlink" test -L "$WT1/.claude/container-audit"
assert_true "container-sessions is a symlink" test -L "$WT1/.claude/container-sessions"
assert_eq "container-audit points at the main checkout" \
    "$MAIN_TREE/.claude/container-audit" "$(readlink "$WT1/.claude/container-audit")"
assert_eq "container-sessions points at the main checkout" \
    "$MAIN_TREE/.claude/container-sessions" "$(readlink "$WT1/.claude/container-sessions")"
assert_true "shared dir created in main when absent" test -d "$MAIN_TREE/.claude/container-audit"
manifest="$(cat "$WT1/.envrcs/.worktree-manifest")"$'\n' # re-add the trailing newline $() strips
assert_contains "manifest records the audit symlink" $'symlink\t.claude/container-audit' "$manifest"
assert_contains "manifest records the sessions symlink" $'symlink\t.claude/container-sessions' "$manifest"
assert_not_contains "manifest has no whole-dir .claude entry" $'symlink\t.claude\n' "$manifest"
# a write through the link lands in the main checkout (the aggregation contract)
echo '{}' >> "$WT1/.claude/container-audit/audit.jsonl"
assert_true "write through the link lands in main" \
    test -f "$MAIN_TREE/.claude/container-audit/audit.jsonl"
rm "$MAIN_TREE/.claude/container-audit/audit.jsonl"

echo "--- fresh worktree: setup-worktree is idempotent ---"
(cd "$WT1" && "$SETUP") >/dev/null
assert_true "second run keeps the audit symlink" test -L "$WT1/.claude/container-audit"
assert_false "second run does not turn .claude into a symlink" test -L "$WT1/.claude"
assert_eq "manifest records the audit symlink exactly once" "1" \
    "$(grep -cx $'symlink\t.claude/container-audit' "$WT1/.envrcs/.worktree-manifest")"

# ---------- test: pre-materialized .claude/agents/ from checkout survives ----------
echo "--- worktree on a branch with tracked .claude/agents ---"
WT2="$TMPDIR_ROOT/wt-agents"
git -C "$MAIN_TREE" worktree add -q "$WT2" -b wt-agents main
assert_true "checkout materialized the tracked agent file" \
    test -f "$WT2/.claude/agents/test-agent.md"
(cd "$WT2" && "$SETUP") >/dev/null
assert_true "agent file survives setup-worktree" test -f "$WT2/.claude/agents/test-agent.md"
assert_files_eq "agent file content untouched" \
    "$MAIN_TREE/.claude/agents/test-agent.md" "$WT2/.claude/agents/test-agent.md"
assert_false "agents/ stays a real (non-symlink) subdir" test -L "$WT2/.claude/agents"
assert_true "state symlinks coexist with tracked content" test -L "$WT2/.claude/container-audit"
assert_true "worktree stays clean after setup" \
    test -z "$(git -C "$WT2" status --porcelain)"

# ---------- test: legacy whole-dir-symlink worktree is left as-is ----------
echo "--- legacy worktree: whole-dir symlink kept ---"
WT3="$TMPDIR_ROOT/wt-legacy"
git -C "$MAIN_TREE" worktree add -q "$WT3" -b wt-legacy base
ln -s "$MAIN_TREE/.claude" "$WT3/.claude" # pre-ADR-0003 layout
(cd "$WT3" && "$SETUP") >/dev/null
assert_true ".claude stays a symlink" test -L "$WT3/.claude"
assert_eq ".claude still points at main's .claude" \
    "$MAIN_TREE/.claude" "$(readlink "$WT3/.claude")"
manifest="$(cat "$WT3/.envrcs/.worktree-manifest")"$'\n'
assert_contains "manifest re-records the legacy whole-dir symlink" \
    $'symlink\t.claude\n' "$manifest"
assert_not_contains "no per-subdir entries in legacy mode" \
    $'symlink\t.claude/container-audit' "$manifest"
assert_false "no nested symlink was created through the link" \
    test -L "$MAIN_TREE/.claude/container-audit/container-audit"

# ---------- test: `devcontainer clean`'s shared-state block ----------
# The block is pure shell over paths ($DEV_WORKSPACE in, filesystem out), so we
# lift it out of dev/devcontainer and run it directly rather than standing up
# docker. Anchors: it is everything between the file-hashes `rm -f` and the
# "Cleaned:" echo inside the `clean` case.
CLEAN_BLOCK="$(awk '
    index($0, "rm -f \"/tmp/devcontainer-${DEV_CONTAINER_NAME}.file-hashes\"") { f = 1; next }
    index($0, "echo \"Cleaned: ") { f = 0 }
    f' "$DEV_BASE/dev/devcontainer")"

# shellcheck disable=SC2034  # DEV_WORKSPACE is consumed by the eval'd block
run_clean_block() {
    (
        set -euo pipefail
        DEV_WORKSPACE="$1"
        eval "$CLEAN_BLOCK"
    )
}

# Seed shared state in main and report whether the block wiped it while leaving
# a real (non-dangling) directory behind for every layout that points at it.
seed_shared_state() {
    mkdir -p "$MAIN_TREE/.claude/container-audit" "$MAIN_TREE/.claude/container-sessions"
    echo '{"tool":"Bash"}' > "$MAIN_TREE/.claude/container-audit/audit.jsonl"
    echo '{}' > "$MAIN_TREE/.claude/container-sessions/123.json"
}

echo "--- devcontainer clean: block extraction ---"
assert_true "the clean shared-state block was extracted" test -n "$CLEAN_BLOCK"

echo "--- devcontainer clean: from a new-layout worktree ---"
seed_shared_state
assert_true "clean block succeeds from a new-layout worktree" run_clean_block "$WT1"
assert_false "shared audit log deleted (blast radius reaches main)" \
    test -e "$MAIN_TREE/.claude/container-audit/audit.jsonl"
assert_false "shared session stub deleted" \
    test -e "$MAIN_TREE/.claude/container-sessions/123.json"
assert_true "shared audit dir recreated in main" test -d "$MAIN_TREE/.claude/container-audit"
assert_true "shared sessions dir recreated in main" test -d "$MAIN_TREE/.claude/container-sessions"
assert_true "the worktree's own audit link is not dangling" test -d "$WT1/.claude/container-audit"
assert_true "the worktree's own sessions link is not dangling" test -d "$WT1/.claude/container-sessions"

echo "--- devcontainer clean: from the MAIN checkout ---"
# The regression this pins: main's .claude/container-* are real directories, so
# nothing here is a symlink — but sibling new-layout worktrees point AT them.
# Deleting without recreating leaves every sibling with a dangling link.
seed_shared_state
assert_true "clean block succeeds from the main checkout" run_clean_block "$MAIN_TREE"
assert_false "shared audit log deleted from main" \
    test -e "$MAIN_TREE/.claude/container-audit/audit.jsonl"
assert_true "main's audit dir recreated" test -d "$MAIN_TREE/.claude/container-audit"
assert_true "main's sessions dir recreated" test -d "$MAIN_TREE/.claude/container-sessions"
assert_true "sibling worktree's audit link still resolves" test -d "$WT1/.claude/container-audit"
assert_true "sibling worktree's sessions link still resolves" test -d "$WT1/.claude/container-sessions"

echo "--- devcontainer clean: from a LEGACY whole-dir-symlink worktree ---"
# Here $WT3/.claude/container-audit resolves THROUGH the whole-dir link, so the
# subdir path is a real directory, not a symlink — same trap as the main
# checkout, and the same sibling worktrees to keep unbroken.
seed_shared_state
assert_true "clean block succeeds from a legacy worktree" run_clean_block "$WT3"
assert_false "shared audit log deleted via the legacy link" \
    test -e "$MAIN_TREE/.claude/container-audit/audit.jsonl"
assert_true "shared audit dir recreated behind the legacy link" \
    test -d "$WT3/.claude/container-audit"
assert_true "shared sessions dir recreated behind the legacy link" \
    test -d "$WT3/.claude/container-sessions"
assert_true "sibling new-layout audit link still resolves" test -d "$WT1/.claude/container-audit"
assert_true "sibling new-layout sessions link still resolves" \
    test -d "$WT1/.claude/container-sessions"

echo "--- devcontainer clean: workspace with no .claude at all ---"
NO_CLAUDE="$TMPDIR_ROOT/no-claude-workspace"
mkdir -p "$NO_CLAUDE"
assert_true "clean block succeeds with no .claude present" run_clean_block "$NO_CLAUDE"
assert_false "no .claude conjured into existence" test -e "$NO_CLAUDE/.claude"

# ---------- test: cleanup-worktree undoes both layouts ----------
run_cleanup() { (cd "$MAIN_TREE" && "$CLEANUP" "$1") >/dev/null 2>&1; }

echo "--- cleanup-worktree: new layout ---"
assert_true "cleanup exits 0 on the new layout" run_cleanup "$WT1"
assert_false "fresh-layout worktree removed" test -d "$WT1"
assert_true "shared audit dir in main survives cleanup" \
    test -d "$MAIN_TREE/.claude/container-audit"

echo "--- cleanup-worktree: new layout with tracked agents ---"
assert_true "cleanup exits 0 with tracked agents present" run_cleanup "$WT2"
assert_false "agents-layout worktree removed" test -d "$WT2"
assert_true "main's tracked agent file survives cleanup" \
    test -f "$MAIN_TREE/.claude/agents/test-agent.md"

echo "--- cleanup-worktree: legacy layout ---"
assert_true "cleanup exits 0 on the legacy layout" run_cleanup "$WT3"
assert_false "legacy worktree removed" test -d "$WT3"
assert_true "main's .claude survives legacy cleanup" test -d "$MAIN_TREE/.claude"

# ---------- test: cleanup in a repo whose .gitignore does NOT ignore .claude ----------
# setup-worktree is shared infrastructure and the live .gitignore is untracked
# per checkout, so a consumer repo can easily lack a .claude entry. There,
# `git status --porcelain` collapses the wholly-untracked directory to a single
# `?? .claude/` that matches no manifest path — which used to make the
# cleanup-worktree pre-flight refuse to remove ANY worktree in that repo.
echo "--- cleanup-worktree: repo whose .gitignore does not ignore .claude ---"
OPEN_MAIN="$(new_repo "$TMPDIR_ROOT/openrepo")"
# Self-ignoring live .gitignore (this repo's convention), minus any .claude
# entry — so `?? .claude/` is the ONLY thing the pre-flight has to reason about.
printf '# deliberately no .claude entry\n.gitignore\n*.log\n' > "$OPEN_MAIN/.gitignore"
WT4="$TMPDIR_ROOT/wt-open"
git -C "$OPEN_MAIN" worktree add -q "$WT4" -b wt-open main
(cd "$WT4" && "$SETUP") >/dev/null
assert_contains "the collapsed untracked .claude entry is really there" \
    "?? .claude/" "$(git -C "$WT4" status --porcelain)"$'\n'

# The pre-flight must still block on a genuinely undominated file inside that
# same untracked directory, and block it in the pre-flight — "before we touch
# anything". Dominating the whole `.claude/` parent instead would sail past the
# pre-flight, tear the symlinks and the manifest down, and only then hit git's
# own refusal, leaving the worktree half-undone with no manifest to replay.
printf 'stray\n' > "$WT4/.claude/stray.txt"
assert_false "cleanup still refuses when an undominated file sits in .claude" \
    bash -c '(cd "$1" && "$2" "$3") >/dev/null 2>&1' _ "$OPEN_MAIN" "$CLEANUP" "$WT4"
assert_true "the refusal did not remove the worktree" test -d "$WT4"
assert_true "the refusal happened before any teardown (manifest intact)" \
    test -f "$WT4/.envrcs/.worktree-manifest"
assert_true "the refusal left the state symlinks in place" \
    test -L "$WT4/.claude/container-audit"
rm "$WT4/.claude/stray.txt"

assert_true "cleanup exits 0 with only manifest-recorded .claude state" \
    bash -c '(cd "$1" && "$2" "$3") >/dev/null 2>&1' _ "$OPEN_MAIN" "$CLEANUP" "$WT4"
assert_false "worktree removed despite the un-ignored .claude" test -d "$WT4"
assert_true "the open repo's shared audit dir survives" \
    test -d "$OPEN_MAIN/.claude/container-audit"

finish
