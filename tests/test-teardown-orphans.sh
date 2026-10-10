#!/usr/bin/env bash
# Tests that teardown leaves nothing behind when an overlay renames a service.
#
# Compose scopes `down` to the services the current files declare. Rename a
# sidecar (minio -> s3) and the old container is an orphan: a plain `down`
# leaves it running, still holding its ports, and the recreate path's dc_up then
# fails to bind. `--remove-orphans` takes the container, but even
# `down --volumes --remove-orphans` keeps the orphan's named volume — compose
# only removes volumes the current files declare — so reset/clean, which promise
# to discard per-worktree volumes, also sweep the project's leftover volumes.
#
# No real docker: the sweep runs extracted verbatim with docker stubbed, as
# test-image-reuse.sh does for ensure_image.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DC="$DEV_BASE/dev/devcontainer"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# ---------- every compose down removes orphans ----------
# Derived from the script rather than listing the arms: a new teardown path
# added later is held to the same rule without editing this suite.
mapfile -t downs < <(grep -nE '^[[:space:]]*dc down\b' "$DC")
assert_true "found the dc down call sites (down, reset, clean, recreate)" \
    test "${#downs[@]}" -ge 4
for line in "${downs[@]}"; do
    assert_contains "dc down passes --remove-orphans: ${line#*:}" \
        "--remove-orphans" "$line"
done

# ---------- reset and clean sweep orphaned volumes ----------
arm_body() { # <arm name> — the body of `    <name>)` up to its `;;`
    awk -v arm="    $1)" '$0 == arm { on = 1; next } on && /^        ;;$/ { exit } on' "$DC"
}
for arm in reset clean; do
    body="$(arm_body "$arm")"
    assert_nonempty "extracted the $arm arm" "$body"
    assert_contains "$arm sweeps orphaned volumes" "remove_orphan_volumes" "$body"
done

# ---------- remove_orphan_volumes removes exactly this project's volumes ----------
fn_body="$(sed -n '/^remove_orphan_volumes()/,/^}$/p' "$DC")"
assert_nonempty "extracted remove_orphan_volumes()" "$fn_body"

RUNNER="$TMPDIR_ROOT/run-sweep.sh"
cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="$1"
DEV_CONTAINER_NAME="proj-dev-wt"
# `docker volume ls` answers only the exact project-label filter (a prefix or
# name match would also catch a sibling worktree's volumes); `volume rm` logs,
# and refuses the volume named "busy" the way docker refuses one in use.
docker() {
    case "$1 $2" in
        "volume ls")
            if [ "$*" = "volume ls -q --filter label=com.docker.compose.project=proj-dev-wt" ]; then
                printf '%s\n' proj-dev-wt_minio-data busy
            fi ;;
        "volume rm")
            [ "$3" = busy ] && return 1
            echo "rm $3" >> "$LOG" ;;
        *) echo "unexpected: docker $*" >> "$LOG" ;;
    esac
}
RUNNER_EOF
printf '%s\n' "$fn_body" 'remove_orphan_volumes' >> "$RUNNER"

LOG="$TMPDIR_ROOT/log"
: > "$LOG"
stderr="$(bash "$RUNNER" "$LOG" 2>&1 >/dev/null)" && rc=0 || rc=$?
assert_eq "a volume that cannot be removed does not abort teardown" 0 "$rc"
assert_eq "removes the project's orphaned volume, and only via rm" \
    "rm proj-dev-wt_minio-data" "$(cat "$LOG")"
assert_contains "names the volume it could not remove" "busy" "$stderr"

finish
