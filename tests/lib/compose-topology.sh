#!/usr/bin/env bash
# Read the MERGED COMPOSE MOUNT GRAPH without docker.
#
# Why this exists: production code reads the graph (mount_point_targets in
# dev/devcontainer shells out to `dc config`), but the hermetic suite could only
# read docker-compose.yml as TEXT — two suites grep it for literals. So mount
# EXISTENCE was assertable and NESTING and ABSENCE were not assertable at all,
# and several load-bearing facts about the graph lived only as prose:
#
#   - "a recursive chown under ~/.claude must not cross into a bind" — stated,
#     lost and re-derived across #48 -> #58 -> #61 -> #113 -> #115
#   - ADR-0001's "the container is NOT bind-mounted to the host credential
#     file" — restated in four files, enforced in none (#116)
#
# Both were green under mutation. The decisive property of reading the graph
# here is that a guard built on it fails FROM THE SIDE THAT CHANGES: the PR that
# edits docker-compose.yml is where the fix is cheap, and it is the one place
# every previous mechanism (invariant ledger, ADR-0005, the drift-guard
# convention, comment sweeps, review) could not reach.
#
# `dc config` is deliberately NOT used: it needs a daemon, and tests/run-all is
# hermetic. Compose interpolation is instead stubbed — see compose_mounts.

# compose_mounts <file>... — emit one `<kind>\t<target>\t<source>` line per
# mount of service `app`, across the given compose files in override order.
#
# Handles both mount syntaxes, because docker-compose.yml uses both: the short
# `source:target[:opts]` form and the long `{type, source, target}` form. A
# short-form entry with no `/` in its source is a NAMED VOLUME (`claude-home:...`)
# — that is the same rule Compose itself applies, and getting it wrong would
# silently reclassify the very mounts these guards are about.
#
# Also emits the service-level `tmpfs:` key as kind `tmpfs`. Those are real
# mounts in the graph (one lands under the claude-home volume), and a topology
# guard that ignored them would inherit exactly the partial view that
# mount_point_targets has.
compose_mounts() {
    python3 -c '
import re, sys, yaml

# Compose interpolation, stubbed. Every ${VAR}, ${VAR:-d}, ${VAR:?msg} becomes a
# stable placeholder path so nesting comparisons are meaningful. Values that
# stand for HOST paths get /host/... and container-side ones their real value,
# because the guards care which side of a bind a path is on.
STUBS = {
    "HOME": "/host/home",
    "DEV_WORKSPACE": "/host/ws",
    "DEV_MAIN_TREE": "/host/tree",
    "DEV_MAIN_GIT": "/host/tree/.git",
    "DEV_SOPS_AGE_DIR": "/host/age",
    "DEV_CLAUDE_LOGS": "/host/home/.claude/projects/-devcontainer-x",
    "DEV_CONTAINER_WORKSPACE": "/workspaces/src",
    "DEV_CONTAINER_PROJECT_KEY": "-workspaces-src",
}
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::[-?][^}]*)?\}")

def interp(s):
    return VAR.sub(lambda m: STUBS.get(m.group(1), "/stub/" + m.group(1).lower()), s)

def emit(kind, target, source):
    if target:
        print("%s\t%s\t%s" % (kind, interp(target), interp(source or "")))

for path in sys.argv[1:]:
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    app = (doc.get("services") or {}).get("app") or {}

    for v in app.get("volumes") or []:
        if isinstance(v, dict):
            emit(v.get("type") or "volume", v.get("target"), v.get("source"))
            continue
        # Short syntax: source:target[:opts]. Interpolate BEFORE splitting —
        # `${DEV_WORKSPACE:?required}` contains a colon, so splitting first
        # tears the entry apart and silently misclassifies every required mount.
        parts = interp(v).split(":")
        if len(parts) < 2:
            continue
        source, target = parts[0], parts[1]
        # No slash in the source => named volume, per Compose own rule.
        emit("volume" if "/" not in source else "bind", target, source)

    for t in app.get("tmpfs") or []:
        emit("tmpfs", t.split(":")[0], "")
' "$@"
}

# compose_targets_under <prefix> <file>... — emit `<kind>\t<target>` for every
# mount whose target is AT or UNDER <prefix>, sorted. The unit the coverage
# assertion compares against a declared allowlist.
compose_targets_under() {
    local prefix="$1"
    shift
    compose_mounts "$@" | awk -F'\t' -v p="$prefix" \
        '$2 == p || index($2, p "/") == 1 { print $1 "\t" $2 }' | sort
}
