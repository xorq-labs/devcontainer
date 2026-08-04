#!/usr/bin/env bash
# Guards on the MERGED COMPOSE MOUNT GRAPH (tests/lib/compose-topology.sh).
#
# The class this closes (#116): facts about the mount graph were restated as
# prose in N files and read by nothing. Production code reads the graph
# (`mount_point_targets` -> `dc config`); the suite read docker-compose.yml only
# as text, so mount EXISTENCE was assertable while NESTING and ABSENCE were not.
# Two independent rules rode on that substrate and both were green under
# mutation:
#
#   - ADR-0001's "the container is NOT bind-mounted to the host credential
#     file" — restated in docker-compose.yml, setup-claude.py, dev/devcontainer
#     and lib/host-bridge.sh, enforced nowhere. Re-adding the exact mount the
#     ADR exists to remove left `tests/run-all` at exit 0.
#   - "a recursive chown under ~/.claude must not cross into a bind" — stated,
#     lost and re-derived across #48 -> #58 -> #61 -> #113 -> #115. #58 added
#     the bind that falsified the comment IN A DIFF THAT RENDERED THAT COMMENT
#     THREE LINES BELOW ITS OWN EDIT, and it was still missed.
#
# The point is not that those comments were wrong. It is that nothing could
# tell. These assertions fail FROM THE SIDE THAT CHANGES — the PR editing
# docker-compose.yml — which is the one place every prior mechanism could not
# reach (see #116 for why the ledger, ADR-0005, the drift-guard convention, the
# #89 sweep and review each structurally could not catch it).
#
# What is asserted:
#   1. the reader is not vacuous, and agrees with real `docker compose config`
#      where a docker CLI exists (the reader re-implements Compose's short-form
#      rules, so it is itself a restatement and needs its own check)
#   2. ADR-0001: nothing bind-mounts the host credential store into the container
#   3. coverage: the mounts under ~/.claude are exactly a declared set — a NEW
#      one is red until someone names it and says why
#   4. nesting: every bind nested under a volume is a declared exception, since
#      that is the topology the unpruned `chown -R` descends through (#115)
#   5. no project overlay introduces a mount under ~/.claude
#
# Verified (ADR-0005 §2), three mutations, each reverted after watching it go
# red. Counts are what the runs produced; the "green before" column is stated
# per-mutation because it is NOT uniform, and the difference is the whole point:
#   1. re-adding `${HOME}/.claude/credentials:/home/vscode/.claude/credentials`,
#      the exact mount ADR-0001 exists to remove — 3 red (items 2, 3, 4).
#      Was GREEN before this file: `bash tests/run-all` -> exit 0.
#   2. adding `${HOME}/.mut-newbind:/home/vscode/.claude/newbind`, a bind
#      directly under the volume #115's `chown -R` is rooted at — 2 red
#      (items 3, 4). Was GREEN before this file: exit 0.
#   3. deleting the transcript bind from docker-compose.yml entirely — 3 red
#      (items 1, 3, 4). This one was ALREADY RED before this file
#      (tests/test-claude-logs.sh greps for `source: ${DEV_CLAUDE_LOGS`, 2 red),
#      so it is not evidence of a gap. It is here because it proves the coverage
#      assertion is two-directional — a REMOVED mount is the #58 case, and a
#      containment check that only noticed additions would miss it.
#   (mutation runs 2026-08-04)
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
. "$(dirname "$(readlink -f "$0")")/lib/compose-topology.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
COMPOSE="$DEV_BASE/docker-compose.yml"
CLAUDE_HOME=/home/vscode/.claude

echo "=== compose mount-graph topology tests ==="

# ---- 1. the reader works, and agrees with Compose itself ----
mounts="$(compose_mounts "$COMPOSE")"
assert_true "the reader returns a non-empty mount graph" test -n "$mounts"
assert_contains "the reader sees the claude-home VOLUME" \
    "volume	$CLAUDE_HOME" "$mounts"
assert_contains "the reader sees the transcript BIND nested inside it" \
    "bind	$CLAUDE_HOME/projects/-workspaces-src" "$mounts"
assert_contains "the reader classifies a host-path short-form mount as a bind" \
    "bind	/workspaces/src" "$mounts"

# Cross-check against Compose's own parser. `docker compose config` needs no
# daemon, only the CLI — but tests/run-all must stay hermetic, so this is
# conditional. Without it the reader is an unverified second implementation of
# Compose's short-form rules (is `claude-home:/x` a volume or a relative bind?),
# which is the restatement shape this whole suite exists to prevent.
if docker compose version >/dev/null 2>&1; then
    real="$(
        DEV_IMAGE_REF=x:1 DEV_CONTAINER_WORKSPACE=/workspaces/src \
        DEV_WORKSPACE=/host/ws DEV_MAIN_GIT=/host/tree/.git DEV_MAIN_TREE=/host/tree \
        DEV_SOPS_AGE_DIR=/host/age HOME=/host/home \
        DEV_CLAUDE_LOGS=/host/home/.claude/projects/-devcontainer-x \
        DEV_CONTAINER_PROJECT_KEY=-workspaces-src \
        docker compose -f "$COMPOSE" config --format=json 2>/dev/null |
            python3 -c '
import json, sys
for v in json.load(sys.stdin)["services"]["app"]["volumes"]:
    print("%s\t%s" % (v.get("type"), v.get("target")))
' | sort
    )"
    ours="$(compose_mounts "$COMPOSE" | awk -F'\t' '$1 != "tmpfs" { print $1 "\t" $2 }' | sort)"
    assert_true "docker compose config produced a mount list to compare against" \
        test -n "$real"
    assert_eq "the hermetic reader agrees with docker compose config" "$real" "$ours"
else
    echo "  SKIP: no docker CLI — reader/Compose cross-check not run"
fi

# ---- 2. ADR-0001: no shared credentials mount ----
# The ADR's central decision is a fact about THIS FILE, and until now it was
# prose in four others. A bind whose source is the host credential store
# re-introduces the shared inode the ADR exists to eliminate.
creds="$(compose_mounts "$COMPOSE" | awk -F'\t' '$1 == "bind" && ($2 ~ /credential/ || $3 ~ /credential/)')"
assert_eq "ADR-0001: nothing bind-mounts the host credential store" "" "$creds"

# ---- 3. coverage: the ~/.claude mounts are exactly this declared set ----
# Two-directional on purpose: an ADDED mount is the mutation case, a REMOVED one
# is the #58 case (a mount changing under a rule that assumed it). Each entry
# below is a claim someone had to make deliberately.
#
#   volume .claude                  — claude-home, container-isolated config (ADR-0001)
#   bind   .claude/projects/<key>   — transcript carve-out; the ONLY bind under
#                                     the volume, and the one #115's chown -R
#                                     descends through
#   tmpfs  .claude/shell-snapshots  — container-local scratch
#
# .claude-host and .claude-host.json are deliberately NOT here: they are
# siblings of ~/.claude, not under it, and the :ro baseline they carry is a
# different decision (ADR-0001's read-only inheritance).
expected_claude="$(
    printf '%s\n' \
        "bind	$CLAUDE_HOME/projects/-workspaces-src" \
        "tmpfs	$CLAUDE_HOME/shell-snapshots" \
        "volume	$CLAUDE_HOME" | sort
)"
assert_eq "the mounts under ~/.claude are exactly the declared set" \
    "$expected_claude" "$(compose_targets_under "$CLAUDE_HOME" "$COMPOSE")"

# ---- 4. nesting: binds under a volume are declared exceptions ----
# This is the topology that makes #115 a defect rather than a curiosity: the
# unpruned `chown -R` is rooted at a volume, so any bind nested under one is on
# the host side of a walk that crosses into it. A NEW such bind — which PR #81
# proposes two of — must be a deliberate, recorded act.
volumes="$(compose_mounts "$COMPOSE" | awk -F'\t' '$1 == "volume" { print $2 }')"
nested=""
while IFS= read -r vol; do
    [ -n "$vol" ] || continue
    while IFS=$'\t' read -r kind target _; do
        [ "$kind" = bind ] || continue
        case "$target" in "$vol"/*) nested="$nested$target"$'\n' ;; esac
    done <<<"$(compose_mounts "$COMPOSE")"
done <<<"$volumes"

# The one declared exception, and the issue that tracks removing the hazard.
assert_eq "the only bind nested under a volume is the transcript carve-out (#115)" \
    "$CLAUDE_HOME/projects/-workspaces-src" "$(printf '%s' "$nested" | sed '/^$/d')"

# ---- 5. project overlays keep out of ~/.claude ----
# Overlays declare project caches; the claude region is the base file's business
# and carries ADR-0001/ADR-0003 decisions. An overlay mount here would be
# invisible to every assertion above, which reads only the base file.
overlay_hits=""
for ov in "$DEV_BASE"/projects/*/compose.override.yml; do
    [ -f "$ov" ] || continue
    hit="$(compose_targets_under "$CLAUDE_HOME" "$ov")"
    [ -n "$hit" ] && overlay_hits="$overlay_hits$ov: $hit"$'\n'
done
assert_eq "no project overlay mounts anything under ~/.claude" "" "$overlay_hits"

finish
