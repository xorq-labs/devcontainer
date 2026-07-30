#!/usr/bin/env bash
# Tests for host-resident Claude session logs: the project keys dev/devcontainer
# hands to compose, and devcontainer-sessions' host-side reading of the bound-out
# log directories (--host-only) plus its --resume-on-host placement rules.
# Drives a fake ~/.claude via --claude-home — no docker required.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SESSIONS="$DEV_BASE/dev/devcontainer-sessions"

# record <session-id> <cwd> <timestamp> — one transcript line.
record() {
    python3 -c '
import json, sys
print(json.dumps({
    "type": "user", "sessionId": sys.argv[1], "cwd": sys.argv[2],
    "timestamp": sys.argv[3], "gitBranch": "main", "version": "2.1.215",
    "message": {"role": "user", "content": "do the thing in " + sys.argv[2]},
}))' "$1" "$2" "$3"
}

# Fresh sandbox: a fake claude home holding one bound-out log dir. Prints the root.
make_sandbox() {
    local root container="$1" session="$2"
    root="$(mktemp -d)"
    _cleanup_dirs+=("$root")
    mkdir -p "$root/claude/projects/-devcontainer-$container"
    {
        record "$session" /workspaces/src 2026-07-29T18:19:00.000Z
        record "$session" /workspaces/src 2026-07-29T18:20:00.000Z
    } >"$root/claude/projects/-devcontainer-$container/$session.jsonl"
    printf '%s' "$root"
}

sessions() { python3 "$SESSIONS" "$@"; }

echo "=== host-resident claude session log tests ==="

SESSION=0e53ef13-d25e-4327-b4a6-ef141c97b137

# ---- the keys dev/devcontainer computes for compose ----------------------
# The container key names the directory the host log dir mounts over, so it has
# to match what Claude Code derives from the container's cwd.
key="$(echo "/workspaces/src" | sed 's|/|-|g')"
assert_eq "container project key mangles the workspace path" "-workspaces-src" "$key"
compose="$(cat "$DEV_BASE/docker-compose.yml")"
assert_contains "compose mounts the host log dir" 'source: ${DEV_CLAUDE_LOGS' "$compose"
assert_contains "compose mounts it at the container's project key" \
    'target: /home/vscode/.claude/projects/${DEV_CONTAINER_PROJECT_KEY' "$compose"
assert_contains "clean tells the user transcripts are kept" \
    'transcripts are kept' "$(grep -F 'This will destroy $DEV_CONTAINER_NAME' "$DEV_BASE/dev/devcontainer")"
assert_contains "reset tells the user transcripts are kept" \
    'transcripts are kept' "$(grep -F 'This will destroy the container' "$DEV_BASE/dev/devcontainer")"

# ---- --host-only reads the bound-out directory, no docker -----------------
root="$(make_sandbox xorq-dev-xorq "$SESSION")"
out="$(sessions --host-only --claude-home "$root/claude" --json)"
assert_eq "the bound-out session is found" 1 "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$out")"
assert_eq "it is reported as host-resident" 'True' \
    "$(python3 -c 'import json,sys; print(bool(json.loads(sys.argv[1])[0]["host_path"]))' "$out")"
assert_eq "the compose project comes back from the directory name" 'xorq-dev-xorq' \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["compose_project"])' "$out")"
# A live transcript sitting in ~/.claude/projects must not be mistaken for a host
# twin of itself, or every session would be filtered out as already-seeded.
assert_eq "a bound-out session is not counted as seeded" 'False' \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["seeded"])' "$out")"
assert_contains "an unresolved worktree reads as unchecked, not deleted" '(?)' \
    "$(sessions --host-only --claude-home "$root/claude")"

# ---- --resume-on-host rewrites and files under the host's own key ---------
root="$(make_sandbox xorq-dev-xorq "$SESSION")"
worktree="$root/repo"
mkdir -p "$worktree"
key="$(echo "$worktree" | sed 's|[^a-zA-Z0-9]|-|g')"
sessions --host-only --claude-home "$root/claude" --resume-on-host "$SESSION" \
    --container-workspace /workspaces/src --worktree-path "$worktree" >/dev/null
placed="$root/claude/projects/$key/$SESSION.jsonl"
assert_true "the transcript lands under the host project key" test -f "$placed"
assert_not_contains "no container paths survive the rewrite" '/workspaces/src' "$(cat "$placed")"
assert_contains "cwd now points at the worktree" "$worktree" "$(cat "$placed")"
assert_eq "every record survives" 2 "$(grep -c . "$placed")"

# ---- placement is a fast-forward, never a merge ---------------------------
out="$(sessions --host-only --claude-home "$root/claude" --resume-on-host "$SESSION" \
    --container-workspace /workspaces/src --worktree-path "$worktree")"
assert_contains "an identical re-copy is a no-op" 'nothing to do' "$out"

record "$SESSION" "$worktree" 2026-07-31T12:00:00.000Z >>"$placed"
rc=0
sessions --host-only --claude-home "$root/claude" --resume-on-host "$SESSION" \
    --container-workspace /workspaces/src --worktree-path "$worktree" >/dev/null 2>&1 || rc=$?
assert_eq "a host copy that is ahead is refused" 1 "$rc"
assert_eq "and is left untouched" 3 "$(grep -c . "$placed")"

sessions --host-only --claude-home "$root/claude" --resume-on-host "$SESSION" \
    --container-workspace /workspaces/src --worktree-path "$worktree" --force >/dev/null
assert_eq "--force overwrites it" 2 "$(grep -c . "$placed")"
assert_eq "and backs up what it replaced" 1 "$(find "$root/claude/backups" -name "$SESSION.jsonl.*" | wc -l)"

finish
