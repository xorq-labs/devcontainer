#!/usr/bin/env bash
# Tests for devcontainer bump-nix-base — digest resolution, the manifest-list
# gate, the BASE_IMAGE rewrite in nix/base/compose.nix-base.yml, and argument
# handling.
#
# The gap this tool exists to close (#83): CI publishes the Nix base, but
# consumers build on the digest pinned in compose.nix-base.yml, and nothing
# owned moving that pin — so the pin sat on the #41 digest while fixes shipped
# to the registry and reached nobody.
#
# Two properties matter more than the rest and both are asserted here:
#
#   1. The rewritten line stays byte-anchored. ensure_nix_base() greps this
#      line at runtime to decide what to pull, and tests/test-nix-base-pin.sh
#      asserts the anchor still matches; a tool that reformatted it would break
#      the pull path with no build-time signal.
#   2. A per-arch digest is refused. `imagetools inspect` prints per-arch
#      digests directly beneath the manifest-list digest, so pinning
#      sha-<short>-amd64 by hand is an easy slip that looks perfectly correct
#      on an amd64 laptop and breaks every arm64 consumer at pull time.
#
# The script targets compose.nix-base.yml relative to its own path, so we run a
# copy from a disposable sandbox and stub `curl` on PATH — no real file is
# touched and no network is required. The stub serves ghcr's three endpoints:
# the anonymous token, a HEAD manifest request (tag -> digest), and a GET
# manifest request (digest -> media type + platforms).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SRC="$DEV_BASE/dev/bump-nix-base"

IMAGE="ghcr.io/xorq-labs/devcontainer-nix-base"
OLD="sha256:$(printf 'b%.0s' {1..64})"   # what the fixture starts pinned to
NEW="sha256:$(printf 'a%.0s' {1..64})"   # the published multi-arch manifest
ARCH="sha256:$(printf 'c%.0s' {1..64})"  # a per-arch image manifest

# ---------- setup: disposable sandbox ----------
SANDBOX="$(mktemp -d)"
_cleanup_dirs+=("$SANDBOX")
mkdir -p "$SANDBOX/dev" "$SANDBOX/nix/base" \
    "$SANDBOX/bin" "$SANDBOX/bin-badnet" "$SANDBOX/bin-notoken" "$SANDBOX/bin-singlearch" \
    "$SANDBOX/bin-onearch" "$SANDBOX/bin-nomanifest" "$SANDBOX/bin-badmedia"
cp "$SRC" "$SANDBOX/dev/bump-nix-base"
BUMP="$SANDBOX/dev/bump-nix-base"
COMPOSE="$SANDBOX/nix/base/compose.nix-base.yml"

# The fixture reproduces the real file's line shape, including the `>-` folded
# scalar and the indentation — the rewrite has to survive all of it.
write_compose() {
    local digest="$1"
    cat > "$COMPOSE" <<EOF
services:
  app:
    build:
      dockerfile: nix/base/Dockerfile.nix-default
      args:
        BASE_IMAGE: >-
          \${DEV_NIX_BASE_IMAGE:-${IMAGE}@${digest}}
EOF
}

# The good stub. Tag "latest" and any sha-<short> tag resolve to the multi-arch
# manifest; the index carries an unknown/unknown attestation entry, which the
# tool must ignore when counting real platforms.
cat > "$SANDBOX/bin/curl" <<EOF
#!/usr/bin/env bash
url=""
head=false
for a in "\$@"; do
    case "\$a" in
        https://*) url="\$a" ;;
        -*I*) head=true ;;
    esac
done
case "\$url" in
    *"/token?"*)
        echo '{"token":"stub-token"}'; exit 0 ;;
esac
ref="\${url##*/manifests/}"
if \$head; then
    case "\$ref" in
        latest|sha-51d9c59) echo "docker-content-digest: ${NEW}"; exit 0 ;;
        *) exit 22 ;;
    esac
fi
case "\$ref" in
    ${NEW})
        cat <<'JSON'
{"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json",
 "manifests":[
   {"digest":"sha256:1","platform":{"os":"linux","architecture":"amd64"}},
   {"digest":"sha256:2","platform":{"os":"linux","architecture":"arm64"}},
   {"digest":"sha256:3","platform":{"os":"unknown","architecture":"unknown"}}]}
JSON
        exit 0 ;;
    ${ARCH}|${OLD})
        echo '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{}}'
        exit 0 ;;
esac
exit 22
EOF

# Registry unreachable: every request fails, including the token.
printf '#!/usr/bin/env bash\nexit 22\n' > "$SANDBOX/bin-badnet/curl"

# Token endpoint reachable but returns junk — no usable credential.
printf '#!/usr/bin/env bash\necho "not json"\nexit 0\n' > "$SANDBOX/bin-notoken/curl"

# "latest" resolves to a per-arch image manifest rather than an index. This is
# the shape a mis-tagged publish would have, and the bump must refuse it.
cat > "$SANDBOX/bin-singlearch/curl" <<EOF
#!/usr/bin/env bash
url=""
head=false
for a in "\$@"; do
    case "\$a" in
        https://*) url="\$a" ;;
        -*I*) head=true ;;
    esac
done
case "\$url" in
    *"/token?"*) echo '{"token":"stub-token"}'; exit 0 ;;
esac
if \$head; then echo "docker-content-digest: ${ARCH}"; exit 0; fi
echo '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{}}'
EOF

# An index that IS a manifest list but names only one real platform — the shape
# a publish leaves behind when one arch's leg failed to attach, or when
# `imagetools create` is handed a single source. This is the headline scenario
# the tool exists to catch, and it is the one the media-type check alone does
# NOT catch: without a platform count, `is_multi_arch` would wave it through.
cat > "$SANDBOX/bin-onearch/curl" <<EOF
#!/usr/bin/env bash
url=""
head=false
for a in "\$@"; do
    case "\$a" in
        https://*) url="\$a" ;;
        -*I*) head=true ;;
    esac
done
case "\$url" in
    *"/token?"*) echo '{"token":"stub-token"}'; exit 0 ;;
esac
if \$head; then echo "docker-content-digest: ${NEW}"; exit 0; fi
cat <<'JSON'
{"mediaType":"application/vnd.oci.image.index.v1+json",
 "manifests":[
   {"digest":"sha256:1","platform":{"os":"linux","architecture":"amd64"}},
   {"digest":"sha256:3","platform":{"os":"unknown","architecture":"unknown"}}]}
JSON
EOF

# A non-list media type that nonetheless carries two real platforms. No registry
# produces this — a per-arch manifest has no `manifests` array at all, which is
# why the platform count alone already refuses every realistic per-arch image.
# That redundancy is the point: without this fixture the media-type arm is dead
# code by test, and deleting it leaves the suite green. Keep it honest instead.
cat > "$SANDBOX/bin-badmedia/curl" <<EOF
#!/usr/bin/env bash
url=""
head=false
for a in "\$@"; do
    case "\$a" in
        https://*) url="\$a" ;;
        -*I*) head=true ;;
    esac
done
case "\$url" in
    *"/token?"*) echo '{"token":"stub-token"}'; exit 0 ;;
esac
if \$head; then echo "docker-content-digest: ${NEW}"; exit 0; fi
cat <<'JSON'
{"mediaType":"application/vnd.docker.distribution.manifest.v2+json",
 "manifests":[
   {"digest":"sha256:1","platform":{"os":"linux","architecture":"amd64"}},
   {"digest":"sha256:2","platform":{"os":"linux","architecture":"arm64"}}]}
JSON
EOF

# Token endpoint works, every manifest request fails: a transient 5xx, a package
# flipped private, a deleted digest. Distinct from bin-badnet, which dies at the
# token and so never reaches the fetch-failure branches at all.
cat > "$SANDBOX/bin-nomanifest/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        *"/token?"*) echo '{"token":"stub-token"}'; exit 0 ;;
    esac
done
exit 22
EOF

chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin-badnet/curl" \
    "$SANDBOX/bin-notoken/curl" "$SANDBOX/bin-singlearch/curl" \
    "$SANDBOX/bin-onearch/curl" "$SANDBOX/bin-nomanifest/curl" \
    "$SANDBOX/bin-badmedia/curl"

# Run the script with a given curl stub on PATH, capturing output and exit code.
OUT=""
RC=0
run_with() {
    local stub="$1"
    shift
    set +e
    OUT="$(PATH="$SANDBOX/$stub:$PATH" "$BUMP" "$@" 2>&1)"
    RC=$?
    set -e
}

# The pin currently written in the sandbox compose file.
pinned() {
    grep -oP '\$\{DEV_NIX_BASE_IMAGE:-\K[^}]+' "$COMPOSE" | sed 's/.*@//'
}

echo "--- --check: reports, never edits, exits 0 ---"
write_compose "$OLD"
run_with bin --check
assert_eq "--check exits 0 when behind" 0 "$RC"
assert_contains "--check reports the committed pin" "current:   $OLD" "$OUT"
assert_contains "--check reports the published latest" "latest:    $NEW" "$OUT"
assert_eq "--check did not edit the file" "$OLD" "$(pinned)"

write_compose "$NEW"
run_with bin --check
assert_eq "--check exits 0 when already current" 0 "$RC"
assert_contains "--check says so when up to date" "already up to date" "$OUT"

echo "--- --verify: gates the committed pin ---"
write_compose "$NEW"
run_with bin --verify
assert_eq "--verify passes on a multi-arch pin" 0 "$RC"
assert_contains "--verify reports the platforms" "linux/amd64 linux/arm64" "$OUT"
assert_not_contains "--verify drops the attestation entry" "unknown" "$OUT"

write_compose "$ARCH"
run_with bin --verify
assert_eq "--verify fails on a per-arch pin" 1 "$RC"
assert_contains "--verify explains the per-arch failure" "not a multi-arch manifest list" "$OUT"

# A gate that passes because it could not check is worse than no gate.
write_compose "$NEW"
run_with bin-badnet --verify
assert_true "--verify fails when the registry is unreachable" test "$RC" -ne 0
assert_eq "--verify left the file alone" "$NEW" "$(pinned)"

echo "--- the bump: rewrite and byte-anchoring ---"
write_compose "$OLD"
run_with bin
assert_eq "bump exits 0" 0 "$RC"
assert_eq "bump wrote the new digest" "$NEW" "$(pinned)"
assert_contains "bump reports the transition" "from $OLD" "$OUT"

# The whole point: the surrounding bytes are load-bearing. Assert the rewritten
# line is exactly what the fixture generator would have produced, so any
# reformatting (indentation, the folded scalar, the interpolation) is caught.
expected="$(write_compose "$NEW" && cat "$COMPOSE")"
write_compose "$OLD"
run_with bin
assert_eq "the rewritten file is byte-identical to a hand-written one" \
    "$expected" "$(cat "$COMPOSE")"
assert_eq "exactly one interpolation survives" \
    1 "$(grep -c 'DEV_NIX_BASE_IMAGE' "$COMPOSE")"

echo "--- explicit targets ---"
write_compose "$OLD"
run_with bin sha-51d9c59
assert_eq "an explicit tag resolves and pins" "$NEW" "$(pinned)"

# The CI path: the workflow passes the digest it just published, so there is no
# tag lookup at all — but the manifest-list gate still applies.
write_compose "$OLD"
run_with bin "$NEW"
assert_eq "an explicit digest pins without a tag lookup" "$NEW" "$(pinned)"
assert_eq "explicit digest exits 0" 0 "$RC"

write_compose "$OLD"
run_with bin "$ARCH"
assert_eq "an explicit per-arch digest is refused" 1 "$RC"
assert_contains "the refusal names the cause" "not a multi-arch manifest list" "$OUT"
assert_eq "the refusal wrote nothing" "$OLD" "$(pinned)"

write_compose "$NEW"
run_with bin "$NEW"
assert_eq "re-pinning the same digest is a no-op" 0 "$RC"
assert_contains "the no-op says so" "already pinned" "$OUT"

echo "--- failure modes report themselves ---"
# Regression: resolve_digest's pipeline used to let curl's exit status escape
# through pipefail, killing the script under set -e before this message printed.
# The symptom was a bare `exit 22` with no output at all.
write_compose "$OLD"
run_with bin sha-deadbee
assert_eq "an unknown tag fails" 1 "$RC"
assert_contains "an unknown tag says which tag" "could not resolve" "$OUT"
assert_contains "an unknown tag names the tag it tried" "sha-deadbee" "$OUT"
assert_eq "a failed resolve wrote nothing" "$OLD" "$(pinned)"

write_compose "$OLD"
run_with bin-singlearch
assert_eq "a per-arch latest is refused" 1 "$RC"
assert_eq "that refusal wrote nothing" "$OLD" "$(pinned)"

# A manifest LIST naming one real platform. The media-type check passes here, so
# only the platform count can catch it — without these four assertions, relaxing
# `-ge 3` to `-ge 1` leaves the whole suite green.
write_compose "$OLD"
run_with bin-onearch
assert_eq "a single-platform index is refused" 1 "$RC"
assert_contains "the refusal names the cause" "not a multi-arch manifest list" "$OUT"
assert_eq "the single-platform refusal wrote nothing" "$OLD" "$(pinned)"
write_compose "$NEW"
run_with bin-onearch --verify
assert_eq "--verify also refuses a single-platform index" 1 "$RC"

write_compose "$OLD"
run_with bin-badmedia
assert_eq "a non-list media type is refused even with two platforms" 1 "$RC"
assert_eq "the media-type refusal wrote nothing" "$OLD" "$(pinned)"

# Token works, manifest fetch fails. bin-badnet dies at the token, so without
# this stub the "could not fetch" branches never execute and deleting them
# leaves the suite green — the user would get a manifest-list complaint with an
# empty media type instead of an accurate "unverifiable" message.
# Via an explicit digest, which skips tag resolution and lands directly on the
# validation fetch — also exactly the CI shape, where the workflow supplies a
# digest and a transient 5xx must not be mistaken for a malformed manifest.
write_compose "$OLD"
run_with bin-nomanifest "$NEW"
assert_eq "an unfetchable manifest fails the bump" 1 "$RC"
assert_contains "the bump says it could not fetch, not that it is single-arch" \
    "could not fetch the manifest" "$OUT"
assert_eq "the unfetchable bump wrote nothing" "$OLD" "$(pinned)"

# The tag-resolution failure is a different message, and must stay that way.
write_compose "$OLD"
run_with bin-nomanifest
assert_eq "an unresolvable tag also fails" 1 "$RC"
assert_contains "but reports resolution, not fetching" "could not resolve" "$OUT"
write_compose "$NEW"
run_with bin-nomanifest --verify
assert_eq "--verify fails on an unfetchable manifest" 1 "$RC"
assert_contains "--verify calls it unverifiable" "treating an unverifiable pin as a failure" "$OUT"

run_with bin-notoken --check
assert_true "an unusable token endpoint fails" test "$RC" -ne 0
assert_contains "it names the token as the problem" "anonymous pull token" "$OUT"

run_with bin-badnet --check
assert_true "--check fails when the registry is unreachable" test "$RC" -ne 0

echo "--- argument handling ---"
run_with bin --check --verify
assert_eq "--check and --verify are mutually exclusive" 1 "$RC"
assert_contains "the conflict explains both" "mutually exclusive" "$OUT"

run_with bin --nope
assert_eq "an unknown flag is rejected" 1 "$RC"
assert_contains "the rejection names the flag" "unknown flag: --nope" "$OUT"

run_with bin one two
assert_eq "a second positional is rejected" 1 "$RC"
assert_contains "the rejection names the extra" "unexpected extra argument" "$OUT"

echo "--- the committed tree ---"
# The real compose file must be something this tool can actually parse: the
# anchor it greps is the same one ensure_nix_base() and test-nix-base-pin.sh use.
real="$(grep -oP '\$\{DEV_NIX_BASE_IMAGE:-\K[^}]+' "$DEV_BASE/nix/base/compose.nix-base.yml")"
assert_true "the committed pin matches the tool's expected reference shape" \
    bash -c "[[ '$real' =~ ^[a-z0-9.:-]+/.+@sha256:[0-9a-f]{64}$ ]]"

echo "--- the workflow drives this tool ---"
# CI is what makes the publish -> pin step owned (#83), and it owns it by
# calling this script. Renaming or relocating the tool without updating the
# workflow would leave the publish green and the pin unmoved again — the exact
# regression, back in a new costume. Guard the coupling in both directions.
WF="$DEV_BASE/.github/workflows/nix-base.yml"
assert_true "the publish workflow exists" test -f "$WF"
wf="$(cat "$WF")"
assert_contains "the pin job invokes dev/bump-nix-base" "dev/bump-nix-base" "$wf"
assert_contains "it passes the per-commit sha- tag" 'dev/bump-nix-base "sha-${short}"' "$wf"
assert_contains "the pin job is main-only" "github.ref == 'refs/heads/main'" "$wf"
# The no-op path depends on the tool exiting 0 when the pin is already current;
# if that ever became non-zero, every republish would redden the publish run.
# Drive it here rather than trusting $RC from an unrelated case above.
write_compose "$NEW"
run_with bin "$NEW"
assert_eq "already-pinned exits 0, which is what makes the job a quiet no-op" \
    0 "$RC"
assert_eq "and leaves the file byte-identical, so git diff --quiet holds" \
    "$NEW" "$(pinned)"
# The pin file is an output of a publish, not an input: leaving it in the
# trigger paths means merging a bump sets off another two-arch republish.
assert_contains "the pin file is excluded from the publish triggers" \
    "'!nix/base/compose.nix-base.yml'" "$wf"

finish
