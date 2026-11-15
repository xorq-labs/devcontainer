#!/usr/bin/env bash
# Guard: nix/base/check-layer-compression.sh fails closed.
#
# nix-base.yml#build runs the script on every real manifest, but after the
# skopeo fix those are all-gzip, so CI only ever sees its pass arm. A refusal
# deleted or widened by an ordinary edit (a plain-tar type added to
# gzip_types "to tolerate" it) would stay green there until the next
# uncompressed push — the one thing the script exists to catch. The script is
# a pure function of a manifest document, so this suite feeds the REAL script
# crafted manifests and pins each refusal on its own message, not just its
# exit code: several malformed inputs also exit 1 by Python traceback, which
# would hide a deleted clause.
#
# Verified (ADR-0005 §2), mutation runs 2026-11-14:
#   form-only: the script's gzip_types set rewritten as a tuple, its two
#     entries swapped — green, 13/13 assertions.
#   semantic, in a form not written here: `if bad:` commented out and its
#     sys.exit put under `if False:` — red, 5 failed, starting "a mixed
#     manifest exits non-zero" (the script printed "ok: all 2 layers").
#   Each clause alone removed: the per-arch refusal (red, 1 failed: "a
#   manifest list is refused as not per-arch" — it exits 1 by KeyError, which
#   is why the cases assert messages), the empty-layers refusal (red, 2
#   failed, exit 0), application/vnd.docker.image.rootfs.diff.tar added to
#   gzip_types (red, 4 failed: the mixed and plain-tar cases). Always-refuse
#   twins: `if bad:` as `if True:`, and the pass line replaced by a refusal
#   (each red, 3 failed: the good-manifest cases).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CHECK="$REPO/nix/base/check-layer-compression.sh"

work="$(mktemp -d)"
_cleanup_dirs+=("$work")

DOCKER_GZ=application/vnd.docker.image.rootfs.diff.tar.gzip
DOCKER_TAR=application/vnd.docker.image.rootfs.diff.tar
OCI_GZ=application/vnd.oci.image.layer.v1.tar+gzip
OCI_ZSTD=application/vnd.oci.image.layer.v1.tar+zstd

# manifest <mediaType>... — a per-arch v2s2 manifest with one layer per type.
manifest() {
    local layers="" t i=0
    for t in "$@"; do
        i=$((i + 1))
        layers+="${layers:+,}{\"mediaType\":\"$t\",\"size\":$i,\"digest\":\"sha256:$(printf '%064d' "$i")\"}"
    done
    printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","layers":[%s]}' "$layers"
}

# run <file|-> [stdin] — sets rc and out (stdout+stderr) from the real script.
run() {
    rc=0
    out="$(printf '%s' "${2:-}" | "$CHECK" "$1" 2>&1)" || rc=$?
}

manifest "$DOCKER_GZ" "$DOCKER_GZ" > "$work/good.json"
run "$work/good.json"
assert_eq "an all-gzip docker manifest passes" "0" "$rc"
assert_contains "the pass names its layer count" "ok: all 2 layers" "$out"

run - "$(manifest "$OCI_GZ")"
assert_eq "an all-gzip OCI manifest passes via stdin" "0" "$rc"

manifest "$DOCKER_GZ" "$DOCKER_TAR" > "$work/mixed.json"
run "$work/mixed.json"
assert_eq "a mixed manifest exits non-zero" "1" "$rc"
assert_contains "a mixed manifest is refused with a count" "1 of 2 layers are not gzip-compressed" "$out"
assert_contains "the refusal names the offending layer" "not gzip: sha256:$(printf '%064d' 2) $DOCKER_TAR" "$out"

run - "$(manifest "$DOCKER_TAR")"
assert_contains "a plain-tar layer is refused" "1 of 1 layers are not gzip-compressed" "$out"

run - "$(manifest "$OCI_ZSTD")"
assert_contains "a zstd layer is refused" "1 of 1 layers are not gzip-compressed" "$out"

run - "$(manifest "${DOCKER_GZ^^}")"
assert_contains "mediaType matching is exact, not case-folded" "1 of 1 layers are not gzip-compressed" "$out"

run - '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json","manifests":[]}'
assert_contains "a manifest list is refused as not per-arch" "not a per-arch image manifest" "$out"

run - "$(manifest)"
assert_eq "an empty layer list exits non-zero" "1" "$rc"
assert_contains "an empty layer list is refused" "lists no layers" "$out"

run "$work/absent.json"
assert_eq "a missing file exits non-zero" "1" "$rc"

finish
