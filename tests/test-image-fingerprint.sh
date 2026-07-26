#!/usr/bin/env bash
# Tests for the shared, fingerprint-tagged project image (DEV_IMAGE_REF).
#
# The fingerprint (config_hash) gates whether an image build runs at all, so
# these tests guard its two failure modes:
#   - a build input missing from config_files() -> edits silently never reach
#     the image (the COPY-source coverage check);
#   - path-as-identity in the hash -> identical worktrees get different
#     fingerprints and stop sharing (the tool-copy equality checks).
# Runs against a disposable git repo and copies of the tooling — no docker.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DC="$DEV_BASE/dev/devcontainer"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

MAIN_TREE="$(new_repo "$TMPDIR_ROOT/fakerepo")"

# ---------- test: every Dockerfile COPY source is hashed by config_files ----------
# config_hash decides whether a build runs, so a COPY'd file it doesn't cover
# can change without ever reaching the image.
echo "--- COPY-source coverage in config_files ---"
config_files_body="$(sed -n '/^config_files()/,/^}$/p' "$DC")"
for df in "$DEV_BASE/Dockerfile" "$DEV_BASE/nix/base/Dockerfile.nix-default"; do
    while IFS= read -r src; do
        if grep -qF "$src" <<< "$config_files_body"; then
            _pass "$(basename "$df"): COPY source hashed: $src"
        else
            _fail "$(basename "$df"): COPY source NOT hashed: $src" \
                "add it to config_files() in dev/devcontainer"
        fi
    done < <(awk '/^COPY/ { if ($2 ~ /^--from=/) print $3; else print $2 }' "$df")
done

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
# Dockerfile must fall back to a never-existing tag instead of aborting.
echo "--- hash-failure fallback ---"
COPY_C="$TMPDIR_ROOT/tool-c"
make_toolcopy "$COPY_C"
rm "$COPY_C/Dockerfile"
if img_c="$(image_of "$COPY_C")"; then
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
