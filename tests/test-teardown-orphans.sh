#!/usr/bin/env bash
# Tests that teardown leaves nothing behind when an overlay renames a service.
#
# Compose scopes `up` and `down` to the services the current files declare.
# Rename a sidecar (minio -> s3) and the old container is an orphan: compose
# only warns about it, so it keeps running and holding its ports, and the
# renamed sidecar then fails to bind. dc() therefore runs every compose command
# with COMPOSE_REMOVE_ORPHANS=true (honoured by both `up` and `down`, measured
# against compose v2.29.7) and COMPOSE_IGNORE_ORPHANS cleared, since compose
# refuses `up` with both set. Removing an orphan container does not remove its
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
# Verified (ADR-0005 §2), fresh copy of the tree per mutation, 2026-10-10
# (18 assertions):
#   FORM-ONLY (must stay green, same assertion count):
#     a. dc(): hoist the assignments into
#        `local -x COMPOSE_IGNORE_ORPHANS='' COMPOSE_REMOVE_ORPHANS=true` on its
#        own line before `docker compose ...` -> green, 18.
#     b. reset arm: `teardown_volumes  # per-worktree volumes` -> green, 18.
#   SEMANTIC (must go red), each written in a form the author did not write:
#     c. dc(): the assignments moved into a comment above an unprefixed call
#        -> red (both dc assertions).
#     d. dc(): `COMPOSE_IGNORE_ORPHANS="${COMPOSE_IGNORE_ORPHANS:-}"`, which
#        keeps the user's value -> red (both dc assertions).
#     e. remove_orphan_volumes: comment out the prefix test -> red (the
#        stale-labelled shared cache is removed).
#     f. remove_orphan_volumes: `|| true` inside the listing's `$(...)` -> red
#        (failed listing not warned about).
#     g. remove_orphan_volumes: `2>/dev/null` in place of `2>&1 >/dev/null` on
#        the rm -> red (docker's reason missing from the warning).
#     p. remove_orphan_volumes: `2>&1` inside the listing's `$(...)` -> red
#        (docker's reason swallowed into the name list).
#     h. teardown_volumes: swap the two calls -> red (order).
#     o. teardown_volumes: comment out the flock block -> red (lock not held).
#     i. clean arm: `# teardown_volumes` -> red.
#     j-m. a new function outside dc() running, in turn,
#        `docker compose -p x down`, `if ! docker compose -p x down; then :;
#        fi`, `docker-compose -p x down`, `docker --context x compose -p x
#        down` -> red each (the first version of this check matched only
#        `docker compose` after `;&|(` and missed k; the second missed l, m).
#     n. `docker compose -p x down` appended to dev/cleanup-worktree -> red
#        (the check scanned only dev/devcontainer and lib/ until round 3).
#     q. dc(): `( unset COMPOSE_IGNORE_ORPHANS; COMPOSE_REMOVE_ORPHANS=true
#        docker compose ... )`, unset instead of exported empty -> red (both dc
#        assertions). Green before the stub printed `${VAR+set}`.
#     r. `docker compose -p x down` appended to dev/hooks/post-checkout -> red.
#        Green before the scan included dev/hooks/.
#   (q and r re-measured 2026-10-10 against both this suite and the one at
#    36f5728, a fresh copy each; c-p re-run unchanged at 18 assertions.)
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
export COMPOSE_IGNORE_ORPHANS=true   # as a user's shell profile might
# `ignore=set:` means exported and empty; unset would print `ignore=:` (dc()
# says why the difference matters).
docker() { echo "remove=${COMPOSE_REMOVE_ORPHANS:-} ignore=${COMPOSE_IGNORE_ORPHANS+set}:${COMPOSE_IGNORE_ORPHANS:-} $*"; }
RUNNER_EOF
printf '%s\n' "$dc_body" 'dc up -d' 'dc down --volumes' >> "$RUNNER"
out="$(bash "$RUNNER")"
assert_contains "dc up runs with orphan removal, ignore cleared" \
    "remove=true ignore=set: compose -f /x/docker-compose.yml -p proj-dev-wt up -d" "$out"
assert_contains "dc down runs with orphan removal, ignore cleared" \
    "remove=true ignore=set: compose -f /x/docker-compose.yml -p proj-dev-wt down --volumes" "$out"

# dc() is the only door to compose: compose run anywhere else bypasses the
# setting above. Any occurrence counts (`if ! docker compose`, `x && docker
# compose`, `docker --context x compose`, the standalone `docker-compose`),
# except in comments and in a double-quoted string with no expansion in it,
# which is a message naming the command rather than running it. Not caught, and
# accepted: a call split across lines with `\`, or built up and run by `eval`.
strays=()
for f in "$DEV_BASE"/dev/* "$DEV_BASE"/dev/hooks/* "$DEV_BASE"/lib/*.sh; do
    [ -f "$f" ] || continue
    while IFS= read -r hit; do
        strays+=("$f:$hit")
    done < <(awk -v skip="$([ "$f" = "$DC" ] && echo 1)" '
        skip && /^dc\(\) \{$/ { in_dc = 1 }
        in_dc { if (/^}$/) in_dc = 0; next }
        /^[[:space:]]*#/ { next }
        { line = $0; gsub(/"[^"$]*"/, "", line) }
        line ~ /docker(-compose|[[:space:]](.*[[:space:]])?compose)([[:space:]]|$)/ { print NR": "$0 }
    ' "$f")
done
assert_eq "no compose call outside dc()" "" "${strays[*]:-}"

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
# LS_FAILS=1 makes the listing fail the way an unreachable daemon does.
docker() {
    case "$1 $2" in
        "volume ls")
            if [ -n "${LS_FAILS:-}" ]; then
                echo "Cannot connect to the Docker daemon" >&2; return 1
            fi
            if [ "$*" = "volume ls -q --filter label=com.docker.compose.project=proj-dev-wt" ]; then
                printf '%s\n' proj-dev-wt_minio-data proj-dev-wt_busy proj-uv-cache
            fi ;;
        "volume rm")
            if [ "$3" = proj-dev-wt_busy ]; then
                echo "volume is in use - [c0ffee]" >&2; return 1
            fi
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
assert_contains "names the volume it could not remove, with docker's reason" \
    "proj-dev-wt_busy: volume is in use - [c0ffee]" "$stderr"

: > "$LOG"
stderr="$(LS_FAILS=1 bash "$RUNNER" "$LOG" 2>&1 >/dev/null)" && rc=0 || rc=$?
assert_eq "a failed listing does not abort teardown" 0 "$rc"
assert_contains "a failed listing is warned about" \
    "could not list orphaned volumes" "$stderr"
assert_contains "docker's own reason for the failed listing reaches the user" \
    "Cannot connect to the Docker daemon" "$stderr"
assert_eq "a failed listing removes nothing" "" "$(cat "$LOG")"

# ---------- teardown_volumes sweeps after down ----------
td_body="$(fn_body teardown_volumes)"
assert_nonempty "extracted teardown_volumes()" "$td_body"
# Each stub reports whether the per-worktree lock is held, by trying to take
# it from a separate process.
out="$(DEV_LOCKFILE="$TMPDIR_ROOT/wt.lock" bash -c "set -euo pipefail
held() { flock -n \"\$DEV_LOCKFILE\" true && echo unlocked || echo locked; }
dc() { echo \"dc \$* \$(held)\"; }
remove_orphan_volumes() { echo \"sweep \$(held)\"; }
$td_body
teardown_volumes")"
assert_eq "down --volumes, then the sweep, both under the worktree lock" \
    $'dc down --volumes locked\nsweep locked' "$out"

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
