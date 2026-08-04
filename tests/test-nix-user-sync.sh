#!/usr/bin/env bash
# Guard: every committed `/home/<user>/.nix-profile` literal names the user
# `lib/nix-seed.sh` actually installs Nix under.
#
# `NIX_USER` in lib/nix-seed.sh is the source of truth: the build-time
# single-user install runs as that user and the runtime symlink points
# ~/.nix-profile at that user's per-user profile. Compose cannot read a bash
# variable, so each nix overlay repeats the resolved path in its `EXTRA_PATH`
# build arg — and the overlays used to say so in a comment ("keep the two in
# sync by hand") with nothing checking it. Change NIX_USER and the profile
# symlink moves while EXTRA_PATH keeps pointing at the old home: every
# nix-seeded container silently loses its Nix tools from PATH. templates/nix/
# makes it propagating — every future `init --nix` overlay inherits a copy.
#
# ADR-0005 rung 2 (derive, don't restate): the expected path is parsed out of
# lib/nix-seed.sh at check time, and the files carrying it are discovered by
# grep rather than listed here, so a NEW overlay with a stale user fails too.
# Fail-closed at both ends: an empty parse and an empty (or template-missing)
# discovery set are FAILs, not skips.
#
# Scope is the `.nix-profile` coupling only. The other `/home/vscode` literals
# in those same compose files (cache/config mounts) are coupled to the image's
# container user in the Dockerfile, a different fact with a different owner.
#
# Verified (ADR-0005 §2), five mutations, each red on the named assertion:
#   - templates/nix/compose.override.yml EXTRA_PATH -> /home/nixuser/... =>
#     FAIL "templates/nix/compose.override.yml: /home/nixuser/.nix-profile/bin"
#     (expected /home/vscode/.nix-profile/bin);
#   - the same edit in nix/base/README.md => FAIL "nix/base/README.md: ...";
#   - renaming NIX_USER in lib/nix-seed.sh => FAIL "NIX_USER default parsed",
#     and the suite stops instead of comparing against an empty expectation;
#   - a NEW overlay projects/zz-probe/compose.override.yml carrying a stale
#     user => FAIL naming that file. This is the one that proves discovery
#     beats listing, so it belongs here and not only in the PR body;
#   - a stale .devcontainer/compose.override.yml (the highest-precedence
#     overlay) => FAIL naming it. Before this suite stopped excluding that
#     directory the same fixture passed green (mutation runs 2026-08-04).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
nix_seed="$DEV_BASE/lib/nix-seed.sh"
readme="$DEV_BASE/nix/base/README.md"

echo "--- NIX_USER / .nix-profile path sync ---"

[ -f "$nix_seed" ] || { echo "  FAIL: $nix_seed not found"; exit 1; }

# The source of truth: the default in `NIX_USER="${NIX_USER:-vscode}"`. The
# anchor is the whole assignment, so a rename or a reformat yields empty and
# fails below rather than silently comparing against nothing.
nix_user="$(grep -m1 -oP '^NIX_USER="\$\{NIX_USER:-\K[^}"]+' "$nix_seed" || true)"
assert_nonempty "lib/nix-seed.sh NIX_USER default parsed" "$nix_user"
[ -n "$nix_user" ] || finish
expected="/home/$nix_user/.nix-profile/bin"

# Discover the compose files carrying the literal instead of listing them: a new
# overlay (or a template copy) with the wrong user must fail here on its own.
#
# `.devcontainer/` is deliberately NOT excluded. resolve_project_dir() in
# lib/git.sh ranks it ABOVE projects/<name>, and `devcontainer init --local
# --nix` writes exactly that file, so a stale copy there wins overlay
# resolution — the one place a stale literal does the most damage. Excluding it
# let a planted stale .devcontainer/compose.override.yml pass green.
#
# Scope boundary: discovery is *.yml/*.yaml plus the one README below. A copy
# of the literal in a shell script or a second doc is NOT in the population.
# None exists today (the only non-yml .nix-profile uses are $HOME-derived), but
# a future one would escape silently.
mapfile -t compose_files < <(
    grep -rlE '\.nix-profile' \
        --include='*.yml' --include='*.yaml' \
        --exclude-dir='.git' --exclude-dir='.claude' \
        "$DEV_BASE" | sort
)
assert_true "compose files carrying .nix-profile discovered" \
    test "${#compose_files[@]}" -gt 0
# Sentinel: the scaffold every `init --nix` overlay inherits must be in the set.
# If it is not, the discovery above broke (moved, renamed, glob too narrow) and
# the rest of this suite would pass vacuously.
assert_line "discovery includes templates/nix/compose.override.yml" \
    "$DEV_BASE/templates/nix/compose.override.yml" \
    "$(printf '%s\n' "${compose_files[@]}")"

for f in "${compose_files[@]}"; do
    rel="${f#"$DEV_BASE"/}"
    # PATH lists are colon-joined and quoted, so a path is a token bounded by
    # whitespace, quotes or colons. Anything containing .nix-profile counts —
    # including a relative or $HOME-rooted spelling, which must also fail.
    mapfile -t paths < <(grep -oE '[^[:space:]":]*\.nix-profile[^[:space:]":]*' "$f")
    assert_true "$rel: .nix-profile path extracted" test "${#paths[@]}" -gt 0
    for p in "${paths[@]}"; do
        assert_eq "$rel: $p" "$expected" "$p"
    done
done

# nix/base/README.md documents the same literal in prose (it tells the reader
# what `init --nix` writes). Same derivation, looser shape: no /bin required.
if [ -f "$readme" ]; then
    mapfile -t doc_paths < <(grep -oE '/home/[^/[:space:]]+/\.nix-profile' "$readme")
    assert_true "nix/base/README.md: .nix-profile path documented" \
        test "${#doc_paths[@]}" -gt 0
    for p in "${doc_paths[@]}"; do
        assert_eq "nix/base/README.md: $p" "/home/$nix_user/.nix-profile" "$p"
    done
else
    _fail "nix/base/README.md: .nix-profile path documented" "$readme not found"
fi

echo ""
echo "NIX_USER: $nix_user    files checked: ${#compose_files[@]} compose + README"
finish
