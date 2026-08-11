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
#   1. gh_hosts_missing_token: which host blocks need filling (the real keyring
#      shape included), including that a token counts only when it is one gh can
#      reach for the ACTIVE user — another user's does not
#   2. gh_hosts_with_token: the token lands in the named block, at that block's
#      OWN indentation — read from the first real body line, waiting past blank
#      lines AND comments — and nothing else in the file changes
#   3. setup_gh: fills a tokenless file, leaves an already-tokened one byte-
#      identical, and copies NOTHING when the host cannot produce a token; on
#      that abort it removes a stale TOKENLESS copy already in the container
#      (broken by definition) but never a tokened one (an in-container login);
#      and the token lookup is stdin-guarded so a gh that reads stdin cannot
#      eat the host list the fill loop is iterating
#   4. the staged file reaches the container 0600, is staged in a private 0700
#      directory (the fill writes the token through an intermediate file), and
#      that directory does not outlive the call
#   5. optional, skipped when gh is absent: real gh loads the filled config
#      without the migration refusal
#
# ADR-0005 §2 mutation pair, re-run 2026-08-07 against lib/host-bridge.sh after
# gh_hosts_missing_token was rewritten to be active-user aware:
#   FORM-ONLY — renamed the awk accumulator `any_user_tok` to `nested_seen`
#     throughout gh_hosts_missing_token and reflowed its per-host reset across
#     two lines. Green, 37/37 assertions, no drop.
#   SEMANTIC — in flush(), commented out the active-user test so any in-file
#     token satisfies the host, which is what the helper did before:
#         ok = host_tok || any_user_tok
#         #   ok = host_tok || (active != "" && (active in user_tok)) ||
#         #        (active == "" && any_user_tok)
#     RED, 36/37: "another user's token does not count for the active user".
#     Expressed as a revert to the previous rule rather than as a rewritten
#     expectation, because the earlier version of this guard asserted only that
#     `oauth_token` appeared SOMEWHERE in the block and stayed GREEN under
#     exactly this behaviour — which is why the mixed-storage fixture exists.
#
# Second §2 pair, run 2026-08-07 after the review-pass hardening (comment-
# tolerant indent inference, stale-container-copy removal, stdin-guarded token
# lookup); gh_hosts_missing_token is unchanged, so the pair above stands:
#   FORM-ONLY — renamed the awk variable `indent` to `pad` throughout
#     gh_hosts_with_token's pending block. Green, 43/43 assertions, no drop.
#   SEMANTIC — two halves, each a revert to what this branch previously shipped:
#     (a) the pending-skip regex back to blank-lines-only,
#             pending && /^[ \t]*$/ { print; next }
#         RED, 41/43: both comment-placement assertions.
#     (b) the abort path's `dc_exec rm -f` neutralized to `:` (warn and leave
#         the broken copy behind). RED, 42/43: "a stale tokenless container
#         copy is removed".
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
# on top of it would write a second one. With no `user:` key to say who is
# active, any in-file token is the only candidate and counts.
users_only="$tmp/users-only.yml"
cat >"$users_only" <<'EOF'
github.com:
    users:
        dlovell:
            oauth_token: gho_nested
EOF
assert_eq "token under users.<name> counts as present" \
    "" "$(gh_hosts_missing_token <"$users_only")"

# Per-user storage is not uniform: one user can be in-file while the ACTIVE one
# is keyring-backed. alice's token does nothing for bob, so the migration still
# goes to the keyring and the host still needs filling — a bare "any oauth_token
# here" test reads this file as fine and leaves gh broken.
mixed_storage="$tmp/mixed-storage.yml"
cat >"$mixed_storage" <<'EOF'
github.com:
    users:
        alice:
            oauth_token: gho_alice
        bob:
    user: bob
EOF
assert_eq "another user's token does not count for the active user" \
    "github.com" "$(gh_hosts_missing_token <"$mixed_storage")"

# The converse, so the rule is a discrimination and not a blanket "users stanza
# means refill": give the active user a token and the host goes quiet.
active_tokened="$tmp/active-tokened.yml"
sed 's/^        bob:$/        bob:\n            oauth_token: gho_bob/' \
    "$mixed_storage" >"$active_tokened"
assert_eq "the active user's own token counts as present" \
    "" "$(gh_hosts_missing_token <"$active_tokened")"

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

# A blank line after the host key has no indent to read. Taking the default
# width there puts a 4-space key in a 2-space mapping, which is not YAML at all
# — gh then dies at config load, the very failure being fixed. So the insert
# waits for a line that can answer the question.
blank_first="$tmp/blank-first.yml"
printf 'github.com:\n\n  git_protocol: https\n' >"$blank_first"
filled3="$(gh_hosts_with_token github.com gho_blank <"$blank_first")"
assert_contains "blank line after the host key: indent still comes from the body" \
    "$(printf '\n  oauth_token: gho_blank\n')" "$(printf '\n%s\n' "$filled3")"
assert_eq "blank line after the host key: the blank survives, token follows it" \
    "github.com:

  oauth_token: gho_blank" "$(printf '%s\n' "$filled3" | head -3)"
# Optional: the shape assertions above are the hermetic half; this one states
# outright what they stand for, when a YAML parser happens to be installed.
if python3 -c 'import yaml' 2>/dev/null; then
    assert_true "blank line after the host key: the result parses as YAML" \
        python3 -c 'import sys,yaml; yaml.safe_load(sys.argv[1])' "$filled3"
else
    echo "  SKIP: no python3+pyyaml — YAML validity of the blank-line fill not checked"
fi

# A comment directly after the host key is the blank-line problem wearing a
# hat: a column-0 comment has no indent to read, so defaulting the width there
# puts a 4-space key in a 2-space mapping — the broken-YAML failure again. The
# insert stays pending past comments too and reads the width from the first
# real body line.
commented="$tmp/commented.yml"
printf 'github.com:\n# pinned by IT\n  git_protocol: https\n' >"$commented"
assert_eq "column-0 comment after the host key: indent still comes from the body" \
    "github.com:
# pinned by IT
  oauth_token: gho_cmt
  git_protocol: https" "$(gh_hosts_with_token github.com gho_cmt <"$commented")"

# And a block that is ONLY a comment ends at EOF still pending — the END branch
# answers with the default width, same as a body-less host key.
comment_only="$tmp/comment-only.yml"
printf 'github.com:\n# nothing else here\n' >"$comment_only"
assert_eq "comment-only block: token still emitted, default indent" \
    "github.com:
# nothing else here
    oauth_token: gho_conly" "$(gh_hosts_with_token github.com gho_conly <"$comment_only")"

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
export STAGE_DIR="$tmp/stage-dir"
export STAGE_MODE="$tmp/stage-mode"
docker() {
    if [ "${1:-}" = "cp" ]; then
        # Recorded here because the staging dir is gone by the time setup_gh
        # returns. Its mode is what protects the intermediate file the fill
        # writes; see assertion 4.
        dirname "$2" >"$STAGE_DIR"
        stat -c %a "$(dirname "$2")" >"$STAGE_MODE"
        cp -p "$2" "$CAPTURED"
    fi
    printf 'docker %s\n' "$*" >>"$DC_LOG"
}
dc() {
    printf 'dc %s\n' "$*" >>"$DC_LOG"
    [ "${1:-}" = "ps" ] && echo "fakecontainerid"
    return 0
}
# The container's hosts.yml, simulated: `dc_exec cat` reads it and `dc_exec rm`
# deletes it — the two container-side operations the abort path performs.
export CONTAINER_HOSTS="$tmp/container-hosts.yml"
dc_exec() {
    printf 'dc_exec %s\n' "$*" >>"$DC_LOG"
    case "${1:-}" in
        cat) if [ -f "$CONTAINER_HOSTS" ]; then cat "$CONTAINER_HOSTS"; fi ;;
        rm) rm -f "$CONTAINER_HOSTS" ;;
    esac
}

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

# The fill is not a single write: it pipes through an intermediate file, and a
# plain `>` redirect creates that one at the ambient umask — 0644 by default,
# with the token already in it. Staging in a private directory is what closes
# that window, so the directory, not just the final file, is the assertion.
assert_eq "staging happens in a 0700 directory" "700" "$(cat "$STAGE_MODE")"
assert_false "staging is not a shared tmpdir" \
    test "$(cat "$STAGE_DIR")" = "${TMPDIR:-/tmp}"

# And it does not survive the call: the dir holds a bearer token.
assert_false "the staging directory is removed on return" \
    test -e "$(cat "$STAGE_DIR")"

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

# A stale copy already sitting in the container — the pre-fill code shipped
# tokenless files, and /home/vscode outlives cold starts — is broken the very
# way the fill prevents, and absent beats broken. The abort path removes it,
# but ONLY when it is itself tokenless: a file with its tokens is an
# in-container `gh auth login`, not ours to delete.
cp "$keyring_shape" "$CONTAINER_HOSTS"
GH_STUB_TOKEN="" run_setup_gh "$keyring_shape"
assert_false "no host token: a stale tokenless container copy is removed" \
    test -f "$CONTAINER_HOSTS"
assert_contains "no host token: the removal is reported on stderr" \
    "removed the container's stale tokenless hosts.yml" "$(cat "$tmp/stderr")"

cp "$insecure_shape" "$CONTAINER_HOSTS"
GH_STUB_TOKEN="" run_setup_gh "$keyring_shape"
assert_true "no host token: an in-container tokened hosts.yml is left alone" \
    test -f "$CONTAINER_HOSTS"
rm -f "$CONTAINER_HOSTS"

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

# The token lookup must not be fed the host list: it runs inside the loop that
# reads that list on stdin, and a gh that reads stdin (auth flows do) would
# swallow the remaining hosts and the fill would silently stop after one.
cat >"$bin/gh" <<'EOF'
#!/bin/sh
# a stdin-hungry gh
cat >/dev/null
echo "gho_slurper"
EOF
chmod +x "$bin/gh"
run_setup_gh "$mixed"
assert_eq "a stdin-reading gh cannot eat the host list" \
    "" "$(gh_hosts_missing_token <"$CAPTURED")"

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
