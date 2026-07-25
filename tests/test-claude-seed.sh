#!/usr/bin/env bash
# Tests for setup-claude's private-token credential seeding
# (docs/adr/0001-devcontainer-private-token-isolation.md). Exercises the
# `seed-credentials` subcommand against a fake filesystem via the CLAUDE_*
# path overrides — no docker required.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SETUP="$DEV_BASE/setup-claude.py"

is_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

# pyget <json-file> <python-expr over `d`> — read a value from a JSON file.
pyget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# Fresh sandbox: a host store dir + a container home dir. Prints the root.
make_sandbox() {
    local root
    root="$(mktemp -d)"
    _cleanup_dirs+=("$root")
    mkdir -p "$root/host/credentials" "$root/home"
    printf '%s' "$root"
}

# Run the seed subcommand against a sandbox. Args: <root> <profile-or-empty>
seed() {
    local root="$1" profile="$2"
    env CLAUDE_HOST_DIR="$root/host" \
        CLAUDE_HOME_DIR="$root/home" \
        CLAUDE_CONTAINER_PREFS="$root/dot-claude.json" \
        DEV_CLAUDE_PROFILE="$profile" \
        python3 "$SETUP" seed-credentials
}

echo "=== setup-claude seed-credentials tests ==="

# ---- full seed: private token + identity, caches dropped, prefs preserved ----
root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-work"}}' >"$root/host/credentials/work.json"
printf '%s' '{"accountUuid":"acct-work","emailAddress":"work@example.com","organizationName":"work-org"}' \
    >"$root/host/credentials/work.oauthAccount.json"
# pre-existing container prefs: a stale account, account-scoped caches, and a
# project trust flag that must survive the identity patch.
printf '%s' '{"oauthAccount":{"emailAddress":"stale@host"},"clientDataCacheSlots":{"a":1},"orgModelDefaultCache":{"b":2},"projects":{"/x":{"hasTrustDialogAccepted":true}}}' \
    >"$root/dot-claude.json"
seed "$root" "work" >/dev/null

assert_true "token is a private regular file, not a symlink" is_regular_file "$root/home/.credentials.json"
assert_eq "token content copied from the profile" \
    'sk-ant-work' "$(pyget "$root/home/.credentials.json" 'd["claudeAiOauth"]["accessToken"]')"
assert_eq "token file is mode 600" 600 "$(stat -c %a "$root/home/.credentials.json")"
assert_eq "identity patched from the profile sidecar" \
    'work@example.com' "$(pyget "$root/dot-claude.json" 'd["oauthAccount"]["emailAddress"]')"
assert_eq "account-scoped cache clientDataCacheSlots dropped" \
    'False' "$(pyget "$root/dot-claude.json" '"clientDataCacheSlots" in d')"
assert_eq "account-scoped cache orgModelDefaultCache dropped" \
    'False' "$(pyget "$root/dot-claude.json" '"orgModelDefaultCache" in d')"
assert_eq "unrelated prefs (project trust) preserved" \
    'True' "$(pyget "$root/dot-claude.json" 'd["projects"]["/x"]["hasTrustDialogAccepted"]')"
assert_eq "onboarding flag set so no re-onboard" \
    'True' "$(pyget "$root/dot-claude.json" 'd["hasCompletedOnboarding"]')"

# ---- default profile: falls back to the host active-profile marker ----
root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-active"}}' >"$root/host/credentials/prod.json"
printf 'prod' >"$root/host/credentials/active-profile"
seed "$root" "" >/dev/null   # no DEV_CLAUDE_PROFILE -> use active-profile

assert_eq "seeds the host active profile when DEV_CLAUDE_PROFILE is unset" \
    'sk-ant-active' "$(pyget "$root/home/.credentials.json" 'd["claudeAiOauth"]["accessToken"]')"

# ---- missing sidecar: token still seeded, identity note printed ----
root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-solo"}}' >"$root/host/credentials/solo.json"
out="$(seed "$root" "solo" 2>&1)"

assert_true "token seeded even without an oauthAccount sidecar" is_regular_file "$root/home/.credentials.json"
assert_contains "warns that identity is blank until refetch" "no oauthAccount sidecar" "$out"
assert_eq "onboarding still set without a sidecar" \
    'True' "$(pyget "$root/dot-claude.json" 'd["hasCompletedOnboarding"]')"

# ---- missing profile: nothing seeded, warning printed ----
root="$(make_sandbox)"
out="$(seed "$root" "ghost" 2>&1)"

assert_false "no token file when the profile is absent" is_regular_file "$root/home/.credentials.json"
assert_contains "warns that the profile was not found" "not found" "$out"

finish
