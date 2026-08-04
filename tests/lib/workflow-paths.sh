# shellcheck shell=bash
# Shared workflow trigger-paths parsing for the guards that derive a
# workflow's expected `paths:` coverage from the Dockerfile it builds
# (test-nix-base-trigger-paths.sh, test-docker-build-trigger-paths.sh).
#
# Same rationale as tests/lib/dockerfile.sh: the extraction and the coverage
# matcher both fail OPEN when they miss — an unextracted list or an unmatched
# entry makes the guard pass while the workflow is broken — so there is one
# implementation and a fix lands in every guard at once.

# workflow_event_paths <workflow> <event>
#
# Emit one entry per line from the `paths:` list of the given `on:` event.
# Deliberately not a YAML parse: PyYAML is not stdlib, and these files' shape
# is fixed (two-space event indent, four-space key, six-space list items).
# Comment lines inside the block are skipped; single quotes around an entry
# (needed for `!`-exclusions) are stripped.
workflow_event_paths() {
    local workflow="$1" event="$2"
    awk -v event="  ${event}:" '
        $0 == event { in_event = 1; next }
        in_event && /^  [a-z_]+:/ { in_event = 0 }
        in_event && /^    paths:/ { in_paths = 1; next }
        in_paths && /^      #/ { next }
        in_paths && /^      - / { sub(/^      - /, ""); gsub(/^'"'"'|'"'"'$/, ""); print; next }
        in_paths { in_paths = 0 }
    ' "$workflow"
}

# workflow_build_dockerfile <workflow>
#
# The Dockerfile the workflow's `docker build` actually builds: the argument to
# `-f`/`--file`, or `Dockerfile` when the build relies on the context default.
# Emitted relative to the repo root, as `paths:` entries are.
#
# Derived, not hardcoded. A guard that parses one Dockerfile while the workflow
# builds another checks nothing: pointing docker-build.yml at a new
# `Dockerfile.classic` left the guard green at 12/12 while every real COPY
# input went unlisted. Continuations are joined first so `-f` on a wrapped line
# is still found.
workflow_build_dockerfile() {
    local workflow="$1" line f
    line="$(sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' "$workflow" \
        | grep -m1 -E '(^|[[:space:]])docker[[:space:]]+(buildx[[:space:]]+)?build([[:space:]]|$)' || true)"
    [ -n "$line" ] || return 1
    f="$(grep -oP '(?:^|\s)(?:-f|--file)[=[:space:]]\s*\K\S+' <<<"$line" | head -n1 || true)"
    printf '%s\n' "${f:-Dockerfile}"
}

# _workflow_matches_entry <entry> <needle>
#
# One entry against one path: literal equality, or a `dir/**` prefix match.
_workflow_matches_entry() {
    local entry="$1" needle="$2"
    [ "$entry" = "$needle" ] && return 0
    case "$entry" in
        *'/**') [ "${needle##"${entry%'/**'}"/}" != "$needle" ] && return 0 ;;
    esac
    return 1
}

# workflow_path_covered <needle> <entry>...
#
# Covered = listed literally, or matched by a `dir/**` entry, with exclusions
# applied in LIST ORDER. GitHub's matcher is last-match-wins — "a matching
# positive pattern after a negative match will include the path again" — so a
# single ordered pass is the only faithful model. Exclusions get the SAME
# literal-or-prefix treatment as inclusions: a future `- '!lib/**'` must not
# leave `lib/git.sh` reported as covered while the trigger really excludes it.
#
# This used to scan all exclusions first and let any of them win regardless of
# position. That is order-INDEPENDENT and wrong in the direction that fails
# open: reordering nix-base.yml so `- '!nix/base/compose.nix-base.yml'`
# precedes `- nix/base/**` makes the pin file trigger the workflow again — the
# hour-long two-arch republish the invariant exists to prevent — while the
# guard still reported it excluded.
workflow_path_covered() {
    local needle="$1" entry covered=1
    shift
    for entry in "$@"; do
        case "$entry" in
            '!'*) _workflow_matches_entry "${entry#!}" "$needle" && covered=1 ;;
            *) _workflow_matches_entry "$entry" "$needle" && covered=0 ;;
        esac
    done
    return "$covered"
}
