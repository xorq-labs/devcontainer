# shellcheck shell=bash
# Shared harness for the suites under tests/: PASS/FAIL accounting, assert
# helpers, temp-dir cleanup, and disposable git repos. Source it at the top of
# a suite (after `set -euo pipefail`):
#
#   . "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
#
# and end the suite with `finish` (prints the summary; exits 1 on any FAIL).
# Lives in tests/lib/ so the tests/*.sh glob used by tests/run-all and CI
# doesn't pick it up as a suite.

# The dev/ scripts honor DEV_* overrides from the environment, and a developer
# shell (or a devcontainer session, where direnv exports them) may carry them —
# they would leak into the suites' invocations and shadow the disposable repos
# the tests set up. Suites drive these explicitly, so start from a clean slate.
unset DEV_WORKSPACE DEV_MAIN_TREE DEV_MAIN_GIT DEV_WORKTREE \
    DEV_PROJECT_DIR DEV_PROJECT_NAME DEV_CONTAINER_WORKSPACE
# Behavior-altering DEV_* inputs honored by dev/devcontainer and
# setup-claude.py. The repo's own .envrcs/.envrc.user exports
# DEV_MODEL_VERSION, so on a direnv-active host these leak into suites that
# assert on resolved output (e.g. tests/test-resolve-list-cleanup.sh) and fail
# locally while CI stays green.
unset DEV_COMMAND_TABLE \
    DEV_MODEL_VERSION DEV_DANGEROUSLY_SKIP_PERMISSIONS \
    DEV_NIX_BASE DEV_NIX_BASE_IMAGE \
    DEV_CLAUDE_PROFILE DEV_CLAUDE_LOGS DEV_CLAUDE_VERIFY DEV_CLAUDE_VERIFY_CMD \
    DEV_HOST_PROJECT_KEY DEV_CONTAINER_PROJECT_KEY
# The unprefixed project.env names too — dev/devcontainer now ignores ambient
# values, and suites that assert on that must not start from a polluted slate.
unset MODEL_VERSION DANGEROUSLY_SKIP_PERMISSIONS

PASS=0 FAIL=0
_cleanup_dirs=()

cleanup() {
    for d in "${_cleanup_dirs[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

_pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

_fail() {
    echo "  FAIL: $1"
    shift
    local line
    for line in "$@"; do
        echo "    $line"
    done
    FAIL=$((FAIL + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$label"
    else
        _fail "$label" "expected: $expected" "actual:   $actual"
    fi
}

assert_nonempty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        _pass "$label"
    else
        _fail "$label" "empty — anchor missed? file moved?"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label" "expected to contain: $needle" "got: $haystack"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label" "expected NOT to contain: $needle" "got: $haystack"
    fi
}

assert_files_eq() {
    local label="$1" a="$2" b="$3"
    if cmp -s "$a" "$b"; then
        _pass "$label"
    else
        _fail "$label" "files differ: $a vs $b"
    fi
}

# assert_true "label" <command...> — asserts the command exits 0. Replaces the
# `assert_eq "..." "true" "$(cmd && echo true || echo false)"` contortion.
assert_true() {
    local label="$1"
    shift
    if "$@"; then
        _pass "$label"
    else
        _fail "$label" "command failed: $*"
    fi
}

assert_false() {
    local label="$1"
    shift
    if "$@"; then
        _fail "$label" "command unexpectedly succeeded: $*"
    else
        _pass "$label"
    fi
}

# new_repo <absolute-dir> — disposable git repo with one empty commit; echoes
# the dir. Caller is responsible for putting it under a cleanup-registered
# parent (or registering it via _cleanup_dirs+=(...)).
new_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -b main --quiet
    git -C "$dir" commit --allow-empty -m "init" --quiet
    printf '%s\n' "$dir"
}

finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] || exit 1
}
