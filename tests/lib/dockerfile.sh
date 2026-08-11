#!/usr/bin/env bash
# Shared Dockerfile parsing for the guards that derive expectations from COPY
# instructions (trigger paths, .dockerignore allowlist, image fingerprint).
#
# Hand-rolled COPY parsers had accumulated one per test, each with its own blind
# spots — one took only `$2` (missing multi-source COPYs), one matched
# `^COPY ` case-sensitively, none joined line continuations, and unquoted
# word-splitting let `COPY lib/*.sh` glob against the caller's CWD. Every one of
# those fails *open*: the source silently disappears from the checked set and
# the guard passes while the thing it guards is broken. One implementation, so a
# fix lands everywhere.

# dockerfile_default_copy_sources <dockerfile>
#
# Emit one source path per line for every COPY that reads the DEFAULT build
# context. Handles:
#   - line continuations (`COPY \` with sources on following lines)
#   - lowercase/mixed-case `copy` (Dockerfile instructions are case-insensitive)
#   - leading flags such as `--chown=user:group`
#   - multi-source COPYs (every argument but the last is a source)
# Skips `COPY --from=<ctx>`, which reads a named additional context or a build
# stage rather than the default one.
dockerfile_default_copy_sources() {
    _dockerfile_copy_sources "$1" default
}

# dockerfile_copy_sources <dockerfile>
#
# As above, but ALSO emits sources of `COPY --from=<ctx>` instructions. Use this
# where a named context's files matter as much as the default context's — the
# image fingerprint hashes both, since either can change what lands in the image.
dockerfile_copy_sources() {
    _dockerfile_copy_sources "$1" all
}

# dockerfile_copy_dests <dockerfile>
#
# Emit the DESTINATION path of every COPY, from the default context and from
# `--from=<ctx>` alike. Sources answer "what inputs can change the image"; the
# mode guard needs the other end — what the file becomes once it lands, which is
# the thing a mode applies to.
#
# A DIRECTORY destination (`COPY a.sh b.sh /usr/local/bin/`) resolves to the
# path each source lands at, because that — not the directory — is what a chmod
# downstream names. A globbed source cannot be resolved without the build
# context, so the directory itself is emitted: a consumer looking for a per-file
# mode then finds none and fails CLOSED, the right direction for "this parser
# does not know".
#
# The exec/JSON form (`COPY ["a", "b"]`) is normalised rather than skipped.
# Word-splitting leaves the brackets, quotes and commas attached, so the
# destination would match nothing downstream and drop silently out of the
# checked set — #86's set-derivation fail-open.
dockerfile_copy_dests() {
    local file="$1" line tok dest n
    local -a args
    while IFS= read -r line; do
        # Globbing off for the same reason as the source parser: a literal
        # argv, never expanded against the caller's CWD.
        set -f
        # shellcheck disable=SC2086 # deliberate word splitting of the COPY argv
        set -- $line
        set +f
        shift                                  # drop the COPY instruction
        while [ "$#" -gt 0 ]; do               # drop leading flags
            case "$1" in
                --*) shift ;;
                *) break ;;
            esac
        done
        case "${1:-}" in
            \[*)                               # exec/JSON form: strip its syntax
                args=()
                for tok in "$@"; do
                    tok="${tok#\[}"
                    tok="${tok%\]}"
                    tok="${tok%,}"
                    tok="${tok#\"}"
                    tok="${tok%\"}"
                    args+=("$tok")
                done
                set -- "${args[@]}"
                ;;
        esac
        [ "$#" -ge 2 ] || continue             # need at least one source + dest
        dest="${*: -1}"
        case "$dest" in
            */)
                n=$(($# - 1))                  # every argument but the last
                for tok in "$@"; do
                    [ "$n" -gt 0 ] || break
                    n=$((n - 1))
                    case "$tok" in
                        *[*?]*) printf '%s\n' "$dest" ;;
                        *) printf '%s%s\n' "$dest" "${tok##*/}" ;;
                    esac
                done
                ;;
            *) printf '%s\n' "$dest" ;;
        esac
    done < <(_dockerfile_copy_lines "$file")
}

# Join continuations before matching, so a wrapped COPY is one line. Shared by
# both parsers: a fix to the joining lands in each.
_dockerfile_copy_lines() {
    sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' "$1" \
        | grep -iP '^COPY[[:space:]]'
}

_dockerfile_copy_sources() {
    local file="$1" mode="$2" line n
    while IFS= read -r line; do
        case "$line" in
            *--from=*) [ "$mode" = all ] || continue ;;
        esac
        # Globbing off: a source like `lib/*.sh` must be reported literally, not
        # expanded against whatever directory the suite happens to run from.
        set -f
        # shellcheck disable=SC2086 # deliberate word splitting of the COPY argv
        set -- $line
        set +f
        shift                                  # drop the COPY instruction
        while [ "$#" -gt 0 ]; do               # drop leading flags
            case "$1" in
                --*) shift ;;
                *) break ;;
            esac
        done
        [ "$#" -ge 2 ] || continue             # need at least one source + dest
        n=$(($# - 1))
        while [ "$n" -gt 0 ]; do
            printf '%s\n' "$1"
            shift
            n=$((n - 1))
        done
    done < <(_dockerfile_copy_lines "$file")
}
