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

# One interpolation model, shared by both readers below. It was duplicated once
# and immediately diverged: mutation 8's fix (interpolate BEFORE splitting) had
# to be applied twice, and the NEXT divergence — `${VAR-def}` and unbraced
# `$VAR` — was found in review one spelling over from the fix. Two hand-synced
# copies of a model of someone else's parser is the restatement shape this whole
# file exists to remove, so there is exactly one.
#
# Modelled on compose's own substitution for an UNSET variable:
#   ${VAR}, $VAR      -> stub path (compose: empty; a stub keeps paths distinct)
#   ${VAR:-d}, ${VAR-d} -> d          ${VAR:?m}, ${VAR?m} -> stub path
# Verified against real `docker compose config`; the cross-check in the test
# suite is what keeps this honest as compose changes.
_ct_interp_py='
import re
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)((?::?[-?])[^}]*)?\}|\$([A-Za-z_][A-Za-z0-9_]*)")

def _expand(m, stubs):
    name = m.group(1) or m.group(3)
    mod = m.group(2) or ""
    if name in stubs:
        return stubs[name]
    # `-` (with or without the colon) supplies a DEFAULT for an unset var.
    # `?` does not — it errors, so the value stays unset.
    if mod.startswith(":-"):
        return mod[2:]
    if mod.startswith("-"):
        return mod[1:]
    return "/stub/" + name.lower()

def interp(s, stubs):
    return VAR.sub(lambda m: _expand(m, stubs), s)
'

# compose_mounts <file>... — emit one `<kind>\t<target>\t<source>\t<opts>` line
# per mount, across the given compose files in override order.
#
# EVERY service, not just `app`: `dc up -d` starts the whole merged config, so a
# sidecar service bind-mounting the host credential store is exactly as real as
# one on `app`. Reading `services.app` alone let that pass — found in review.
#
# Handles both mount syntaxes, because docker-compose.yml uses both: the short
# `source:target[:opts]` form and the long `{type, source, target}` form. A
# short-form entry with no `/` in its source is a NAMED VOLUME (`claude-home:...`)
# — that is the same rule Compose itself applies, and getting it wrong would
# silently reclassify the very mounts these guards are about.
#
# Also emits service-level `tmpfs:` as kind `tmpfs`, and TOP-LEVEL named volumes
# declared with `driver_opts: {type: none, o: bind, device: ...}` — a real
# compose construct that is a bind wearing volume clothing, and another way the
# host store can be mounted without the word "bind" appearing anywhere.
compose_mounts() {
    python3 -c "$_ct_interp_py"'
import sys, yaml

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

def emit(kind, target, source, opts=""):
    # Options are a FOURTH column, not discarded: ADR-0001 records the
    # read-only-ness of the .claude-host mount as part of its decision, so a
    # reader that drops `:ro` cannot enforce half the ADR it exists to enforce.
    if target:
        print("%s\t%s\t%s\t%s" % (kind, interp(target, STUBS),
                                   interp(source or "", STUBS), opts))

for path in sys.argv[1:]:
    # Name the file on a parse failure. Under `set -euo pipefail` a raised
    # exception aborts the whole suite, and a bare traceback leaves the reader
    # guessing which of eleven compose files is malformed.
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh) or {}
    except yaml.YAMLError as exc:
        sys.exit("compose-topology: cannot parse %s: %s" % (path, exc))

    for svc in (doc.get("services") or {}).values():
        if not isinstance(svc, dict):
            continue
        for v in svc.get("volumes") or []:
            if isinstance(v, dict):
                emit(v.get("type") or "volume", v.get("target"), v.get("source"),
                     "ro" if v.get("read_only") else "")
                continue
            # Short syntax: source:target[:opts]. Interpolate BEFORE splitting —
            # `${DEV_WORKSPACE:?required}` contains a colon, so splitting first
            # tears the entry apart and silently misclassifies every required
            # mount.
            parts = interp(v, STUBS).split(":")
            if len(parts) < 2:
                continue
            source, target = parts[0], parts[1]
            # No slash in the source => named volume, per Compose own rule.
            emit("volume" if "/" not in source else "bind", target, source,
                 ",".join(parts[2:]))

        for t in svc.get("tmpfs") or []:
            emit("tmpfs", interp(t, STUBS).split(":")[0], "")

    # Top-level volumes: a local-driver volume with o=bind is a bind mount by
    # another name, and its device is a HOST path.
    for name, vol in (doc.get("volumes") or {}).items():
        if not isinstance(vol, dict):
            continue
        opts = vol.get("driver_opts") or {}
        dev = opts.get("device")
        if dev and "bind" in str(opts.get("o", "")):
            print("volume-bind\t%s\t%s\t%s" % (name, interp(str(dev), STUBS), ""))
' "$@"
}

# host_mount_mounts <host-mounts.txt>... — emit the same
# `<kind>\t<target>\t<source>\t<opts>` shape for the OTHER committed bind
# channel.
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
    python3 -c "$_ct_interp_py"'
import sys

STUBS = {"HOME": "/host/home"}

for path in sys.argv[1:]:
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:
        continue
    for line in lines:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        # interp BEFORE splitting: the generated override is handed to compose
        # with -f, so compose expands ${...} in it, and a colon inside a
        # ${X:-de} default otherwise tears the entry at the wrong place.
        parts = interp(line, STUBS).split(":")
        # A colon-free line is forwarded verbatim by
        # generate_host_mounts_override, and compose reads `- /path` as an
        # ANONYMOUS VOLUME mounted at that container path — so it is a mount
        # under that target, not a line to skip.
        if len(parts) == 1:
            print("volume\t%s\t\t" % parts[0])
            continue
        source = parts[0]
        # lib/host-mounts.sh:25 expands a leading ~ to $HOME.
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
