#!/usr/bin/env bash
# Tests for the harness's own assertion helpers (tests/lib/harness.sh).
#
# Why this exists: every other suite's correctness rests on these, and one of
# them has a trap that shipped a fail-open assertion. `assert_contains` matches
# a needle that is a PREFIX of a longer line, so an assertion about
# `<owner> /a/b` is satisfied by an unrelated `-R <owner> /a/b/c` — it passed
# while the behaviour it named had stopped happening (caught in review on
# PR #113, in a file that already documented the trap in a comment).
#
# `assert_line`/`assert_no_line` are the line-anchored forms. What is pinned
# here is the DIFFERENCE between the two families, because that difference is
# the whole reason the safe pair exists — if assert_line ever degraded to
# substring matching, every migrated call site would silently go fail-open
# again and nothing else would notice.
#
# Helpers are exercised through a subshell so a deliberate failure does not
# pollute this suite's own PASS/FAIL accounting: run_assert captures the
# helper's output and exit status, and this suite asserts on THOSE.
#
# Verified (ADR-0005 §2), two mutations, both run through tests/mutation-coverage
# (which reverts by construction — each runs in a throwaway copy):
#   1. `grep -qxF` -> `grep -qF` in both helpers, dropping the LINE ANCHORING
#      that is their entire reason to exist — 2 red: "assert_line REJECTS a
#      needle that is only a line prefix" and "assert_no_line ACCEPTS a needle
#      that is only a line prefix". Degrading assert_line to `[[ == *…* ]]`
#      is the same defect and reds the same pair.
#   2. the `--` end-of-options guard removed — 1 red, "a needle starting with a
#      dash is a needle, not an option". A distinct property from anchoring,
#      hence a separate mutation rather than a second spelling of the first.
#
# 3 of 11 assertions are red under those two. The rest pin the CONTRAST with
# assert_contains/assert_not_contains, whose behaviour these mutations do not
# touch — they would only move if the unsafe pair changed, which is itself the
# thing to notice. Run `tests/mutation-coverage tests/test-harness-assertions.sh
# '<cmd>'` to re-measure.
#   (mutation runs 2026-08-04)
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

echo "=== harness assertion-helper tests ==="

# run_assert <helper> <label> <needle> <haystack> — invoke a helper in a
# subshell and echo "pass" or "fail" for what the HELPER decided.
#
# The counters are the harness's own `PASS`/`FAIL` (not _passed/_failed —
# getting that wrong makes every case report "pass", including the failures,
# which is how this file's first draft was itself fail-open). Zeroed inside the
# subshell so the probe's outcome never reaches this suite's totals.
run_assert() {
    (
        # shellcheck disable=SC2034  # PASS is reset for isolation (the probe's
        # own passes must not reach this suite's totals) even though only FAIL
        # is read back.
        PASS=0 FAIL=0
        "$@" >/dev/null 2>&1
        [ "$FAIL" -eq 0 ] && printf 'pass' || printf 'fail'
    )
}

# The exact shape that shipped fail-open: an ancestor-style path assertion whose
# needle is a prefix of a longer recursive line.
LOG='-R alice:alice /home/u/repos/proj/.venv
alice:alice /home/u/repos'
PREFIX_NEEDLE='alice:alice /home/u/repos/proj'
WHOLE_NEEDLE='alice:alice /home/u/repos'

# ---- the trap, demonstrated ----
assert_eq "assert_contains ACCEPTS a needle that is only a line prefix (the trap)" \
    "pass" "$(run_assert assert_contains lbl "$PREFIX_NEEDLE" "$LOG")"
assert_eq "assert_line REJECTS a needle that is only a line prefix" \
    "fail" "$(run_assert assert_line lbl "$PREFIX_NEEDLE" "$LOG")"

# ---- and the negatives, where the trap inverts into a false PASS ----
# assert_not_contains is the more dangerous half: it reports "absent" only when
# the needle appears nowhere, so a prefix match makes it report a violation that
# has not happened — and, mirrored, lets a real one hide.
assert_eq "assert_not_contains reports a prefix-only needle as PRESENT" \
    "fail" "$(run_assert assert_not_contains lbl "$PREFIX_NEEDLE" "$LOG")"
assert_eq "assert_no_line ACCEPTS a needle that is only a line prefix" \
    "pass" "$(run_assert assert_no_line lbl "$PREFIX_NEEDLE" "$LOG")"

# ---- whole-line needles behave identically in both families ----
assert_eq "assert_line accepts a whole-line needle" \
    "pass" "$(run_assert assert_line lbl "$WHOLE_NEEDLE" "$LOG")"
assert_eq "assert_no_line rejects a whole-line needle" \
    "fail" "$(run_assert assert_no_line lbl "$WHOLE_NEEDLE" "$LOG")"

# ---- empty haystack: the other fail-open shape ----
# A negative assertion passes on empty output, which is also what a run that did
# NOTHING produces. That is not a bug in the helper — it is why a negative
# assertion needs a paired positive — but it must at least behave predictably.
assert_eq "assert_no_line passes on an empty haystack" \
    "pass" "$(run_assert assert_no_line lbl "$WHOLE_NEEDLE" "")"
assert_eq "assert_line fails on an empty haystack" \
    "fail" "$(run_assert assert_line lbl "$WHOLE_NEEDLE" "")"

# ---- needles that are not plain text ----
# grep -F, not -E: a needle containing regex metacharacters is compared
# literally. Paths in this repo really do contain `.` and `[`, and a helper that
# treated them as patterns would over-match silently.
META_LOG='alice:alice /home/u/a.b
alice:alice /home/u/axb'
assert_eq "a regex metacharacter in the needle is matched literally" \
    "fail" "$(run_assert assert_line lbl 'alice:alice /home/u/a.c' "$META_LOG")"
assert_eq "a literal needle with a dot still matches its own line" \
    "pass" "$(run_assert assert_line lbl 'alice:alice /home/u/a.b' "$META_LOG")"

# A needle starting with `-` must not be read as a grep option; the helpers pass
# `--` before it. `-R alice:alice ...` is exactly the shape of a chown log line.
assert_eq "a needle starting with a dash is a needle, not an option" \
    "pass" "$(run_assert assert_line lbl '-R alice:alice /home/u/repos/proj/.venv' "$LOG")"

finish
