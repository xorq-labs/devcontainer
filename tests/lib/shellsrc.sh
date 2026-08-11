# shellcheck shell=bash
# Shared reading of bash SOURCES for the guards that assert wiring — "production
# actually calls this" — rather than behaviour.
#
# Same rationale as tests/lib/dockerfile.sh and tests/lib/workflow-paths.sh: the
# hand-rolled form fails OPEN, so there is one implementation and a fix lands
# everywhere. Here the hand-rolled form is `grep -q '<literal>' dev/foo`, which
# matches the literal inside a COMMENT. Commenting a call out is the most common
# way code gets disabled, so the assertion stays green precisely when the wiring
# it guards has been turned off.
#
# Proven three times on this repo: `# chown_named_volume_targets (disabled)`
# passed the setup() check at 25/0; a commented-out `check-gitignore-agents`
# call passed the setup-worktree wiring check at 16/0; and prefixing the
# volume-perms driver line with `# disabled for now: ` passed at 21/0 — all with
# `tests/run-all` green.
#
# Comment stripping is deliberately naive: a `#` at line start or after
# whitespace ends the line. It can therefore truncate a line whose `#` sits
# inside a quoted string. That direction is safe — the pattern then fails to
# match and the assertion goes RED, never green — but if you hit a false FAIL on
# such a line, match a shorter prefix of it rather than reaching back for a raw
# `grep` on the unstripped file.

# shell_strip_comments <file>...
#
# Emit the file with `#` comments removed, so a match means the text is not in a
# comment. NOT that it is live code — see the scope note above.
#
# Strips only `#` at line start or after whitespace. Bash actually begins a
# comment at any word-initial `#`, so `:;#real_call args` is dead code this
# leaves intact; that spelling is unnatural but it is a genuine false-pass
# direction, not merely the fail-closed truncation documented above.
shell_strip_comments() {
    sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$@"
}

# assert_shell_wired <label> <file> <pattern> [grep-mode]
#
# The pattern must appear in the file's LIVE code. grep-mode defaults to -F
# (fixed string); pass -E for a regex.
assert_shell_wired() {
    local label="$1" file="$2" pattern="$3" mode="${4:--F}"
    if [ ! -f "$file" ]; then
        _fail "$label" "no such file: $file"
        return
    fi
    # An empty pattern matches every line, so `grep -qF -- ""` is an
    # unconditional PASS — the fail-open this helper exists to remove. A
    # multi-line pattern degrades to grep's OR semantics, so a garbage first
    # line would pass on the second. Both are what an extracted-from-elsewhere
    # pattern looks like when its extraction broke.
    if [ -z "$pattern" ]; then
        _fail "$label" "empty pattern — the extraction that produced it failed"
        return
    fi
    case "$pattern" in
        *$'\n'*) _fail "$label" "multi-line pattern would match as an OR: $pattern"; return ;;
    esac
    # Capture first rather than piping into `grep -q`: -q exits on the first
    # match, `sed` then dies of SIGPIPE, and `pipefail` reports 141 for the whole
    # pipeline — so a SUCCESSFUL match read as a failure. Fail-closed, but wrong.
    local live
    live="$(shell_strip_comments "$file")"
    if grep -q "$mode" -- "$pattern" <<<"$live"; then
        _pass "$label"
    else
        _fail "$label" \
            "not present in the live (non-comment) code of $file:" \
            "  $pattern" \
            "a commented-out call is not wiring."
    fi
}

# shell_function_body <file> <name>
#
# The body of a shell function, in ONE spelling. Matches `name()` and `name ()`,
# with the brace on that line or the next. Returns 1 — not an empty string —
# when the function is absent, so a rename fails CLOSED instead of yielding an
# empty body that vacuously satisfies a "does not contain X" assertion.
#
# The repo had six hand-rolled versions of this range in three incompatible
# spellings (`awk '/^f\(\) \{/,/^\}/'`, `sed -n '/^f()/,/^}$/p'`, and the same
# without the `$`). They disagree about `f ()` and about a brace on the next
# line: reformatting `dc_up()` to `dc_up ()` — valid bash, shellcheck-clean —
# emptied three of them and false-FAILed the assertions built on them.
#
# Two known edges, neither reachable in this repo today. It stops at the FIRST
# column-0 `}`, so a body containing one inside a heredoc is truncated there;
# and a one-liner definition captures on through the next function's closer.
# Truncation is the unsafe direction — a NEGATIVE assertion over a truncated
# body can pass for the wrong reason — so guard negative assertions with a
# non-empty check on the body.
shell_function_body() {
    local file="$1" name="$2" body
    body="$(awk -v fn="$name" '
        !inb && $0 ~ "^"fn"[[:space:]]*\\([[:space:]]*\\)" { inb = 1; print; next }
        inb { print; if ($0 ~ /^\}/) exit }
    ' "$file")"
    [ -n "$body" ] || return 1
    printf '%s\n' "$body"
}
