#!/usr/bin/env bash
# Guard: every script COPYd into /usr/local/bin by either Dockerfile must be
# given an ABSOLUTE mode (`chmod 755`, or `COPY --chmod=`) — never a relative
# `+x`. BOTH Dockerfiles are checked; the nix route's tail mirrors the root
# Dockerfile's COPY block, so a fix applied to one route only leaves the other
# broken at runtime.
#
# COPY preserves the source file's mode, and one of these sources —
# setup-env.sh — comes from a project overlay, i.e. a contributor's working
# tree, where the mode is whatever their umask made it. `chmod +x` adds execute
# bits but cannot restore a missing READ bit:
#
#   0700 (umask 0077 checkout) + chmod +x  ->  0711
#
# The copy is root-owned in the image, so the owner bits stop applying to
# vscode, and bash must read an interpreted script to execute it. Every
# container entry then dies on `setup-env: Permission denied` — a message that
# points at the exec bit, which is the one thing that is fine (#129).
#
# Derivation (ADR-0005 §3, rung 2): the set of guarded paths is parsed out of
# each Dockerfile's COPY destinations, not listed here. A fourth script added to
# /usr/local/bin is covered the day it is added, with no edit to this file — the
# rung-3 alternative would restate {setup-claude, audit-hook, setup-env} and go
# stale silently.
#
# Verified (ADR-0005 §2), two mutations against the fixed tree (14 passed, 0
# failed):
#   - reverting both `chmod 755` lines to `chmod +x` -> 8 passed, 6 failed;
#     "an absolute mode is applied to /usr/local/bin/setup-env", expected
#     `absolute`, actual `relative (+x)` — once per COPYd script per Dockerfile.
#   - deleting both chmod lines outright -> 2 passed, 12 failed; the
#     `assert_nonempty` anchor goes red alongside, which is the fail-open case
#     (a file with NO mode applied) it exists to catch.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
. "$(dirname "$(readlink -f "$0")")/lib/dockerfile.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# applied_mode <dockerfile> <dest> — the mode token the Dockerfile applies to
# <dest>: the value of `--chmod=` on the COPY that creates it, else the argument
# of a chmod that names it. Echoes nothing when no mode is applied at all, which
# the caller asserts against — a silently unmoded file is the fail-open case.
#
# Matching is on exact argv words, not a substring: /usr/local/bin/setup-env is
# a prefix of any future /usr/local/bin/setup-env-foo, and a substring match
# would let one path's mode vouch for another's.
applied_mode() {
    local file="$1" dest="$2" line tok prev found
    while IFS= read -r line; do
        # Globbing off: instruction argv is literal, never expanded against the
        # caller's CWD (same reason as lib/dockerfile.sh's parsers).
        set -f
        # shellcheck disable=SC2086 # deliberate word splitting of the argv
        set -- $line
        set +f

        found=0
        for tok in "$@"; do
            if [ "$tok" = "$dest" ]; then found=1; break; fi
        done
        [ "$found" -eq 1 ] || continue

        for tok in "$@"; do
            case "$tok" in
                --chmod=*) printf '%s\n' "${tok#--chmod=}"; return 0 ;;
            esac
        done

        prev=""
        for tok in "$@"; do
            if [ "$prev" = chmod ]; then printf '%s\n' "$tok"; return 0; fi
            prev="$tok"
        done
    done < <(
        # Join continuations first, so a wrapped COPY or a multi-line RUN is one
        # instruction — an unjoined parser would miss the mode and fail open.
        sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' "$file"
    )
    # Explicit: "no mode applied" is a result the caller asserts on, not an
    # error. Falling off the loop would leave the status incidental, and under
    # `set -e` a non-zero one would abort the suite inside the command
    # substitution instead of reporting the empty mode as a FAIL.
    return 0
}

echo "--- scripts COPYd into /usr/local/bin get an absolute mode ---"

for dockerfile in "$DEV_BASE/Dockerfile" "$DEV_BASE/nix/base/Dockerfile.nix-default"; do
    df_name="${dockerfile#"$DEV_BASE/"}"
    [ -f "$dockerfile" ] || { echo "  FAIL: Dockerfile not found at $dockerfile"; exit 1; }

    mapfile -t dests < <(dockerfile_copy_dests "$dockerfile" | grep '^/usr/local/bin/' || true)

    # Anchor: if the COPY block moves or the parser stops matching, the loop
    # below would iterate zero times and the suite would pass having checked
    # nothing.
    assert_true "$df_name COPYs at least one script into /usr/local/bin" \
        [ "${#dests[@]}" -gt 0 ]

    for dest in "${dests[@]}"; do
        mode="$(applied_mode "$dockerfile" "$dest")"
        assert_nonempty "$df_name applies a mode to $dest" "$mode"

        # Classified rather than pattern-asserted so the failure message names
        # the offending mode: "relative (+x)" and "none" are different bugs and
        # want different fixes.
        case "$mode" in
            [0-7][0-7][0-7] | [0-7][0-7][0-7][0-7]) kind=absolute ;;
            '') kind=none ;;
            *) kind="relative ($mode)" ;;
        esac
        assert_eq "$df_name: an absolute mode is applied to $dest" absolute "$kind"
    done
done

finish
