#!/usr/bin/env bash
# Tests for the gh half of lib/host-bridge.sh — setup_gh(), which bridges the
# host's ~/.config/gh/hosts.yml into the container AND wires git's credential
# helper so HTTPS push works there. Exercises the SHIPPED function off-container
# and off-network: the lib is sourced and its three collaborators (`dc`,
# `dc_exec`, `docker`, plus the `is_running` the lib's header requires) are
# replaced with bash functions that append their argv to one shared log, so
# every container-side effect is recorded instead of performed. HOME points at a
# temp dir, which is what decides whether the host has gh auth to bridge at all.
#
# Why the credential half is load-bearing: bridging hosts.yml authenticates the
# `gh` CLI only. Without `gh auth setup-git` the container has git identity
# (setup_git, right above) and a green `gh auth status`, yet `git push` over
# HTTPS fails — and because the container's ~/.gitconfig is ephemeral, a
# hand-applied fix is lost on every recreate.
#
# THE RULE: the helper is wired wherever gh can authenticate AT ALL — from a
# hosts.yml OR from GH_TOKEN/GITHUB_TOKEN — not merely where a file was
# bridged. The two env-only cases (the #136 tokenless abort, and mountless
# runtimes) return before the copy, which is why the copy half is split out
# into gh_bridge_hosts_config and the wiring sits in setup_gh after it.
#
# What is asserted:
#   1. bridged hosts.yml -> copied in, chowned, then `gh auth setup-git` RUNS
#      (ordering matters: gh must read the bridged file, as vscode), and the
#      token never reaches argv
#   2. neither side has auth -> no helper and SILENCE (gh refuses by itself, so
#      the gate spares the developer a per-entry warning, not gh a bad config)
#   3. env token only, either name -> the helper IS wired, nothing copied
#   4. tokenless abort -> no copy, helper still wired when the container has a
#      token; the gate sees the POST-removal state of a stale copy
#   5. the gate costs ONE round trip on paths that previously made none
#   6. a failing setup-git warns and still returns 0 — entry must not abort
#   7. dev/devcontainer still calls setup_git and setup_gh as a pair
#
# Scope note: this suite owns the credential-helper half only. The copied bytes
# — keyring fill, indentation, staging mode, stale-copy removal — belong to
# tests/test-gh-hosts-token.sh, which is why the fixture here carries its token
# in the file: that path copies byte-for-byte with no `gh auth token` lookup.
#
# ADR-0005 §2 mutation pairs.
#   1. FORM-ONLY reflowed the injected gate to one line: 30/30, nothing lost
#      (the stub runs the script rather than matching its text). SEMANTIC
#      dropped the `${GITHUB_TOKEN:-}` arm: red 29/30 on "GITHUB_TOKEN counts
#      too".
#   2. FORM-ONLY renamed gh_bridge_hosts_config: 30/30. SEMANTIC reverted to
#      the pre-widening placement (gate commented out, `dc_exec gh auth
#      setup-git` back on the copy half's tail, warning text byte-identical):
#      red 26/30 on the round-trip count, both env-token assertions, and the
#      abort path. Every BRIDGED-path assertion stays green under it — the old
#      placement still satisfies the original claim, so only a mutation aimed
#      at placement rather than at the wiring's existence can detect it.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

LOG="$tmp/argv.log"
FAKE_CID="container-abc123"
# A token-shaped value in the fixture: nothing may pass it as an argument.
FAKE_TOKEN="gho_FAKEtoken0000000000000000000000000"

# CHOME — a directory standing in for the container's filesystem. The gate is a
# `[ -f /home/vscode/... ]` test evaluated in the container, so a stub that only
# LOGGED the injected script would assert nothing about which branch it takes.
# The dc_exec stub instead runs the script for real, with that one hardcoded
# prefix rewritten to point here; the container-side effects (mkdir, the copy,
# rm) land here too, so the gate sees the state the previous steps left.
export CHOME="$tmp/chome"
# c_path <container-path> — the same rewrite, for assertions.
c_path() { printf '%s\n' "${1/\/home\/vscode/$CHOME}"; }

# --- collaborator stubs: record argv, act only on the fake container fs. ------
# `dc ps -q app` must still answer with a container id — setup_gh interpolates
# it into the docker cp destination.
dc() {
    printf 'dc %s\n' "$*" >>"$LOG"
    if [ "${1:-}" = "ps" ]; then
        printf '%s\n' "$FAKE_CID"
    fi
}

dc_exec() {
    printf 'dc_exec %s\n' "$*" >>"$LOG"
    # Run whatever was asked, with the container prefix rewritten in EVERY
    # argument — deliberately uniform rather than a per-command case list. A
    # stub that only executed the form the lib happens to use today would fail
    # a differently-shaped implementation for the wrong reason (no command ran,
    # so no effect to observe), turning assertions about behaviour into
    # assertions about form.
    local a rewritten=()
    for a in "$@"; do rewritten+=("${a//\/home\/vscode/$CHOME}"); done
    "${rewritten[@]}"
}

docker() {
    printf 'docker %s\n' "$*" >>"$LOG"
    # `docker cp <src> <cid>:<dest>` — land it in the fake container so the
    # gate's -f test sees a bridged file where one was really bridged.
    if [ "${1:-}" = "cp" ]; then
        local dest="$(c_path "${3#*:}")"
        mkdir -p "$(dirname "$dest")"
        cp "$2" "$dest"
    fi
}

is_running() { return 0; }

# `gh` is external and runs on BOTH sides here: the host keyring lookup
# (`gh auth token`) and, through the dc_exec stub, the container-side
# `gh auth setup-git`. One PATH stub answers both — an unstubbed one would
# consult the real developer's keyring. It logs to the shared $LOG, so the
# ordering assertions can place the helper against the copy.
#   GH_STUB_TOKEN         — what `gh auth token` yields ("" = logged-out host)
#   GH_STUB_SETUP_GIT_FAIL — non-empty makes `gh auth setup-git` fail
export LOG
bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/gh" <<'EOF'
#!/bin/sh
printf 'GH-RAN gh %s\n' "$*" >>"$LOG"
case "${1:-} ${2:-}" in
    "auth token")
        [ -n "${GH_STUB_TOKEN:-}" ] || { echo "no oauth token found" >&2; exit 1; }
        printf '%s\n' "$GH_STUB_TOKEN"
        ;;
    "auth setup-git")
        [ -z "${GH_STUB_SETUP_GIT_FAIL:-}" ] || { echo "not logged in" >&2; exit 1; }
        ;;
esac
EOF
chmod +x "$bin/gh"
export PATH="$bin:$PATH"

# Required by the lib at source time (pidfile names are derived from it).
# shellcheck disable=SC2034  # consumed by lib/host-bridge.sh, same idiom as dev/devcontainer
DEV_CONTAINER_NAME="test-host-bridge-gh"

# shellcheck source=/dev/null
. "$DEV_BASE/lib/host-bridge.sh"

# run_setup_gh — clear the log and the fake container, run the shipped function
# with HOME pointed at the fixture, echo its exit status. $CHOME is reset per
# run except where a case seeds it first (the stale-copy cases), so a bridged
# file never leaks into the next case's gate.
run_setup_gh() {
    : >"$LOG"
    local rc=0
    HOME="$fake_home" setup_gh 2>"$tmp/stderr" || rc=$?
    printf '%s\n' "$rc"
}

reset_container() {
    rm -rf "$CHOME"
    mkdir -p "$CHOME"
}

# n_exec — how many container round trips this run cost. The gate is one exec,
# and the claim that it is cheap on the paths that used to make none rests on
# there being exactly one.
n_exec() { grep -cE '^(dc_exec|dc exec|docker) ' "$LOG" || true; }

log() { cat "$LOG"; }

# line_no <fixed-string> — 1-based index of the first log line containing it, or
# empty when absent. Ordering assertions compare these.
line_no() {
    grep -nF -- "$1" "$LOG" 2>/dev/null | head -1 | cut -d: -f1 || true
}

# before <label> <earlier> <later>
before() {
    local label="$1" a b
    a="$(line_no "$2")"
    b="$(line_no "$3")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
        _pass "$label"
    else
        _fail "$label" "'$2' at line ${a:-<absent>}, '$3' at line ${b:-<absent>}" \
            "log:" "$(log)"
    fi
}

echo "=== host-bridge gh credential tests ==="

echo "--- host has gh auth (hosts.yml present) ---"
fake_home="$tmp/home-authed"
mkdir -p "$fake_home/.config/gh"
cat >"$fake_home/.config/gh/hosts.yml" <<EOF
github.com:
    oauth_token: $FAKE_TOKEN
    user: someone
EOF

reset_container
rc="$(run_setup_gh)"
out="$(log)"
assert_eq "setup_gh succeeds with a bridged hosts.yml" "0" "$rc"
assert_contains "the container gh config dir is created" \
    "dc_exec mkdir -p /home/vscode/.config/gh" "$out"
# The source is a staged copy, not the host path: setup_gh fills keyring tokens
# into it (#136). Its bytes are that suite's assertion; here only the
# destination matters.
assert_contains "hosts.yml is copied into the container" \
    "$FAKE_CID:/home/vscode/.config/gh/hosts.yml" "$out"
assert_contains "the copied file is chowned to vscode" \
    "dc exec -u root app chown vscode:vscode /home/vscode/.config/gh/hosts.yml" "$out"
# The fix: without this, `gh auth status` is green and `git push` over HTTPS
# still fails, on every entry, in every container. Asserted on the gh stub's own
# log line, not the injected script's text — the script mentions setup-git
# whether or not the gate lets it run.
assert_contains "gh auth setup-git actually runs in the container" \
    "GH-RAN gh auth setup-git" "$out"
assert_true "the bridged file is what satisfied the gate" \
    test -f "$CHOME/.config/gh/hosts.yml"

echo "--- ordering: helper wired after the file is in place ---"
before "the helper is wired after the hosts.yml copy" \
    "docker cp" "GH-RAN gh auth setup-git"
before "the helper is wired after the chown" \
    "chown vscode:vscode" "GH-RAN gh auth setup-git"

echo "--- the token stays out of argv ---"
# `gh auth setup-git` writes a helper that shells out to `gh auth
# git-credential`; a hand-written credential.<host>.helper would have to carry
# the secret through an argument (and into ps/history) instead.
assert_not_contains "no command receives the oauth token as an argument" \
    "$FAKE_TOKEN" "$out"

echo "--- nothing to bridge, and the container has no token either ---"
# The one path where the answer is "do nothing". gh would refuse here anyway
# (exit 1, writing nothing), so the gate is not protecting gh — it is protecting
# the developer from a warning on every entry that names no action they can take.
fake_home="$tmp/home-bare"
mkdir -p "$fake_home"
reset_container
rc="$(GH_TOKEN='' GITHUB_TOKEN='' run_setup_gh)"
out="$(log)"
assert_eq "setup_gh succeeds with nothing to bridge" "0" "$rc"
assert_not_contains "no hosts.yml is copied" "docker cp" "$out"
assert_not_contains "no credential helper wired for an unauthenticated container" \
    "GH-RAN gh auth setup-git" "$out"
assert_eq "and it stays silent" "" "$(cat "$tmp/stderr")"
# The cost of covering this path is one round trip, not two: the gate that
# decides is the same exec that would have acted.
assert_eq "the gate costs exactly one container round trip" "1" "$(n_exec)"

echo "--- nothing to bridge, but the container has GH_TOKEN (CI, Codespaces) ---"
# gh authenticates from the environment with no hosts.yml at all, and `gh auth
# git-credential` serves that token — so the helper works here, and without it
# HTTPS push fails exactly as it does in a bridged container. This path used to
# return before the wiring.
reset_container
rc="$(GH_TOKEN=gho_container_env run_setup_gh)"
out="$(log)"
assert_eq "setup_gh succeeds on a GH_TOKEN-only container" "0" "$rc"
assert_not_contains "still nothing to copy" "docker cp" "$out"
assert_contains "the helper IS wired from the container's own GH_TOKEN" \
    "GH-RAN gh auth setup-git" "$out"
# GITHUB_TOKEN is gh's other environment source; the gate must read both or a
# GITHUB_TOKEN-only container silently keeps the broken push.
reset_container
rc="$(GH_TOKEN='' GITHUB_TOKEN=gho_container_env run_setup_gh)"
assert_contains "GITHUB_TOKEN counts too" "GH-RAN gh auth setup-git" "$(log)"

echo "--- host gh auth is tokenless (keyring unreachable) ---"
# #136's all-or-nothing abort: no token means no hosts.yml reaches the container
# and any stale tokenless copy is removed, leaving the container on GH_TOKEN.
# That is a documented recovery state, not a broken one, so the helper belongs
# here — it is the only thing that makes push work in it.
fake_home="$tmp/home-tokenless"
mkdir -p "$fake_home/.config/gh"
cat >"$fake_home/.config/gh/hosts.yml" <<'EOF'
github.com:
    git_protocol: https
    user: someone
EOF
reset_container
rc="$(GH_TOKEN=gho_container_env run_setup_gh)"
out="$(log)"
assert_eq "setup_gh succeeds when the host token is unavailable" "0" "$rc"
assert_not_contains "no hosts.yml is copied when the abort fires" \
    "docker cp" "$out"
assert_contains "the helper is still wired on the abort path" \
    "GH-RAN gh auth setup-git" "$out"

# Same abort, but the container has no token of its own: nothing gh can use, so
# nothing to wire and nothing to say.
reset_container
rc="$(GH_TOKEN='' GITHUB_TOKEN='' run_setup_gh)"
out="$(log)"
assert_eq "tokenless abort with no container token still succeeds" "0" "$rc"
assert_not_contains "no helper wired when neither side has auth" \
    "GH-RAN gh auth setup-git" "$out"

# The abort removes a stale TOKENLESS copy (#136). The gate must see the
# post-removal state, or it would wire a helper against a file that is gone.
reset_container
mkdir -p "$CHOME/.config/gh"
cat >"$CHOME/.config/gh/hosts.yml" <<'EOF'
github.com:
    git_protocol: https
EOF
rc="$(GH_TOKEN='' GITHUB_TOKEN='' run_setup_gh)"
out="$(log)"
assert_false "the stale tokenless copy is gone" test -f "$CHOME/.config/gh/hosts.yml"
assert_not_contains "the gate sees the removal, not the pre-removal file" \
    "GH-RAN gh auth setup-git" "$out"

echo "--- a failing gh auth setup-git must not abort container entry ---"
fake_home="$tmp/home-authed"
reset_container
rc="$(GH_STUB_SETUP_GIT_FAIL=1 run_setup_gh)"
assert_eq "setup_gh still returns 0 when setup-git fails" "0" "$rc"
assert_contains "a failing setup-git still warns" \
    "gh auth setup-git" "$(cat "$tmp/stderr")"
# The stub failure must be gh's, reached through the gate — not the exec itself
# refusing, which would prove nothing about the soft-failure path.
assert_contains "the failure came from gh, past the gate" \
    "GH-RAN gh auth setup-git" "$(log)"

echo "--- identity and credentials are bridged as a pair ---"
# Both bridges must stay on dev/devcontainer's entry path; dropping the setup_gh
# call would silently restore the broken-push state this suite exists to prevent.
assert_true "dev/devcontainer calls setup_git on the entry path" \
    grep -qE '^[[:space:]]*setup_git$' "$DEV_BASE/dev/devcontainer"
assert_true "dev/devcontainer calls setup_gh on the entry path" \
    grep -qE '^[[:space:]]*setup_gh$' "$DEV_BASE/dev/devcontainer"

finish
