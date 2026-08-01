#!/usr/bin/env bash
# Guard: the hand-maintained command lists track the real dispatch surface.
#
# dev/devcontainer's subcommands are enumerated in five places: the dispatch
# itself (early `if [ "${1:-}" = "cmd" ]` delegations plus the main
# `case "${1:-up}" in` arms), the bash/zsh/fish word lists emitted by
# dev/devcontainer-completions, and show_usage. The four presentation lists
# are hand-maintained, so a new subcommand added to the dispatch drifts out
# of completions and usage with no signal. This test derives the canonical
# set (a) from the dispatch and asserts each list (b)-(e) equals it as a set.
#
# Parsing is anchored on stable syntax, not line numbers:
#   (a) `if [ "${1:-}" = "<cmd>" ]` lines + the `case "${1:-up}" in` arms
#       (awk tracks case/esac nesting depth so nested cases inside arm
#       bodies don't leak in; multi-pattern arms `a|b)` are split; the `*`
#       error arm never matches the [a-z-]-only pattern class)
#   (b)-(d) the emitted completion scripts (run the generator): bash
#       `local subcmds="..."`, zsh the `'cmd:desc'` entries of the subcmds
#       array, fish `set -l cmds ...`
#   (e) the show_usage heredoc's two-space-indented command column
#
# HIDDEN_OK below allowlists dispatch arms deliberately absent from the
# user-facing lists. It is currently empty: `help` (with -h/--help) is
# handled before the dispatch case and appears in no list, so it never
# enters set (a) at all.
#
# Every extraction is anchor-guarded: an empty set fails loudly.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

# The harness has no bare non-empty asserter; this guard leans on it to prove
# the parse anchors still match (an empty capture means the anchor missed).
assert_nonempty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        _pass "$label"
    else
        _fail "$label" "empty — anchor missed? file restructured?"
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
devcontainer="$DEV_BASE/dev/devcontainer"
completions="$DEV_BASE/dev/devcontainer-completions"

echo "--- subcommand list sync (dispatch vs completions vs usage) ---"

[ -f "$devcontainer" ] || { echo "  FAIL: $devcontainer not found"; exit 1; }
[ -f "$completions" ] || { echo "  FAIL: $completions not found"; exit 1; }

# Dispatch arms deliberately internal/hidden — allowed to be missing from the
# completion and usage lists. None today; add sparingly, with a reason.
HIDDEN_OK=()

# (a) canonical set: early string-equality delegations...
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

# (b) bash: the `local subcmds="..."` word list in the emitted script.
bash_cmds="$(bash "$completions" bash | grep -m1 -oP 'local subcmds="\K[^"]+' \
    | tr ' ' '\n' | sort -u || true)"
assert_nonempty "bash completion word list extracted" "$bash_cmds"

# (c) zsh: the 'cmd:description' entries of the subcmds array (other quoted
# specs in the script start with (, digits, or * and never match).
zsh_cmds="$(bash "$completions" zsh | grep -oP "^\s*'\K[a-z][a-z0-9-]*(?=:)" \
    | sort -u || true)"
assert_nonempty "zsh completion word list extracted" "$zsh_cmds"

# (d) fish: the `set -l cmds ...` word list gating the -a completions.
fish_cmds="$(bash "$completions" fish | grep -m1 -oP '^set -l cmds \K.*' \
    | tr ' ' '\n' | sort -u || true)"
assert_nonempty "fish completion word list extracted" "$fish_cmds"

# (e) show_usage: the command column of its heredoc — two-space indent then
# the command name (continuation/description lines are indented deeper).
usage_cmds="$(sed -n '/^show_usage() {$/,/^USAGE$/p' "$devcontainer" \
    | grep -oP '^  \K[a-z][a-z0-9-]*' | sort -u || true)"
assert_nonempty "show_usage command column extracted" "$usage_cmds"

assert_eq "bash completions == dispatch" "$visible" "$bash_cmds"
assert_eq "zsh completions == dispatch" "$visible" "$zsh_cmds"
assert_eq "fish completions == dispatch" "$visible" "$fish_cmds"
assert_eq "show_usage == dispatch" "$visible" "$usage_cmds"

echo ""
echo "dispatch surface: ${visible//$'\n'/ }"
finish
