#!/usr/bin/env bash
# Guard: .envrcs/.envrc.kata hands kata the team token only together with the
# team server, and .envrc.user.template loads .env.local before it.
#
# The fragment is vendored from xorq-envrcs, whose own suite does not cover it.
# Its one safety property is "both or neither": KATA_AUTH_TOKEN overrides every
# daemon's token, so a token exported without KATA_SERVER would go to whatever
# local daemon kata picks — including one inherited from the outer shell, which
# the fragment must unset. Driven functionally: the fragment is SOURCED with
# direnv's log_error stubbed, under env -i, and the resulting environment is
# what is asserted, not the fragment's text.
#
# ADR-0005 §2 mutation pair (run 2026-11-14):
#   form-only — swap the two `[ -n ... ]` tests in the `if` and rename
#     `_kata_missing` to `_missing`: stays green, same assertion count.
#   semantic  — comment out the `unset KATA_AUTH_TOKEN` in the else branch:
#     goes red ("an inherited KATA_AUTH_TOKEN is dropped ..." x3).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fragment="$DEV_BASE/.envrcs/.envrc.kata"
template="$DEV_BASE/.envrcs/.envrc.user.template"

[ -f "$fragment" ] || { echo "  FAIL: fragment not found at $fragment"; exit 1; }

# run_fragment VAR=value... -> the KATA_* vars it leaves set, then LOG:<errors>
run_fragment() {
    env -i PATH="$PATH" "$@" bash -c '
        _log=
        log_error() { _log="${_log:+$_log; }$*"; }
        . "$1"
        env | grep "^KATA_" | sort
        printf "LOG:%s\n" "$_log"
    ' _ "$fragment"
}

echo "--- .envrc.kata: both set ---"
out="$(run_fragment KATA_TEAM_SERVER=http://100.64.0.1:7777 KATA_TEAM_TOKEN=tok \
    KATA_ALLOW_INSECURE=1)"
assert_contains "KATA_SERVER comes from KATA_TEAM_SERVER" "KATA_SERVER=http://100.64.0.1:7777" "$out"
assert_contains "KATA_AUTH_TOKEN comes from KATA_TEAM_TOKEN" "KATA_AUTH_TOKEN=tok" "$out"
assert_contains "private-network trust is enabled" "KATA_TRUST_PRIVATE_NETWORK=1" "$out"
assert_not_contains "KATA_ALLOW_INSECURE is removed" "KATA_ALLOW_INSECURE" "$out"
assert_eq "no error is logged" "LOG:" "$(tail -n1 <<<"$out")"

for case in "KATA_TEAM_SERVER|KATA_TEAM_TOKEN=tok" \
            "KATA_TEAM_TOKEN|KATA_TEAM_SERVER=http://100.64.0.1:7777" \
            "KATA_TEAM_SERVER and KATA_TEAM_TOKEN|"; do
    missing="${case%%|*}" given="${case#*|}"
    echo ""
    echo "--- .envrc.kata: $missing missing ---"
    # An empty value counts as missing; an inherited token must not survive.
    # shellcheck disable=SC2086 # $given is one VAR=value word or none
    out="$(run_fragment KATA_TEAM_SERVER= $given KATA_AUTH_TOKEN=inherited)"
    assert_not_contains "an inherited KATA_AUTH_TOKEN is dropped ($missing missing)" "KATA_AUTH_TOKEN" "$out"
    assert_not_contains "no KATA_SERVER is set ($missing missing)" "KATA_SERVER=" "$out"
    assert_eq "the error names what is missing" "LOG:kata here is not set up for the team server: $missing unset or empty" "$(tail -n1 <<<"$out")"
done

echo ""
echo "--- .envrc.user.template: .env.local loads before .envrc.kata ---"
# The fragment reads KATA_TEAM_SERVER, which .env.local holds; opted in, the
# template must load that file first. Order observed by sourcing the template
# with the kata line uncommented and the direnv stdlib stubbed to record calls.
order="$(sed 's|^# *\(source_env \.envrc\.kata\)|\1|' "$template" | env -i PATH="$PATH" bash -c '
    source_env() { echo "source_env $1"; }
    dotenv_if_exists() { echo "dotenv_if_exists $1"; }
    PATH_add() { :; }
    . /dev/stdin
')"
dotenv_at="$(grep -n '^dotenv_if_exists \.env\.local$' <<<"$order" | cut -d: -f1 || true)"
kata_at="$(grep -n '^source_env \.envrc\.kata$' <<<"$order" | cut -d: -f1 || true)"
assert_nonempty "the template loads .env.local" "$dotenv_at"
assert_nonempty "the template offers .envrc.kata" "$kata_at"
if [ -n "$dotenv_at" ] && [ -n "$kata_at" ] && [ "$dotenv_at" -lt "$kata_at" ]; then
    _pass ".env.local is loaded before .envrc.kata"
else
    _fail ".env.local is loaded before .envrc.kata" "order: $(tr '\n' ',' <<<"$order")"
fi

finish
