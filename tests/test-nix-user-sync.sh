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
# Verified (ADR-0005 §2), review round — four more, ALL green on the first cut
# of this upstream block:
#   - the alias guard reformatted so the grep misses it (single-quoted RHS, or
#     operands swapped) => FAIL "HOST_USER alias guard found". The loop had no
#     non-empty assertion, so two assertions evaporated silently — the #86
#     fail-open shape, reintroduced here two commits after #102 fixed it;
#   - a partial rename inside nix/base/flake.nix alone (its `mkdir -p
#     home/vscode/...`, `chmod 700`, `chown -R` lines are RELATIVE paths that
#     an absolute /home/<user> pattern misses) => FAIL "flake.nix: home/devuser";
#   - deleting `ENV HOME=/home/vscode` from the root Dockerfile entirely =>
#     FAIL "Dockerfile declares ENV HOME=/home/<user>". Globbing every
#     /home/<user> literal does not require the declaration to exist.
#   (mutation runs 2026-08-04)
#
# Verified (ADR-0005 §2), upstream half — three mutations, ALL green on the
# suite before it existed (11 passed, 0 failed each):
#   - renaming the container user throughout both Dockerfiles
#     (s/vscode/devuser/g) with NIX_USER left stale => 4 FAILs;
#   - a PARTIAL rename, only `ENV HOME=/home/vscode` in the root Dockerfile
#     => FAIL "Dockerfile: /home/devuser";
#   - only nix/base/flake.nix's Env HOME renamed, so the nix route drifts
#     alone => FAIL "nix/base/flake.nix: Env HOME=/home/devuser"
#   (mutation runs 2026-08-04).
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
assert_true "discovery includes templates/nix/compose.override.yml" \
    grep -qxF "$DEV_BASE/templates/nix/compose.override.yml" \
    <(printf '%s\n' "${compose_files[@]}")

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
echo "--- NIX_USER matches the container user the image actually creates ---"
# Everything above is the DOWNSTREAM half: every EXTRA_PATH copy tracks
# NIX_USER. This is the upstream half, and without it the coupling is guarded
# from only one end. `vscode` is a bare literal in both Dockerfiles — 9x and 6x,
# with no ARG USERNAME — so renaming the container user there leaves NIX_USER
# stale, every assertion above still passes, and the nix seed symlinks a profile
# into a home that no longer belongs to the container user. Nothing fails until
# a nix-seeded container starts and its tools are missing from PATH.
#
# Derived from each route's own declaration, never restated:
#   classic route  -> Dockerfile's `ENV HOME=/home/<user>`
#   nix base       -> nix/base/flake.nix's Env `HOME=/home/<user>` (whose own
#                     comment says it mirrors the Dockerfile's ENV HOME)
# plus every other literal /home/<user> path in either Dockerfile, so a PARTIAL
# rename is caught too. Paths interpolating a variable (`/home/$HOST_USER`, the
# host-user alias symlink) are legitimately a different value and excluded.
# Both absolute (/home/<user>) and repo-relative (home/<user>, as the flake's
# image-build steps write) spellings. `+` needs at least one char from the
# class and `$` is outside it, so `/home/$HOST_USER` — the host-user alias,
# legitimately a different value — yields no match and is excluded.
#
# The population is the WHOLE file, comments included. That is deliberate:
# Dockerfile.nix-default's comment about what the base ships is real coverage.
# The cost is that a legitimate non-container path in a comment (say a note
# mentioning /home/node) would FAIL here — if you hit that, exclude it
# explicitly rather than narrowing the pattern.
user_paths_in() {
    grep -oE 'home/[A-Za-z0-9._-]+' "$1" | sed 's|^home/||' | sort -u
}

# The classic route's own declaration must exist and name NIX_USER. Globbing
# every /home/<user> path below would otherwise pass a Dockerfile with no
# ENV HOME at all.
env_home_user="$(grep -oP '^ENV\s+HOME=/home/\K[A-Za-z0-9._-]+' "$DEV_BASE/Dockerfile" || true)"
assert_nonempty "Dockerfile declares ENV HOME=/home/<user>" "$env_home_user"
assert_eq "Dockerfile: ENV HOME user" "$nix_user" "$env_home_user"

for f in "$DEV_BASE/Dockerfile" "$DEV_BASE/nix/base/Dockerfile.nix-default" \
         "$DEV_BASE/nix/base/flake.nix"; do
    rel="${f#"$DEV_BASE"/}"
    mapfile -t users < <(user_paths_in "$f")
    assert_true "$rel: home/<user> paths found" test "${#users[@]}" -gt 0
    for u in "${users[@]}"; do
        assert_eq "$rel: home/$u" "$nix_user" "$u"
    done
done

# The flake bakes HOME into the nix base's image config; the tail Dockerfile
# inherits it rather than restating ENV HOME.
mapfile -t flake_users < <(grep -oE '"HOME=/home/[A-Za-z0-9._-]+"' "$DEV_BASE/nix/base/flake.nix" \
    | sed -E 's|^"HOME=/home/||; s|"$||' | sort -u)
assert_true "nix/base/flake.nix: Env HOME declared" test "${#flake_users[@]}" -gt 0
for u in "${flake_users[@]}"; do
    assert_eq "nix/base/flake.nix: Env HOME=/home/$u" "$nix_user" "$u"
done

# The host-user alias symlink is skipped when HOST_USER already IS the container
# user; that comparison is a further copy of the name. Non-empty guarded: a
# reformat the grep misses (single quotes, swapped operands) must FAIL here, not
# silently assert nothing — the #86 shape this repo keeps re-finding.
for f in "$DEV_BASE/Dockerfile" "$DEV_BASE/nix/base/Dockerfile.nix-default"; do
    rel="${f#"$DEV_BASE"/}"
    mapfile -t cmp_users < <(grep -oE '"\$HOST_USER" != "[A-Za-z0-9._-]+"' "$f" \
        | sed -E 's|.* != "||; s|"$||' | sort -u)
    assert_true "$rel: HOST_USER alias guard found" test "${#cmp_users[@]}" -gt 0
    for u in "${cmp_users[@]}"; do
        assert_eq "$rel: HOST_USER alias guard compares against $u" "$nix_user" "$u"
    done
done

echo ""
echo "NIX_USER: $nix_user    files checked: ${#compose_files[@]} compose + README + 2 Dockerfiles + flake"
finish
