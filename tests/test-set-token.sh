#!/usr/bin/env bash
# Tests for the container-side token installer used by `devcontainer set-token`
# (docs/adr/0002-devcontainer-setup-token-env-delivery.md). Exercises
# lib/install-claude-token.sh directly against a fake filesystem — no docker
# required. The installer is the piece with the real risk: it must validate that
# it was handed a single raw bearer (not a JSON blob or a multi-value paste),
# strip a trailing newline defensively, write 0600, and never strand a temp.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
INSTALLER="$DEV_BASE/lib/install-claude-token.sh"
OWNER="$(id -un):$(id -gn)"

is_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

# Fresh sandbox dir; prints the root (registered for cleanup).
make_sandbox() {
    local root
    root="$(mktemp -d)"
    _cleanup_dirs+=("$root")
    printf '%s' "$root"
}

echo "=== set-token installer tests ==="

# ---- a bare bearer (no trailing newline) is stored verbatim, 0600 ----
root="$(make_sandbox)"
dest="$root/.oauth-token"
printf '%s' 'sk-ant-oat01-abc123' | sh "$INSTALLER" "$dest" "$OWNER"
assert_true "dest is a regular file" is_regular_file "$dest"
assert_eq "token stored verbatim" 'sk-ant-oat01-abc123' "$(cat "$dest")"
assert_eq "token file is mode 600" 600 "$(stat -c %a "$dest")"
assert_true "no .tok.* temp left behind" \
    [ -z "$(find "$root" -maxdepth 1 -name '.tok.*' -print -quit)" ]

# ---- a trailing newline is stripped defensively (echo/pipe convenience) ----
root="$(make_sandbox)"
dest="$root/.oauth-token"
printf '%s\n' 'sk-ant-oat01-def456' | sh "$INSTALLER" "$dest" "$OWNER"
assert_eq "trailing newline stripped" 'sk-ant-oat01-def456' "$(cat "$dest")"

# ---- empty input is refused, non-zero exit, no file ----
root="$(make_sandbox)"
dest="$root/.oauth-token"
rc=0
printf '' | sh "$INSTALLER" "$dest" "$OWNER" >/dev/null 2>&1 || rc=$?
assert_true "empty input exits non-zero" [ "$rc" -ne 0 ]
assert_false "empty input writes no file" is_regular_file "$dest"

# ---- a JSON blob (whitespace inside) is refused: NOT drop-in for a bearer ----
root="$(make_sandbox)"
dest="$root/.oauth-token"
rc=0
printf '%s' '{"claudeAiOauth": {"accessToken": "x"}}' | sh "$INSTALLER" "$dest" "$OWNER" >/dev/null 2>&1 || rc=$?
assert_true "a JSON credentials blob is rejected (has whitespace)" [ "$rc" -ne 0 ]
assert_false "rejected JSON writes no file" is_regular_file "$dest"

# ---- a multi-line paste is refused (embedded newline) ----
root="$(make_sandbox)"
dest="$root/.oauth-token"
rc=0
printf 'token-one\ntoken-two' | sh "$INSTALLER" "$dest" "$OWNER" >/dev/null 2>&1 || rc=$?
assert_true "embedded newline is rejected" [ "$rc" -ne 0 ]

# ---- refusal leaves any prior token untouched, no temp ----
root="$(make_sandbox)"
dest="$root/.oauth-token"
printf '%s' 'good-token' | sh "$INSTALLER" "$dest" "$OWNER"
printf 'bad token with space' | sh "$INSTALLER" "$dest" "$OWNER" >/dev/null 2>&1 || true
assert_eq "prior token survives a rejected install" 'good-token' "$(cat "$dest")"
assert_true "rejected install leaves no .tok.* temp" \
    [ -z "$(find "$root" -maxdepth 1 -name '.tok.*' -print -quit)" ]

finish
