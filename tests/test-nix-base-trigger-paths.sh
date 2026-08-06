#!/usr/bin/env bash
# Guard: .github/workflows/nix-base.yml's trigger paths must cover every
# default-context COPY source of nix/base/Dockerfile.nix-default.
#
# The workflow states the rule in its own header:
#
#   Paths beyond nix/base/** are the tail-build inputs (Dockerfile.nix-default
#   COPYs them): a change there must prove the default consumer image still
#   builds.
#
# ...and then drifted from it. lib/claude-code-token-env.sh was COPYd by both
# Dockerfiles, allowlisted in .dockerignore and hashed by image_config_files(),
# yet missing from these lists (#86) — so a PR touching only that file skipped
# the "Build the project tail on the base" step, which is the one step that
# exists to prove exactly that change is safe. Nothing failed; the verification
# simply did not run. That is the failure mode this test converts into a red
# check.
#
# Four input classes are checked, because a tail build can break through any of
# them: default-context COPY sources; the additional build context that
# `COPY --from=project ...` reads (CI supplies ./defaults, derived here from the
# workflow's own --build-context flag rather than hardcoded); .dockerignore,
# which is not a COPY source at all but filters the repo-root context the tail
# build uses — a new deny pattern there breaks a COPY with no COPY source
# touched; and the workflow file itself, whose edits change what the build
# does and must therefore trigger it (#109).
#
# Verified (ADR-0005 §2), audit round: deleting `- .github/workflows/nix-base.yml`
# from both paths lists turns this red on ".github/workflows/nix-base.yml is
# itself a trigger path" (15 passed, 1 failed). This workflow already listed
# itself; the assertion exists so the sibling cannot silently lose it again
# (mutation run 2026-08-04).
#
# Verified (ADR-0005 §2), review round: deleting `- nix/base/**` from both paths
# lists turns this red on "nix/base/Dockerfile.nix-default is itself a trigger
# path" (14 passed, 1 failed) — 13/13 green before that assertion existed.
# Reordering the lists so `- '!nix/base/compose.nix-base.yml'` PRECEDES
# `- nix/base/**` turns it red on "the pin file is excluded from the triggers"
# (14 passed, 1 failed): GitHub's matcher is last-match-wins, so that order
# re-includes the pin file and restarts the two-arch republish, which the old
# order-independent exclusion scan reported as excluded (mutation runs
# 2026-08-04).
#
# Scope note: the ROOT Dockerfile's COPY sources are still not required here —
# this workflow builds the nix tail, not the classic image. The classic build's
# workflow (docker-build.yml) hand-mirrors the same input classes and has its
# own copy of this guard, tests/test-docker-build-trigger-paths.sh (#92); the
# parsing both share lives in tests/lib/workflow-paths.sh.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
. "$(dirname "$(readlink -f "$0")")/lib/dockerfile.sh"
. "$(dirname "$(readlink -f "$0")")/lib/workflow-paths.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
workflow="$DEV_BASE/.github/workflows/nix-base.yml"

echo "--- nix-base.yml trigger paths cover the tail-build inputs ---"

[ -f "$workflow" ] || { echo "  FAIL: workflow not found at $workflow"; exit 1; }

# Read the built Dockerfile out of the build step rather than assuming it, and
# require its own path to be a trigger — the sibling guard had the same hole
# (removing `- nix/base/**` here left it 13/13 green).
dockerfile_rel="$(workflow_build_dockerfile "$workflow" || true)"
assert_nonempty "the tail-build step names the Dockerfile it builds" "$dockerfile_rel"
dockerfile="$DEV_BASE/$dockerfile_rel"
[ -f "$dockerfile" ] || { echo "  FAIL: Dockerfile not found at $dockerfile"; exit 1; }

mapfile -t push_paths < <(workflow_event_paths "$workflow" push)
mapfile -t pr_paths < <(workflow_event_paths "$workflow" pull_request)

assert_true "the push paths list was found" test "${#push_paths[@]}" -gt 0
assert_true "the pull_request paths list was found" test "${#pr_paths[@]}" -gt 0

# The two lists must stay identical. A path added to push but not pull_request
# means the tail build runs only after merge, which is the wrong end.
assert_eq "push and pull_request trigger on the same paths" \
    "$(printf '%s\n' "${push_paths[@]}")" "$(printf '%s\n' "${pr_paths[@]}")"

covered() {
    workflow_path_covered "$1" "${push_paths[@]}"
}

if covered "$dockerfile_rel"; then
    _pass "$dockerfile_rel is itself a trigger path"
else
    _fail "$dockerfile_rel is itself a trigger path" \
        "the tail build builds $dockerfile_rel, so a change to it must" \
        "trigger the build that exists to verify it."
fi

# Default-context COPY sources, via the shared parser (tests/lib/dockerfile.sh)
# so continuations, mixed case, leading flags and multi-source COPYs are handled
# in one place rather than three.
mapfile -t sources < <(dockerfile_default_copy_sources "$dockerfile")
assert_true "found default-context COPYs in Dockerfile.nix-default" \
    test "${#sources[@]}" -gt 0

for src in "${sources[@]}"; do
    if covered "$src"; then
        _pass "$src is a trigger path"
    else
        _fail "$src is a trigger path" \
            "Dockerfile.nix-default COPYs $src from the default context," \
            "but nix-base.yml's paths do not match it — a change to that" \
            "file skips the tail build that exists to verify it."
    fi
done

# The additional build context the tail-build step passes. Derived from the
# workflow rather than hardcoded, so moving ./defaults fails here instead of
# leaving a stale assertion quietly passing.
project_ctx="$(grep -oP -- '--build-context project=\./\K\S+' "$workflow" | head -n1 || true)"
assert_nonempty "the tail-build step names a project build context" "$project_ctx"
if covered "${project_ctx}/x"; then
    _pass "${project_ctx}/** covers the --from=project build context"
else
    _fail "${project_ctx}/** covers the --from=project build context" \
        "the tail build reads ./${project_ctx} as the 'project' context, so a" \
        "change there must trigger the workflow."
fi

# The workflow file is itself a build input: it holds the docker build command,
# its --build-context and its --build-args. nix-base.yml has always listed
# itself; docker-build.yml did not, so PR #93 — which existed to fix that
# workflow's trigger paths — merged without ever running the classic build.
# Derived from the workflow this suite already points at, not restated.
workflow_rel="${workflow#"$DEV_BASE"/}"
if covered "$workflow_rel"; then
    _pass "$workflow_rel is itself a trigger path"
else
    _fail "$workflow_rel is itself a trigger path" \
        "the workflow defines the tail build — its build command, contexts and args —" \
        "so a change to it must re-run the verification it configures."
fi

# Not a COPY source, but it filters the repo-root context the tail build uses:
# adding a pattern here can break a COPY without any COPY source changing.
if covered .dockerignore; then
    _pass ".dockerignore is a trigger path"
else
    _fail ".dockerignore is a trigger path" \
        "the tail build's context is the repo root, so .dockerignore gates" \
        "every default-context COPY; a new deny pattern breaks the build with" \
        "no COPY source touched and no workflow run to catch it."
fi

# The pin is an output of a publish, not an input to one; it must stay excluded
# or merging a pin bump sets off another two-arch republish.
if covered nix/base/compose.nix-base.yml; then
    _fail "the pin file is excluded from the triggers" \
        "compose.nix-base.yml is an output of a publish, not an input to one;" \
        "while it matches, merging a pin bump sets off another two-arch" \
        "republish of byte-identical layers."
else
    _pass "the pin file is excluded from the triggers"
fi

echo ""
finish
