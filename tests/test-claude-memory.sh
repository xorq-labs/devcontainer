#!/usr/bin/env bash
# Drift guards for the durable memory carve-outs (ADR-0004). Two layers hold
# the same invariants — lib/claude-memory.sh (host-side migration into the
# bind-mounted shared store) and merge_memory in setup-claude.py (the fallback
# copy for setups without the binds):
#   1. a container-written MEMORY.md index line SURVIVES a reseed/merge
#      (the pre-ADR-0004 copytree clobbered it, orphaning memories), and
#   2. every memory file ends up with an index line (an unindexed memory is
#      invisible to every session).
# No docker required: the bash lib is sourced directly, the python side runs
# against sandbox dirs via the CLAUDE_* path overrides.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SETUP="$DEV_BASE/setup-claude.py"

. "$DEV_BASE/lib/claude-memory.sh"

make_sandbox() {
    local root
    root="$(mktemp -d)"
    _cleanup_dirs+=("$root")
    printf '%s' "$root"
}

# write_memory <dir> <slug> <description> — one memory file, ADR frontmatter shape
write_memory() {
    mkdir -p "$1"
    printf -- '---\nname: %s\ndescription: %s\n---\n\nbody of %s\n' "$2" "$3" "$2" > "$1/$2.md"
}

echo "=== lib/claude-memory.sh: migration into the shared store ==="

root="$(make_sandbox)"
old="$root/legacy" new="$root/shared"
# legacy per-container dir: one memory shared with the store, one container-only
# memory, one ORPHAN (on disk, not indexed — the clobber's residue)
write_memory "$old" fact-shared "old copy"
write_memory "$old" fact-container "container-only fact"
write_memory "$old" fact-orphan "orphaned by the index clobber"
printf '# Memory\n- [fact-shared](fact-shared.md) — container edit\n- [fact-container](fact-container.md) — container-only fact\n' > "$old/MEMORY.md"
# shared store already has its own version of fact-shared (newer) and one more
write_memory "$new" fact-host "host-only fact"
write_memory "$new" fact-shared "host copy, newer"
touch -d '2030-01-01' "$new/fact-shared.md"
printf '# Memory\n- [fact-shared](fact-shared.md) — host edit\n- [fact-host](fact-host.md) — host-only fact\n' > "$new/MEMORY.md"

migrate_project_memory "$old" "$new"
index="$(cat "$new/MEMORY.md")"

assert_contains "container-only memory file migrated" "container-only fact" "$(cat "$new/fact-container.md")"
assert_contains "container index line survives" "- [fact-container](fact-container.md)" "$index"
assert_contains "host-only index line survives" "- [fact-host](fact-host.md)" "$index"
assert_contains "index collision: container line wins" "fact-shared.md) — container edit" "$index"
assert_not_contains "index collision: host duplicate dropped" "host edit" "$index"
assert_contains "newer store file not clobbered by older legacy copy" "host copy, newer" "$(cat "$new/fact-shared.md")"
assert_contains "orphan gets a synthesized index line from frontmatter" \
    "- [fact-orphan](fact-orphan.md) — orphaned by the index clobber" "$index"
assert_eq "one index header after union" "1" "$(grep -c '^# Memory$' "$new/MEMORY.md")"
assert_eq "legacy dir drained to an empty mountpoint stub" "" "$(ls -A "$old")"

# idempotent + no resurrection: delete a memory from the store, re-run
rm "$new/fact-container.md"
migrate_project_memory "$old" "$new"
assert_false "re-run does not resurrect a deleted memory file" test -e "$new/fact-container.md"

echo ""
echo "=== setup-claude.py merge_memory: fallback copy semantics ==="

# Drive the module functions directly (same import seam as the CLAUDE_* env
# overrides used by tests/test-claude-seed.sh, but for the merge helpers).
run_merge() { # <host-dir> <home-dir>
    env MERGE_SRC="$1" MERGE_DST="$2" SETUP_PY="$SETUP" python3 - <<'EOF'
import importlib.util, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("sc", os.environ["SETUP_PY"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.merge_memory(Path(os.environ["MERGE_SRC"]), Path(os.environ["MERGE_DST"]))
EOF
}

root="$(make_sandbox)"
host="$root/host-mem" home="$root/home-mem"
write_memory "$host" fact-host "host fact"
printf '# Memory\n- [fact-host](fact-host.md) — host fact\n' > "$host/MEMORY.md"
write_memory "$home" fact-container "container fact"
write_memory "$home" fact-orphan "container orphan"
printf '# Memory\n- [fact-container](fact-container.md) — container fact\n' > "$home/MEMORY.md"

run_merge "$host" "$home"
index="$(cat "$home/MEMORY.md")"

assert_contains "container index line survives the reseed" "- [fact-container](fact-container.md)" "$index"
assert_contains "host index line arrives with its memory" "- [fact-host](fact-host.md)" "$index"
assert_true "host memory file copied in" test -f "$home/fact-host.md"
assert_contains "container-side orphan gets an index line" "- [fact-orphan](fact-orphan.md)" "$index"

# reseed again: stable (no duplicate lines, nothing clobbered)
run_merge "$host" "$home"
assert_eq "second reseed adds no duplicate container line" \
    "1" "$(grep -cF -- '- [fact-container](fact-container.md)' "$home/MEMORY.md")"

# samefile guard: with the ADR-0004 bind both names are one host dir. A union
# with itself is content-stable, so pin the no-op via mtime: the guard must
# return before rewriting the index at all.
root="$(make_sandbox)"
write_memory "$root/store" fact-x "x"
printf '# Memory\n- [fact-x](fact-x.md) — x\n' > "$root/store/MEMORY.md"
ln -s "$root/store" "$root/alias"
before="$(stat -c %y "$root/store/MEMORY.md")"
run_merge "$root/alias" "$root/store"
assert_eq "bind present (same dir): index not rewritten" \
    "$before" "$(stat -c %y "$root/store/MEMORY.md")"

finish
