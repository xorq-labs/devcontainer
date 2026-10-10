#!/usr/bin/env bash
# Tests that teardown leaves nothing behind when an overlay renames a service.
#
# Compose scopes `up` and `down` to the services the current files declare.
# Rename a sidecar (minio -> s3) and the old container is an orphan: compose
# only warns about it, so it keeps running and holding its ports, and the
# renamed sidecar then fails to bind. dc() therefore runs every compose command
# with COMPOSE_REMOVE_ORPHANS=true (honoured by both `up` and `down`, measured
# against compose v2.29.7). Removing an orphan container does not remove its
# named volume, though, and neither does `down --volumes`, which only removes
# declared volumes, so reset/clean (teardown_volumes) also sweep the project's
# leftover volumes. The sweep must not reach the shared caches.
#
# No real docker: each function runs extracted verbatim with docker (or dc)
# stubbed, as test-image-reuse.sh does for ensure_image. The arm check is the
# one textual assertion, and the order of down and sweep lives in
# teardown_volumes rather than being repeated in each arm, so the arm check only
# has to show that the call is live code.
#
# Verified (ADR-0005 §2), fresh copy of the tree per mutation, 2026-10-10:
#   FORM-ONLY (must stay green, same assertion count):
#     a. dc(): hoist the assignment into `local -x COMPOSE_REMOVE_ORPHANS=true`
#        on its own line before `docker compose ...` -> green.
#     b. reset arm: `teardown_volumes  # per-worktree volumes` (trailing
#        comment) -> green.
#   SEMANTIC (must go red), each written in a form the author did not write:
#     c. dc(): comment out the prefix assignment by moving it to a
#        `# COMPOSE_REMOVE_ORPHANS=true` line above an unprefixed call -> red.
#     d. remove_orphan_volumes: comment out the prefix test line -> red (the
#        stale-labelled shared cache is removed).
#     e. teardown_volumes: swap the two calls -> red (order).
#     f. clean arm: `# teardown_volumes` -> red.
#     g. add `docker compose -p x down` as a new line outside dc() -> red.
#     h. the same, written `if ! docker compose -p x down; then :; fi` -> red
#        (the first version of this check matched only command position after
#        `;&|(` and missed it).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DC="$DEV_BASE/dev/devcontainer"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

fn_body() { sed -n "/^$1()/,/^}\$/p" "$DC"; }

# ---------- every compose command removes orphans ----------
dc_body="$(fn_body dc)"
assert_nonempty "extracted dc()" "$dc_body"

RUNNER="$TMPDIR_ROOT/run-dc.sh"
cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
COMPOSE_FILE=/x/docker-compose.yml COMPOSE_OVERRIDE=/nonexistent
DEV_USE_NIX_BASE=false DEV_BASE_DIR=/x DEV_CONTAINER_NAME=proj-dev-wt
docker() { echo "${COMPOSE_REMOVE_ORPHANS:-unset} $*"; }
RUNNER_EOF
printf '%s\n' "$dc_body" 'dc up -d' 'dc down --volumes' >> "$RUNNER"
out="$(bash "$RUNNER")"
assert_contains "dc up runs with orphan removal" \
    "true compose -f /x/docker-compose.yml -p proj-dev-wt up -d" "$out"
assert_contains "dc down runs with orphan removal" \
    "true compose -f /x/docker-compose.yml -p proj-dev-wt down --volumes" "$out"

# dc() is the only door to compose: a `docker compose` anywhere else bypasses
# the setting above. Any occurrence counts (`if ! docker compose`, `x &&
# docker compose`), except in comments and in a double-quoted string with no
# expansion in it, which is a message naming the command rather than running it.
strays=()
for f in "$DC" "$DEV_BASE"/lib/*.sh; do
    while IFS= read -r hit; do
        strays+=("$f:$hit")
    done < <(awk -v skip="$([ "$f" = "$DC" ] && echo 1)" '
        skip && /^dc\(\) \{$/ { in_dc = 1 }
        in_dc { if (/^}$/) in_dc = 0; next }
        /^[[:space:]]*#/ { next }
        { line = $0; gsub(/"[^"$]*"/, "", line) }
        line ~ /docker[[:space:]]+compose([[:space:]]|$)/ { print NR": "$0 }
    ' "$f")
done
assert_eq "no docker compose call outside dc()" "" "${strays[*]:-}"

# ---------- remove_orphan_volumes takes only this worktree's own volumes ----------
sweep_body="$(fn_body remove_orphan_volumes)"
assert_nonempty "extracted remove_orphan_volumes()" "$sweep_body"

RUNNER="$TMPDIR_ROOT/run-sweep.sh"
cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="$1"
DEV_CONTAINER_NAME="proj-dev-wt"
# `volume ls` answers only the exact project-label filter. Behind it:
#   proj-dev-wt_minio-data  the renamed service's orphan        -> removed
#   proj-dev-wt_busy        one docker refuses (still in use)   -> warned, kept
#   proj-uv-cache           a shared cache compose created before the overlay
#                           marked it external, so it kept the label -> kept
docker() {
    case "$1 $2" in
        "volume ls")
            if [ "$*" = "volume ls -q --filter label=com.docker.compose.project=proj-dev-wt" ]; then
                printf '%s\n' proj-dev-wt_minio-data proj-dev-wt_busy proj-uv-cache
            fi ;;
        "volume rm")
            [ "$3" = proj-dev-wt_busy ] && return 1
            echo "rm $3" >> "$LOG" ;;
        *) echo "unexpected: docker $*" >> "$LOG" ;;
    esac
}
RUNNER_EOF
printf '%s\n' "$sweep_body" 'remove_orphan_volumes' >> "$RUNNER"

LOG="$TMPDIR_ROOT/log"
: > "$LOG"
stderr="$(bash "$RUNNER" "$LOG" 2>&1 >/dev/null)" && rc=0 || rc=$?
assert_eq "a volume that cannot be removed does not abort teardown" 0 "$rc"
assert_eq "removes the orphaned volume and nothing else, including the stale-labelled cache" \
    "rm proj-dev-wt_minio-data" "$(cat "$LOG")"
assert_contains "names the volume it could not remove" "proj-dev-wt_busy" "$stderr"

# ---------- teardown_volumes sweeps after down ----------
td_body="$(fn_body teardown_volumes)"
assert_nonempty "extracted teardown_volumes()" "$td_body"
out="$(bash -c "set -euo pipefail
dc() { echo \"dc \$*\"; }
remove_orphan_volumes() { echo sweep; }
$td_body
teardown_volumes")"
assert_eq "down --volumes, then the sweep" $'dc down --volumes\nsweep' "$out"

# ---------- reset and clean call teardown_volumes ----------
arm_body() { # <arm name> — the body of `    <name>)` up to its `;;`
    awk -v arm="    $1)" '$0 == arm { on = 1; next } on && /^        ;;$/ { exit } on' "$DC"
}
for arm in reset clean; do
    body="$(arm_body "$arm")"
    assert_nonempty "extracted the $arm arm" "$body"
    live="$(grep -cE '^[[:space:]]*teardown_volumes[[:space:]]*(#.*)?$' <<< "$body" || true)"
    assert_eq "$arm calls teardown_volumes as live code" 1 "$live"
done

finish
