#!/usr/bin/env bash
# Tests for dev/devcontainer-sessions' pure helpers -- the parts that need no
# docker: sanitize (which must stay a faithful mirror of lib/git.sh's
# sanitize_name, since guess_worktree relies on the two agreeing), transcript
# parsing (read_session / first_prompt), and the small formatters. Runs against
# crafted transcripts in /tmp.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SCRIPT="$DEV_BASE/dev/devcontainer-sessions"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# run_dcs <snippet> — load devcontainer-sessions as a module (without running
# main()) and exec the snippet with `m` (the module), `Path`, and `sys` in
# scope. The snippet prints its own result.
run_dcs() {
    python3 - "$SCRIPT" "$1" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
loader = SourceFileLoader("dcs", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("dcs", loader))
loader.exec_module(m)
exec(sys.argv[2])
PY
}

# ---------- test: sanitize mirrors lib/git.sh sanitize_name ----------
# A divergence here silently breaks guess_worktree (which re-sanitizes host
# directories to match a removed container's compose project), so pin them
# together across the awkward inputs.
echo "--- sanitize mirrors sanitize_name ---"
# shellcheck source=/dev/null
. "$DEV_BASE/lib/git.sh"
for inp in "plainrepo" "Foo/Bar.baz" ".dotfiles" "a//b__c" "..." "UPPER-Case" \
    "trailing-/." "/home/dan/repos/github/xorq" "with space"; do
    want="$(sanitize_name "$inp")"
    got="$(run_dcs "print(m.sanitize(r'''$inp'''), end='')")"
    assert_eq "sanitize('$inp') matches sanitize_name" "$want" "$got"
done

# ---------- test: host_project_key ----------
echo "--- host_project_key ---"
assert_eq "path mangled to Claude's project key" \
    "-home-dan-repos-github-xorq" \
    "$(run_dcs "print(m.host_project_key('/home/dan/repos/github/xorq'), end='')")"

# ---------- test: parse_timestamp ----------
echo "--- parse_timestamp ---"
assert_eq "ISO Z stamp parses" "True" \
    "$(run_dcs "print(m.parse_timestamp('2026-07-30T10:05:00.000Z') is not None, end='')")"
assert_eq "junk returns None" "None" \
    "$(run_dcs "print(m.parse_timestamp('not-a-time'), end='')")"
assert_eq "empty returns None" "None" \
    "$(run_dcs "print(m.parse_timestamp(None), end='')")"

# ---------- test: first_prompt strips reminder/tag noise ----------
echo "--- first_prompt ---"
assert_eq "string content, tags stripped" "hello there" \
    "$(run_dcs "print(m.first_prompt({'type':'user','message':{'content':'<system-reminder>ignore me</system-reminder>hello there'}}), end='')")"
assert_eq "list content joined" "a b" \
    "$(run_dcs "print(m.first_prompt({'type':'user','message':{'content':[{'type':'text','text':'a'},{'type':'text','text':'b'}]}}), end='')")"
assert_eq "summary record uses its summary" "the summary" \
    "$(run_dcs "print(m.first_prompt({'type':'summary','summary':'the summary'}), end='')")"
assert_eq "assistant turn ignored" "None" \
    "$(run_dcs "print(m.first_prompt({'type':'assistant','message':{'content':'x'}}), end='')")"

# ---------- test: read_session identity + last-activity walk-back ----------
# A final summary line with no timestamp must not become last_timestamp: the
# walk-back skips it for the last record that actually carries a clock.
echo "--- read_session ---"
TF="$TMPDIR_ROOT/transcript.jsonl"
{
    printf '%s\n' '{"type":"user","sessionId":"5331ec2b-aaaa","cwd":"/workspaces/src","gitBranch":"feat/x","version":"1.2.3","timestamp":"2026-07-30T10:00:00.000Z","message":{"role":"user","content":"<system-reminder>noise</system-reminder>real opening prompt"}}'
    printf '%s\n' '{"type":"assistant","sessionId":"5331ec2b-aaaa","gitBranch":"feat/x","version":"1.2.3","timestamp":"2026-07-30T10:05:00.000Z","message":{"role":"assistant","content":"ok"}}'
    printf '%s\n' '{"type":"summary","summary":"A trailing summary with no timestamp"}'
} >"$TF"

read_field() { run_dcs "print(m.read_session(Path(r'''$TF'''))[r'''$1'''], end='')"; }
assert_eq "session_id from head" "5331ec2b-aaaa" "$(read_field session_id)"
assert_eq "cwd from head" "/workspaces/src" "$(read_field cwd)"
assert_eq "opening prompt, tags stripped" "real opening prompt" "$(read_field summary)"
assert_eq "git_branch recovered" "feat/x" "$(read_field git_branch)"
assert_eq "version recovered" "1.2.3" "$(read_field version)"
assert_eq "last_timestamp skips the untimestamped summary" \
    "2026-07-30T10:05:00.000Z" "$(read_field last_timestamp)"
assert_eq "records_tail counts lines in the tail window" "3" "$(read_field records_tail)"

# ---------- test: fmt_size ----------
echo "--- fmt_size ---"
assert_eq "bytes" "500B" "$(run_dcs "print(m.fmt_size(500), end='')")"
assert_eq "kilobytes" "2.0K" "$(run_dcs "print(m.fmt_size(2048), end='')")"
assert_eq "megabytes" "5.0M" "$(run_dcs "print(m.fmt_size(5 * 1024 * 1024), end='')")"

finish
