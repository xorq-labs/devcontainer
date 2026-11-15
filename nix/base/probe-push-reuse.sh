#!/usr/bin/env bash
# Reproduce, against a local registry, the blob reuse that failed the first
# publish after #166, and check that nix-base.yml's push step resists it.
#
# skopeo may reuse any variant of a layer the destination repo already
# holds unless the copy forces a compression format. The "Compress layers"
# step records each gzip blob's uncompressed digest in skopeo's blob-info
# cache; the Docker 29 publish had left those uncompressed blobs on ghcr; so
# the push swapped them in under a rewritten manifest, and the post-push
# digest compare failed (run 43724122066). CI cannot show this before a
# merge: the push step runs only on main. This is a local tool, not a suite:
# it needs docker, nix and the network for the first nix run.
#
# Usage: nix/base/probe-push-reuse.sh [workflow-file]
#   default .github/workflows/nix-base.yml; pass another revision's copy
#   (git show origin/main:.github/workflows/nix-base.yml > f) to probe it.
# Env: PROBE_PORT (5055), PROBE_IMAGE (registry:2, saved as the test image).
#
# Both steps run from the workflow's own text, extracted with the yq pinned
# by the base flake: the compress step with its `./result` line replaced by
# the test tarball, the push step as written. Each repo is first seeded the
# way Docker 29 left ghcr (uncompressed blobs, a rootfs.diff.tar manifest),
# and each case gets its own HOME and XDG_DATA_HOME, so no cache is shared.
#
#   fixed        cache from the compress step, push step as written   -> ok
#   unforced     same, --dest-force-compress-format removed           -> error
#   empty-cache  unforced push step, no cache                         -> ok
#
# unforced is the negative control: if it passes, the probe no longer
# reproduces the reuse and its "fixed" verdict means nothing. empty-cache
# shows the compress step's cache is the trigger. Exits 0 only when every
# case matches its expectation. A workflow whose push step lacks the flag
# fails "fixed" and skips "unforced" (nothing to remove).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$(realpath "${1:-$repo_root/.github/workflows/nix-base.yml}")"
port="${PROBE_PORT:-5055}"
image="${PROBE_IMAGE:-registry:2}"
registry="127.0.0.1:$port"
work="$(mktemp -d "${TMPDIR:-/tmp}/probe-push-reuse.XXXXXX")"
container="probe-push-reuse-$$"
force_flag=" --dest-force-compress-format"

cleanup() { docker stop "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

cd "$repo_root"
nixpkgs() { nix run --inputs-from ./nix/base "nixpkgs#$1" -- "${@:2}"; }

step_text() {
  local text
  text="$(nixpkgs yq-go ".jobs.build.steps[] | select(.name == \"$1\") | .run" "$workflow")"
  if [ -z "$text" ] || [ "$text" = null ]; then
    echo "error: no step named '$1' in $workflow" >&2
    exit 2
  fi
  printf '%s\n' "$text"
}

compress="$(step_text "Compress layers for the registry")"
push="$(step_text "Push per-arch image")"
result_line='./result > "$RUNNER_TEMP/base.tar"'
if [ "$(grep -cxF "$result_line" <<<"$compress")" != 1 ]; then
  echo "error: compress step no longer has exactly one line: $result_line" >&2
  exit 2
fi
if [ "$(grep -c 'skopeo copy' <<<"$push")" != 1 ]; then
  echo "error: push step does not have exactly one 'skopeo copy'" >&2
  exit 2
fi
compress="${compress/"$result_line"/cp \"\$PROBE_TAR\" \"\$RUNNER_TEMP/base.tar\"}"
push="${push//'${{ matrix.arch }}'/amd64}"

docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null
docker save "$image" >"$work/img.tar"
docker run -d --rm --name "$container" -p "$registry:5000" registry:2 >/dev/null
for _ in $(seq 40); do curl -fsS "http://$registry/v2/" >/dev/null 2>&1 && break; sleep 0.25; done

# A HOME whose registries.conf marks the local registry insecure (nix's
# skopeo ignores CONTAINERS_REGISTRIES_CONF) and whose XDG_DATA_HOME holds
# the blob-info cache (with XDG_DATA_HOME set, HOME alone does not move it).
new_home() {
  mkdir -p "$1/.config/containers" "$1/share"
  printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$registry" \
    >"$1/.config/containers/registries.conf"
}
in_home() { local h=$1; shift; HOME="$h" XDG_DATA_HOME="$h/share" "$@"; }

# The seed: --dest-decompress writes plain tar blobs but keeps the gzip
# media type, so the manifest is rewritten to say what the blobs are.
new_home "$work/home-seed"
in_home "$work/home-seed" nixpkgs skopeo --insecure-policy copy --format v2s2 \
  --dest-decompress "docker-archive:$work/img.tar" "dir:$work/seed" >/dev/null
jq '.layers |= map(.mediaType = "application/vnd.docker.image.rootfs.diff.tar")' \
  "$work/seed/manifest.json" >"$work/seed-manifest.json"

seed() {
  local repo=$1 d loc sep
  for d in $(jq -r '.config.digest, .layers[].digest' "$work/seed-manifest.json"); do
    loc="$(curl -fsS -D - -o /dev/null -X POST "http://$registry/v2/$repo/blobs/uploads/" |
      tr -d '\r' | awk -F': ' 'tolower($1) == "location" { print $2 }')"
    case "$loc" in http*) ;; *) loc="http://$registry$loc" ;; esac
    case "$loc" in *\?*) sep='&' ;; *) sep='?' ;; esac
    curl -fsS -X PUT -H 'Content-Type: application/octet-stream' \
      --data-binary @"$work/seed/${d#sha256:}" "$loc${sep}digest=$d" -o /dev/null
  done
  curl -fsS -X PUT -H 'Content-Type: application/vnd.docker.distribution.manifest.v2+json' \
    --data-binary @"$work/seed-manifest.json" "http://$registry/v2/$repo/manifests/seed" -o /dev/null
}

# The compress step, run once; its cache is copied into each case that uses it.
new_home "$work/home-ci"
mkdir -p "$work/rt"
in_home "$work/home-ci" env PROBE_TAR="$work/img.tar" RUNNER_TEMP="$work/rt" \
  bash -eo pipefail -c "$compress" >"$work/compress.log" 2>&1 || {
  cat "$work/compress.log" >&2
  echo "error: the compress step failed" >&2
  exit 2
}

failures=0
run_case() {
  local name=$1 cache=$2 text=$3 expect=$4 home="$work/home-$1" rc layers verdict
  if [ "$cache" = ci ]; then cp -a "$work/home-ci" "$home"; else new_home "$home"; fi
  seed "$name"
  set +e
  in_home "$home" env IMAGE="$registry/$name" GITHUB_SHA=0000000probe RUNNER_TEMP="$work/rt" \
    bash -eo pipefail -c "$text" >"$work/$name.log" 2>&1
  rc=$?
  set -e
  layers="$(curl -fsS -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://$registry/v2/$name/manifests/sha-0000000-amd64" 2>/dev/null |
    jq -r '[.layers[].mediaType | sub(".*rootfs.diff."; "")] | unique | join(",")' 2>/dev/null)"
  if { [ "$expect" = ok ] && [ "$rc" = 0 ]; } || { [ "$expect" = error ] && [ "$rc" = 1 ]; }; then
    verdict=as-expected
  else
    verdict=UNEXPECTED
    failures=$((failures + 1))
  fi
  printf '%-12s cache=%-5s expect=%-5s rc=%s layers=%-8s %s\n' \
    "$name" "$cache" "$expect" "$rc" "${layers:-none}" "$verdict"
  grep -E '^(ok|error):' "$work/$name.log" | sed 's/^/             /' || tail -3 "$work/$name.log" | sed 's/^/             /'
}

run_case fixed ci "$push" ok
if grep -qF -- "$force_flag" <<<"$push"; then
  unforced="${push//"$force_flag"/}"
  run_case unforced ci "$unforced" error
  run_case empty-cache none "$unforced" ok
else
  echo "unforced     skipped: the push step has no${force_flag}"
  run_case empty-cache none "$push" ok
fi

[ "$failures" = 0 ] || { echo "$failures case(s) did not match their expectation" >&2; exit 1; }
echo "all cases matched their expectations"
