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
#   3. every table command actually reaches every generated script. Generation
#      makes the three lists agree with each OTHER structurally; it does not
#      make them non-empty or correct.
#   4. the table is well-formed, and the validator rejects a malformed one.
#   5. the table really is the single source — mutate one row and watch usage
#      and all three shells move together.
#   6. every arg-type in the validator's vocabulary is wired in all three
#      generators. That vocabulary is a four-file convention with no other
#      guard, and its failure mode (a type nobody generates for) is silent.
#   7. a failed `install-completions` leaves an already-installed completion
#      file alone — generation can now fail, so installation must be atomic.
#
# Parsing of the dispatch is anchored on stable syntax, not line numbers:
#   `if [ "${1:-}" = "<cmd>" ]` lines + the `case "${1:-up}" in` arms (awk
#   tracks case/esac nesting depth so nested cases inside arm bodies don't
#   leak in; multi-pattern arms `a|b)` are split; the `*` error arm never
#   matches the [a-z-]-only pattern class). Every extraction is
#   anchor-guarded: an empty set fails loudly.
#
# Strict-shape parsing is only sound if an unrecognised shape FAILS, which it
# did not until #96 — a dispatch arm written any other way silently left the
# set and its command bypassed the table with this suite green. Both halves are
# now accounted for rather than best-effort:
#   - early region: every top-level $1 test is either a command delegation in
#     the strict shape or an EARLY_NON_COMMAND entry carrying its reason;
#     anything else fails, and a stale allowlist entry fails too.
#   - case block: parsed arms are cross-checked against the `;;` terminators at
#     the same depth, so an arm the pattern class misses diverges the counts.
#
# Verified (ADR-0005 §2), two mutations, both previously green:
#   1. #96's mutation — a live `if [[ "${1:-}" == "phantom-cmd" ]]; then` arm
#      inserted before the bump-nix-base delegation — now fails with
#      "early dispatch: $1 test at line 40 is classified".
#   2. A case arm in an unmatched shape (`"quoted-cmd")` … `;;`) now fails
#      "every case arm is parsed (arms == `;;` terminators)", expected 28 got 27.
#   (mutation runs 2026-08-03)
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

# Both halves of the dispatch are parsed by STRICT SHAPE, which is only sound
# if a shape the parser doesn't understand is a FAILURE rather than a silent
# skip. Until #96 it was a skip: a live, reachable
# `if [[ "${1:-}" == "phantom-cmd" ]]; then` arm simply dropped out of the
# derived set, so a command could bypass the table — no table row, no usage
# line, no completions — with this suite green. That is the #86 parser shape
# recurring inside a guard. Each half is now accounted for:
#   early region — every top-level $1 test must be classified;
#   case block   — every arm must be matched by a `;;` terminator.

# --- early region: every top-level $1 test is classified ---
early_region="$(awk '/^case "\$\{1:-up\}" in$/ { exit } { print }' "$devcontainer")"
early_tests="$(grep -nE '^(if|elif|while|until|case)[[:space:]].*\$\{1:-' <<< "$early_region" || true)"
assert_nonempty "early-region \$1 tests found" "$early_tests"

# $1 tests in the early region that are deliberately NOT command delegations.
# Whole-line matches, each with its reason. A stale entry fails too (checked
# below), so this cannot rot into a blanket skip.
EARLY_NON_COMMAND=(
    # global help — handled before dispatch, deliberately in no list
    'if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then'
    # global option loop — consumes flags, dispatches nothing
    'while [[ "${1:-}" == -* ]]; do'
    # pre-dispatch grouping for teardown commands; each also has a case arm
    'if [[ "${1:-up}" =~ ^(down|reset|clean|clean-caches|clean-images|status|logs|list|resolve)$ ]]; then'
)
early_nc_used=()
for ((i = 0; i < ${#EARLY_NON_COMMAND[@]}; i++)); do early_nc_used[i]=0; done

early_cmds=""
while IFS= read -r numbered; do
    [ -n "$numbered" ] || continue
    lineno="${numbered%%:*}"
    line="${numbered#*:}"
    if [[ "$line" =~ ^if\ \[\ \"\$\{1:-\}\"\ =\ \"([a-z][a-z0-9-]*)\"\ \]\;\ then$ ]]; then
        early_cmds+="${BASH_REMATCH[1]}"$'\n'
        continue
    fi
    _early_matched=0
    for ((i = 0; i < ${#EARLY_NON_COMMAND[@]}; i++)); do
        if [ "$line" = "${EARLY_NON_COMMAND[i]}" ]; then
            early_nc_used[i]=1
            _early_matched=1
            break
        fi
    done
    if [ "$_early_matched" -eq 0 ]; then
        _fail "early dispatch: \$1 test at line $lineno is classified" \
            "unrecognised: $line" \
            "write it as \`if [ \"\${1:-}\" = \"<cmd>\" ]; then\` so it reaches the table check," \
            "or add the exact line to EARLY_NON_COMMAND with a reason"
    fi
done <<< "$early_tests"

early_cmds="$(printf '%s' "$early_cmds" | sort -u)"
assert_nonempty "early-dispatch delegations extracted" "$early_cmds"

# A non-command entry that no longer matches anything is dead weight that would
# quietly widen the allowlist for the next reader.
for ((i = 0; i < ${#EARLY_NON_COMMAND[@]}; i++)); do
    if [ "${early_nc_used[i]}" -eq 1 ]; then
        _pass "EARLY_NON_COMMAND entry $((i + 1)) still matches the dispatch"
    else
        _fail "EARLY_NON_COMMAND entry $((i + 1)) is stale" \
            "matches no line: ${EARLY_NON_COMMAND[i]}"
    fi
done

# --- case block: every arm is parsed ---
# Depth-tracked so nested `case ... in`/`esac` inside arm bodies (e.g. the
# worktree porcelain parser under `list)`) don't contribute arms. Arm patterns
# are `[a-z-]`-shaped; the `*)` error arm is counted but contributes no command.
# The arm count is cross-checked against the `;;` terminators at the same depth:
# an arm written in a shape the pattern doesn't match still terminates, so the
# counts diverge and this goes red instead of silently dropping the command.
case_parse="$(awk '
    /^case "\$\{1:-up\}" in$/ { depth = 1; next }
    depth >= 1 {
        if ($0 ~ /(^|[[:space:]])case[[:space:]].*[[:space:]]in[[:space:]]*$/) { depth++; next }
        if ($0 ~ /^[[:space:]]*esac/) { depth--; if (depth == 0) exit; next }
        if (depth != 1) next
        if ($0 ~ /^[[:space:]]*;;[[:space:]]*$/) { term++ }
        if ($0 ~ /^[[:space:]]*[a-z][a-z0-9|-]*\)/) {
            arms++
            pat = $0
            sub(/^[[:space:]]*/, "", pat); sub(/\).*$/, "", pat)
            n = split(pat, parts, "|")
            for (j = 1; j <= n; j++) print "CMD " parts[j]
        } else if ($0 ~ /^[[:space:]]*\*\)/) {
            arms++
        }
    }
    END { print "COUNT " arms+0 " " term+0 }
' "$devcontainer" || true)"

case_cmds="$(sed -n 's/^CMD //p' <<< "$case_parse" | sort -u)"
assert_nonempty "dispatch case arms extracted" "$case_cmds"
_counts="$(sed -n 's/^COUNT //p' <<< "$case_parse")"
assert_eq "every case arm is parsed (arms == \`;;\` terminators)" \
    "${_counts##* }" "${_counts%% *}"

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

echo ""
echo "--- every table command reaches every generated script ---"

# Generation makes "bash list == zsh list == fish list" structural, but it does
# NOT make those lists CORRECT. A generator that emitted no command names at
# all still produces three mutually consistent, parseable, useless files where
# `devcontainer <TAB>` offers nothing. So extract each shell's real candidate
# list and compare it against the table. (zsh and fish are also covered by the
# sentinel-description assertions further down; bash carries no descriptions,
# so without this its list is only ever asserted non-empty.)
bash_list="$(grep -oP '^    local subcmds="\K[^"]*' "$tmp/bash.out" | tr ' ' '\n' | sort -u)"
zsh_list="$(sed -n "s/^        '\([a-z][a-z0-9-]*\):.*/\1/p" "$tmp/zsh.out" | sort -u)"
fish_list="$(grep -oP 'not __fish_seen_subcommand_from \$cmds" -a \K[a-z][a-z0-9-]*' "$tmp/fish.out" | sort -u)"
fish_var="$(grep -oP '^set -l cmds \K.*' "$tmp/fish.out" | tr ' ' '\n' | sort -u)"

assert_nonempty "bash subcmds list extracted" "$bash_list"
assert_nonempty "zsh subcmds list extracted" "$zsh_list"
assert_nonempty "fish candidate list extracted" "$fish_list"
assert_nonempty "fish \$cmds list extracted" "$fish_var"

assert_eq "bash offers every table command" "$table_cmds" "$bash_list"
assert_eq "zsh offers every table command" "$table_cmds" "$zsh_list"
assert_eq "fish offers every table command" "$table_cmds" "$fish_list"
# $cmds is what fish's "have we seen a subcommand yet" guard tests against, so
# a short list there keeps the root completions firing after one is typed.
assert_eq "fish \$cmds covers every table command" "$table_cmds" "$fish_var"

# The emitted fish/zsh descriptions are free prose. Prove the generator
# escapes rather than relying on the old "avoid apostrophes" authoring
# discipline: a quote, a colon and a backslash in a description must not break
# either file. The backslash row is the asymmetric case — fish_escape doubled
# backslashes from the start, zsh_escape did not, so an input `\` merged with
# the `\:` zsh_escape adds for a following colon and split the description.
tricky="$tmp/tricky.tsv"
awk -F'\t' -v OFS='\t' '
    /^[[:space:]]*(#|$)/ { print; next }
    $1 == "up" { $6 = "quote: it'\''s fine; colon: yes"; $7 = "quote: it'\''s fine" }
    $1 == "down" { $6 = "backslash: a\\b and trailing bs\\" }
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
# zsh: each input `\` doubles, and the `:` still gets its own `\:` — with the
# backslash pass missing (or ordered last) this reads `backslash\\: a\\b ...`,
# i.e. an escaped backslash followed by a BARE colon that ends the name field.
assert_contains "zsh escapes the backslash" 'down:backslash\: a\\b and trailing bs\\' \
    "$(cat "$tmp/tricky-zsh.out")"
assert_contains "fish escapes the backslash" "-d 'backslash: a\\\\b and trailing bs\\\\'" \
    "$(cat "$tmp/tricky-fish.out")"

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
# Padding whitespace is invisible in an editor but reaches the user verbatim,
# in help text and in completion menus.
mutate "trailing-space-in-desc" '/^[[:space:]]*(#|$)/ { print; next } $1 == "logs" { $6 = $6 " " } { print }'
mutate "leading-space-in-arg-syntax" '/^[[:space:]]*(#|$)/ { print; next } $1 == "ps" { $2 = " " $2 } { print }'

# A directory passes -r. Without an -f test the reader falls through to awk,
# which answers with its own "read error (Is a directory)" instead.
assert_false "rejects a directory as the table" validates "$tmp"
assert_not_contains "the directory error is the reader's, not awk's" "awk:" \
    "$(command_table_rows "$tmp" 2>&1 >/dev/null || true)"

# CRLF is tolerated rather than rejected — but the \r must not survive into
# any generated output, where it lands mid-line in `devcontainer help` and
# inside the quoted descriptions of the completion scripts.
crlf="$tmp/crlf.tsv"
sed 's/$/\r/' "$table" > "$crlf"
assert_true "a CRLF table still validates" validates "$crlf"
# Byte-identity against the LF table, not just "contains no \r": if the CRLF
# table stopped validating, an "absence of \r" assertion would pass vacuously
# on the empty output of a failed run.
assert_eq "a CRLF table yields byte-identical usage" \
    "$("$devcontainer" help)" "$(DEV_COMMAND_TABLE="$crlf" "$devcontainer" help || true)"
for sh in bash zsh fish; do
    assert_eq "a CRLF table yields byte-identical $sh completions" \
        "$(cat "$tmp/$sh.out")" "$(DEV_COMMAND_TABLE="$crlf" bash "$completions" "$sh" || true)"
done

echo ""
echo "--- every arg-type is wired in every shell ---"

# arg-type is a convention spread over four files: the `ok_type` vocabulary in
# lib/command-table.sh (plus the table header documenting it), and one
# `case "${types[$n]}"` block per shell in dev/devcontainer-completions. Add a
# value to the validator but not to a generator and that type emits NO wiring,
# silently — the exact class of drift that shipped once already, when fish's
# `-F` file-completion line went missing.
#
# So read the vocabulary out of the validator itself, build a synthetic table
# with one command per value, and require each value to produce non-empty and
# mutually distinct wiring in all three shells.
arg_types="$(grep -oP 'split\("\K[a-z ]+(?=", _t, " "\))' "$DEV_BASE/lib/command-table.sh")"
assert_nonempty "arg-type vocabulary extracted from the validator" "$arg_types"

# The one value whose correct wiring is *no* wiring; anything else that emits
# nothing is a generator that has not heard of the type.
NO_WIRING=" none "

types_tsv="$tmp/argtypes.tsv"
: > "$types_tsv"
for t in $arg_types; do
    printf 'cmd-%s\t-\t%s\t-\t-\t%s desc\t%s desc\n' "$t" "$t" "$t" "$t" >> "$types_tsv"
done
for sh in bash zsh fish; do
    DEV_COMMAND_TABLE="$types_tsv" bash "$completions" "$sh" > "$tmp/types-$sh.out"
done

# The wiring one shell emits for one command, with the command name blanked
# out so two arg-types that produced identical wiring compare equal.
wiring_for() {
    local sh="$1" name="$2" out
    case "$sh" in
        bash) out="$(awk -v n="        $name)" '
                  $0 == n { on = 1; next }
                  on && $0 ~ /^            ;;$/ { on = 0 }
                  on' "$tmp/types-bash.out")" ;;
        zsh)  out="$(grep -F "                $name)" "$tmp/types-zsh.out" || true)" ;;
        fish) out="$(grep -F "__fish_seen_subcommand_from $name\"" "$tmp/types-fish.out" || true)" ;;
    esac
    printf '%s' "${out//"$name"/CMD}"
}

declare -A _seen_wiring
for sh in bash zsh fish; do
    unset _seen_wiring
    declare -A _seen_wiring
    for t in $arg_types; do
        w="$(wiring_for "$sh" "cmd-$t")"
        if [[ "$NO_WIRING" == *" $t "* ]]; then
            assert_eq "$sh emits no per-command wiring for arg-type=$t" "" "$w"
            continue
        fi
        assert_nonempty "$sh wires arg-type=$t" "$w"
        # Nothing to compare (and an empty associative-array subscript is a
        # hard bash error) — the assertion above has already reported it.
        [ -n "$w" ] || continue
        if [ -n "${_seen_wiring["$w"]:-}" ]; then
            _fail "$sh wiring for arg-type=$t is distinct" \
                "identical to arg-type=${_seen_wiring["$w"]}: ${w//$'\n'/ }"
        else
            _pass "$sh wiring for arg-type=$t is distinct"
        fi
        _seen_wiring["$w"]="$t"
    done
done

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
# Anchored to the generated ARM, not the bare wiring: `_filedir -d` on its own
# also appears in the hand-written -w/--workspace preamble, so that form of the
# assertion stayed green even with the whole per-command arm emitter neutered.
assert_contains "bash rewires logs for arg-type=dir" \
    $'        logs)\n            _filedir -d\n            ;;' "$(cat "$tmp/single-bash.out")"
assert_contains "zsh rewires logs for arg-type=dir" 'logs) _files -/ ;;' "$(cat "$tmp/single-zsh.out")"
assert_contains "fish rewires logs for arg-type=dir" \
    '__fish_seen_subcommand_from logs" -a '"'"'(__fish_complete_directories)'"'" \
    "$(cat "$tmp/single-fish.out")"

echo ""
echo "--- an unloadable table degrades loudly, but readably ---"

# show_usage's Commands block is generated, so a table that will not load used
# to leave the help text stopping dead after the "Commands:" header. Still a
# hard error (nothing should quietly pretend the surface is empty), but it says
# what happened.
help_rc=0
help_out="$(DEV_COMMAND_TABLE="$tmp/no-such-table.tsv" "$devcontainer" help 2>/dev/null)" || help_rc=$?
assert_eq "help still fails when the table will not load" "1" "$help_rc"
assert_contains "help says the command list is unavailable" "unavailable" "$help_out"

echo ""
echo "--- a failed install never damages an installed completion ---"

# dev/install-completions used to redirect the generator straight into the
# destination, which truncates it before the generator writes a byte. That was
# unreachable while the generator could not fail for a valid shell; now that a
# malformed table fails it, a bad table would replace a working installed
# completion with an empty file — which a shell loads in silence.
installer="$DEV_BASE/dev/install-completions"
inst="$tmp/inst"
mkdir -p "$inst"
XDG_DATA_HOME="$inst/data" XDG_CONFIG_HOME="$inst/config" bash "$installer" bash >/dev/null
dest="$inst/data/bash-completion/completions/devcontainer"
assert_true "install-completions installed a bash completion" test -s "$dest"
installed="$(cat "$dest")"

inst_rc=0
XDG_DATA_HOME="$inst/data" XDG_CONFIG_HOME="$inst/config" \
    DEV_COMMAND_TABLE="$tmp/no-such-table.tsv" bash "$installer" bash >/dev/null 2>&1 || inst_rc=$?
assert_eq "a failed install reports failure" "1" "$inst_rc"
assert_eq "a failed install leaves the installed file intact" "$installed" "$(cat "$dest")"
assert_eq "a failed install leaves no temp file behind" "1" \
    "$(find "$(dirname "$dest")" -type f | wc -l)"

echo ""
echo "dispatch surface: ${visible//$'\n'/ }"
finish
