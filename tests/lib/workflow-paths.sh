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
# Covered = listed literally, or matched by a `dir/**` entry, and not negated
# by an exclusion. Exclusions get the SAME literal-or-prefix treatment as
# inclusions: a future `- '!lib/**'` must not leave `lib/git.sh` reported as
# covered via a `dir/**`-style branch while the trigger really excludes it —
# that would be a green test over a broken workflow.
workflow_path_covered() {
    local needle="$1" entry
    shift
    for entry in "$@"; do
        case "$entry" in
            '!'*) _workflow_matches_entry "${entry#!}" "$needle" && return 1 ;;
        esac
    done
    for entry in "$@"; do
        case "$entry" in
            '!'*) ;;
            *) _workflow_matches_entry "$entry" "$needle" && return 0 ;;
        esac
    done
    return 1
}
