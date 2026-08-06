#!/usr/bin/env bash
# Tests for the reuse/lock behavior of ensure_image() — the runtime half of the
# shared, fingerprint-tagged image that the fingerprint suite doesn't cover.
#
# A live multi-worktree round-trip against a real daemon stays a manual step (a
# real build pulls the ~0.76 GB nix base): what CI can and must pin down is the
# *decision* logic that makes sharing correct —
#   - present ref  -> reuse, no build (the whole point: siblings skip building);
#   - absent ref   -> build exactly once, then the ref is present;
#   - unhashable   -> refuse to build (never mint an image off a bad fingerprint);
#   - concurrent   -> the repo-scoped flock + in-lock double-check collapse a
#                     two-worktree race to a single build.
#
# So we run the *actual* ensure_image (extracted verbatim, as the fingerprint
# suite does for config_files) with docker/dc stubbed. No real docker: `docker
# image inspect` reads a marker file, `dc build` simulates a slow build. flock
# is real — the concurrency test genuinely races two processes on one lock.
# Verified (ADR-0005 §2 pair), second review round: the pairing walk compared
# against the previous non-blank line only, so `ensure_image && dc_up` and
# `ensure_image; dc_up` — genuinely paired, and plausible refactors — were
# FALSE FAILs at 17/1. Admitted explicitly. Detection is unchanged: deleting
# either call site is 17/1, commenting both out is 16/2, and the form-only
# signature reformat still holds at 18 (mutation runs 2026-08-04).
#
# Known and accepted, per tests/lib/shellsrc.sh's stated limits: dead code
# satisfies the pairing (`if false; then ensure_image; fi` above a dc_up stays
# green). A textual guard cannot do reachability; see issue #123.
#
# Verified (ADR-0005 §2, review round): presence-only was not enough. DELETING
# either ensure_image call site — the cold-start one or the recreate arm's —
# left the suite at 16/0, because assert_contains only needs one. Losing the
# recreate one means `dc down; dc_up` runs with the new fingerprint tag absent,
# so compose's fallback build fires unlocked and without ensure_image's
# nix-base pull or unhashable-refusal. Pairing each dc_up with a preceding
# ensure_image turns both deletions red (17/1 each), and the form-only
# reformat still holds at 18 (mutation runs 2026-08-04).
#
# Verified (ADR-0005 §2, amended: a mutation PAIR) — PRIOR ROUND, counts as
# measured on the pre-pairing tree; the block above supersedes them (the same
# mutations now give 16/2 and 18/0, because the pairing assertions were added):
#   SEMANTIC, in a form not written here — comment out BOTH `ensure_image` call
#     sites in ensure_up() (there are two, and disabling one leaves the other
#     genuinely calling it). On main's version of this suite that is 14 passed /
#     0 failed: `assert_contains` matched the commented-out text and no image
#     would be built before `dc up`. Now 15/1, FAIL "ensure_up makes the image
#     present via ensure_image".
#   FORM-ONLY — reformat `ensure_up()` to `ensure_up ()`, and separately
#     `dc_up()` to `dc_up ()` (both valid bash, both shellcheck-clean). The
#     suite stays green at 16 assertions, unchanged. Against the old hand-rolled
#     `sed -n '/^ensure_up()/,/^}$/p'` each reformat emptied the body and turned
#     an assertion red for the wrong reason (13/1).
#   (mutation runs 2026-08-04)
#
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
. "$(dirname "$(readlink -f "$0")")/lib/shellsrc.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DC="$DEV_BASE/dev/devcontainer"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")
# ensure_image hardcodes its lock at /tmp/devcontainer-<project>.build.lock; our
# stub projects are all prefixed, so sweep them (and only them) on exit.
LOCK_GLOB="/tmp/devcontainer-pr52-reuse-test-"
cleanup_locks() { rm -f "${LOCK_GLOB}"*.build.lock 2>/dev/null || true; }
trap cleanup_locks EXIT

# ---------- build a standalone runner around the real ensure_image ----------
ensure_image_body="$(sed -n '/^ensure_image()/,/^}$/p' "$DC")"
if ! grep -q 'flock' <<< "$ensure_image_body"; then
    _fail "extracted ensure_image() body" "sed range did not capture the function"
    finish
fi

RUNNER="$TMPDIR_ROOT/run-ensure.sh"
# Quoted heredoc: the stub preamble is literal. The extracted function body is
# appended after (it contains $vars/$(...) that must NOT expand at write time).
cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="$1"                       # dir holding the image marker + build log
DEV_PROJECT_NAME="$2"            # unique per test -> unique /tmp lock file
DEV_IMAGE_HASH_OK="${HASH_OK:-true}"
DEV_IMAGE_REF="proj-devimg:testhash"
DEV_USE_NIX_BASE=false
IMG_MARKER="$STATE/present"
BUILD_LOG="$STATE/builds"

# `docker image inspect <ref>` -> present iff the marker exists; anything else
# (the image-agnostic calls ensure_image never makes here) just succeeds.
docker() {
    if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
        [ -f "$IMG_MARKER" ]
        return
    fi
    return 0
}
# Only reached on the hash-not-OK path, to surface the underlying error.
config_files() { echo "stub: build input missing" >&2; return 1; }
# Stand in for `dc build app`: a slow build (widen the race window) that records
# itself and marks the ref present, mirroring compose tagging its `image:`.
dc() {
    sleep 0.3
    echo build >> "$BUILD_LOG"
    : > "$IMG_MARKER"
}
RUNNER_EOF
printf '%s\n\nensure_image\n' "$ensure_image_body" >> "$RUNNER"

fresh_state() { mktemp -d "$TMPDIR_ROOT/state.XXXXXX"; }
build_count() {   # build_count <state-dir>
    if [ -f "$1/builds" ]; then wc -l < "$1/builds" | tr -d ' '; else echo 0; fi
}
run_ensure() {    # run_ensure <hashok> <state> <project> ; echoes exit code
    local rc=0
    HASH_OK="$1" bash "$RUNNER" "$2" "$3" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# ---------- test: present ref is reused, never rebuilt ----------
echo "--- reuse: present image skips the build ---"
st="$(fresh_state)"; : > "$st/present"
rc="$(run_ensure true "$st" pr52-reuse-test-present)"
assert_eq "present image -> ensure_image succeeds" "0" "$rc"
assert_eq "present image -> zero builds (sibling reuse)" "0" "$(build_count "$st")"

# ---------- test: absent ref builds exactly once, then is present ----------
echo "--- build: absent image builds once ---"
st="$(fresh_state)"
rc="$(run_ensure true "$st" pr52-reuse-test-absent)"
assert_eq "absent image -> ensure_image succeeds" "0" "$rc"
assert_eq "absent image -> exactly one build" "1" "$(build_count "$st")"
assert_true "build leaves the ref present" [ -f "$st/present" ]

# ---------- test: unhashable inputs refuse to build ----------
# :unresolved (DEV_IMAGE_HASH_OK=false) must never mint an image off a
# valid-looking-but-wrong fingerprint — it refuses and builds nothing.
echo "--- refusal: unhashable inputs never build ---"
st="$(fresh_state)"
rc="$(run_ensure false "$st" pr52-reuse-test-nohash)"
assert_true "unhashable inputs -> ensure_image refuses (nonzero)" [ "$rc" -ne 0 ]
assert_eq "refusal builds nothing" "0" "$(build_count "$st")"

# ---------- test: concurrent worktrees collapse to one build ----------
# Same absent ref + same project (same /tmp lock) from two processes: the
# repo-scoped flock plus the in-lock double-check must yield exactly one build,
# regardless of interleaving. This is the race the per-worktree ensure_up flock
# does not cover, and the reason ensure_image takes its own lock.
echo "--- concurrency: two worktrees -> one build ---"
st="$(fresh_state)"
HASH_OK=true bash "$RUNNER" "$st" pr52-reuse-test-race >/dev/null 2>&1 &
p1=$!
HASH_OK=true bash "$RUNNER" "$st" pr52-reuse-test-race >/dev/null 2>&1 &
p2=$!
rc1=0; wait "$p1" || rc1=$?
rc2=0; wait "$p2" || rc2=$?
assert_eq "racer A exits clean" "0" "$rc1"
assert_eq "racer B exits clean" "0" "$rc2"
assert_eq "concurrent build races collapse to exactly one build" "1" "$(build_count "$st")"
assert_true "race leaves the ref present" [ -f "$st/present" ]

# ---------- test: up-path wiring matches the shared-image scheme ----------
# Guards the exact refactor: the image is made present before the container
# starts, and `up` itself no longer builds.
echo "--- wiring: ensure_image before dc_up, no --build in up ---"
# Comment-stripped, and via the shared extractor: `assert_contains` on the raw
# body matched a COMMENTED-OUT call, so `# ensure_image (disabled)` passed at
# 14/0 with no image built before `dc up` on a cold start.
ensure_up_body="$(shell_function_body "$DC" ensure_up || true)"
assert_nonempty "ensure_up() body extracted from dev/devcontainer" "$ensure_up_body"
ensure_up_live="$(shell_strip_comments <<<"$ensure_up_body")"
assert_contains "ensure_up makes the image present via ensure_image" "ensure_image" "$ensure_up_live"
# Presence is not enough: ensure_up() has TWO dc_up paths — cold start, and the
# recreate arm — each with its own ensure_image. Asserting the name merely
# appears let either site be DELETED while the other kept the guard green, and
# losing the recreate one means `dc down; dc_up` runs with the new fingerprint
# tag absent, so compose's fallback build fires unlocked and without
# ensure_image's nix-base pull or unhashable-refusal. Pair them instead, with
# both counts derived from the body.
_paired=0; _unpaired=0; _prev=""
while IFS= read -r _line; do
    case "$_line" in
        # Both on one line (`ensure_image && dc_up`, `ensure_image; dc_up`) is a
        # plausible refactor and genuinely paired; the _prev walk cannot see it.
        *ensure_image*dc_up*) _paired=$((_paired + 1)) ;;
        *dc_up*)
            case "$_prev" in
                *ensure_image*) _paired=$((_paired + 1)) ;;
                *) _unpaired=$((_unpaired + 1)) ;;
            esac
            ;;
    esac
    [ -n "${_line//[[:space:]]/}" ] && _prev="$_line"
done <<<"$ensure_up_live"
assert_true "ensure_up() has at least one dc_up call site" \
    test "$((_paired + _unpaired))" -gt 0
assert_eq "every dc_up in ensure_up() is preceded by ensure_image" "0" "$_unpaired"
dc_up_body="$(shell_function_body "$DC" dc_up || true)"
assert_nonempty "dc_up() body extracted from dev/devcontainer" "$dc_up_body"
dc_up_body="$(shell_strip_comments <<<"$dc_up_body")"
if grep -q 'dc up -d' <<< "$dc_up_body"; then
    _pass "dc_up starts the container with 'dc up -d'"
else
    _fail "dc_up starts the container with 'dc up -d'" "got: $dc_up_body"
fi
if grep -q -- '--build' <<< "$dc_up_body"; then
    _fail "dc_up no longer passes --build" "--build resurfaced in dc_up"
else
    _pass "dc_up no longer passes --build (ensure_image builds instead)"
fi

finish
