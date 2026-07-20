#!/usr/bin/env bash
# Tests for devcontainer resolve, list, and cleanup-worktree path argument.
# Runs against a disposable git repo in /tmp — no docker required.
set -euo pipefail

PASS=0 FAIL=0
_cleanup_dirs=()

cleanup() {
    for d in "${_cleanup_dirs[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected to contain: $needle"
        echo "    got: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected NOT to contain: $needle"
        echo "    got: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DC="$DEV_BASE/dev/devcontainer"

# ---------- setup: disposable git repo ----------
TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

MAIN_TREE="$TMPDIR_ROOT/fakerepo"
mkdir -p "$MAIN_TREE"
git -C "$MAIN_TREE" init -b main --quiet
git -C "$MAIN_TREE" commit --allow-empty -m "init" --quiet

# Run devcontainer from inside the fake repo so dev_main_tree() resolves there.
# DEV_BASE_DIR is derived from the script's own path, so overlay lookup still
# hits the real devcontainer repo.
run_dc() {
    (cd "$MAIN_TREE" && "$DC" "$@" 2>&1)
}

# ---------- test: devcontainer resolve (defaults fallback) ----------
echo "--- devcontainer resolve (defaults fallback) ---"
out="$(run_dc resolve)"
assert_contains "shows workspace path" "$MAIN_TREE" "$out"
assert_contains "falls back to defaults" "[fallback] defaults/" "$out"
assert_contains "shows PROJECT_NAME" "PROJECT_NAME=fakerepo" "$out"
assert_contains "shows CONTAINER_NAME" "CONTAINER_NAME=fakerepo-dev-fakerepo" "$out"
assert_not_contains "MODEL_VERSION unset" "MODEL_VERSION=claude" "$out"

# ---------- test: devcontainer resolve with DEV_PROJECT_NAME override ----------
echo "--- devcontainer resolve (DEV_PROJECT_NAME override) ---"
out="$(cd "$MAIN_TREE" && DEV_PROJECT_NAME=custom "$DC" resolve 2>&1)"
assert_contains "resolve uses custom name in CONTAINER_NAME" "CONTAINER_NAME=custom-dev-fakerepo" "$out"
assert_contains "resolve shows custom PROJECT_NAME" "PROJECT_NAME=custom" "$out"
assert_contains "resolve tier2 uses custom name" "projects/custom/" "$out"

# ---------- test: /nix delivery routing shown by resolve ----------
# The defaults overlay mounts no nix seed volume, so it routes to the Nix
# base unless DEV_NIX_BASE says otherwise; an overlay mounting :/nix routes
# to the classic Dockerfile. env -u pins the inherited-environment cases.
echo "--- devcontainer resolve (nix base routing) ---"
out="$(cd "$MAIN_TREE" && env -u DEV_NIX_BASE "$DC" resolve 2>&1)"
assert_contains "non-seed overlay defaults to the nix base" "BASE=nix-base (default" "$out"

out="$(cd "$MAIN_TREE" && DEV_NIX_BASE=0 "$DC" resolve 2>&1)"
assert_contains "DEV_NIX_BASE=0 forces the classic Dockerfile" "BASE=classic (forced by DEV_NIX_BASE=0)" "$out"

out="$(cd "$MAIN_TREE" && DEV_NIX_BASE=1 "$DC" resolve 2>&1)"
assert_contains "DEV_NIX_BASE=1 forces the nix base" "BASE=nix-base (forced by DEV_NIX_BASE=1)" "$out"

SEED_OVERLAY="$TMPDIR_ROOT/seed-overlay"
mkdir -p "$SEED_OVERLAY"
printf 'services:\n  app:\n    volumes:\n      - nix:/nix\n' > "$SEED_OVERLAY/compose.override.yml"
out="$(cd "$MAIN_TREE" && env -u DEV_NIX_BASE DEV_PROJECT_DIR="$SEED_OVERLAY" "$DC" resolve 2>&1)"
assert_contains "seed overlay routes to the classic Dockerfile" "BASE=classic (overlay mounts a nix seed volume)" "$out"

# false-friendly spellings of "off" must not force the base ON, and an
# unrecognized value must error rather than silently picking a side
out="$(cd "$MAIN_TREE" && DEV_NIX_BASE=false "$DC" resolve 2>&1)"
assert_contains "DEV_NIX_BASE=false forces classic too" "BASE=classic (forced by DEV_NIX_BASE=false)" "$out"
if out="$(cd "$MAIN_TREE" && DEV_NIX_BASE=bogus "$DC" resolve 2>&1)"; then rcU=0; else rcU=$?; fi
assert_eq "unrecognized DEV_NIX_BASE exits nonzero" "1" "$rcU"
assert_contains "unrecognized DEV_NIX_BASE names the value" "unrecognized DEV_NIX_BASE='bogus'" "$out"

# compose long-syntax seed volumes must be detected too
LONG_SEED_OVERLAY="$TMPDIR_ROOT/long-seed-overlay"
mkdir -p "$LONG_SEED_OVERLAY"
printf 'services:\n  app:\n    volumes:\n      - type: volume\n        source: nix\n        target: /nix\n' \
    > "$LONG_SEED_OVERLAY/compose.override.yml"
out="$(cd "$MAIN_TREE" && env -u DEV_NIX_BASE DEV_PROJECT_DIR="$LONG_SEED_OVERLAY" "$DC" resolve 2>&1)"
assert_contains "long-syntax seed volume routes to classic" "BASE=classic (overlay mounts a nix seed volume)" "$out"

# a target merely PREFIXED with /nix (e.g. /nixcache) is not a seed volume,
# and comments mentioning :/nix don't count
NEAR_MISS_OVERLAY="$TMPDIR_ROOT/near-miss-overlay"
mkdir -p "$NEAR_MISS_OVERLAY"
printf '# not a seed mount: this overlay has nothing at :/nix\nservices:\n  app:\n    volumes:\n      - cache:/nixcache\n' \
    > "$NEAR_MISS_OVERLAY/compose.override.yml"
out="$(cd "$MAIN_TREE" && env -u DEV_NIX_BASE DEV_PROJECT_DIR="$NEAR_MISS_OVERLAY" "$DC" resolve 2>&1)"
assert_contains "/nixcache mount still routes to the nix base" "BASE=nix-base (default" "$out"

# an overlay overriding classic-only Dockerfile build args keeps the classic
# base — the nix-base compose would silently clobber them otherwise
ARGS_OVERLAY="$TMPDIR_ROOT/classic-args-overlay"
mkdir -p "$ARGS_OVERLAY"
printf 'services:\n  app:\n    build:\n      args:\n        BASE_IMAGE: mcr.microsoft.com/devcontainers/base:ubuntu\n' \
    > "$ARGS_OVERLAY/compose.override.yml"
out="$(cd "$MAIN_TREE" && env -u DEV_NIX_BASE DEV_PROJECT_DIR="$ARGS_OVERLAY" "$DC" resolve 2>&1)"
assert_contains "classic-args overlay routes to classic" "BASE=classic (overlay overrides classic Dockerfile build args)" "$out"

# EXTRA_PATH is honored by both Dockerfiles, so it must NOT trip the
# classic-args routing (regression guard for the arg list)
EXTRA_OVERLAY="$TMPDIR_ROOT/extra-path-overlay"
mkdir -p "$EXTRA_OVERLAY"
printf 'services:\n  app:\n    build:\n      args:\n        EXTRA_PATH: "/workspaces/src/.venv/bin"\n' \
    > "$EXTRA_OVERLAY/compose.override.yml"
out="$(cd "$MAIN_TREE" && env -u DEV_NIX_BASE DEV_PROJECT_DIR="$EXTRA_OVERLAY" "$DC" resolve 2>&1)"
assert_contains "EXTRA_PATH-only overlay stays on the nix base" "BASE=nix-base (default" "$out"

# ---------- test: devcontainer resolve with project overlay ----------
echo "--- devcontainer resolve (project overlay match) ---"
mkdir -p "$DEV_BASE/projects/fakerepo"
_cleanup_dirs+=("$DEV_BASE/projects/fakerepo")
out="$(run_dc resolve)"
assert_contains "matches project overlay" "[matched] projects/fakerepo/" "$out"
assert_contains "defaults superseded" "[skipped] defaults/ — superseded" "$out"
rm -rf "$DEV_BASE/projects/fakerepo"

# ---------- test: devcontainer list (no running containers) ----------
echo "--- devcontainer list (no running containers) ---"
out="$(run_dc list)"
assert_contains "list has header" "WORKTREE" "$out"
assert_contains "list has STATUS header" "STATUS" "$out"
assert_contains "list shows main branch" "main" "$out"
assert_contains "list shows not-created status" "not created" "$out"
assert_contains "list shows overlay" "defaults/" "$out"

# ---------- test: devcontainer list with worktree ----------
echo "--- devcontainer list (with worktree) ---"
git -C "$MAIN_TREE" branch test-branch
WT_PATH="$TMPDIR_ROOT/fakerepo-test-branch"
git -C "$MAIN_TREE" worktree add "$WT_PATH" test-branch --quiet
out="$(run_dc list)"
assert_contains "list shows worktree branch" "test-branch" "$out"
git -C "$MAIN_TREE" worktree remove "$WT_PATH" --force 2>/dev/null || true

# ---------- test: devcontainer list reads .resolved-env for container name ----------
echo "--- devcontainer list (.resolved-env container name) ---"
git -C "$MAIN_TREE" branch wt-resolved
WT_RESOLVED="$TMPDIR_ROOT/fakerepo-wt-resolved"
git -C "$MAIN_TREE" worktree add "$WT_RESOLVED" wt-resolved --quiet
mkdir -p "$WT_RESOLVED/.envrcs"
printf 'CONTAINER_NAME=%q\n' "custom-project-dev-wt-resolved" > "$WT_RESOLVED/.envrcs/.resolved-env"
out="$(run_dc list)"
assert_contains "list shows resolved worktree" "wt-resolved" "$out"
git -C "$MAIN_TREE" worktree remove "$WT_RESOLVED" --force 2>/dev/null || true

# ---------- test: write_resolved_env quoting ----------
echo "--- write_resolved_env quoting ---"
resolved_out="$TMPDIR_ROOT/resolved-test"
(
    # Source just the function from the devcontainer script
    _overlay_label="projects/test (has spaces)"
    # shellcheck disable=SC2034
    DEV_PROJECT_DIR="$TMPDIR_ROOT/project dir"
    # shellcheck disable=SC2034
    DEV_PROJECT_NAME="test-project"
    # shellcheck disable=SC2034
    DEV_MODEL_VERSION=""
    # shellcheck disable=SC2034
    DEV_DANGEROUSLY_SKIP_PERMISSIONS=""
    # shellcheck disable=SC2034
    DEV_CONTAINER_NAME="test-container"
    eval "$(sed -n '/^write_resolved_env()/,/^}/p' "$DC")"
    write_resolved_env "$resolved_out"
)
(
    # shellcheck disable=SC1090
    . "$resolved_out"
    assert_eq "quoted OVERLAY round-trips" "projects/test (has spaces)" "$OVERLAY"
    assert_eq "quoted OVERLAY_DIR round-trips" "$TMPDIR_ROOT/project dir" "$OVERLAY_DIR"
    assert_eq "quoted PROJECT_NAME round-trips" "test-project" "$PROJECT_NAME"
    assert_eq "quoted CONTAINER_NAME round-trips" "test-container" "$CONTAINER_NAME"
)

# ---------- test: cleanup-worktree path argument ----------
echo "--- cleanup-worktree (path argument) ---"
git -C "$MAIN_TREE" branch cleanup-test
WT_CLEANUP="$TMPDIR_ROOT/fakerepo-cleanup-test"
git -C "$MAIN_TREE" worktree add "$WT_CLEANUP" cleanup-test --quiet
git -C "$MAIN_TREE" worktree lock "$WT_CLEANUP" --reason "test" 2>/dev/null || true
(cd "$MAIN_TREE" && "$DEV_BASE/dev/cleanup-worktree" "$WT_CLEANUP") 2>&1
assert_eq "worktree removed" "false" "$([ -d "$WT_CLEANUP" ] && echo true || echo false)"

# ---------- test: cleanup-worktree --help ----------
echo "--- cleanup-worktree --help ---"
out="$("$DEV_BASE/dev/cleanup-worktree" --help 2>&1)"
assert_contains "help text" "Usage: cleanup-worktree" "$out"

# ---------- test: devcontainer --help ----------
echo "--- devcontainer --help ---"
out="$(run_dc --help)" || true
assert_contains "devcontainer help shows resolve" "resolve" "$out"
assert_contains "devcontainer help shows list" "list" "$out"

# ---------- test: new-worktree --help ----------
echo "--- new-worktree --help ---"
out="$("$DEV_BASE/dev/new-worktree" --help 2>&1)"
assert_contains "new-worktree help text" "Usage: new-worktree" "$out"

# ---------- summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
