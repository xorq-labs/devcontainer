#!/usr/bin/env bash
# Guard: dev/hooks/pre-commit must survive resolving the main checkout and reach
# its `exec pre-commit hook-impl`, in a repo with many worktrees — AND, section 5,
# the second copy of that pipeline, dev_main_tree() in lib/git.sh. The invariant
# names both sites, so one suite covers both or the `test:` citation is half true.
#
# The failure it exists for: `git worktree list --porcelain | head -1` makes git
# die of SIGPIPE, and `set -o pipefail` turns that into a hook that exits 141
# AFTER the assignment has already succeeded. A failing hook produces no message
# of its own, so `git commit` aborts with exit 1 and EMPTY stdout and stderr —
# the least diagnosable shape a failure can take, and the natural response is to
# retry until it works.
#
# Size-dependent, which is why it hid: git's stdio buffer flushes at 4 KB, so
# output under one buffer is written once at exit and never notices the closed
# pipe. Measured on the real repo — 3014 bytes (24 worktrees) SIGPIPEs 0/5 while
# 4478 bytes (36) does it 5/5. The fixture therefore adds worktrees until the
# porcelain output passes 6 KB rather than hardcoding a count, since bytes per
# entry follow path length.
#
# dev_main_tree() in lib/git.sh had the same `| head -1` and takes the same fix.
# It shipped with the rationale that piping a builtin `printf` is one write and
# therefore safe below the 64 KB pipe capacity; that is measurably false —
# printf writes in many small chunks, and the pipeline fails intermittently from
# around 60 KB of input (13/200 at 61 KB, 200/200 at 100 KB). Nobody has 500
# worktrees, so the practical risk was nil, but "safe because racy in our
# favour" is not a fact worth recording, so both sites are raceless now.
#
# The MAIN value is asserted, not just its exit status: resolving it is the only
# reason that line exists, and a hook that "works" by resolving nothing would
# lose the container/worktree fallback it was written for (#7).
#
# Verified (ADR-0005 §2), three mutations:
#   1. FORM-ONLY — respell the fix as `sed -e '1!d' -e 's/^worktree //'` (same
#      read-to-EOF behaviour, different sed program). Green: 16 passed, 0
#      failed — assertion count unchanged.
#   2. SEMANTIC, in the form this bug actually shipped in — restore
#      `| head -1` in dev/hooks/pre-commit. Observed red on 10 assertions:
#      "the shipped form resolves the main checkout and survives", both
#      "exits 0" checks, "dispatched exactly once", all four argv checks, the
#      worktree .tools/bin check, and the install hint.
#      Results: 6 passed, 10 failed
#   3. SEMANTIC, narrow — drop `--hook-dir` from all three exec branches, i.e.
#      revert 12c15c7's flag. Observed red:
#        FAIL: passes --hook-dir
#      Results: 15 passed, 1 failed
#   The pair earns its place twice over: mutation 2 found TWO fail-opens in
#   this suite as first written, neither of them in the code under test.
#   (a) It ABORTED instead of reporting — the failure being guarded is a
#       non-zero exit, and `set -e` in the suite turned that into a dead run
#       with no summary at all. Hence run_hook()'s captured status.
#   (b) The "shipped form" check passed against the reverted hook, because
#       $MAIN holds the right value even when the pipeline SIGPIPEs and the
#       check leaned on `set -e` to notice. Only an explicit `status=$?`
#       distinguishes the two forms. That is this bug's whole character —
#       correct value, poisoned status — so the guard reproduced the bug's
#       invisibility inside itself.
#   (mutation runs 2026-08-19)
#
# Section 5 was added after an independent review found this suite fully green
# with dev_main_tree() reverted: the invariant named two copies of the pipeline
# and only one was guarded. Its own §2 runs:
#   4. SEMANTIC, in the form the bug shipped in — restore `| head -1` in
#      dev_main_tree(). Observed red:
#        FAIL: the shipped dev_main_tree pipeline survives 148284 bytes
#      Results: 20 passed, 1 failed. The VALUE assertion stayed green, which is
#      this bug's whole character and why section 5 asserts status AND value.
#   5. FORM-ONLY — respell the fix as `sed -e '1!d' -e 's/^worktree //'` (same
#      read-to-EOF, different program). Green: 21 passed, 0 failed, no drop.
#   6. FAIL-CLOSED PROBE — move the pipe to a continuation line so the lift
#      anchor cannot match. The line still parses and behaves identically, so a
#      guard that cannot find what it lifts must REPORT. First run produced NO
#      OUTPUT AT ALL: `grep -m1` exits 1 on no match and `set -e` killed the run
#      before any assertion could speak. That is fail-open (a) above, reintroduced
#      by the new section — hence `|| true` on BOTH lifts; the `^MAIN=` one had
#      the same defect latent. After the fix, red:
#        FAIL: dev_main_tree's pipeline is still findable in lib/git.sh
#        FAIL: and still resolves the first worktree
#      Results: 19 passed, 2 failed
#   7. The same probe against the pre-existing lift — break the hook's `MAIN=`
#      across a continuation. Reports rather than aborting: 11 passed, 10 failed.
#   Mutations 4-6 all ran green locally and section 5 STILL failed in CI, on the
#   anchor: it pinned exit 141, which only holds where SIGPIPE is default. The
#   failing element is a bash builtin, and Actions runs steps with SIGPIPE
#   ignored, so the builtin gets EPIPE back and exits 1 instead of dying. Fixed
#   by asserting non-zero — the invariant was always "the old form fails", never
#   a particular code — and both dispositions are now exercised here:
#     default SIGPIPE   status 141, 21 passed / 0 failed; revert -> 20/1
#     SIGPIPE ignored   status 1,   21 passed / 0 failed; revert -> 20/1
#   (`trap '' PIPE` in the parent reproduces the CI shape.) Section 1's anchor
#   keeps its 141: it pipes GIT, a real process that resets SIGPIPE to default,
#   so there the signal is portable and worth naming.
#   (mutation runs 2026-08-21)
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
hook="$DEV_BASE/dev/hooks/pre-commit"

echo "--- dev/hooks/pre-commit: main-checkout resolution under many worktrees ---"

assert_true "the hook is executable" test -x "$hook"

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

# A stand-in for pre-commit: records its argv, answers --version so the hook's
# is_runnable() probe passes, and exits 0.
mk_stub() {
    local path="$1" tag="$2"
    mkdir -p "$(dirname "$path")"
    cat >"$path" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && { echo "pre-commit 0.0.0-$tag"; exit 0; }
printf '%s\n' "$tag \$*" >>"$tmp/argv.log"
exit 0
STUB
    chmod +x "$path"
}

# Fixture: a repo carrying the real hook, with enough worktrees that the
# porcelain output clears git's 4 KB flush boundary with margin.
repo="$(new_repo "$tmp/repo")"
mkdir -p "$repo/dev/hooks"
cp "$hook" "$repo/dev/hooks/pre-commit"
git -C "$repo" add -A >/dev/null
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm hooks
n=0
while [ "$(git -C "$repo" worktree list --porcelain | wc -c)" -le 6144 ]; do
    n=$((n + 1))
    git -C "$repo" worktree add -q -b "branch$n" "$tmp/worktree-number-$n" >/dev/null 2>&1
done
bytes="$(git -C "$repo" worktree list --porcelain | wc -c)"
assert_true "fixture clears git's 4 KB flush boundary ($bytes bytes, $n worktrees)" \
    [ "$bytes" -gt 4096 ]

# --- 1. the fixture really does reproduce the failure it guards against ---
# If a future git stops signalling here, THIS goes red rather than the suite
# passing vacuously on a fixture that no longer reproduces anything.
old_form_status=0
(
    cd "$repo" && set -o pipefail
    git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //' >/dev/null
) || old_form_status=$?
assert_eq "the historical '| head -1' form still dies of SIGPIPE here" \
    "141" "$old_form_status"

# The shipped form, lifted out of the hook rather than restated. `|| true`
# because a lift that finds nothing must REPORT, not abort: grep exits 1 on no
# match and `set -e` would kill the run before the assertion below can say so.
main_line="$(grep -m1 '^MAIN=' "$hook" || true)"
assert_nonempty "the MAIN= assignment is still findable in the hook" "$main_line"
new_form_status=0
(
    # The assignment's own status, captured explicitly rather than left to
    # `set -e`: $MAIN still holds the right value even when the pipeline
    # SIGPIPEs, so only the status distinguishes the two forms — and relying on
    # -e to surface it made this check pass against a reverted hook.
    cd "$repo" && set -o pipefail
    eval "$main_line"
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    [ "$MAIN" = "$repo" ] || exit 9
) || new_form_status=$?
assert_eq "the shipped form resolves the main checkout and survives" \
    "0" "$new_form_status"

# --- 2. the hook reaches its exec, and passes hook-impl what it needs ---
mk_stub "$tmp/bin/pre-commit" PATH
: >"$tmp/argv.log"

# run_hook <dir> — the hook as git runs it, exit status captured rather than
# allowed to abort the suite: the failure this guards against IS a non-zero
# exit, so it has to be reportable, not fatal.
run_hook() {
    local status=0
    (cd "$1" && PATH="$tmp/bin:$PATH" "$BASH" "$1/dev/hooks/pre-commit") || status=$?
    printf '%s\n' "$status"
}

assert_eq "the hook exits 0 from the main checkout" "0" "$(run_hook "$repo")"
assert_eq "and dispatched exactly once" \
    "1" "$(grep -c '^PATH ' "$tmp/argv.log")"
argv="$(cat "$tmp/argv.log")"
assert_contains "invokes hook-impl" "hook-impl" "$argv"
assert_contains "names the config" "--config=.pre-commit-config.yaml" "$argv"
assert_contains "names the hook type" "--hook-type=pre-commit" "$argv"
# --hook-dir is load-bearing: without it newer pre-commit crashes on a None
# path join instead of erroring cleanly (12c15c7).
assert_contains "passes --hook-dir" "--hook-dir=" "$argv"

# --- 3. from a linked worktree, MAIN's .tools/bin wins over PATH ---
# This is what the MAIN= line is FOR: a worktree ships no .tools/ of its own.
wt="$tmp/worktree-number-1"
mk_stub "$repo/.tools/bin/pre-commit" MAINTOOLS
: >"$tmp/argv.log"
assert_eq "the hook exits 0 from a linked worktree" "0" "$(run_hook "$wt")"
assert_eq "a worktree commit uses the main checkout's .tools/bin/pre-commit" \
    "1" "$(grep -c '^MAINTOOLS ' "$tmp/argv.log")"
assert_eq "and not the one on PATH" "0" "$(grep -c '^PATH ' "$tmp/argv.log")"

# --- 4. nothing runnable anywhere: a named failure, not a silent one ---
rm -f "$repo/.tools/bin/pre-commit"
# A PATH carrying exactly what the hook shells out to — git and sed — and no
# pre-commit. Emptying PATH outright would take bash and git with it and the
# hook would die before reaching the branch under test.
mkdir -p "$tmp/minbin"
ln -sf "$(command -v git)" "$tmp/minbin/git"
ln -sf "$(command -v sed)" "$tmp/minbin/sed"
assert_eq "the minimal PATH really has no pre-commit on it" "" \
    "$(PATH="$tmp/minbin" command -v pre-commit || true)"
err="$(cd "$wt" && PATH="$tmp/minbin" "$BASH" "$wt/dev/hooks/pre-commit" 2>&1 >/dev/null || true)"
assert_contains "says how to install pre-commit when it is missing" \
    "uv tool install pre-commit" "$err"

# --- 5. the OTHER site the invariant names: dev_main_tree() in lib/git.sh ---
# One invariant, two copies of the pipeline, so both are guarded here or the
# `test:` citation covers half of what it claims. dev_main_tree() captures git's
# output first and pipes a builtin printf, so its threshold is the ~60 KB where
# printf's chunked writes start meeting a closed pipe rather than git's 4 KB —
# hence a fixture of its own rather than reuse of the one above.
#
# The pipeline is LIFTED out of lib/git.sh, never restated: `$out` is the only
# thing dev_main_tree pipes, so the anchor stays unique under reformatting.
lib_line="$(grep -m1 '"\$out" |' "$DEV_BASE/lib/git.sh" || true)"
assert_nonempty "dev_main_tree's pipeline is still findable in lib/git.sh" "$lib_line"

# Sized well past the threshold on purpose: the race window itself (~60 KB) is
# intermittent by definition, and a guard that fails 13/200 of the time is not a
# guard. At this size both forms are deterministic (measured 5/5 either way).
big=""
for i in $(seq 1 900); do
    big+="worktree $tmp/a-worktree-with-a-realistically-long-path-number-$i
HEAD 0000000000000000000000000000000000000000
branch refs/heads/branch-number-$i

"
done
assert_true "the synthetic listing clears printf's threshold (${#big} bytes)" \
    [ "${#big}" -gt 65536 ]

# Status AND value, for the reason section 2 spells out: $out's first line is
# right even when the pipeline is signalled, so neither alone tells the forms
# apart.
lib_status=0
(
    set -o pipefail
    out="$big"
    eval "$lib_line" >"$tmp/lib-main.txt"
) || lib_status=$?
assert_eq "the shipped dev_main_tree pipeline survives ${#big} bytes" "0" "$lib_status"
assert_eq "and still resolves the first worktree" \
    "$tmp/a-worktree-with-a-realistically-long-path-number-1" \
    "$(cat "$tmp/lib-main.txt")"

# The anti-vacuous anchor, same role as section 1's: if the old form ever stops
# failing here, THIS goes red rather than the check above passing for free on a
# fixture that reproduces nothing.
#
# NON-ZERO, not 141 — unlike section 1, which pipes GIT and can name the signal.
# The failing element here is a bash BUILTIN, and how a builtin reports a closed
# pipe depends on the shell's SIGPIPE disposition, which is not ours to fix:
# killed by the signal (141) when SIGPIPE is default, but a returned EPIPE plus
# `write error: Broken pipe` (status 1) when the parent has it ignored or
# handled. GitHub Actions runs steps the second way, so pinning 141 failed in CI
# while passing locally. Either status breaks the commit identically, so the
# invariant is "it fails", and the exact code was never part of it.
old_lib_status=0
(
    set -o pipefail
    out="$big"
    printf '%s\n' "$out" 2>/dev/null | head -1 | sed 's/^worktree //' >/dev/null
) || old_lib_status=$?
assert_true "the historical '| head -1' form still fails at this size (status $old_lib_status)" \
    [ "$old_lib_status" -ne 0 ]

finish
