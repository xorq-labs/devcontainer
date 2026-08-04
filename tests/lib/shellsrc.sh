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
# Emit the file with comments removed, so a match means live code.
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
