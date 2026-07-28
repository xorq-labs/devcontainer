#!/usr/bin/env bash
# Tests for setup-claude's setup-token support
# (docs/adr/0002-devcontainer-setup-token-env-delivery.md): the `token-path`
# resolver, the `token-doctor` precedence check, and seed_credentials' tolerance
# of a token-only profile. Exercised against a fake filesystem via the CLAUDE_*
# path overrides — no docker.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SETUP="$DEV_BASE/setup-claude.py"

is_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# Fresh sandbox: a host store dir + a container home dir. Prints the root.
make_sandbox() {
    local root
    root="$(mktemp -d)"
    _cleanup_dirs+=("$root")
    mkdir -p "$root/host/credentials" "$root/home"
    printf '%s' "$root"
}

# token-path against a sandbox. Args: <root> <profile-or-empty>. The Compose
# secret path is pinned into the sandbox ($root/run-secret) so the real
# /run/secrets never interferes; a test opts in by creating that file.
tokenpath() {
    local root="$1" profile="$2"
    env CLAUDE_HOST_DIR="$root/host" \
        CLAUDE_HOME_DIR="$root/home" \
        CLAUDE_RUN_SECRETS_TOKEN="$root/run-secret" \
        DEV_CLAUDE_PROFILE="$profile" \
        python3 "$SETUP" token-path
}

# seed-credentials against a sandbox. Args: <root> <profile-or-empty>.
seed() {
    local root="$1" profile="$2"
    env CLAUDE_HOST_DIR="$root/host" \
        CLAUDE_HOME_DIR="$root/home" \
        CLAUDE_CONTAINER_PREFS="$root/dot-claude.json" \
        DEV_CLAUDE_PROFILE="$profile" \
        python3 "$SETUP" seed-credentials
}

# token-doctor against a sandbox. Args: <root> <profile-or-empty> [VAR=VAL ...].
# The five precedence vars are cleared first so the ambient test env can't leak
# in; any extra VAR=VAL args simulate an ambient higher-precedence source.
doctor() {
    local root="$1" profile="$2"
    shift 2
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL \
        -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
        CLAUDE_HOST_DIR="$root/host" \
        CLAUDE_HOME_DIR="$root/home" \
        CLAUDE_RUN_SECRETS_TOKEN="$root/run-secret" \
        DEV_CLAUDE_PROFILE="$profile" \
        "$@" \
        python3 "$SETUP" token-doctor
}

echo "=== setup-claude token-path + doctor + seed tolerance tests ==="

# ---- token-path resolves the RO store token for the named profile ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-store' >"$root/host/credentials/work.token"
rc=0; out="$(tokenpath "$root" work)" || rc=$?
assert_eq "token-path exits 0 when a store token exists" 0 "$rc"
assert_eq "token-path prints the store token path" "$root/host/credentials/work.token" "$out"

# ---- token-path falls back to the active-profile marker ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-active' >"$root/host/credentials/prod.token"
printf 'prod' >"$root/host/credentials/active-profile"
rc=0; out="$(tokenpath "$root" "")" || rc=$?
assert_eq "token-path uses active-profile when DEV_CLAUDE_PROFILE is empty" \
    "$root/host/credentials/prod.token" "$out"

# ---- an explicit set-token private file overrides the store token ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-store' >"$root/host/credentials/work.token"
printf '%s' 'sk-ant-oat01-override' >"$root/home/.oauth-token"
rc=0; out="$(tokenpath "$root" work)" || rc=$?
assert_eq "the private set-token file wins over the store" "$root/home/.oauth-token" "$out"

# ---- a Docker/Compose secret is used ahead of the store (mountless CI) ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-store' >"$root/host/credentials/work.token"
printf '%s' 'sk-ant-oat01-secret' >"$root/run-secret"
rc=0; out="$(tokenpath "$root" work)" || rc=$?
assert_eq "the /run/secrets Compose secret wins over the store" "$root/run-secret" "$out"

# ---- an explicit set-token override still wins over a Compose secret ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-secret' >"$root/run-secret"
printf '%s' 'sk-ant-oat01-override' >"$root/home/.oauth-token"
rc=0; out="$(tokenpath "$root" work)" || rc=$?
assert_eq "a manual set-token still wins over a Compose secret (debug override)" \
    "$root/home/.oauth-token" "$out"

# ---- token-path exits non-zero and prints nothing when no token exists ----
root="$(make_sandbox)"
rc=0; out="$(tokenpath "$root" work 2>/dev/null)" || rc=$?
assert_true "token-path exits non-zero with no token" [ "$rc" -ne 0 ]
assert_eq "token-path prints nothing with no token" "" "$out"

# ---- seed on a token-only profile: no credential file, note, onboarding set ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-only' >"$root/host/credentials/tok.token"
out="$(seed "$root" "tok" 2>&1)"
assert_false "no .credentials.json is seeded for a token-only profile" \
    is_regular_file "$root/home/.credentials.json"
assert_contains "prints a setup-token note (not a 'not found' warning)" "setup-token profile" "$out"
assert_not_contains "does not warn 'not found' for a token-only profile" "not found" "$out"
assert_eq "onboarding flag set so no re-onboard" \
    'True' "$(pyget "$root/dot-claude.json" 'd["hasCompletedOnboarding"]')"

# ---- coexistence: a profile with both .json and .token seeds the OAuth file ----
root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-both"}}' >"$root/host/credentials/both.json"
printf '%s' 'sk-ant-oat01-both' >"$root/host/credentials/both.token"
seed "$root" "both" >/dev/null
assert_true "OAuth material is seeded when both materials exist (default)" \
    is_regular_file "$root/home/.credentials.json"
assert_eq "seeded file is the OAuth .json" \
    'sk-ant-both' "$(pyget "$root/home/.credentials.json" 'd["claudeAiOauth"]["accessToken"]')"
rc=0; out="$(tokenpath "$root" both)" || rc=$?
assert_eq "token-path still resolves the token for a --token launch" \
    "$root/host/credentials/both.token" "$out"

# ---- token-doctor: clean when a token is active and no source shadows it ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-store' >"$root/host/credentials/work.token"
rc=0; out="$(doctor "$root" work 2>&1)" || rc=$?
assert_eq "doctor exits 0 when nothing shadows the token" 0 "$rc"
assert_contains "doctor reports the token is unshadowed" "no higher-precedence source" "$out"

# ---- token-doctor: an ambient higher-precedence env var is flagged ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-store' >"$root/host/credentials/work.token"
rc=0; out="$(doctor "$root" work ANTHROPIC_API_KEY=sk-ambient 2>&1)" || rc=$?
assert_true "doctor exits non-zero when a source shadows the token" [ "$rc" -ne 0 ]
assert_contains "doctor names the shadowing env var" "ANTHROPIC_API_KEY" "$out"
assert_contains "doctor warns the source silently outranks the token" "SILENTLY outrank" "$out"

# ---- token-doctor: a base-URL redirect is flagged too ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-store' >"$root/host/credentials/work.token"
rc=0; out="$(doctor "$root" work ANTHROPIC_BASE_URL=https://proxy.example 2>&1)" || rc=$?
assert_true "doctor flags an ambient ANTHROPIC_BASE_URL" [ "$rc" -ne 0 ]
assert_contains "doctor names the base-URL redirect" "ANTHROPIC_BASE_URL" "$out"

# ---- token-doctor: an apiKeyHelper in settings.json is flagged ----
root="$(make_sandbox)"
printf '%s' 'sk-ant-oat01-store' >"$root/host/credentials/work.token"
printf '%s' '{"apiKeyHelper":"/bin/echo key"}' >"$root/home/settings.json"
rc=0; out="$(doctor "$root" work 2>&1)" || rc=$?
assert_true "doctor flags an apiKeyHelper hook in settings.json" [ "$rc" -ne 0 ]
assert_contains "doctor names the apiKeyHelper source" "apiKeyHelper" "$out"

# ---- token-doctor: no-op (exit 0) when no token profile is active ----
root="$(make_sandbox)"
rc=0; out="$(doctor "$root" work ANTHROPIC_API_KEY=sk-ambient 2>&1)" || rc=$?
assert_eq "doctor exits 0 with no active token (nothing to check)" 0 "$rc"
assert_contains "doctor notes the precedence check was skipped" "precedence check skipped" "$out"

finish
