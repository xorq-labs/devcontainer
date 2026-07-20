#!/usr/bin/env bash
# Guard the built image's Env against the pinned MS base's.
#
# streamLayeredImage (nixpkgs >= 26.05) merges the fromImage config into the
# flake's `config` per-variable — except PATH, which flake.nix hand-maintains
# to prepend the infra profile while keeping the base's components. Two ways
# that silently rots: the hand-copied PATH drifts after a digest repin, or a
# nixpkgs bump changes the merge behavior and the base's vars vanish from the
# built image. This check fails loudly on either. It compares the pinned
# base's Config.Env against the built image's:
#
#   - PATH: every component of the base's PATH must survive somewhere in the
#     built PATH (the flake prepends the infra profile; prepends are fine,
#     dropped base dirs are not — losing them breaks python/pip/pipx).
#   - every other VAR=VAL must appear in the built Env verbatim. Additions in
#     the built image (HOME, SSL_CERT_FILE) are allowed; losses are not.
#
# Intended to run in the base-build CI job right after `docker load`, and by
# hand after re-deriving the Env list (see the comment above `Env` in
# flake.nix). Needs docker; pulls the pinned base on first run.
#
# Usage: check-env-drift.sh [built-image]
#        (default built-image: devcontainer-nix-base:latest)
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
built="${1:-devcontainer-nix-base:latest}"

digest="$(grep -oP 'msBaseDigest = "\K[^"]*' "$here/flake.nix")" || true
if [ -z "$digest" ]; then
    echo "error: could not read msBaseDigest from $here/flake.nix" >&2
    exit 1
fi
base_ref="mcr.microsoft.com/devcontainers/python@${digest}"

docker image inspect "$built" >/dev/null 2>&1 || {
    echo "error: built image '$built' is not loaded (nix build .#defaultBase && ./result | docker load)" >&2
    exit 1
}
# The digest is the manifest-list digest; docker resolves it to this host's
# arch — the same sub-manifest pullImage bakes for this arch's build.
docker image inspect "$base_ref" >/dev/null 2>&1 || docker pull -q "$base_ref" >/dev/null

BASE_ENV="$(docker image inspect --format '{{json .Config.Env}}' "$base_ref")" \
BUILT_ENV="$(docker image inspect --format '{{json .Config.Env}}' "$built")" \
python3 - <<'EOF'
import json
import os
import sys

base = json.loads(os.environ["BASE_ENV"])
built = json.loads(os.environ["BUILT_ENV"])

built_set = set(built)
built_path = next((v.split("=", 1)[1] for v in built if v.startswith("PATH=")), "")
built_path_parts = set(filter(None, built_path.split(":")))

missing = []
for entry in base:
    var, _, val = entry.partition("=")
    if var == "PATH":
        missing.extend(
            f"PATH component: {comp}" for comp in filter(None, val.split(":")) if comp not in built_path_parts
        )
    elif entry not in built_set:
        missing.append(entry)

if missing:
    print("env drift: the built image LOST Env the MS base sets:", file=sys.stderr)
    for m in missing:
        print(f"  - {m}", file=sys.stderr)
    print("update the Env list in nix/base/flake.nix (see its re-derive comment).", file=sys.stderr)
    sys.exit(1)

print(f"env drift check OK: all {len(base)} MS-base Env entries survive in the built image.")
EOF
