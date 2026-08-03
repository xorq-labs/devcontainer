#!/usr/bin/env bash
# Tests for the shared, fingerprint-tagged project image (DEV_IMAGE_REF) and
# its split from the container-staleness hash (issue #53).
#
# The image fingerprint (image_config_hash) gates whether an image build runs
# at all, so these tests guard its two failure modes:
#   - a build input missing from image_config_files() -> edits silently never
#     reach the image (the COPY-source coverage check);
#   - path-as-identity in the hash -> identical worktrees get different
#     fingerprints and stop sharing (the tool-copy equality checks).
# The split adds a second axis: a runtime-only input (a host mount) must move
# the staleness hash (container recreate) WITHOUT moving the image tag (no
# rebuild), and the root Dockerfile must not feed the image hash on the nix
# route (over-invalidation nit).
# Runs against a disposable git repo and copies of the tooling — no docker.
#
# Verified (ADR-0005 §2): deleting "$DEV_BASE_DIR/lib/claude-code-token-env.sh"
# from image_config_files()'s emitted list and adding a comment naming that path
# in the function body — the #97 mutation, which the previous textual
# containment check passed — turns the COPY-source coverage block red on both
# routes with "COPY source NOT hashed: lib/claude-code-token-env.sh"
# (mutation run 2026-08-03).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
. "$(dirname "$(readlink -f "$0")")/lib/dockerfile.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DC="$DEV_BASE/dev/devcontainer"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

MAIN_TREE="$(new_repo "$TMPDIR_ROOT/fakerepo")"

# ---------- setup: two identical copies of the tooling ----------
# resolve is driven from each copy so DEV_BASE_DIR (and with it every
# config_files path) differs while the *content* is identical.
make_toolcopy() {
    local dst="$1"
    mkdir -p "$dst"
    cp -a "$DEV_BASE/Dockerfile" "$DEV_BASE/docker-compose.yml" \
        "$DEV_BASE/setup-claude.py" "$DEV_BASE/audit-hook" \
        "$DEV_BASE/dev" "$DEV_BASE/lib" "$DEV_BASE/defaults" "$DEV_BASE/nix" \
        "$dst/"
}
COPY_A="$TMPDIR_ROOT/tool-a"
COPY_B="$TMPDIR_ROOT/tool-b"
make_toolcopy "$COPY_A"
make_toolcopy "$COPY_B"

# IMAGE=<repo>:<tag> as printed by resolve; extra env (PATH stubs) goes first.
image_of() {
    local tool="$1"
    shift
    (cd "$MAIN_TREE" && env "$@" "$tool/dev/devcontainer" resolve 2>/dev/null) \
        | grep -oE 'IMAGE=\S+'
}

# STALENESS=<hash> as printed by resolve (image inputs + runtime inputs).
staleness_of() {
    local tool="$1"
    shift
    (cd "$MAIN_TREE" && env "$@" "$tool/dev/devcontainer" resolve 2>/dev/null) \
        | grep -oE 'STALENESS=\S+'
}

# ---------- test: every Dockerfile COPY source is hashed by image_config_files ----------
# image_config_hash decides whether a build runs, so a COPY'd file it doesn't
# cover can change without ever reaching the image.
#
# This was textual containment until #97: `grep -qF "$src"` against the SOURCE
# TEXT of image_config_files(), which a comment naming the path satisfies while
# the file is genuinely unhashed. It now proves the property the invariant
# actually states — edit the source, the fingerprint must move. The source set
# is derived per Dockerfile by the shared parser, and the overlay dir that
# `COPY --from=project` reads is read back from resolve, so nothing here
# restates the hashed set.
echo "--- COPY-source coverage in image_config_files ---"

# `COPY --from=project` sources resolve against the overlay dir, not the repo
# root. Ask resolve where that is rather than restating overlay lookup.
project_dir_of() {
    local tool="$1"
    shift
    (cd "$MAIN_TREE" && env "$@" "$tool/dev/devcontainer" resolve 2>/dev/null) \
        | sed -n 's/^  from:[[:space:]]*//p'
}

# Edit each COPY source in turn; the fingerprint must move every time. Driven on
# the route that actually builds the given Dockerfile — the two routes hash
# different sets, so each is probed against its own tool copy.
assert_copy_sources_hashed() {
    local df="$1" nixflag="$2" tool="$3"
    local dfname all default project_dir src path prev cur
    dfname="$(basename "$df")"

    all="$(dockerfile_copy_sources "$df")"
    default="$(dockerfile_default_copy_sources "$df")"
    assert_nonempty "$dfname: COPY sources extracted" "$all"

    project_dir="$(project_dir_of "$tool" "DEV_NIX_BASE=$nixflag")"
    assert_nonempty "$dfname: overlay dir resolved" "$project_dir"

    prev="$(image_of "$tool" "DEV_NIX_BASE=$nixflag")"
    assert_nonempty "$dfname: baseline fingerprint" "$prev"

    while IFS= read -r src; do
        [ -n "$src" ] || continue
        if grep -qxF "$src" <<< "$default"; then
            path="$tool/$src"
        else
            path="$project_dir/$src"
        fi
        # An unresolvable source (a glob, a context this mapping doesn't know)
        # FAILS rather than being skipped: silently dropping a source is the
        # exact fail-open shape this rewrite exists to remove.
        if [ ! -f "$path" ]; then
            _fail "$dfname: COPY source resolvable: $src" "no such file: $path"
            continue
        fi
        printf '\n# copy-coverage probe: %s\n' "$src" >> "$path"
        cur="$(image_of "$tool" "DEV_NIX_BASE=$nixflag")"
        if [ -z "$cur" ] || [ "${cur##*:}" = "unresolved" ]; then
            _fail "$dfname: COPY source hashed: $src" \
                "editing $path made the fingerprint unresolvable: ${cur:-<empty>}"
        elif [ "$cur" = "$prev" ]; then
            _fail "$dfname: COPY source NOT hashed: $src" \
                "editing $path left the fingerprint at $prev" \
                "add it to image_config_files() in dev/devcontainer"
        else
            _pass "$dfname: COPY source hashed: $src"
        fi
        prev="$cur"
    done <<< "$all"
}

COV_CLASSIC="$TMPDIR_ROOT/tool-cov-classic"
COV_NIX="$TMPDIR_ROOT/tool-cov-nix"
make_toolcopy "$COV_CLASSIC"
make_toolcopy "$COV_NIX"
assert_copy_sources_hashed "$DEV_BASE/Dockerfile" 0 "$COV_CLASSIC"
assert_copy_sources_hashed "$DEV_BASE/nix/base/Dockerfile.nix-default" 1 "$COV_NIX"

# ---------- test: resolve prints a fingerprint-tagged image ----------
echo "--- resolve prints IMAGE ---"
img_a="$(image_of "$COPY_A")"
assert_contains "image repo is project-scoped" "IMAGE=fakerepo-devimg:" "$img_a"
if [[ "$img_a" =~ ^IMAGE=fakerepo-devimg:[0-9a-f]{64}$ ]]; then
    _pass "tag is a sha256 fingerprint"
else
    _fail "tag is a sha256 fingerprint" "got: $img_a"
fi

# ---------- test: identical content at different paths -> same fingerprint ----------
# Guards against path-as-identity leaking into config_hash (e.g. hashing
# DEV_PROJECT_DIR's absolute path): that would splinter the shared image
# whenever the script runs from a different checkout.
echo "--- path independence ---"
img_b="$(image_of "$COPY_B")"
assert_eq "same content, different base dir -> same image" "$img_a" "$img_b"
img_real="$( (cd "$MAIN_TREE" && "$DC" resolve 2>/dev/null) | grep -oE 'IMAGE=\S+')"
assert_eq "real checkout agrees with copies" "$img_a" "$img_real"

# ---------- test: baked build inputs change the fingerprint ----------
echo "--- content sensitivity ---"
# lib/git.sh is COPY'd into the image; regression guard for it being absent
# from config_files (an edit must produce a new fingerprint, not a silent reuse)
printf '\n# fingerprint test mutation\n' >> "$COPY_B/lib/git.sh"
img_b2="$(image_of "$COPY_B")"
assert_true "lib/git.sh edit changes the fingerprint" [ "$img_a" != "$img_b2" ]

# ---------- test: baked build args change the fingerprint ----------
# USER_UID/USER_GID/HOST_USER are compose build args baked into the image but
# invisible to file hashing; they must be hashed explicitly.
echo "--- build-arg sensitivity ---"
STUB_BIN="$TMPDIR_ROOT/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\necho stubbeduser\n' > "$STUB_BIN/whoami"
printf '#!/usr/bin/env bash\ncase "${1:-}" in -u) echo 4242 ;; -g) echo 4242 ;; *) exec /usr/bin/id "$@" ;; esac\n' \
    > "$STUB_BIN/id"
chmod +x "$STUB_BIN/whoami" "$STUB_BIN/id"
img_user="$(image_of "$COPY_A" PATH="$STUB_BIN:$PATH")"
assert_true "different host user/uid changes the fingerprint" [ "$img_a" != "$img_user" ]

# ---------- test: unhashable inputs degrade, not die ----------
# Teardown (down/reset/clean) runs through the same top-level code; a missing
# required build input must fall back to a never-existing tag instead of
# aborting. Forced to the classic route (DEV_NIX_BASE=0), where the root
# Dockerfile IS a required build input — on the nix route it isn't one, so its
# absence is correctly not a hash failure (see the nix-route test below).
echo "--- hash-failure fallback ---"
COPY_C="$TMPDIR_ROOT/tool-c"
make_toolcopy "$COPY_C"
rm "$COPY_C/Dockerfile"
if img_c="$(image_of "$COPY_C" DEV_NIX_BASE=0)"; then
    assert_eq "missing Dockerfile falls back to :unresolved" \
        "IMAGE=fakerepo-devimg:unresolved" "$img_c"
else
    _fail "resolve survives unhashable build inputs" "resolve exited nonzero"
fi
# A missing *overlay* file must refuse too — config_hash `cat`s each entry
# inside a pipeline where the failure is silent, so without the readability
# guard this would mint a different but valid-looking fingerprint.
COPY_D="$TMPDIR_ROOT/tool-d"
make_toolcopy "$COPY_D"
rm "$COPY_D/defaults/setup-env.sh"
if img_d="$(image_of "$COPY_D")"; then
    assert_eq "missing overlay file falls back to :unresolved" \
        "IMAGE=fakerepo-devimg:unresolved" "$img_d"
else
    _fail "resolve survives a missing overlay file" "resolve exited nonzero"
fi

# ---------- test: staleness hash splits from the image tag (issue #53) ----------
# A purely-runtime input (host-mounts.txt) must move the staleness hash — so the
# container recreate prompt still fires — WITHOUT moving the image tag, so no
# rebuild is triggered. A build input, being in both sets, must move both.
echo "--- image / staleness split ---"
COPY_E="$TMPDIR_ROOT/tool-e"
make_toolcopy "$COPY_E"
# Reduce the staleness set to the image set (defaults/ ships a host-mounts.txt):
# with no runtime inputs the two hashes are byte-identical.
rm -f "$COPY_E/defaults/host-mounts.txt" "$COPY_E/defaults/host-mounts.local.txt"
img_e0="$(image_of "$COPY_E")"
stale_e0="$(staleness_of "$COPY_E")"
assert_true "resolve prints a staleness hash" [ -n "$stale_e0" ]
assert_eq "no runtime inputs -> staleness hash equals image hash" \
    "${img_e0##*:}" "${stale_e0#STALENESS=}"

# Add a runtime-only input.
printf '%s\n' "/tmp:/mnt/tmp" > "$COPY_E/defaults/host-mounts.txt"
img_e1="$(image_of "$COPY_E")"
stale_e1="$(staleness_of "$COPY_E")"
assert_eq "host-mounts edit leaves the image tag unchanged" "$img_e0" "$img_e1"
assert_true "host-mounts edit changes the staleness hash" [ "$stale_e0" != "$stale_e1" ]

# A build input still moves both hashes (staleness is a superset).
printf '\n# split test mutation\n' >> "$COPY_E/lib/git.sh"
img_e2="$(image_of "$COPY_E")"
stale_e2="$(staleness_of "$COPY_E")"
assert_true "build-input edit changes the image tag" [ "$img_e1" != "$img_e2" ]
assert_true "build-input edit changes the staleness hash too" [ "$stale_e1" != "$stale_e2" ]

# ---------- test: nix route excludes the root Dockerfile from the image hash ----------
# On the nix route Dockerfile.nix-default is the build input and the root
# Dockerfile is never referenced, so hashing it there only over-invalidates
# nix images (issue #53 nit). Classic route must still track it.
echo "--- nix route excludes the root Dockerfile ---"
COPY_F="$TMPDIR_ROOT/tool-f"
make_toolcopy "$COPY_F"
img_classic="$(image_of "$COPY_F" DEV_NIX_BASE=0)"
img_nix="$(image_of "$COPY_F" DEV_NIX_BASE=1)"
assert_true "classic and nix routes fingerprint differently" [ "$img_classic" != "$img_nix" ]
printf '\n# nix-route root Dockerfile mutation\n' >> "$COPY_F/Dockerfile"
img_classic2="$(image_of "$COPY_F" DEV_NIX_BASE=0)"
img_nix2="$(image_of "$COPY_F" DEV_NIX_BASE=1)"
assert_true "classic route: root Dockerfile edit changes the image" \
    [ "$img_classic" != "$img_classic2" ]
assert_eq "nix route: root Dockerfile edit does NOT change the image" \
    "$img_nix" "$img_nix2"

# ---------- test: compose wires the shared image ref ----------
echo "--- compose wiring ---"
assert_true "docker-compose.yml pins service image to DEV_IMAGE_REF" \
    grep -q 'image: ${DEV_IMAGE_REF' "$DEV_BASE/docker-compose.yml"

# ---------- test: clean-images is a known command ----------
echo "--- clean-images plumbing ---"
out="$( (cd "$MAIN_TREE" && "$DC" --help 2>&1) )" || true
assert_contains "help lists clean-images" "clean-images" "$out"
assert_contains "completions list clean-images" "clean-images" \
    "$("$DEV_BASE/dev/devcontainer-completions" bash)"

finish
