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
#
# Dependency note: this is the first suite to need pyyaml, which is NOT stdlib
# (tests/lib/workflow-paths.sh avoided it for that reason). The failure mode is
# loud and fail-closed — ModuleNotFoundError aborts the suite rather than
# quietly asserting nothing — and CI has it.

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
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:[-?][^}]*)?\}")

def _expand(m):
    name, mod = m.group(1), m.group(2) or ""
    if name in STUBS:
        return STUBS[name]
    # `${VAR:-default}` with VAR unset expands to DEFAULT, which is what compose
    # does — substituting a stub instead moves the path somewhere it never goes.
    # That is not academic: `/home/vscode/.clau${X:-de}/two` really mounts under
    # ~/.claude, and a stub expansion put it under /home/vscode/.clau/stub/x/,
    # matching no prefix and evading the guard.
    if mod.startswith(":-"):
        return mod[2:]
    return "/stub/" + name.lower()

def interp(s):
    return VAR.sub(_expand, s)

def emit(kind, target, source, opts=""):
    # Options are a FOURTH column, not discarded: ADR-0001 records the
    # read-only-ness of the .claude-host mount as part of its decision, so a
    # reader that drops `:ro` cannot enforce half the ADR it exists to enforce.
    if target:
        print("%s\t%s\t%s\t%s" % (kind, interp(target), interp(source or ""), opts))

for path in sys.argv[1:]:
    # Name the file on a parse failure. Under `set -euo pipefail` a raised
    # exception aborts the whole suite, and a bare traceback leaves the reader
    # guessing which of eleven compose files is malformed. Third instance of
    # "a failure here aborts with no diagnostic" in this file (the others:
    # the docker render, and `git ls-files`).
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh) or {}
    except yaml.YAMLError as exc:
        sys.exit("compose-topology: cannot parse %s: %s" % (path, exc))
    app = (doc.get("services") or {}).get("app") or {}

    for v in app.get("volumes") or []:
        if isinstance(v, dict):
            emit(v.get("type") or "volume", v.get("target"), v.get("source"),
                 "ro" if v.get("read_only") else "")
            continue
        # Short syntax: source:target[:opts]. Interpolate BEFORE splitting —
        # `${DEV_WORKSPACE:?required}` contains a colon, so splitting first
        # tears the entry apart and silently misclassifies every required mount.
        parts = interp(v).split(":")
        if len(parts) < 2:
            continue
        source, target = parts[0], parts[1]
        # No slash in the source => named volume, per Compose own rule.
        emit("volume" if "/" not in source else "bind", target, source,
             ",".join(parts[2:]))

    for t in app.get("tmpfs") or []:
        # interp BEFORE split, same reason as the short-form volumes above.
        emit("tmpfs", interp(t).split(":")[0], "")
' "$@"
}

# host_mount_mounts <host-mounts.txt>... — emit the same `<kind>\t<target>\t
# <source>\t<opts>` shape for the OTHER committed bind channel.
#
# `lib/host-mounts.sh` reads these list files and generates a compose override
# that lands in services.app.volumes, in the same `host:container[:opts]` short
# form — so a mount declared here is every bit as real as one in
# docker-compose.yml, and was invisible to a reader that only parsed compose
# files. A committed `~/.claude/x:/home/vscode/.claude/x` line is exactly the
# #115 hazard class, and the whole suite stayed green with one present.
#
# Comment/blank handling mirrors read_list() in lib/list-file.sh: strip from
# `#`, trim, drop empties. `host-mounts.local.txt` is deliberately NOT read —
# it is gitignored per-developer state, not a repo fact.
host_mount_mounts() {
    python3 -c '
import re, sys

# Same interpolation stub as compose_mounts, for the same reason: the generated
# override is handed to compose with -f, so compose expands ${...} in it. A
# line like `~/.claude/x:/home/vscode/.clau${X:-de}/x` really mounts under
# ~/.claude, but splitting on ":" FIRST tears it at the colon inside ${X:-de}
# and yields a target of `/home/vscode/.clau${X`, which matches no prefix and
# sails past every assertion. compose_mounts documents this hazard and this
# parser reintroduced it — caught in review.
STUBS = {"HOME": "/host/home"}
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:[-?][^}]*)?\}")

def _expand(m):
    name, mod = m.group(1), m.group(2) or ""
    if name in STUBS:
        return STUBS[name]
    if mod.startswith(":-"):   # compose expands an unset ${VAR:-d} to d
        return mod[2:]
    return "/stub/" + name.lower()

def interp(s):
    return VAR.sub(_expand, s)

for path in sys.argv[1:]:
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:
        continue
    for line in lines:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = interp(line).split(":")
        # A colon-free line is forwarded verbatim by
        # generate_host_mounts_override, and compose reads `- /path` as an
        # ANONYMOUS VOLUME mounted at that container path — so it is a mount
        # under that target, not a line to skip.
        if len(parts) == 1:
            print("volume\t%s\t\t" % parts[0])
            continue
        source = parts[0]
        # lib/host-mounts.sh:25 expands a leading ~ to $HOME. Mirrored with the
        # same /host/home stub the compose reader uses, so the source column
        # means the same thing in both. Only the TARGET column is asserted on
        # today, but a reader that models the format wrongly is a trap for the
        # next assertion someone adds.
        if source.startswith("~"):
            source = "/host/home" + source[1:]
        print("bind\t%s\t%s\t%s" % (parts[1], source, ",".join(parts[2:])))
' "$@"
}

# committed_compose_files — every compose file tracked in the repo, one per
# line, absolute.
#
# DERIVED, not listed. A hand-maintained list of "the compose files to check"
# has leaked a channel three times running: the first revision of this guard
# read docker-compose.yml only; review found projects/*/host-mounts.txt; the
# next review found defaults/compose.override.yml (a real overlay —
# DEV_PROJECT_DIR falls back to defaults/) and nix/base/compose.nix-base.yml
# (appended by dc() on the nix route). Each time the fix was to extend the
# list, and each time the list leaked again.
#
# So there is no list. `git ls-files` decides, which means a compose file added
# anywhere in the repo is scanned the day it lands, with nobody having to
# remember. This is deliberately WIDER than the set dc() assembles for any one
# run — templates/nix/ is a scaffold, never mounted — because over-scanning
# costs an assertion and under-scanning costs the guard.
committed_compose_files() {
    git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" ls-files |
        grep -E '(^|/)(docker-)?compose[^/]*\.ya?ml$' |
        sed "s|^|$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/|"
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
