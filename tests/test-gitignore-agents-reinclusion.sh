#!/usr/bin/env bash
# Guard: dev/check-gitignore-agents — the functional probe of ADR-0003's
# re-inclusion in the LIVE .gitignore (#91) — must go red on a broken live
# file and green on a correct or absent one, and must stay wired into both
# consumers (the .pre-commit-config.yaml local hook and the dev/setup-worktree
# warning). The live file is untracked, so the probe is the guard for a fact
# no hermetic test over committed files can see; this suite guards the probe.
#
# Verified (ADR-0005 §2), third round: the parser tokenized YAML COMMENTS.
#     stages: [manual]  # run via pre-commit run --hook-stage manual
# passed at 16/0 with the gate fully disabled, because "pre-commit" from the
# comment landed in the value set — and that sentence is the natural comment to
# write when moving a hook to manual. Same for the block form. Also
# `stages: [pre-commit,manual]` (legitimate, fires on commit) was glued into one
# token by `tr -d ','` and spuriously FAILed. Ten spellings now verified:
# [manual], [commit-msg], block -manual, bare `stages:`, and either form with a
# pre-commit-naming comment all FAIL; [pre-commit], [commit], block -pre-commit
# and [pre-commit,manual] all pass (mutation runs 2026-08-04).
#
# Verified (ADR-0005 §2), review round: the first cut of the stage check parsed
# only the FLOW spelling, so the YAML block form
#     stages:
#       - manual
# yielded an empty match and took the "no stages: key" pass — the ADR-0003 gate
# still silently disabled, suite green. All seven spellings now behave:
# [manual]/[commit-msg]/block -manual/bare `stages:` FAIL; [pre-commit]/[commit]/
# block -pre-commit PASS. Also replaced a fixed `grep -A5` window for
# always_run, which produced a spurious FAIL whenever the hook block grew by two
# lines (mutation runs 2026-08-04).
#
# Verified (ADR-0005 §2), audit round: adding `stages: [manual]` to the hook in
# .pre-commit-config.yaml left this suite at 14 passed / 0 failed while a commit
# with a broken live .gitignore went through clean (rc 0; rc 1 with the hook
# restored) — the ADR-0003 hard gate off, silently. Now FAILs "the hook runs at
# the commit stage" (15 passed, 1 failed) (mutation run 2026-08-04).
#
# Verified (ADR-0005 §2), review round: reverting the probe to its dotfile name
# and its `dir="${1:-.}"` handling, and un-gating the setup-worktree warning,
# turns three assertions red — "a broken repo is still red when probed from a
# subdirectory", "a personal dotfile ignore ... does not false-positive", and
# "the setup-worktree warning is gated ..." (11 passed, 3 failed). All three
# were green before the assertions existed (mutation run 2026-08-04).
#
# Verified (ADR-0005 §2): with a bare `.claude` written into a live
# .gitignore, dev/check-gitignore-agents exits 1 and
# `pre-commit run gitignore-agents-reinclusion` fails; restoring the template
# stanza turns both green (mutation run 2026-08-02).
# Verified (ADR-0005 §2), fourth round: BOTH setup-worktree wiring greps matched
# commented-out code. Commenting the probe call passed at 16/0 (ADR-0003's
# worktree probe never runs); commenting the ls-files gate — never tested before
# — passed too. Rounds two and three anchored the hook-block assertions and left
# these. Now via tests/lib/shellsrc.sh (mutation runs 2026-08-04).
#
# Verified (ADR-0005 §2 pair), sixth round — three more, all previously 16/0:
#   the whole `shellcheck (extensionless)` hook commented out, files: pattern
#     included, left "the extensionless shellcheck hook covers the probe
#     script" PASSING while the probe was linted by nothing;
#   a QUOTED key, `"stages": [manual]` — pre-commit honours it, yamllint is
#     clean, and the bare `stages:` match never saw it. The parser failed
#     closed on unreadable VALUES and open on unreadable KEYS;
#   top-level `default_stages: [manual]`, which moves the hook off the commit
#     stage from OUTSIDE the block this suite parses, so "no stages: key"
#     passed while the gate was off.
#   (mutation runs 2026-08-04)
#
# Verified (ADR-0005 §2 pair), fifth round:
#   SEMANTIC — a comment on the `stages:` KEY line, `stages: # run via
#     pre-commit run --hook-stage manual` over a block `- manual`, was 16/0
#     GREEN: the parser's own sed needed whitespace BEFORE the `#`, and the awk
#     had already eaten it. One stripper now (shell_strip_comments carries the
#     line-start rule). Also: commenting the setup-worktree gate out => red.
#   FORM-ONLY — requoting to `ls-files -- '.claude/agents'` was a false FAIL
#     against the fixed-string pin; the pattern is quoting-tolerant now and the
#     suite holds at 16. (mutation runs 2026-08-04)
#
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
. "$(dirname "$(readlink -f "$0")")/lib/shellsrc.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
check="$DEV_BASE/dev/check-gitignore-agents"

echo "--- check-gitignore-agents: ADR-0003 re-inclusion probe ---"

[ -x "$check" ] || { echo "  FAIL: $check not found or not executable"; exit 1; }

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")
repo="$(new_repo "$tmp/repo")"

# quiet <dir> — the probe with its (expected) diagnostic suppressed, so a red
# fixture doesn't spray remediation text through the suite output.
quiet() { "$check" "$1" 2>/dev/null; }

# Broken: the bare entry ADR-0003 forbids — it matches the directory itself,
# so no negation beneath it can re-include anything. This is the #91 incident.
printf '.claude\n' > "$repo/.gitignore"
assert_false "a bare .claude entry turns the probe red" quiet "$repo"

# Broken, subtler: the split stanza missing its negation.
printf '.claude/*\n' > "$repo/.gitignore"
assert_false "missing !.claude/agents/ turns the probe red" quiet "$repo"

# Correct: the ADR-0003 stanza.
printf '.claude/*\n!.claude/agents/\n' > "$repo/.gitignore"
assert_true "the ADR-0003 stanza passes" "$check" "$repo"

# The tracked template must satisfy the probe — derived, not restated: this
# reads the real template, so a template regression fails here too.
cp "$DEV_BASE/.gitignore.template" "$repo/.gitignore"
assert_true "a live file copied from .gitignore.template passes" "$check" "$repo"

# Absent: a fresh clone has no live .gitignore, and nothing ignores the probe.
rm "$repo/.gitignore"
assert_true "no live .gitignore passes (fresh clone)" "$check" "$repo"

# check-ignore matches a RELATIVE path against the rules in force where it runs,
# so the probe must resolve to the repo root first. Called from a subdirectory
# it used to ask about `<subdir>/.claude/agents/...`, which a root-anchored
# `.claude/*` never matches — a broken repo reported green.
printf '.claude/*\n' > "$repo/.gitignore"
mkdir -p "$repo/sub"
assert_false "a broken repo is still red when probed from a subdirectory" \
    bash -c "cd '$repo/sub' && '$check' 2>/dev/null"

# The probe must be representative of what it stands for. As a dotfile it was
# caught by a personal `.claude/agents/.*` extra while real agent .md files
# staged fine, so the hard gate blocked every commit over a phantom.
printf '.claude/*\n!.claude/agents/\n.claude/agents/.*\n' > "$repo/.gitignore"
assert_true "a personal dotfile ignore under .claude/agents/ does not false-positive" \
    "$check" "$repo"
assert_false "...while a real agent definition is genuinely not ignored" \
    git -C "$repo" check-ignore -q .claude/agents/foo.md

# A non-repo must not be mistaken for a passing probe.
assert_false "a directory outside any repo is not reported green" \
    bash -c "'$check' /tmp 2>/dev/null"

# Wiring: a probe only guards if its consumers run it.
# Read once, comment-stripped, and reused: a raw grep here matches a commented
# hook just as happily as a live one.
_precommit_live="$(shell_strip_comments "$DEV_BASE/.pre-commit-config.yaml")"

assert_true "the pre-commit local hook runs the probe" \
    grep -q 'entry: dev/check-gitignore-agents' <<<"$_precommit_live"
# ...and runs at the COMMIT stage. Greps for `entry:` and `always_run:` say
# nothing about when the hook fires: adding `stages: [manual]` left this suite
# at 14/0 while a commit with a broken live .gitignore went through clean (rc 0
# vs rc 1 with the hook restored). The gate #91/#94 exists to provide was off,
# silently. Checked hermetically — pre-commit is not installed in the Bash-tests
# CI job, and a skip there is the same "verification never ran" shape.
# ONE comment-stripper for this file too. YAML and shell both use `#`, and the
# stage parser's own `sed 's/[[:space:]]#.*$//'` required whitespace BEFORE the
# `#` — so a comment on the `stages:` KEY line survived, because the awk had
# already eaten the whitespace. shell_strip_comments carries the line-start rule.
hook_block="$(shell_strip_comments "$DEV_BASE/.pre-commit-config.yaml" | awk '/id: gitignore-agents-reinclusion/{f=1} f&&/^      - id: /&&!/gitignore-agents-reinclusion/{exit} f' \
    )"
assert_nonempty "the hook block was found in .pre-commit-config.yaml" "$hook_block"
# Against the extracted block, not a fixed `grep -A5` window: adding two lines
# to the hook pushed always_run out of that window and produced a spurious FAIL
# on an unrelated edit.
assert_true "the hook runs even when no files match" \
    grep -qE '^[[:space:]]*always_run:[[:space:]]*true' <<<"$hook_block"
# A `stages:` key can be written flow-style (`stages: [manual]`) or block-style
# (`stages:` then indented `- manual` lines). The first cut parsed only the flow
# form, so the block form yielded an EMPTY match and took the "no stages: key"
# pass — the gate still silently disabled, suite green. Distinguish "no key"
# from "key present, values unreadable", and fail closed on the latter.
# The key may be quoted (`"stages":`), which pre-commit honours and a bare
# `stages:` match does not see — the parser failed closed on unreadable VALUES
# and open on unreadable KEYS. And with no hook-level key at all, a top-level
# `default_stages:` still moves the hook off the commit stage from outside the
# block this suite parses.
if ! grep -qE '^[[:space:]]*"?stages"?[[:space:]]*:' <<<"$hook_block"; then
    _default_stages="$(grep -oP '^default_stages[[:space:]]*:[[:space:]]*\K.*' <<<"$_precommit_live" || true)"
    if [ -z "$_default_stages" ]; then
        _pass "the hook is not restricted off the commit stage (no stages: key)"
    elif grep -qE '(^|[^a-z-])(pre-commit|commit)([^a-z-]|$)' <<<"$_default_stages"; then
        _pass "no hook stages:; top-level default_stages includes commit: $_default_stages"
    else
        _fail "the hook runs at the commit stage" \
            "no hook-level stages:, but top-level default_stages: $_default_stages" \
            "excludes pre-commit, so the ADR-0003 gate never fires on a commit."
    fi
else
    # The pipeline matters: strip YAML comments FIRST (an inline comment on a
    # `stages:` line naturally mentions pre-commit — "run via pre-commit run
    # --hook-stage manual" — and tokenizing it re-enabled the pass), and map
    # commas to newlines rather than deleting them (deleting glued
    # `[pre-commit,manual]` into one token and failed a legitimate config).
    stage_vals="$(awk '
        /^[[:space:]]*stages:/ {
            v = $0; sub(/^[[:space:]]*stages:[[:space:]]*/, "", v)
            if (v != "") print v
            blk = 1; next
        }
        blk {
            if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
                v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); print v; next
            }
            blk = 0
        }
    ' <<<"$hook_block" \
        | tr -d "[]\"'" \
        | tr ', ' '\n\n' \
        | grep -v '^$' || true)"
    if [ -z "$stage_vals" ]; then
        _fail "the hook runs at the commit stage" \
            "a stages: key is present but no values could be parsed —" \
            "failing closed rather than assuming it is harmless."
    elif grep -qxE '(pre-commit|commit)' <<<"$stage_vals"; then
        _pass "the hook's stages include the commit stage: $(tr '\n' ' ' <<<"$stage_vals")"
    else
        _fail "the hook runs at the commit stage" \
            "stages: $(tr '\n' ' ' <<<"$stage_vals") excludes pre-commit, so the" \
            "ADR-0003 gate never fires on a real commit — silently, suite green."
    fi
fi
assert_shell_wired "setup-worktree warns through the same probe" \
    "$DEV_BASE/dev/setup-worktree" "check-gitignore-agents"
# ...but only where ADR-0003's convention is in force. setup-worktree runs on
# every `devcontainer up` in a non-main worktree for ANY project, so an
# ungated warning is per-start noise in consumer repos that simply ignore
# .claude/ — and its "commits will be blocked" claim is false there, since the
# hard gate is this repo's .pre-commit-config.yaml.
# Quoting-tolerant: pinning the unquoted spelling as a fixed string made an
# ordinary requote (`ls-files -- '.claude/agents'`) a false FAIL. Fail-closed,
# but a guard that reddens on a no-op reformat trains people to edit the test.
assert_shell_wired "the setup-worktree warning is gated on the repo tracking .claude/agents" \
    "$DEV_BASE/dev/setup-worktree" "ls-files -- [\"']?\.claude/agents[\"']?" -E
# Read from the stripped config, and in THIS shell: a `bash -c` subshell does
# not inherit $_precommit_live. Commenting out the whole shellcheck hook — its
# files: pattern included — used to leave this PASSING while the probe script
# was no longer linted at all.
_shellcheck_files="$(grep -F '^dev/(' <<<"$_precommit_live" || true)"
assert_nonempty "the extensionless shellcheck hook has a files: pattern" "$_shellcheck_files"
assert_true "the extensionless shellcheck hook covers the probe script" \
    grep -q 'check-gitignore-agents' <<<"$_shellcheck_files"

echo ""
finish
