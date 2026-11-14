#!/usr/bin/env bash
# Guard that every layer of a per-arch image manifest is gzip-compressed.
#
# The base is published with `skopeo copy --dest-compress-format gzip`, not
# `docker push`, because what `docker push` uploads depends on the runner's
# Docker. Docker 28 gzipped the layers `docker load` had stored uncompressed;
# Docker 29, whose default is the containerd image store, pushes them as
# stored. The move to ubuntu-26.04 (#163) therefore republished an unchanged
# base with 42 uncompressed layers (~2.1 GB per arch instead of ~760 MB) under
# a new digest, and the pin job proposed it as a bump. Nothing failed: the
# image config, and so the content, was byte-identical.
#
# Runs twice per CI leg: on the local copy's manifest before any push (so a
# PR exercises it), and on the registry's manifest after the push.
#
# Usage: check-layer-compression.sh <manifest.json | ->
set -euo pipefail

src="${1:?usage: check-layer-compression.sh <manifest.json | ->}"
if [ "$src" = - ]; then
    manifest="$(cat)"
else
    manifest="$(cat "$src")"
fi

MANIFEST="$manifest" python3 - <<'EOF'
import json
import os
import sys

manifest = json.loads(os.environ["MANIFEST"])
if "layers" not in manifest:
    # A manifest list has no layers of its own; passing it would check nothing.
    sys.exit(f"error: not a per-arch image manifest (mediaType {manifest.get('mediaType')!r})")
layers = manifest["layers"]
if not layers:
    sys.exit("error: manifest lists no layers, so nothing was checked")

gzip_types = {
    "application/vnd.docker.image.rootfs.diff.tar.gzip",
    "application/vnd.oci.image.layer.v1.tar+gzip",
}
bad = [layer for layer in layers if layer["mediaType"] not in gzip_types]
for layer in bad:
    print(f"not gzip: {layer['digest']} {layer['mediaType']} ({layer['size']} bytes)", file=sys.stderr)
if bad:
    sys.exit(f"error: {len(bad)} of {len(layers)} layers are not gzip-compressed")
print(f"ok: all {len(layers)} layers gzip-compressed")
EOF
