# shellcheck shell=bash
# Reader + validator for lib/command-table.tsv, the single source of truth for
# the `devcontainer` command surface (see the comment header in that file).
#
# Two consumers source this: dev/devcontainer (to generate the Commands block
# of `show_usage`) and dev/devcontainer-completions (to generate the bash, zsh
# and fish completion scripts). Both read the table at generation time only —
# `devcontainer install-completions` and the Nix package redirect the
# generator's stdout into a static file, so an installed completion script has
# no runtime dependency on this repo.
#
# Host-only: nothing here is COPYed into a container image.

# Path to the table. `DEV_COMMAND_TABLE` overrides it (used by the drift
# guards to point the generators at a mutated copy).
command_table_path() {
    if [ -n "${DEV_COMMAND_TABLE:-}" ]; then
        printf '%s\n' "$DEV_COMMAND_TABLE"
        return 0
    fi
    printf '%s/command-table.tsv\n' "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
}

# Emit the table's data rows (comments and blank lines stripped) on stdout.
#
# A malformed table fails loudly here rather than silently producing a broken
# completion script: the shells load these files with no error reporting, so a
# bad row would surface as "completion mysteriously stopped working".
command_table_rows() {
    local path="${1:-}"
    [ -n "$path" ] || path="$(command_table_path)"
    if [ ! -r "$path" ]; then
        echo "error: command table not found (or unreadable): $path" >&2
        return 1
    fi
    awk -F'\t' '
        function err(msg) {
            printf "error: %s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"
            bad = 1
        }
        BEGIN {
            split("none file dir command", _t, " ")
            for (i in _t) ok_type[_t[i]] = 1
        }
        /^[[:space:]]*($|#)/ { next }
        {
            if (NF != 7) {
                err(sprintf("expected 7 tab-separated columns, got %d", NF))
                next
            }
            if ($1 !~ /^[a-z][a-z0-9-]*$/) { err("bad command name: " $1) }
            if ($1 in seen) { err("duplicate command name: " $1) }
            seen[$1] = 1
            if ($2 == "") { err($1 ": empty arg-syntax (use - for none)") }
            if (!($3 in ok_type)) { err($1 ": unknown arg-type: " $3) }
            if ($4 != "-") {
                n = split($4, w, "|")
                for (i = 1; i <= n; i++) {
                    if (w[i] == "") { err($1 ": empty entry in arg-words"); continue }
                    # word[:description] — the description carries the only
                    # colon, so a second one is an unparseable entry.
                    if (gsub(/:/, ":", w[i]) > 1) {
                        err($1 ": arg-word description may not contain a colon: " w[i])
                    }
                    word = w[i]; sub(/:.*$/, "", word)
                    # Words land unquoted in `compgen -W` / `_values` lists;
                    # keeping them shell-inert removes any quoting question.
                    if (word !~ /^(--?)?[A-Za-z0-9][A-Za-z0-9_.-]*$/) {
                        err($1 ": arg-word is not a plain flag/value: " word)
                    }
                }
            }
            if ($5 == "") { err($1 ": empty arg-label (use - for none)") }
            if ($6 == "" || $6 == "-") { err($1 ": empty short-desc") }
            if ($7 == "" || $7 == "-") { err($1 ": empty usage-desc") }
            print
            rows++
        }
        END {
            if (rows == 0) { print "error: command table has no rows" > "/dev/stderr"; bad = 1 }
            if (bad) exit 1
        }
    ' "$path"
}
