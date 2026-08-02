# shellcheck shell=bash
# Host-side maintenance of the durable Claude memory carve-outs
# (docs/adr/0004-durable-claude-memory-carve-outs.md).
#
# Memory is a directory of one-fact-per-file markdown plus a MEMORY.md index —
# the index is what gets loaded into a session's context, so the invariant to
# hold everywhere is: EVERY memory file has an index line. A memory file whose
# index line is lost is orphaned — present on disk, absent from every session's
# view (the defect that motivated ADR-0004).
#
# Sourced by dev/devcontainer. No dependencies on the sourcer.

# memory_index_union <out> <winner> <loser>
# Write the union of two MEMORY.md files to <out>. Lines are keyed by their
# markdown link target ("](file.md)"); on a key collision the <winner> line is
# kept. Lines without a link (headers, blanks) dedupe by full content. <out>
# may be the same path as either input.
memory_index_union() {
    local out="$1" winner="$2" loser="$3"
    local tmp
    tmp="$(mktemp)"
    awk '
        {
            key = $0
            if (match($0, /\]\([^)]*\)/)) key = substr($0, RSTART, RLENGTH)
            if (key in seen) next
            seen[key] = 1
            print
        }
    ' "$winner" "$loser" > "$tmp"
    mv "$tmp" "$out"
}

# memory_synthesize_index_lines <dir>
# Restore the every-file-has-an-index-line invariant: append an index line for
# any memory file MEMORY.md does not reference, titled from the file's
# frontmatter `name:` (falling back to the filename) and summarized from its
# `description:`. Repairs orphans left by the pre-ADR-0004 index clobber.
memory_synthesize_index_lines() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local index="$dir/MEMORY.md" f base title desc
    for f in "$dir"/*.md; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ "$base" = "MEMORY.md" ] && continue
        if [ -f "$index" ] && grep -qF "]($base)" "$index"; then
            continue
        fi
        title="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)"
        [ -n "$title" ] || title="${base%.md}"
        desc="$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)"
        [ -f "$index" ] || printf '# Memory\n' > "$index"
        if [ -n "$desc" ]; then
            printf -- '- [%s](%s) — %s\n' "$title" "$base" "$desc" >> "$index"
        else
            printf -- '- [%s](%s)\n' "$title" "$base" >> "$index"
        fi
    done
}

# migrate_project_memory <old> <new>
# One-shot merge of a legacy per-container memory dir (the memory/ subdir of
# the DEV_CLAUDE_LOGS transcript bind) into the shared per-project store that
# ADR-0004 bind-mounts over it. Per file: MEMORY.md is unioned with the OLD
# (container-written) line winning a collision; other files copy when the
# destination is missing or older. Merged sources are removed, so the old dir
# converges to an empty mountpoint stub, re-running is a no-op, and a memory
# later deleted from the shared store cannot resurrect from the legacy copy.
# An interrupted run self-heals: copy-before-remove means the next entry
# re-merges whatever remains.
migrate_project_memory() {
    local old="$1" new="$2"
    [ -d "$old" ] || return 0
    mkdir -p "$new"
    local f base
    for f in "$old"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        if [ "$base" = "MEMORY.md" ]; then
            if [ -f "$new/MEMORY.md" ]; then
                memory_index_union "$new/MEMORY.md" "$f" "$new/MEMORY.md"
            else
                cp -p "$f" "$new/MEMORY.md"
            fi
        elif [ ! -e "$new/$base" ] || [ "$f" -nt "$new/$base" ]; then
            cp -p "$f" "$new/$base"
        fi
        rm -f "$f"
    done
    memory_synthesize_index_lines "$new"
}
