#!/usr/bin/env bash
# Tests for gh credential bridging (setup_gh and its two text helpers in
# lib/host-bridge.sh).
#
# The failure being guarded (a tokenless hosts.yml takes gh down wholesale, so
# an absent one is strictly better and the fill is all-or-nothing) is described
# at setup_gh in lib/host-bridge.sh.
#
# Runs the REAL setup_gh body — no docker, no daemon — by sourcing the shipped
# lib and shadowing its three collaborators (`dc`, `dc_exec`, `docker`) with
# recording stubs; `gh` is stubbed on PATH because setup_gh shells out to the
# host's. The `docker cp` stub keeps the staged file, so the assertions are made
# against the exact bytes and mode that would have entered the container.
#
# What is asserted:
#   1. gh_hosts_missing_token: which host blocks lack a token (the real keyring
#      shape included), and that a token under users.<name> counts as present
#   2. gh_hosts_with_token: the token lands in the named block, at that block's
#      OWN indentation, and nothing else in the file changes
#   3. setup_gh: fills a tokenless file, leaves an already-tokened one byte-
#      identical, and copies NOTHING when the host cannot produce a token
#   4. the staged file reaches the container 0600 (it carries a bearer token)
#   5. optional, skipped when gh is absent: real gh loads the filled config
#      without the migration refusal
#
# ADR-0005 §2 mutation pair, run 2026-08-07 against lib/host-bridge.sh:
#   FORM-ONLY — renamed the awk accumulator `tok` to `has_token` throughout
#     gh_hosts_missing_token and reflowed its three rule bodies onto single
#     lines. Green, 29/29 assertions, no drop.
#   SEMANTIC — in gh_hosts_with_token, commented out the indent derivation so
#     the insert always uses a literal four spaces:
#         #   if ($0 ~ /^[ \t]+[^ \t]/) { indent = $0; sub(/[^ \t].*$/, "", indent) }
#     RED, 27/29: both 2-space assertions fail. Expressed as the deletion of a
#     derivation rather than as a rewritten expectation, because that is the
#     form the guard did not already have: an earlier draft asserted only
#     against the 4-space keyring fixture and stayed GREEN under this exact
#     mutation, which is why the 2-space fixture exists at all.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

# host-bridge.sh derives a pidfile name from DEV_CONTAINER_NAME at source time.
# shellcheck disable=SC2034  # read by the lib below, not by this suite.
DEV_CONTAINER_NAME="gh-hosts-token-test"
# shellcheck source=/dev/null
. "$DEV_BASE/lib/host-bridge.sh"

# --- fixtures -----------------------------------------------------------------

# The real thing: what a keyring host writes. Note the half-migrated `users:`
# stanza with a nil value — that is what sends gh to the keyring.
keyring_shape="$tmp/keyring.yml"
cat >"$keyring_shape" <<'EOF'
github.com:
    git_protocol: https
    users:
        dlovell:
    user: dlovell
EOF

# A host that stores tokens in the file (gh auth login --insecure-storage).
insecure_shape="$tmp/insecure.yml"
cat >"$insecure_shape" <<'EOF'
github.com:
    git_protocol: https
    users:
        dlovell:
            oauth_token: gho_hostfile
    user: dlovell
    oauth_token: gho_hostfile
EOF

echo "=== gh hosts.yml token fill ==="

# ---- 1. which blocks lack a token ----
assert_eq "keyring shape: the host is reported as tokenless" \
    "github.com" "$(gh_hosts_missing_token <"$keyring_shape")"
assert_eq "in-file token: nothing reported" \
    "" "$(gh_hosts_missing_token <"$insecure_shape")"

# A token nested under users.<name> is a token: gh's migrated form, and filling
# on top of it would write a second one.
users_only="$tmp/users-only.yml"
cat >"$users_only" <<'EOF'
github.com:
    users:
        dlovell:
            oauth_token: gho_nested
EOF
assert_eq "token under users.<name> counts as present" \
    "" "$(gh_hosts_missing_token <"$users_only")"

# Enterprise + github.com, one of each. Both are reported in file order, and the
# tokened one is left out.
mixed="$tmp/mixed.yml"
cat >"$mixed" <<'EOF'
github.com:
    git_protocol: https
    user: dlovell
ghe.example.com:
    git_protocol: ssh
    oauth_token: gho_enterprise
    user: dlovell
gitlab-ish.example.org:
    user: dlovell
EOF
assert_eq "mixed file: exactly the tokenless hosts, in file order" \
    "github.com
gitlab-ish.example.org" "$(gh_hosts_missing_token <"$mixed")"

# ---- 2. where the token lands ----
filled="$(gh_hosts_with_token github.com gho_filled <"$keyring_shape")"
assert_contains "token is inserted into the named block" \
    "    oauth_token: gho_filled" "$filled"
assert_eq "insert goes directly under the host key" \
    "github.com:
    oauth_token: gho_filled" "$(printf '%s\n' "$filled" | head -2)"
assert_eq "every original line survives, in order" \
    "$(cat "$keyring_shape")" "$(printf '%s\n' "$filled" | grep -v 'oauth_token: gho_filled')"
assert_eq "exactly one token is written" \
    "1" "$(printf '%s\n' "$filled" | grep -c oauth_token)"

# Indentation is the block's, not a constant: YAML requires the keys of one
# mapping to agree, so a hard-coded four spaces corrupts a 2-space file.
two_space="$tmp/two-space.yml"
cat >"$two_space" <<'EOF'
github.com:
  git_protocol: https
  user: dlovell
EOF
filled2="$(gh_hosts_with_token github.com gho_two <"$two_space")"
assert_contains "2-space file: token adopts the block's own indent" \
    "$(printf '\n  oauth_token: gho_two\n')" "$(printf '\n%s\n' "$filled2")"
assert_eq "2-space file: no 4-space key is introduced" \
    "0" "$(printf '%s\n' "$filled2" | grep -c '^    ')"

# Only the named block is touched.
mixed_filled="$(gh_hosts_with_token github.com gho_only <"$mixed")"
assert_eq "other hosts' blocks are untouched" \
    "$(grep -A3 '^ghe.example.com:' "$mixed")" \
    "$(printf '%s\n' "$mixed_filled" | grep -A3 '^ghe.example.com:')"
assert_eq "a second tokenless host is NOT filled by the first host's pass" \
    "gitlab-ish.example.org" "$(printf '%s\n' "$mixed_filled" | gh_hosts_missing_token)"

# A host key as the final line has no body to read an indent from — the END
# branch, which a fixture with a trailing key is the only way to reach.
trailing="$tmp/trailing.yml"
printf 'github.com:\n' >"$trailing"
assert_eq "host key with no body: token still emitted, default indent" \
    "github.com:
    oauth_token: gho_end" "$(gh_hosts_with_token github.com gho_end <"$trailing")"

# A token is opaque bytes to the filler; it must not be re-interpreted.
odd_token='gho_a\tb&c$d'
assert_contains "token is written verbatim (no escape or backreference expansion)" \
    "oauth_token: $odd_token" "$(gh_hosts_with_token github.com "$odd_token" <"$keyring_shape")"

# ---- 3. setup_gh end to end ----
# Collaborator stubs. `docker` and `dc` are external to the lib, so shell
# functions shadow them; the cp stub preserves mode because assertion 4 reads it.
export CAPTURED="$tmp/captured.yml"
export DC_LOG="$tmp/dc-argv"
docker() {
    if [ "${1:-}" = "cp" ]; then
        cp -p "$2" "$CAPTURED"
    fi
    printf 'docker %s\n' "$*" >>"$DC_LOG"
}
dc() {
    printf 'dc %s\n' "$*" >>"$DC_LOG"
    [ "${1:-}" = "ps" ] && echo "fakecontainerid"
    return 0
}
dc_exec() { printf 'dc_exec %s\n' "$*" >>"$DC_LOG"; }

# `gh` is a real external command here, so it gets a PATH stub. It answers with
# $GH_STUB_TOKEN, or fails like a logged-out / keyring-less host when that is
# empty.
bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/gh" <<'EOF'
#!/bin/sh
# gh auth token -h <host>
if [ -n "${GH_STUB_TOKEN:-}" ]; then
    printf '%s\n' "$GH_STUB_TOKEN"
    exit 0
fi
echo "no oauth token found" >&2
exit 1
EOF
chmod +x "$bin/gh"
export PATH="$bin:$PATH"

# run_setup_gh <fixture> — point $HOME at a throwaway gh config holding the
# fixture, clear the recordings, and drive the real setup_gh.
run_setup_gh() {
    local fixture="$1"
    rm -f "$CAPTURED"
    : >"$DC_LOG"
    HOME="$tmp/home"
    rm -rf "$HOME"
    mkdir -p "$HOME/.config/gh"
    cp "$fixture" "$HOME/.config/gh/hosts.yml"
    setup_gh 2>"$tmp/stderr"
}

real_home="$HOME"

GH_STUB_TOKEN="gho_fromkeyring" run_setup_gh "$keyring_shape"
assert_true "keyring host: a file is copied in" test -f "$CAPTURED"
assert_contains "keyring host: the copy carries the keyring's token" \
    "oauth_token: gho_fromkeyring" "$(cat "$CAPTURED")"
assert_eq "keyring host: the copy needs no further filling" \
    "" "$(gh_hosts_missing_token <"$CAPTURED")"
assert_contains "keyring host: the container's copy is chowned to vscode" \
    "chown vscode:vscode /home/vscode/.config/gh/hosts.yml" "$(cat "$DC_LOG")"

# ---- 4. the staged file carries a bearer token ----
assert_eq "the copied file is 0600" "600" "$(stat -c %a "$CAPTURED")"

# An already-tokened host file is passed through untouched — no re-fill, and the
# host's own token is not replaced by the stub's.
GH_STUB_TOKEN="gho_should_not_appear" run_setup_gh "$insecure_shape"
assert_files_eq "in-file token: copied byte-for-byte" "$insecure_shape" "$CAPTURED"
assert_not_contains "in-file token: no keyring lookup result is written" \
    "gho_should_not_appear" "$(cat "$CAPTURED")"

# The all-or-nothing rule: no token available -> copy NOTHING. A tokenless
# hosts.yml would break gh wholesale, while no hosts.yml leaves it usable.
GH_STUB_TOKEN="" run_setup_gh "$keyring_shape"
assert_false "no host token: nothing is copied into the container" test -f "$CAPTURED"
assert_not_contains "no host token: no hosts.yml is written" \
    "docker cp" "$(cat "$DC_LOG")"
assert_contains "no host token: the reason is reported on stderr" \
    "skipping gh config copy" "$(cat "$tmp/stderr")"

# Partial availability is the same case: gh answers for one host, so the other
# would land tokenless and take gh down with it.
cat >"$bin/gh" <<'EOF'
#!/bin/sh
# gh auth token -h <host> — knows github.com only.
for a in "$@"; do
    [ "$a" = "github.com" ] && { echo "gho_onlygithub"; exit 0; }
done
echo "no oauth token found" >&2
exit 1
EOF
chmod +x "$bin/gh"
run_setup_gh "$mixed"
assert_false "one host unresolvable: the whole copy is skipped" test -f "$CAPTURED"

# No host config at all: nothing to do, and nothing copied.
rm -f "$CAPTURED"
: >"$DC_LOG"
HOME="$tmp/empty-home"
mkdir -p "$HOME"
setup_gh
assert_false "no host hosts.yml: nothing copied" test -f "$CAPTURED"

HOME="$real_home"

# ---- 5. does real gh accept the result? ----
# Not hermetic and therefore optional: it needs gh on PATH. Only the POSITIVE
# half is checkable anywhere — reproducing the failure needs a machine with no
# keyring backend, which a developer host generally has.
unset -f docker dc dc_exec
PATH="${PATH#"$bin":}"
if command -v gh >/dev/null 2>&1; then
    ghcfg="$tmp/ghcfg"
    mkdir -p "$ghcfg"
    gh_hosts_with_token github.com gho_notarealtoken <"$keyring_shape" >"$ghcfg/hosts.yml"
    # A fake token cannot authenticate, so `gh auth status` exits non-zero and
    # reports an invalid token — that is fine and expected. What must NOT appear
    # is the config-load refusal, which happens before any token is used.
    status="$(GH_CONFIG_DIR="$ghcfg" gh auth status 2>&1 || true)"
    assert_not_contains "filled config: gh does not refuse to migrate" \
        "cowardly refusing to continue" "$status"
    assert_not_contains "filled config: gh does not reach for the keyring" \
        "dbus-launch" "$status"
    assert_contains "filled config: gh loads it and resolves the account" \
        "github.com" "$status"
else
    echo "  SKIP: gh not on PATH — end-to-end config load not checked"
fi

finish
