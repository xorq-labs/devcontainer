#!/usr/bin/env bash
# Tests for lib/claude-code-token-env.sh — the launch-time setup-token injection
# snippet (ADR-0002). Exercises the SHIPPED snippet off-container by stubbing
# `setup-claude` on PATH and sourcing it in a `sh -eu` subshell (it ships into
# /etc/profile.d, so it must survive strict shells):
#   - token active -> CLAUDE_CODE_OAUTH_TOKEN exported, higher-precedence
#     sources dropped, the $__cc_tok temp var cleaned up
#   - no token profile -> env no-op (ambient auth preserved, nothing injected)
#   - empty token file -> no-op (an empty export that also strips
#     ANTHROPIC_API_KEY would break ambient auth that was working)
#   - drift guard: the snippet's unset-list matches setup-claude.py's
#     HIGHER_PRECEDENCE_ENV — the two encodings of the precedence model that
#     both files say must stay in sync.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SNIPPET="$DEV_BASE/lib/claude-code-token-env.sh"

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

# setup-claude stub, same contract as the real resolver: `token-path` prints
# $STUB_TOKEN_PATH and exits 0 when set, else stays silent and exits 1.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/setup-claude" <<'EOF'
#!/bin/sh
[ "$1" = "token-path" ] || exit 2
[ -n "${STUB_TOKEN_PATH:-}" ] || exit 1
printf '%s\n' "$STUB_TOKEN_PATH"
EOF
chmod +x "$tmp/bin/setup-claude"

tok="$tmp/store.token"
printf 'sk-ant-oat01-test-bearer' >"$tok"

# run_snippet [token-path] — source the shipped snippet under `sh -eu` with a
# canned higher-precedence env, then dump the auth-relevant result.
run_snippet() {
    STUB_TOKEN_PATH="${1:-}" PATH="$tmp/bin:$PATH" sh -euc '
        ANTHROPIC_API_KEY=ambient-key; export ANTHROPIC_API_KEY
        ANTHROPIC_BASE_URL=https://ambient.example; export ANTHROPIC_BASE_URL
        . "$1"
        echo "OAUTH=${CLAUDE_CODE_OAUTH_TOKEN:-<unset>}"
        echo "APIKEY=${ANTHROPIC_API_KEY:-<unset>}"
        echo "BASEURL=${ANTHROPIC_BASE_URL:-<unset>}"
        echo "TMPVAR=${__cc_tok:-<unset>}"
    ' sh "$SNIPPET"
}

echo "=== token-env snippet tests ==="

echo "--- token active ---"
out="$(run_snippet "$tok")"
assert_contains "token exported as CLAUDE_CODE_OAUTH_TOKEN" \
    "OAUTH=sk-ant-oat01-test-bearer" "$out"
assert_contains "higher-precedence ANTHROPIC_API_KEY dropped" "APIKEY=<unset>" "$out"
assert_contains "higher-precedence ANTHROPIC_BASE_URL dropped" "BASEURL=<unset>" "$out"
assert_contains "temp var cleaned up" "TMPVAR=<unset>" "$out"

echo "--- no token profile ---"
out="$(run_snippet)"
assert_contains "nothing injected" "OAUTH=<unset>" "$out"
assert_contains "ambient API key preserved (no-op)" "APIKEY=ambient-key" "$out"
assert_contains "ambient base URL preserved" "BASEURL=https://ambient.example" "$out"

echo "--- empty token file ---"
empty="$tmp/empty.token"
: >"$empty"
out="$(run_snippet "$empty")"
assert_contains "empty token not injected" "OAUTH=<unset>" "$out"
assert_contains "ambient API key preserved on empty token" "APIKEY=ambient-key" "$out"

echo "--- unset-list drift guard ---"
# Both files carry a "keep the two lists in sync" note; pin it. The snippet's
# multi-line `unset A B \\n  C D` inside the if-block (indented, unlike the
# `unset __cc_tok` cleanup) vs the HIGHER_PRECEDENCE_ENV tuple.
snippet_vars="$(sed -n '/^  unset /,/[^\\]$/p' "$SNIPPET" \
    | tr -d '\\' | sed 's/^ *unset //' | tr ' ' '\n' | grep -v '^$' | sort)"
python_vars="$(sed -n '/^HIGHER_PRECEDENCE_ENV = (/,/^)/p' "$DEV_BASE/setup-claude.py" \
    | grep -o '"[A-Z_]*"' | tr -d '"' | sort)"
[ -n "$snippet_vars" ] || _fail "extracted the snippet's unset-list" "sed anchor matched nothing"
[ -n "$python_vars" ] || _fail "extracted HIGHER_PRECEDENCE_ENV" "sed anchor matched nothing"
assert_eq "snippet unset-list matches HIGHER_PRECEDENCE_ENV" \
    "$python_vars" "$snippet_vars"

finish
