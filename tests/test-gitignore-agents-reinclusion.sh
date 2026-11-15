#!/usr/bin/env bash
# Guard: dev/check-gitignore-agents — the functional probe of ADR-0003's
# re-inclusion in the LIVE .gitignore (#91) — must go red on a broken live
# file and green on a correct or absent one, and must stay wired into both
# consumers (the .pre-commit-config.yaml local hook and the dev/setup-worktree
# warning). The live file is untracked, so the probe is the guard for a fact
# no hermetic test over committed files can see; this suite guards the probe.
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
#
# Template drift (ADR-0005 §2, run 2026-11-15, PR 167): form-only — rename
# ignored_set and swap the want/have lines: green, 23/23. Semantic — comment
# out `missing+=`: red ("deleting any one template rule is reported"); comment
# out the later-'!' `append+=`: red ("a missing rule followed by a template
# '!' rule is fixed by the command"); comment out `extra+=`, or turn the
# no-template skip into an unconditional exit 0: red; delete that skip: red
# (5 failures). Commenting out the trailing-`/` child survived — check-ignore
# reads `dir/` as a directory — so that clause was deleted.
#
# Round 2 (run 2026-11-15, PR 167), 32 assertions: form-only — rename sgit
# (4 occurrences): green. Semantic, each red on its own assertion: the
# absent-live branch made `if false` -> "an absent live .gitignore is named";
# GIT_CONFIG_GLOBAL=/dev/null dropped from sgit -> "a global excludesFile does
# not mask ..."; `-u GIT_CONFIG_PARAMETERS` dropped -> "an inherited git -c
# excludesFile ..."; the `have` side read from the live repo -> both mask
# cases; the '!'-as-missing clause made `false` -> "a missing '!' rule is in
# the append command"; ignored_set's `-gt 1` made `-gt 200` -> "a check-ignore
# failure on the drift side exits non-zero".
#
# Remaining clauses (run 2026-11-15, PR 167), 38 assertions, each red alone:
# the anchor strip made a no-op -> 35/3 (git rejects `/anchored-rule`); the
# quote escaping made `'$r'` -> 37/1; the empty-template guard made a no-op ->
# 37/1; the EXIT trap made a no-op -> 37/1 "leaves no scratch dir behind".
# The `*`/`?` substitutions and `--no-index` survived their removal for every
# input (a literal glob matches itself; scratch repos track nothing) and were
# deleted.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

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

# Template drift: a warning (exit 0) naming every template rule the live file
# decides differently. Expectations are derived from the real template: each
# rule in turn is deleted from an otherwise identical live file.
echo ""
echo "--- check-gitignore-agents: template drift warning ---"
drift_repo="$(new_repo "$tmp/drift")"
cp "$DEV_BASE/.gitignore.template" "$drift_repo/.gitignore.template"
template_rules=()
while IFS= read -r rule; do template_rules+=("$rule"); done \
    < <(grep -vE '^(#|$)' "$DEV_BASE/.gitignore.template")
assert_true "the template has rules to derive probes from" test "${#template_rules[@]}" -gt 0

# warn <dir> -> the probe's stderr; its exit code must be 0 whatever it says.
# Run with no global git config and an empty XDG dir: a host's global ignore
# (core.excludesFile, or ~/.config/git/ignore) would otherwise satisfy a rule
# the live file lacks, and the suite would pass here and fail in CI.
mkdir -p "$tmp/xdg"
warn() {
    local err rc=0
    err="$(GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="$tmp/xdg" \
        "$check" "$1" 2>&1 >/dev/null)" || rc=$?
    printf '%s\n' "$err"
    return "$rc"
}

cp "$DEV_BASE/.gitignore.template" "$drift_repo/.gitignore"
assert_eq "a live file equal to the template draws no warning" "" "$(warn "$drift_repo")"

unreported=()
for rule in "${template_rules[@]}"; do
    grep -vxF -- "$rule" "$DEV_BASE/.gitignore.template" > "$drift_repo/.gitignore"
    # Deleting ADR-0003's negation is the hard gate's case: exit 1, its own text.
    if [ "$rule" = '!.claude/agents/' ]; then
        warn "$drift_repo" >/dev/null && unreported+=("$rule (hard gate passed)")
        continue
    fi
    out="$(warn "$drift_repo")" || { unreported+=("$rule (exit non-zero)"); continue; }
    grep -qF -- "$rule" <<<"$out" || unreported+=("$rule")
done
if [ "${#unreported[@]}" -eq 0 ]; then
    _pass "deleting any one of the ${#template_rules[@]} template rules is reported, exit 0"
else
    _fail "deleting any one template rule is reported, exit 0" "unreported: ${unreported[*]}"
fi

# The printed remediation is a command, and running it clears the drift.
grep -vxF '.kata.toml' "$DEV_BASE/.gitignore.template" > "$drift_repo/.gitignore"
fix="$(warn "$drift_repo" | grep -F "printf '%s\n'" | sed 's/^ *//' || true)"
assert_nonempty "a missing rule comes with an append command" "$fix"
bash -c "$fix"
assert_eq "running the printed command clears the warning" "" "$(warn "$drift_repo")"

# The PR 167 migration: a live file from before .envrcs/.env.* lacks the rule
# AND its '!' re-include. The printed command must restore both, in order, or
# the appended glob swallows the tracked templates.
grep -vxF -e '.envrcs/.env.*' -e '!.envrcs/.env.*.template' "$DEV_BASE/.gitignore.template" \
    > "$drift_repo/.gitignore"
fix="$(warn "$drift_repo" | grep -F "printf '%s\n'" | sed 's/^ *//' || true)"
bash -c "$fix"
assert_eq "a missing rule followed by a template '!' rule is fixed by the command" \
    "" "$(warn "$drift_repo")"

# A personal extra that ignores what the template re-includes is drift too.
{ cat "$DEV_BASE/.gitignore.template"; echo '.envrcs/.env.*.template'; } > "$drift_repo/.gitignore"
assert_contains "an extra rule defeating a template negation is reported" \
    '!.envrcs/.env.*.template' "$(warn "$drift_repo")"

# A live file lacking only a '!' rule gets a command too, and it clears.
grep -vxF '!.envrcs/.env.*.template' "$DEV_BASE/.gitignore.template" > "$drift_repo/.gitignore"
fix="$(warn "$drift_repo" | grep -F "printf '%s\n'" | sed 's/^ *//' || true)"
assert_contains "a missing '!' rule is in the append command" '!.envrcs/.env.*.template' "$fix"
bash -c "$fix"
assert_eq "...and running it clears the warning" "" "$(warn "$drift_repo")"

# No live file: one line saying how to start one, not every rule as drift
# (a fresh clone, and every CI lint run).
rm "$drift_repo/.gitignore"
out="$(warn "$drift_repo" || true)"
assert_contains "an absent live .gitignore is named, with the cp to fix it" \
    "cp .gitignore.template .gitignore" "$out"
assert_eq "...in one line" "1" "$(wc -l <<<"$out" | tr -d ' ')"

# The comparison is file against file. A global excludesFile, or one passed
# with `git -c` (which reaches a hook as GIT_CONFIG_PARAMETERS), must not mask
# a rule the live FILE lacks: the host's global ignore does not reach the
# container (setup_git copies only user.name and user.email).
grep -vxF '.kata.toml' "$DEV_BASE/.gitignore.template" > "$drift_repo/.gitignore"
printf '.kata.toml\n' > "$tmp/global-excludes"
printf '[core]\n\texcludesFile = %s\n' "$tmp/global-excludes" > "$tmp/global-config"
out="$(GIT_CONFIG_GLOBAL="$tmp/global-config" XDG_CONFIG_HOME="$tmp/xdg" "$check" "$drift_repo" 2>&1 >/dev/null || true)"
assert_contains "a global excludesFile does not mask a rule the live file lacks" ".kata.toml" "$out"
out="$(GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="$tmp/xdg" \
    GIT_CONFIG_PARAMETERS="'core.excludesfile'='$tmp/global-excludes'" \
    "$check" "$drift_repo" 2>&1 >/dev/null || true)"
assert_contains "an inherited git -c excludesFile does not mask it either" ".kata.toml" "$out"

# A drift comparison git cannot run must not read as "no drift": a template
# rule check-ignore rejects makes the probe exit non-zero.
cp "$DEV_BASE/.gitignore.template" "$drift_repo/.gitignore"
{ cat "$DEV_BASE/.gitignore.template"; echo '/'; } > "$drift_repo/.gitignore.template"
assert_false "a check-ignore failure on the drift side exits non-zero" \
    env GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="$tmp/xdg" "$check" "$drift_repo"
cp "$DEV_BASE/.gitignore.template" "$drift_repo/.gitignore.template"

# Rule shapes the real template does not carry yet, in a template of their
# own: an anchored rule (whose probe must lose its leading `/`, or git rejects
# it as outside the repository) and a rule holding a single quote (which the
# printed command must escape). Each, missing from the live file, is reported
# by a command that clears it.
shapes_template="$(cat "$DEV_BASE/.gitignore.template"; printf '%s\n' '/anchored-rule' "it's-a-rule")"
printf '%s\n' "$shapes_template" > "$drift_repo/.gitignore.template"
for rule in '/anchored-rule' "it's-a-rule"; do
    grep -vxF -- "$rule" <<<"$shapes_template" > "$drift_repo/.gitignore"
    fix="$(warn "$drift_repo" | grep -F "printf '%s\n'" | sed 's/^ *//' || true)"
    assert_contains "a missing rule shaped $rule is in the append command" "$rule" "$(warn "$drift_repo" || true)"
    bash -c "$fix" 2>/dev/null || true
    assert_eq "...and the printed command clears $rule" "" "$(warn "$drift_repo" || true)"
done

# A template of comments only has nothing to compare: no output, exit 0 (an
# empty probe list would otherwise hand check-ignore a blank path).
printf '# comments only\n\n' > "$drift_repo/.gitignore.template"
assert_eq "a template with no rules draws no warning" "" "$(warn "$drift_repo")"

# The scratch repos go away with the run, on the drift path and the clean one.
mkdir -p "$tmp/tmpdir"
cp "$DEV_BASE/.gitignore.template" "$drift_repo/.gitignore.template"
grep -vxF '.kata.toml' "$DEV_BASE/.gitignore.template" > "$drift_repo/.gitignore"
TMPDIR="$tmp/tmpdir" warn "$drift_repo" >/dev/null || true
cp "$DEV_BASE/.gitignore.template" "$drift_repo/.gitignore"
TMPDIR="$tmp/tmpdir" warn "$drift_repo" >/dev/null || true
assert_eq "the drift check leaves no scratch dir behind" "" "$(ls -A "$tmp/tmpdir")"

# No template, nothing to compare: a consumer repo gets no drift output.
rm "$drift_repo/.gitignore.template"
: > "$drift_repo/.gitignore"
assert_eq "a checkout without .gitignore.template draws no warning" "" "$(warn "$drift_repo")"

# As a pre-commit hook in a linked worktree, the probe runs with git's own
# GIT_DIR (and GIT_INDEX_FILE) exported. The drift check's scratch `git init`
# then re-initialised THAT repo, writing core.bare=true into the shared config,
# so the main checkout stopped being a work tree. Reproduced here against a
# disposable main checkout and worktree, never a real one. The drift assertion
# is a control: it held even with the bug (`-C "$scratch"` still made the
# scratch dir the work tree), so only the config assertion pins the fix.
hook_main="$(new_repo "$tmp/hookmain")"
git -C "$hook_main" worktree add -q "$tmp/hookwt" -b hookwt
cp "$DEV_BASE/.gitignore.template" "$tmp/hookwt/.gitignore.template"
grep -vxF '.kata.toml' "$DEV_BASE/.gitignore.template" > "$tmp/hookwt/.gitignore"
hook_out="$(cd "$tmp/hookwt" && GIT_DIR="$(git rev-parse --absolute-git-dir)" \
    GIT_INDEX_FILE="$(git rev-parse --absolute-git-dir)/index" \
    GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="$tmp/xdg" "$check" 2>&1 >/dev/null || true)"
assert_eq "under an exported GIT_DIR, the main checkout's config is not made bare" \
    "false" "$(git -C "$hook_main" config --get core.bare || echo unset)"
assert_contains "under an exported GIT_DIR, drift is still reported" ".kata.toml" "$hook_out"

# Wiring: a probe only guards if its consumers run it.
assert_true "the pre-commit local hook runs the probe" \
    grep -q 'entry: dev/check-gitignore-agents' "$DEV_BASE/.pre-commit-config.yaml"
assert_true "the hook runs even when no files match" \
    bash -c "grep -A5 'id: gitignore-agents-reinclusion' '$DEV_BASE/.pre-commit-config.yaml' | grep -q 'always_run: true'"
assert_true "pre-commit shows the hook's output, where the drift warning goes" \
    bash -c "grep -A7 'id: gitignore-agents-reinclusion' '$DEV_BASE/.pre-commit-config.yaml' | grep -q 'verbose: true'"
assert_true "setup-worktree warns through the same probe" \
    grep -q 'check-gitignore-agents' "$DEV_BASE/dev/setup-worktree"
# ...but only where ADR-0003's convention is in force. setup-worktree runs on
# every `devcontainer up` in a non-main worktree for ANY project, so an
# ungated warning is per-start noise in consumer repos that simply ignore
# .claude/ — and its "commits will be blocked" claim is false there, since the
# hard gate is this repo's .pre-commit-config.yaml.
assert_true "the setup-worktree warning is gated on the repo tracking .claude/agents" \
    grep -q 'ls-files -- .claude/agents' "$DEV_BASE/dev/setup-worktree"
assert_true "the extensionless shellcheck hook covers the probe script" \
    bash -c "grep -F '^dev/(' '$DEV_BASE/.pre-commit-config.yaml' | grep -q 'check-gitignore-agents'"

echo ""
finish
