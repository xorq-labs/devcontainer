#!/usr/bin/env bash
# Guard for dev/check-adr, which is itself the guard for the ADR conventions
# in docs/adr/README.md (ADR-numbers-come-from-pull-requests). Two halves,
# matching the two the script has: the hermetic checks run against synthetic
# ADR directories built here, and the pull-request-number check runs against a
# real disposable repo with a real diff.
#
# The live docs/adr/ is also asserted green, deriving rather than restating:
# nothing here lists our real ADRs, so a status that goes stale or a citation
# that stops resolving fails at this line rather than at review.
#
# Verified (ADR-0005 §2), mutation run 2026-08-15, four runs at 46 assertions:
#   FORM-ONLY, on the source the guard parses — reordered the real
#   docs/adr/0005 header list items (Date above Status) and reflowed its
#   wrapped status onto one long line: 46 passed, 0 failed, assertion count
#   unchanged. The guard anchors on `^- Status:` rather than on position or
#   width, so neither move is visible to it.
#   SEMANTIC A, in a form I did not write — relaxed the status gate by
#   replacing the `[ "$num" = XXXX ]` condition with `true` (a plausible
#   loosening rather than a deletion): 43 passed, 3 failed.
#   SEMANTIC B — commented out the `check_allowlist` call: 45 passed, 1 failed.
#   SEMANTIC C — substituted `cat` for `strip_shown_code`, so shown code counts
#   as cited: 42 passed, 4 failed, one of them "the repo's own docs/adr passes".
#   Three semantic runs rather than one because each aims at a different half,
#   and a single mutation confirms the hole you just closed while missing the
#   parsing assumption you did not know you had made.
#
# The "unparseable status line" assertion below exists because the FIRST draft
# of dev/check-adr skipped any file whose status it could not find — the #86
# and #96 fail-open shape, reproduced inside the new guard on its first day and
# caught by writing the status in xorq's bolded format rather than this repo's.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
check="$DEV_BASE/dev/check-adr"

echo "--- check-adr: the ADR conventions guard ---"

[ -x "$check" ] || { echo "  FAIL: $check not found or not executable"; exit 1; }

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

# adr <dir> <filename> [status] [body] — write a minimally valid ADR whose
# heading is derived from the filename, so a fixture cannot accidentally test
# heading drift unless it asks to.
adr() {
    local dir="$1" file="$2" status="${3:-Accepted (2026-08-15 — fixture)}" body="${4:-}"
    local num="${file%%-*}"
    mkdir -p "$dir/docs/adr"
    {
        printf '# ADR-%s: fixture\n\n' "$num"
        printf -- '- Status: %s\n' "$status"
        printf -- '- Date: 2026-08-15\n\n'
        printf '## Context\n\n%s\n' "$body"
    } > "$dir/docs/adr/$file"
}

# fresh <name> — a fixture tree with one valid ADR already in it, so that a
# suite case adds exactly the defect it is about.
fresh() {
    local dir="$tmp/$1"
    rm -rf "$dir"
    adr "$dir" "0100-baseline.md"
    printf '%s\n' "$dir"
}

quiet() { "$check" --repo "$1" >/dev/null 2>&1; }

# --- the live tree ----------------------------------------------------------

assert_true "the repo's own docs/adr passes" quiet "$DEV_BASE"

# --- filenames --------------------------------------------------------------

d="$(fresh names)"; adr "$d" "100-short.md"
assert_false "a number with fewer than four digits is rejected" quiet "$d"

d="$(fresh names)"; adr "$d" "0101-Mixed_Case.md"
assert_false "a slug that is not lowercase-hyphenated is rejected" quiet "$d"

d="$(fresh names)"; cp "$d/docs/adr/0100-baseline.md" "$d/docs/adr/notes.md"
assert_false "a stray .md that is neither an ADR nor a meta file is rejected" quiet "$d"

d="$(fresh names)"; adr "$d" "XXXX-in-flight.md" "Proposed"
assert_true "a draft still carrying XXXX passes, and may read Proposed" quiet "$d"

# --- headings ---------------------------------------------------------------

d="$(fresh heading)"
printf '# ADR-0999: fixture\n\n- Status: Accepted\n' > "$d/docs/adr/0101-disagrees.md"
assert_false "a heading that disagrees with the filename is rejected" quiet "$d"

d="$(fresh heading)"
printf 'no heading here\n\n- Status: Accepted\n' > "$d/docs/adr/0101-headless.md"
assert_false "a missing heading is rejected" quiet "$d"

# --- uniqueness -------------------------------------------------------------

d="$(fresh unique)"; adr "$d" "0100-second-file-same-number.md"
assert_false "two ADRs sharing a number are rejected" quiet "$d"

d="$(fresh unique)"; adr "$d" "0101-baseline.md"
assert_false "two ADRs sharing a slug are rejected" quiet "$d"

# --- status -----------------------------------------------------------------

d="$(fresh status)"; adr "$d" "0101-open.md" "Proposed"
assert_false "a numbered ADR reading bare Proposed is rejected" quiet "$d"

d="$(fresh status)"; adr "$d" "0101-open.md" "Proposed (decision due 2026-12-01)"
assert_true "a landed proposal with a decision date passes" quiet "$d"

d="$(fresh status)"; adr "$d" "0101-gone.md" "Superseded by ADR-0100"
assert_true "Superseded by an existing ADR passes" quiet "$d"

d="$(fresh status)"; adr "$d" "0101-odd.md" "Pending"
assert_false "a status outside the vocabulary is rejected" quiet "$d"

# The fail-closed case, and the reason it is asserted separately: the first
# draft of the guard skipped a file whose status line it could not find, so a
# reformat could silently exempt an ADR from the whole rule.
d="$(fresh status)"
printf '# ADR-0101: fixture\n\n- **Status:** Proposed\n' > "$d/docs/adr/0101-bold.md"
assert_false "an unparseable status line is an error, not a silent pass" quiet "$d"

# --- references -------------------------------------------------------------

d="$(fresh refs)"; adr "$d" "0101-cites.md" "Accepted" "See ADR-0777 for context."
assert_false "a numeric reference to an ADR that does not exist is rejected" quiet "$d"

d="$(fresh refs)"; adr "$d" "0101-cites.md" "Accepted" "See ADR-not-landed-yet for context."
assert_true "a named reference that does not resolve is a warning, not an error" quiet "$d"
out="$("$check" --repo "$d" 2>&1 >/dev/null || true)"
assert_contains "...and it says so" "ADR-not-landed-yet" "$out"

d="$(fresh refs)"; adr "$d" "0101-cites.md" "Accepted" 'A shown `ADR-0777` is not a citation.'
assert_true "a reference inside an inline code span is not a citation" quiet "$d"

# The multi-line span: prose wraps at 78 columns, so a span that opens on one
# line and closes on the next is ordinary, and a per-line strip reports it as a
# citation. Found by running the guard against the ADR that introduces it.
d="$(fresh refs)"
adr "$d" "0101-cites.md" "Accepted" 'The clause `ADR-0777 is reserved by
someone else` was deleted.'
assert_true "an inline span wrapped across a line break is still not a citation" quiet "$d"

d="$(fresh refs)"
adr "$d" "0101-cites.md" "Accepted" '```
ADR-0777 appears in a fenced block.
```'
assert_true "a reference inside a fenced block is not a citation" quiet "$d"

# --- vacuity ----------------------------------------------------------------

d="$tmp/empty"; mkdir -p "$d/docs/adr"
assert_false "an ADR directory with no ADRs fails rather than passing vacuously" quiet "$d"

# --- the pull-request number ------------------------------------------------
#
# The half that needs a real diff: --base names what to compare against and
# --pr what the number must equal.

pr_fixture() {
    local dir="$tmp/$1"
    rm -rf "$dir"
    new_repo "$dir" >/dev/null
    adr "$dir" "0100-baseline.md"
    git -C "$dir" add -A && git -C "$dir" commit -qm "baseline"
}

pr_check() { "$check" --repo "$1" --base main --pr "$2" >/dev/null 2>&1; }

pr_fixture prnum; d="$tmp/prnum"
git -C "$d" checkout -qb feature
adr "$d" "0150-matches.md"
git -C "$d" add -A && git -C "$d" commit -qm "add adr"
assert_true "an added ADR numbered after its pull request passes" pr_check "$d" 150
assert_false "the same ADR fails against a different pull request number" pr_check "$d" 151

pr_fixture placeholder; d="$tmp/placeholder"
git -C "$d" checkout -qb feature
adr "$d" "XXXX-unnumbered.md" "Proposed"
git -C "$d" add -A && git -C "$d" commit -qm "add draft"
assert_false "an added ADR still carrying XXXX fails the pull request check" pr_check "$d" 150
assert_true "...but the same tree passes the directory checks on their own" quiet "$d"

pr_fixture floor; d="$tmp/floor"
git -C "$d" checkout -qb feature
adr "$d" "0007-legacy-looking.md"
git -C "$d" add -A && git -C "$d" commit -qm "add adr"
assert_false "an added ADR below the legacy floor is rejected" pr_check "$d" 150

pr_fixture two; d="$tmp/two"
git -C "$d" checkout -qb feature
adr "$d" "0150-first.md"; adr "$d" "0150-second.md"
git -C "$d" add -A && git -C "$d" commit -qm "add two"
assert_false "two ADRs added by one pull request are rejected" pr_check "$d" 150

# The allowlist, derived from the guard's own table rather than restated: the
# entry named in dev/check-adr must be exempt from the floor, and must report
# itself once it has landed.
allow="$(awk '/^LEGACY_IN_FLIGHT=\(/{f=1;next} f&&/^\)/{exit} f{gsub(/[" ]/,"");sub(/\|.*/,"");print}' "$check")"
assert_nonempty "the allowlist is readable from dev/check-adr" "$allow"

pr_fixture allowed; d="$tmp/allowed"
git -C "$d" checkout -qb feature
adr "$d" "$allow"
git -C "$d" add -A && git -C "$d" commit -qm "land the allowlisted adr"
assert_true "the allowlisted legacy ADR may land at its reserved number" pr_check "$d" 150

pr_fixture spent; d="$tmp/spent"
adr "$tmp/spent" "$allow"
git -C "$d" add -A && git -C "$d" commit -qm "already landed"
git -C "$d" checkout -qb feature
git -C "$d" commit -qm "unrelated" --allow-empty
assert_true "a spent allowlist entry does not fail the run" pr_check "$d" 150
out="$("$check" --repo "$d" --base main --pr 150 2>&1 >/dev/null || true)"
assert_contains "...it asks for its own deletion instead" "should be deleted" "$out"

# --- dev/adr-rename ---------------------------------------------------------
#
# The `tool:` half: it writes the number, so it is the only thing standing
# between a human and a wrong one. Its sweep rewrites tracked files, which is
# why the "leaves shown code alone" rule is asserted rather than trusted — a
# sweep that rewrote README.md's own examples would turn the convention's
# documentation into nonsense on the first ADR that landed.

rename="$DEV_BASE/dev/adr-rename"
d="$tmp/rename"
rm -rf "$d"; new_repo "$d" >/dev/null
mkdir -p "$d/docs/adr" "$d/bin"
adr "$d" "XXXX-a-new-decision.md" "Proposed"
printf 'Prose cites ADR-a-new-decision, and a shown `ADR-a-new-decision` does not.\n' \
    > "$d/docs/adr/README.md"
printf '# see ADR-a-new-decision\n' > "$d/bin/script"
git -C "$d" add -A && git -C "$d" commit -qm "draft"

# Stub the forge: the number comes from `gh pr view`, and the point of the tool
# is that nobody types it.
mkdir -p "$d/stub"
printf '#!/bin/sh\necho 150\n' > "$d/stub/gh"
chmod +x "$d/stub/gh"

( cd "$d" && PATH="$d/stub:$PATH" "$rename" >/dev/null 2>&1 )

assert_true "adr-rename renames the draft to its pull request number" \
    test -f "$d/docs/adr/0150-a-new-decision.md"
assert_false "...and the XXXX draft is gone" test -f "$d/docs/adr/XXXX-a-new-decision.md"
assert_contains "...the heading moves with the filename" "# ADR-0150:" \
    "$(cat "$d/docs/adr/0150-a-new-decision.md")"
assert_contains "...a named citation in prose becomes the number" \
    "Prose cites ADR-0150," "$(cat "$d/docs/adr/README.md")"
assert_contains "...a named citation in an inline span is left alone" \
    '`ADR-a-new-decision`' "$(cat "$d/docs/adr/README.md")"
assert_contains "...and a citation in a non-Markdown file is rewritten" \
    "# see ADR-0150" "$(cat "$d/bin/script")"
# Renaming numbers an ADR; it does not accept one. The guard says so, which is
# the handoff working rather than a gap: adr-rename prints the same reminder,
# and the author is the only one who can decide the status.
assert_false "a renamed ADR still reading Proposed does not pass" pr_check "$d" 150
out="$("$check" --repo "$d" --base main --pr 150 2>&1 >/dev/null || true)"
assert_contains "...and the guard names the status as the reason" "merging one accepts it" "$out"
sed -i 's/^- Status: Proposed$/- Status: Accepted (2026-08-15 — fixture)/' \
    "$d/docs/adr/0150-a-new-decision.md"
assert_true "accepting it makes the renamed tree pass against its pull request" \
    pr_check "$d" 150

# No pull request, no number: the tool refuses rather than inventing one.
d="$tmp/norename"
rm -rf "$d"; new_repo "$d" >/dev/null
adr "$d" "XXXX-no-forge.md" "Proposed"
git -C "$d" add -A && git -C "$d" commit -qm "draft"
mkdir -p "$d/stub"
printf '#!/bin/sh\nexit 1\n' > "$d/stub/gh"
chmod +x "$d/stub/gh"
assert_false "adr-rename refuses when the branch has no pull request" \
    env -C "$d" PATH="$d/stub:$PATH" "$rename"
assert_true "...and leaves the draft where it was" test -f "$d/docs/adr/XXXX-no-forge.md"

# --- wiring -----------------------------------------------------------------
#
# The pull-request half is unreachable without a CI event, so the workflow that
# supplies one is part of the guard. Asserting it here is what keeps a rename
# or a deleted job from quietly retiring the check (#86, #92, #93).

wf="$DEV_BASE/.github/workflows/adr.yml"
assert_true "the ADR workflow exists" test -f "$wf"
assert_contains "the workflow runs the guard" "dev/check-adr" "$(cat "$wf")"
assert_contains "the workflow passes the pull request number" "--pr" "$(cat "$wf")"
assert_not_contains "the workflow carries no paths: filter, or it can never be required" \
    "paths:" "$(cat "$wf")"

finish
