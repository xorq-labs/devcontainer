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
#      where a docker CLI exists (the reader re-implements Compose's rules, so
#      it is itself a restatement and needs its own check)
#   2. ADR-0001: no WRITABLE mount of the host home/credential store, keyed on
#      the mount SOURCE, with the transcript carve-out as the one declared
#      exception; plus `:ro` pinned on the two `.claude-host` mounts
#   3. coverage: the mounts under ~/.claude are exactly a declared set — a NEW
#      one is red until someone names it and says why
#   4. nesting: every bind nested under a volume is a declared exception, since
#      that is the topology the unpruned `chown -R` descends through (#115)
#   5. no compose file other than the base mounts anything under ~/.claude,
#      across the DERIVED file set and EVERY service
#   6. no committed host-mounts.txt does either, and the parser for that format
#      is pinned against a synthetic line
#
# Verified (ADR-0005 §2), twelve mutations. Counts are transcribed from the
# runs; the "green before" column is stated PER MUTATION because it is not
# uniform, and that difference is the whole point — several of these were green
# against an earlier revision of this same file, i.e. they are gaps this guard
# had and closed, not gaps it never had:
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
#   4. committing `~/.claude/evil:/home/vscode/.claude/evil` to
#      projects/devcontainer/host-mounts.txt — a bind under the volume #115's
#      `chown -R` is rooted at, arriving through the OTHER committed channel —
#      1 red (item 6). Was GREEN against this suite's first revision: the
#      guard read compose files only, so the whole point of it was evadable by
#      putting the mount one file over in the same overlay directory.
#      (Found in review, not by me.)
#   5. dropping `:ro` from the `${HOME}/.claude:/home/vscode/.claude-host`
#      mount, making the host credential store shared-WRITABLE from every
#      container — 1 red (item 2's read-only half). Also GREEN against the
#      first revision, because the reader discarded the options field, so no
#      assertion could have checked it. (Found in review.)
#   6. a `~/.claude` bind added to `defaults/compose.override.yml` — 1 red
#      (item 5). Was GREEN through review round 1: the overlay check globbed
#      `projects/*/compose.override.yml`, and `defaults/` is a real overlay
#      (DEV_PROJECT_DIR falls back to it).
#   7. the same bind added to `nix/base/compose.nix-base.yml`, which dc()
#      appends on the nix route — 1 red (item 5). Also GREEN through round 1;
#      no assertion read that file at all.
#   8. a host-mounts line whose target hides a colon in a default —
#      `~/.claude/two:/home/vscode/.clau${X:-de}/two`, which really mounts
#      under ~/.claude — 1 red (item 6). Green until the interpolation model
#      was fixed TWICE: first the parser split before interpolating at all,
#      then it expanded `${X:-de}` to a stub path instead of to `de` as
#      compose does, putting the target under /home/vscode/.clau/stub/x/ where
#      it matched no prefix.
#   9. a colon-free host-mounts line, `/home/vscode/.claude/backup`, which
#      compose reads as an anonymous volume at that path — 1 red (item 6).
#      Green while the parser skipped single-field lines.
#
#  10. a WRITABLE `${HOME}/.claude:/home/vscode/.claude-rw` — the host store,
#      which contains .credentials.json, at a target no assertion named — 1 red
#      (item 2). Green through round 2: the ADR-0001 check keyed on the word
#      "credential" appearing in a path, so choosing another target evaded it.
#      The rule is now keyed on the SOURCE, with one declared exception (the
#      transcript carve-out, which is writable by design).
#  11. a second SERVICE (`sidecar`) in a project overlay bind-mounting the host
#      store under ~/.claude — 1 red (item 5). Green through round 2: the
#      reader read `services.app` only, while `dc up -d` starts every service
#      in the merged config.
#  12. a host-mounts target hiding a COLON-LESS default, `${X-de}`, and
#      separately an unbraced `$Y` — 1 red each (item 6). Green through round
#      2: the interpolation model required a colon before `-`/`?` and only
#      matched braced forms, so both rendered under ~/.claude for real compose
#      while the reader left them literal. Third instance of this class, one
#      spelling over from the previous fix — which is why the model is now a
#      single shared definition rather than two hand-synced copies.
#
# METHOD: measure each mutation in a FRESH copy of the tree and transcribe the
# numbers from the run. Counts taken from one scratch copy reused across
# mutations disagreed with one-copy-per-mutation counts, and only the latter
# reproduce; the reason the reused copy drifted was never established (an
# earlier note blamed `git checkout` failing to restore in a `cp -a` copy of a
# linked worktree — that does not reproduce). tests/mutation-coverage automates
# this; it is not in this tree, it ships on the branch behind PR #124.
#   (mutation runs 2026-08-04; 4-5 added in round 1, 6-9 in round 2,
#    10-12 in round 3)
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
# Two distinct outcomes, deliberately not collapsed into one skip:
#   no docker CLI at all      -> SKIP (the hermetic half still ran)
#   docker present, no output -> FAIL (loud: an old CLI without `--format`,
#                                which arrived ~compose v2.24, or a broken
#                                render — either way the cross-check silently
#                                not running is the thing to avoid)
# Gating on `docker compose version` instead left an old CLI feeding empty
# output to json.load, and `set -e` killed the suite mid-run before the
# assertion written for that case could be reached. The render is captured
# ONCE, with the same env stubs the reader uses, so the probe cannot pass while
# the real invocation fails on a missing `${VAR:?}`.
if command -v docker >/dev/null 2>&1; then
    real="$(
        DEV_IMAGE_REF=x:1 DEV_CONTAINER_WORKSPACE=/workspaces/src \
        DEV_WORKSPACE=/host/ws DEV_MAIN_GIT=/host/tree/.git DEV_MAIN_TREE=/host/tree \
        DEV_SOPS_AGE_DIR=/host/age HOME=/host/home \
        DEV_CLAUDE_LOGS=/host/home/.claude/projects/-devcontainer-x \
        DEV_CONTAINER_PROJECT_KEY=-workspaces-src \
        docker compose -f "$COMPOSE" config --format=json 2>/dev/null |
            python3 -c '
import json, sys
# Tolerant on purpose: an old CLI (no --format) or a failed render feeds empty
# or non-JSON here. Raising would abort the whole suite through set -e on this
# assignment; returning nothing lets the anti-vacuity assertion below report a
# normal FAIL with a message a reader can act on.
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for v in doc.get("services", {}).get("app", {}).get("volumes") or []:
    print("%s\t%s" % (v.get("type"), v.get("target")))
' | sort || true
    )"
    # `|| true` is load-bearing, not defensive noise: without it `pipefail`
    # propagates a nonzero docker status out of this command substitution and
    # `set -e` kills the SUITE at this assignment — before the assertion written
    # for exactly that case can run. The previous revision's comment claimed to
    # have fixed this; the tolerant JSON parse only covered exit-0-with-garbage,
    # and the nonzero-exit path (an old CLI without `--format`) still aborted.
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
# Keyed on the SOURCE, not on the word "credential" appearing in a path.
# Name-keying was evadable by simply choosing another target: a writable
# `${HOME}/.claude:/home/vscode/.claude-rw` mounts the host store (which
# contains .credentials.json) and passed every assertion, because no path said
# "credential". The rule ADR-0001 actually states is about the STORE, so: any
# mount whose source is the host home or under it must be read-only, wherever
# it lands and whatever it is called.
#
# ONE declared exception, and it is ADR-0001's own: the transcript carve-out
# under ~/.claude/projects/<key> must be writable — that is the whole point of
# it, and it addresses a per-container leaf, not the store. Anything else
# writable under the host home is the regression.
#
# Read across the DERIVED set, not just the base file: an overlay (or a sidecar
# service in one) mounting the store at a target outside ~/.claude would be
# invisible to both this and the ~/.claude coverage assertion below.
# shellcheck disable=SC2046  # word-splitting the derived file list is intended
writable_host_store="$(compose_mounts $(committed_compose_files) |
    awk -F'\t' '($3 == "/host/home" || index($3, "/host/home/") == 1) &&
                $4 !~ /ro/ &&
                index($3, "/host/home/.claude/projects/") != 1')"
assert_eq "ADR-0001: no WRITABLE mount of the host home/credential store" \
    "" "$writable_host_store"

# The ADR's OTHER half, docs/adr/0001-...:46 — "the store is still reachable
# READ-ONLY via the existing .claude-host mount (host ~/.claude, which includes
# credentials/)". The host credential store IS mounted; `:ro` is the entire
# reason that is acceptable. Dropping it makes it shared-writable from every
# container — a regression squarely inside the ADR — and nothing pinned it,
# because the reader used to discard the options field.
for ro_target in "$CLAUDE_HOME-host" "$CLAUDE_HOME-host.json"; do
    assert_eq "ADR-0001: $ro_target is mounted read-only" "ro" \
        "$(compose_mounts "$COMPOSE" | awk -F'\t' -v t="$ro_target" '$2 == t { print $4 }')"
done

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
# DERIVED from `git ls-files`, not a glob of the directories someone thought of.
# A hand-maintained file list leaked a channel three times: this assertion once
# read projects/*/compose.override.yml only, and both defaults/compose.override.yml
# (a real overlay — DEV_PROJECT_DIR falls back to defaults/) and
# nix/base/compose.nix-base.yml (appended by dc() on the nix route) were live,
# unread channels. A ~/.claude bind in either left the whole suite green.
# `|| true` for the same reason as the docker render below: without it, a failing
# `git ls-files` (no repo, no git binary) exits nonzero through this
# substitution and `set -e` kills the suite AT THE ASSIGNMENT, before the
# anti-vacuity assertion written for exactly that case can report it. An empty
# derived set must be a clean FAIL naming the cause, not a silent abort.
compose_set="$(committed_compose_files || true)"
assert_true "the committed compose set was derived from git ls-files" \
    test -n "$compose_set"
# Anti-vacuity with teeth: name the members whose absence caused a real gap, so
# a regex that silently stops matching them cannot pass as "nothing to scan".
# grep -qxF, not assert_contains: a path is a prefix of longer paths in this
# set. (Migrate to assert_line once #124 lands — it adds that helper.)
for expected in docker-compose.yml defaults/compose.override.yml \
    nix/base/compose.nix-base.yml projects/devcontainer/compose.override.yml; do
    assert_true "the derived set includes $expected" \
        grep -qxF "$DEV_BASE/$expected" <<<"$compose_set"
done

overlay_hits=""
while IFS= read -r ov; do
    [ -n "$ov" ] && [ "$ov" != "$COMPOSE" ] || continue
    hit="$(compose_targets_under "$CLAUDE_HOME" "$ov")"
    [ -n "$hit" ] && overlay_hits="$overlay_hits$ov: $hit"$'\n'
done <<<"$compose_set"
assert_eq "no compose file other than the base mounts anything under ~/.claude" \
    "" "$overlay_hits"

# ---- 6. the OTHER committed bind channel ----
# lib/host-mounts.sh turns projects/<name>/host-mounts.txt into a compose
# override that lands in services.app.volumes. Assertion 5's comment named the
# blind spot for compose.override.yml and left the identical one in the same
# directory: a committed `~/.claude/x:/home/vscode/.claude/x` here is a bind
# under the volume #115's `chown -R` is rooted at, and every assertion above
# reads compose files only. The files are empty today, which is precisely when
# a guard is cheap to add.
hm_files=("$DEV_BASE"/defaults/host-mounts.txt "$DEV_BASE"/projects/*/host-mounts.txt)
hm_all="$(host_mount_mounts "${hm_files[@]}")"
hm_hits="$(printf '%s\n' "$hm_all" | awk -F'\t' -v p="$CLAUDE_HOME" \
    '$2 == p || index($2, p "/") == 1')"
assert_eq "no committed host-mounts.txt declares a mount under ~/.claude" \
    "" "$(printf '%s' "$hm_hits" | sed '/^$/d')"

# Anti-vacuity for the parser itself: a guard over a channel it cannot read is
# green for the wrong reason. Most committed files are comment-only (one live
# line exists, projects/xorq-desktop's X11 socket, whose target is not under
# ~/.claude), so a synthetic line is what pins the parsing rules.
# shellcheck disable=SC2088  # the ~ is literal PARSER INPUT, not a path this
# shell should expand: host-mounts.txt lines carry it verbatim and
# lib/host-mounts.sh:25 is what expands it. The assertion pins that expansion.
hm_probe="$(printf '%s\n' "# a comment" "" \
    "~/.claude/evil:$CLAUDE_HOME/evil:ro" |
    host_mount_mounts /dev/stdin)"
assert_eq "the host-mounts parser reads a line, drops comments, expands ~" \
    "bind	$CLAUDE_HOME/evil	/host/home/.claude/evil	ro" "$hm_probe"

finish
