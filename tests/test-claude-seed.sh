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

# ---- main setup path pins the resolved profile (ADR-0002 §Resolver) ----
# Regression: a container that has only ever been `up`'d (main setup, never
# `fix-credentials`) must record the seed-time profile in .active-profile, or
# launches — which never inherit the per-exec DEV_CLAUDE_PROFILE — fall through
# to the HOST marker and can inject a different profile's token than seeding
# installed.

# Run the full main setup against a sandbox. Args: <root> <profile-or-empty>
setup_main() {
    local root="$1" profile="$2"
    mkdir -p "$root/workspace"
    env CLAUDE_HOST_DIR="$root/host" \
        CLAUDE_HOME_DIR="$root/home" \
        CLAUDE_HOST_PREFS="$root/host-dot-claude.json" \
        CLAUDE_CONTAINER_PREFS="$root/dot-claude.json" \
        DEV_CLAUDE_PROFILE="$profile" \
        DEV_CONTAINER_WORKSPACE="$root/workspace" \
        DEV_HOST_PROJECT_KEY="-host-proj" \
        DEV_CONTAINER_PROJECT_KEY="-container-proj" \
        python3 "$SETUP"
}

root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-work"}}' >"$root/host/credentials/work.json"
printf 'other' >"$root/host/credentials/active-profile"
setup_main "$root" "work" >/dev/null

assert_true "main setup writes the .active-profile record" is_regular_file "$root/home/.active-profile"
assert_eq "record pins the resolved profile, not the host marker" \
    "work" "$(cat "$root/home/.active-profile")"

# no DEV_CLAUDE_PROFILE, no record yet: the host marker is resolved and pinned.
root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-active"}}' >"$root/host/credentials/prod.json"
printf 'prod' >"$root/host/credentials/active-profile"
setup_main "$root" "" >/dev/null

assert_eq "main setup pins the host marker on a container with no record" \
    "prod" "$(cat "$root/home/.active-profile")"

# THE DURABILITY GUARD. This path runs on every up/exec/claude, so it must
# HONOR an existing pin: a profile pinned by an explicit re-seed cannot be
# undone by the next plain `exec` just because the host marker moved on.
root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-work"}}' >"$root/host/credentials/work.json"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-personal"}}' >"$root/host/credentials/personal.json"
printf 'personal' >"$root/host/credentials/active-profile"
printf 'work\n' >"$root/home/.active-profile"
setup_main "$root" "" >/dev/null

assert_eq "a plain entry honors the pinned profile over the host marker" \
    "work" "$(cat "$root/home/.active-profile")"
assert_contains "and re-seeds that profile's credential, not the marker's" \
    "sk-ant-work" "$(cat "$root/home/.credentials.json")"

# ...but an explicit DEV_CLAUDE_PROFILE still outranks the pin and re-pins.
setup_main "$root" "personal" >/dev/null

assert_eq "DEV_CLAUDE_PROFILE overrides the pin and re-pins" \
    "personal" "$(cat "$root/home/.active-profile")"

# The deliberate re-point path keeps excluding the record, so a host profile
# switch + fix-credentials takes effect (a stale pin must not re-seed itself).
root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-active"}}' >"$root/host/credentials/prod.json"
printf 'prod' >"$root/host/credentials/active-profile"
printf 'stale\n' >"$root/home/.active-profile"
seed "$root" "" >/dev/null

assert_eq "seed-credentials re-points from the host marker, ignoring the record" \
    "prod" "$(cat "$root/home/.active-profile")"

# An empty resolution must not silently strip an existing pin on a plain entry:
# clearing the record would drop a token-profile container to ambient auth.
root="$(make_sandbox)"
printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-work"}}' >"$root/host/credentials/work.json"
printf 'work\n' >"$root/home/.active-profile"
setup_main "$root" "" >/dev/null

assert_eq "a plain entry with no host marker keeps the existing pin" \
    "work" "$(cat "$root/home/.active-profile")"

# recording happens even when seeding finds no credential material — same
# semantics as the seed-credentials subcommand (pin BEFORE seeding).
root="$(make_sandbox)"
setup_main "$root" "ghost" >/dev/null 2>&1

assert_eq "record pinned even when the profile has no credential material" \
    "ghost" "$(cat "$root/home/.active-profile")"

finish
