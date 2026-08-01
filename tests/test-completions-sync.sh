#!/usr/bin/env bash
# Guard: lib/command-table.tsv is the single source of the `devcontainer`
# command surface, and the dispatch is the one encoding it cannot generate.
#
# The command set used to be written out five times — the dispatch, the
# show_usage heredoc, and three hand-maintained lists in
# dev/devcontainer-completions — and this suite compared the four presentation
# lists against the dispatch by NAME only. That left real holes: a stale fish
# description or a deleted fish `-F` file-completion line kept it green, and
# both of those had shipped.
#
# show_usage and all three completion scripts are now GENERATED from the
# table, so "bash list == zsh list == fish list == usage list" is structurally
# impossible to violate. Those four assertions are DELETED. What is left is
# what generation cannot prove:
#
#   1. dispatch arms == table names — the only pair with two hand-written
#      ends (a new subcommand still has to be added in both places).
#   2. the generators run at all, and their output parses in the target shell
#      (a generator bug is silent: shells load completions with no diagnostic).
#   3. the table is well-formed, and the validator rejects a malformed one.
#   4. the table really is the single source — mutate one row and watch usage
#      and all three shells move together.
#
# Parsing of the dispatch is anchored on stable syntax, not line numbers:
#   `if [ "${1:-}" = "<cmd>" ]` lines + the `case "${1:-up}" in` arms (awk
#   tracks case/esac nesting depth so nested cases inside arm bodies don't
#   leak in; multi-pattern arms `a|b)` are split; the `*` error arm never
#   matches the [a-z-]-only pattern class). Every extraction is
#   anchor-guarded: an empty set fails loudly.
#
# HIDDEN_OK below allowlists dispatch arms deliberately absent from the table.
# It is currently empty: `help` (with -h/--help) is handled before the
# dispatch case and appears in no list, so it never enters the set at all.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
devcontainer="$DEV_BASE/dev/devcontainer"
completions="$DEV_BASE/dev/devcontainer-completions"
table="$DEV_BASE/lib/command-table.tsv"

[ -f "$devcontainer" ] || { echo "  FAIL: $devcontainer not found"; exit 1; }
[ -f "$completions" ] || { echo "  FAIL: $completions not found"; exit 1; }
[ -f "$table" ] || { echo "  FAIL: $table not found"; exit 1; }

# shellcheck source=../lib/command-table.sh
. "$DEV_BASE/lib/command-table.sh"

tmp="$(mktemp -d)"
_cleanup_dirs+=("$tmp")

echo "--- dispatch vs command table ---"

# Dispatch arms deliberately internal/hidden — allowed to be missing from the
# table. None today; add sparingly, with a reason.
HIDDEN_OK=()

# Canonical set: early string-equality delegations...
early_cmds="$(grep -oP '^if \[ "\$\{1:-\}" = "\K[a-z][a-z0-9-]*(?=" \]; then$)' "$devcontainer" || true)"
assert_nonempty "early-dispatch delegations extracted" "$early_cmds"

# ...plus the main dispatch case's top-level arm patterns. Depth-tracked so
# nested `case ... in`/`esac` inside arm bodies (e.g. the worktree porcelain
# parser under `list)`) don't contribute arms; `[a-z-]`-shaped patterns only,
# so the `*)` error arm and function definitions `name() {` never match.
case_cmds="$(awk '
    /^case "\$\{1:-up\}" in$/ { depth = 1; next }
    depth >= 1 {
        if ($0 ~ /(^|[[:space:]])case[[:space:]].*[[:space:]]in[[:space:]]*$/) { depth++; next }
        if ($0 ~ /^[[:space:]]*esac/) { depth--; if (depth == 0) exit; next }
        if (depth == 1 && $0 ~ /^[[:space:]]*[a-z][a-z0-9|-]*\)/) {
            pat = $0
            sub(/^[[:space:]]*/, "", pat); sub(/\).*$/, "", pat)
            gsub(/\|/, "\n", pat)
            print pat
        }
    }
' "$devcontainer" || true)"
assert_nonempty "dispatch case arms extracted" "$case_cmds"

dispatch="$(printf '%s\n%s\n' "$early_cmds" "$case_cmds" | sort -u)"
# Visible surface = dispatch minus the allowlisted hidden arms.
visible="$dispatch"
if [ "${#HIDDEN_OK[@]}" -gt 0 ]; then
    visible="$(comm -23 <(printf '%s\n' "$dispatch") <(printf '%s\n' "${HIDDEN_OK[@]}" | sort -u))"
fi

rows="$(command_table_rows "$table")" || rows=""
assert_nonempty "command table rows read" "$rows"
table_cmds="$(awk -F'\t' '{ print $1 }' <<<"$rows" | sort -u)"

assert_eq "command table == dispatch" "$visible" "$table_cmds"

echo ""
echo "--- generators run and their output parses ---"

for sh in bash zsh fish; do
    if bash "$completions" "$sh" > "$tmp/$sh.out" 2>"$tmp/$sh.err"; then
        _pass "generator emits $sh completions"
    else
        _fail "generator emits $sh completions" "$(cat "$tmp/$sh.err")"
        continue
    fi
    assert_nonempty "$sh completion output non-empty" "$(cat "$tmp/$sh.out")"
done

assert_true "generated bash parses (bash -n)" bash -n "$tmp/bash.out"
if command -v zsh >/dev/null 2>&1; then
    assert_true "generated zsh parses (zsh -n)" zsh -n "$tmp/zsh.out"
else
    echo "  SKIP: zsh not installed — cannot parse-check the zsh output"
fi
if command -v fish >/dev/null 2>&1; then
    assert_true "generated fish parses (fish -n)" fish -n "$tmp/fish.out"
else
    echo "  SKIP: fish not installed — cannot parse-check the fish output"
fi

# The emitted fish/zsh descriptions are free prose. Prove the generator
# escapes rather than relying on the old "avoid apostrophes" authoring
# discipline: a quote and a colon in a description must not break either file.
tricky="$tmp/tricky.tsv"
awk -F'\t' -v OFS='\t' '
    /^[[:space:]]*(#|$)/ { print; next }
    $1 == "up" { $6 = "quote: it'\''s fine; colon: yes"; $7 = "quote: it'\''s fine" }
    { print }
' "$table" > "$tricky"
DEV_COMMAND_TABLE="$tricky" bash "$completions" zsh > "$tmp/tricky-zsh.out"
DEV_COMMAND_TABLE="$tricky" bash "$completions" fish > "$tmp/tricky-fish.out"
if command -v zsh >/dev/null 2>&1; then
    assert_true "quote/colon in a description keeps zsh parsing" zsh -n "$tmp/tricky-zsh.out"
fi
if command -v fish >/dev/null 2>&1; then
    assert_true "quote/colon in a description keeps fish parsing" fish -n "$tmp/tricky-fish.out"
fi
assert_contains "zsh escapes the colon" "quote\\: it'\\''s fine; colon\\: yes" "$(cat "$tmp/tricky-zsh.out")"
assert_contains "fish escapes the apostrophe" "quote: it\\'s fine; colon: yes" "$(cat "$tmp/tricky-fish.out")"

echo ""
echo "--- the table is well-formed (and the validator says so) ---"

# command_table_rows echoes the table on success; only its status matters here.
validates() { command_table_rows "$1" >/dev/null 2>&1; }

assert_true "the real table validates" validates "$table"

# Each mutation below is a class the validator must reject; a table that slips
# through produces a completion script the shell silently refuses to load.
mutate() {
    local name="$1" prog="$2"
    awk -F'\t' -v OFS='\t' "$prog" "$table" > "$tmp/$name.tsv"
    assert_false "rejects $name" validates "$tmp/$name.tsv"
}

mutate "duplicate-name" '{ print } END { print "up\t-\tnone\t-\t-\tdupe\tdupe" }'
mutate "unknown-arg-type" '/^[[:space:]]*(#|$)/ { print; next } $1 == "logs" { $3 = "filesystem" } { print }'
mutate "empty-short-desc" '/^[[:space:]]*(#|$)/ { print; next } $1 == "logs" { $6 = "" } { print }'
mutate "empty-usage-desc" '/^[[:space:]]*(#|$)/ { print; next } $1 == "logs" { $7 = "" } { print }'
mutate "wrong-column-count" '/^[[:space:]]*(#|$)/ { print; next } $1 == "logs" { NF = 6 } { print }'
mutate "bad-command-name" '/^[[:space:]]*(#|$)/ { print; next } $1 == "logs" { $1 = "Logs!" } { print }'
mutate "colon-in-arg-word-desc" '/^[[:space:]]*(#|$)/ { print; next } $1 == "ps" { $4 = "--all:show all: containers" } { print }'

echo ""
echo "--- one source: a single row moves usage and all three shells ---"

sentinel="XYZZY-sentinel-desc"
single="$tmp/single.tsv"
awk -F'\t' -v OFS='\t' -v s="$sentinel" '
    /^[[:space:]]*(#|$)/ { print; next }
    $1 == "logs" { $6 = s; $7 = s; $3 = "dir" }
    { print }
' "$table" > "$single"

usage_out="$(DEV_COMMAND_TABLE="$single" "$devcontainer" help)"
assert_contains "usage picks up the table description" "$sentinel" "$usage_out"

for sh in bash zsh fish; do
    DEV_COMMAND_TABLE="$single" bash "$completions" "$sh" > "$tmp/single-$sh.out"
done
# bash carries no descriptions, so it is the arg-type change that must show.
assert_contains "zsh picks up the table description" "$sentinel" "$(cat "$tmp/single-zsh.out")"
assert_contains "fish picks up the table description" "$sentinel" "$(cat "$tmp/single-fish.out")"
assert_contains "bash rewires logs for arg-type=dir" '_filedir -d' "$(cat "$tmp/single-bash.out")"
assert_contains "zsh rewires logs for arg-type=dir" 'logs) _files -/ ;;' "$(cat "$tmp/single-zsh.out")"
assert_contains "fish rewires logs for arg-type=dir" \
    '__fish_seen_subcommand_from logs" -a '"'"'(__fish_complete_directories)'"'" \
    "$(cat "$tmp/single-fish.out")"

echo ""
echo "dispatch surface: ${visible//$'\n'/ }"
finish
