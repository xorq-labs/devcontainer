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
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

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
ensure_up_body="$(sed -n '/^ensure_up()/,/^}$/p' "$DC")"
assert_contains "ensure_up makes the image present via ensure_image" "ensure_image" "$ensure_up_body"
dc_up_body="$(sed -n '/^dc_up()/,/^}$/p' "$DC")"
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
