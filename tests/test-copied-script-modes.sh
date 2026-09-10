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
# stale silently. What derivation cannot cover is the PARSER's own assumptions,
# so the second section feeds `applied_mode` and `dockerfile_copy_dests`
# Dockerfiles written to fool them.
#
# Verified (ADR-0005 §2, the amended PAIR), against the fixed tree at 28 passed
# / 0 failed:
#
#   - FORM-ONLY: reflow both `chmod 755` lines across continuations and add a
#     comment above each naming all three paths with the good mode ->
#     28 passed, 0 failed. Green, and no assertion lost.
#   - SEMANTIC, in a form not written here: chain the regression onto the good
#     line, `chmod 755 <two paths> \ && chmod +x /usr/local/bin/setup-env` ->
#     26 passed, 2 failed, one per Dockerfile.
#
# The second one is why the pair is the rule. Both of the following were GREEN
# AT 14/0 in this guard's first revision — #129 fully restored, suite passing —
# and neither is reachable by mutating in the shape the fix was written in:
#
#   - the chained form above; the mode was read from the first chmod in the
#     instruction, whichever path that chmod named.
#   - `chmod +x` on all three under a comment stating `chmod 755 <all three>` —
#     the shape of the prose that now sits above these very lines -> 22 passed,
#     6 failed, the comment no longer being read as an instruction.
#
# And the two mutations in the form this guard was written to catch, kept from
# the first revision with counts refreshed:
#
#   - reverting both `chmod 755` lines to `chmod +x` -> 22 passed, 6 failed;
#     expected `absolute`, actual `relative (+x)`, once per script per
#     Dockerfile.
#   - deleting both chmod lines outright -> 16 passed, 12 failed; the
#     `assert_nonempty` anchor goes red alongside, which is the fail-open case
#     (a file with NO mode applied) it exists to catch.
#
# The fixtures were mutated too, since a self-test that cannot fail is the same
# problem one level down. Each rule in `applied_mode` was disabled in turn and
# exactly one fixture caught each (27 passed, 1 failed): dropping the comment
# filter -> "a comment naming the path ... does not vouch for it"; dropping the
# `&&` segment reset -> "a mode does not carry across a boundary ...". That
# second run is also how the segment-carry fixture came to exist: the reversed
# chain it was written from stayed green under the mutation, because a second
# chmod overwrites the tracked mode either way, so it pinned nothing.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
. "$(dirname "$(readlink -f "$0")")/lib/dockerfile.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# applied_mode <dockerfile> <dest> — the mode token the Dockerfile applies to
# <dest>: the value of `--chmod=` on the COPY that creates it, else the mode
# argument of the chmod that names it. Echoes nothing when no mode is applied at
# all, which the caller asserts against — a silently unmoded file is the
# fail-open case.
#
# Three things it must not do. Each was a live fail-open in this guard's first
# revision, and each is pinned by a fixture in the second section below:
#
#   - Read a COMMENT as an instruction. Both Dockerfiles carry prose about modes
#     directly above the chmod it describes, so an unbackticked `chmod 755
#     /usr/local/bin/setup-env` in that prose would vouch for a `chmod +x` on
#     the real line — #110's comment-blind parse, and the shape of #97, where a
#     comment naming a path satisfied a coverage check.
#   - Take a mode from a DIFFERENT command in the same instruction. RUN bodies
#     chain (`Dockerfile:55` already ends one with `&& chmod +x`), so the mode
#     is tracked per `&&` segment: only a chmod naming the file in its OWN
#     segment counts, and swapping two segments must not move a mode between
#     them.
#   - Match a substring. /usr/local/bin/setup-env is a prefix of any future
#     /usr/local/bin/setup-env-foo, and one path's mode must never vouch for
#     another's, so matching is on exact argv words throughout.
applied_mode() {
    local file="$1" dest="$2" line tok prev cur last
    # A COPY may name the directory rather than the file
    # (`COPY a.sh /usr/local/bin/`); its --chmod= is what lands on the file.
    local dir="${dest%/*}/"
    while IFS= read -r line; do
        # Globbing off: instruction argv is literal, never expanded against the
        # caller's CWD (same reason as lib/dockerfile.sh's parsers).
        set -f
        # shellcheck disable=SC2086 # deliberate word splitting of the argv
        set -- $line
        set +f
        [ "$#" -ge 2 ] || continue

        # `COPY --chmod=`: the mode rides on the instruction that CREATES the
        # file, so it counts only when this COPY's DESTINATION is the file (or
        # the directory it lands in) — not merely when the path appears
        # somewhere in the argv.
        case "$1" in
            [Cc][Oo][Pp][Yy])
                last="${*: -1}"
                if [ "$last" = "$dest" ] || [ "$last" = "$dir" ]; then
                    for tok in "$@"; do
                        case "$tok" in
                            --chmod=*) printf '%s\n' "${tok#--chmod=}"; return 0 ;;
                        esac
                    done
                fi
                ;;
        esac

        # `chmod <mode> <path>...`: cur is the mode of the chmod currently in
        # effect, cleared at every command boundary so a neighbouring chmod's
        # mode cannot vouch for this path.
        prev="" cur=""
        for tok in "$@"; do
            case "$tok" in
                '&&' | '||' | ';' | '|') cur="" ;;
                *) if [ "$prev" = chmod ]; then cur="$tok"; fi ;;
            esac
            if [ "$tok" = "$dest" ] && [ -n "$cur" ]; then
                printf '%s\n' "$cur"
                return 0
            fi
            prev="$tok"
        done
    done < <(
        # Join continuations first, so a wrapped COPY or a multi-line RUN is one
        # instruction — an unjoined parser would miss the mode and fail open —
        # then drop comments, which are prose ABOUT modes, not modes.
        sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' "$file" \
            | grep -v '^[[:space:]]*#'
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

echo ""
echo "--- the parsers, against Dockerfiles built to fool them ---"

# The mutations recorded in the header are hand runs against the two real
# Dockerfiles; these fixtures make the same interrogation permanent, and they
# are what keeps the PARSER honest while both real files stay compliant — the
# only way this guard can go quietly vacuous. Every case below returned the
# wrong answer in this guard's first revision, and the first three did so in the
# GREEN direction: ADR-0005's "guards that fail open are worse than no guard",
# reachable here by writing the same regression in a shape the author did not.
fixtures="$(mktemp -d)"
_cleanup_dirs+=("$fixtures")

# write_fixture <name> <line>... — write a Dockerfile, echo its path.
write_fixture() {
    local name="$1"
    shift
    printf '%s\n' "$@" > "$fixtures/$name"
    printf '%s\n' "$fixtures/$name"
}

f="$(write_fixture chained \
    'COPY setup-env.sh /usr/local/bin/setup-env' \
    'COPY audit-hook /usr/local/bin/audit-hook' \
    'RUN chmod 755 /usr/local/bin/audit-hook \' \
    '    && chmod +x /usr/local/bin/setup-env')"
assert_eq "a chained chmod does not lend its mode to the next command" \
    "+x" "$(applied_mode "$f" /usr/local/bin/setup-env)"
assert_eq "...and the path that chmod does name keeps its own" \
    "755" "$(applied_mode "$f" /usr/local/bin/audit-hook)"

f="$(write_fixture chained-reversed \
    'COPY setup-env.sh /usr/local/bin/setup-env' \
    'COPY audit-hook /usr/local/bin/audit-hook' \
    'RUN chmod +x /usr/local/bin/setup-env && chmod 755 /usr/local/bin/audit-hook')"
assert_eq "segment ORDER does not decide the answer (relative first)" \
    "+x" "$(applied_mode "$f" /usr/local/bin/setup-env)"
assert_eq "segment ORDER does not decide the answer (absolute second)" \
    "755" "$(applied_mode "$f" /usr/local/bin/audit-hook)"

# The reversed pair above does not actually pin the `&&` reset — a second chmod
# overwrites the tracked mode regardless. What the reset is for is a segment
# that applies NO mode and merely names the file.
f="$(write_fixture segment-carry \
    'COPY setup-env.sh /usr/local/bin/setup-env' \
    'RUN chmod 755 /usr/local/bin/audit-hook \' \
    '    && ln -sf /usr/local/bin/setup-env /usr/local/bin/se')"
assert_eq "a mode does not carry across a boundary to a path the next command merely names" \
    "" "$(applied_mode "$f" /usr/local/bin/setup-env)"

f="$(write_fixture naming-comment \
    '# Historically: chmod 755 /usr/local/bin/setup-env — see #129.' \
    'COPY setup-env.sh /usr/local/bin/setup-env' \
    'RUN chmod +x /usr/local/bin/setup-env')"
assert_eq "a comment naming the path with a good mode does not vouch for it" \
    "+x" "$(applied_mode "$f" /usr/local/bin/setup-env)"

f="$(write_fixture dir-dest \
    'COPY a.sh b.sh /usr/local/bin/' \
    'RUN chmod 755 /usr/local/bin/a.sh /usr/local/bin/b.sh')"
assert_eq "a directory destination resolves to the paths that land in it" \
    "/usr/local/bin/a.sh /usr/local/bin/b.sh" \
    "$(dockerfile_copy_dests "$f" | paste -sd' ' -)"
assert_eq "...and those paths find their mode" \
    "755" "$(applied_mode "$f" /usr/local/bin/a.sh)"

f="$(write_fixture copy-chmod-dir 'COPY --chmod=0755 c.sh /usr/local/bin/')"
assert_eq "COPY --chmod= on a directory destination applies to what lands there" \
    "0755" "$(applied_mode "$f" /usr/local/bin/c.sh)"

f="$(write_fixture glob-dir-dest 'COPY lib/*.sh /usr/local/bin/')"
assert_eq "a globbed source is unresolvable without the context, so the check fails closed" \
    "/usr/local/bin/" "$(dockerfile_copy_dests "$f")"

f="$(write_fixture json-form \
    'COPY ["d.sh", "/usr/local/bin/d"]' \
    'RUN chmod 755 /usr/local/bin/d')"
assert_eq "the exec/JSON COPY form yields a destination, not bracket noise" \
    "/usr/local/bin/d" "$(dockerfile_copy_dests "$f")"
assert_eq "...which then finds its mode" "755" "$(applied_mode "$f" /usr/local/bin/d)"

f="$(write_fixture no-mode 'COPY e.sh /usr/local/bin/e')"
assert_eq "a file with NO mode applied reports none, not a neighbour's" \
    "" "$(applied_mode "$f" /usr/local/bin/e)"

f="$(write_fixture prefix \
    'COPY setup-env.sh /usr/local/bin/setup-env' \
    'RUN chmod 755 /usr/local/bin/setup-env-foo')"
assert_eq "a longer path's chmod does not vouch for its prefix" \
    "" "$(applied_mode "$f" /usr/local/bin/setup-env)"

finish
