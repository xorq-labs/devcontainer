#!/usr/bin/env bash
# Guard: .github/workflows/docker-build.yml's trigger paths must cover every
# build input of the root Dockerfile.
#
# This is the second place the same list is hand-mirrored — the first was
# nix-base.yml, which drifted (#86) and got this guard's sibling in #87
# (tests/test-nix-base-trigger-paths.sh). Here the drift was .dockerignore
# (#92): not a COPY source, but it filters the repo-root build context, so a
# deny pattern that newly matches a COPY source (say setup-claude.py or
# audit-hook) breaks the build with no COPY source touched. A PR touching only
# .dockerignore never triggered the workflow, merged green, and the next
# unrelated build on main would fail. An absent check looks identical to a
# passing one — this test converts it into a red one.
#
# Three input classes are checked, matching the sibling: default-context COPY
# sources of the root Dockerfile; the additional build context that
# `COPY --from=project ...` reads (CI supplies ./defaults, derived from the
# workflow's own --build-context flag rather than hardcoded); and
# .dockerignore.
#
# Verified (ADR-0005 §2), audit round: deleting `- .github/workflows/docker-build.yml`
# from both paths lists turns this red on ".github/workflows/docker-build.yml is
# itself a trigger path" (14 passed, 1 failed). That was main's actual state:
# PR #93, which existed to fix this workflow's trigger paths, ran only `Bash
# tests` and `pre-commit` — `gh pr checks 93` vs `gh pr checks 87`, whose
# self-listing twin ran Build (amd64)/(arm64) (mutation run 2026-08-04).
#
# Verified (ADR-0005 §2), review round: deleting `- Dockerfile` from BOTH paths
# lists turns this red on "Dockerfile is itself a trigger path" (13 passed, 1
# failed) — it was 12/12 green before that assertion existed, while the workflow
# had stopped running on the very file it builds. Pointing the build step at a
# new `-f Dockerfile.classic` turns it red on that path plus the classic file's
# own unlisted COPY sources (8 passed, 2 failed), because the built Dockerfile
# is now read from the build step instead of hardcoded (mutation runs
# 2026-08-04).
#
# Verified (ADR-0005 §2): removing .dockerignore from both workflow lists
# turns this red on ".dockerignore is a trigger path"; removing it from
# pull_request only turns the push==pull_request assertion red (mutation run
# 2026-08-02).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"
. "$(dirname "$(readlink -f "$0")")/lib/dockerfile.sh"
. "$(dirname "$(readlink -f "$0")")/lib/workflow-paths.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
workflow="$DEV_BASE/.github/workflows/docker-build.yml"

echo "--- docker-build.yml trigger paths cover the classic-build inputs ---"

[ -f "$workflow" ] || { echo "  FAIL: workflow not found at $workflow"; exit 1; }

# Which Dockerfile this workflow builds is read from the build step, not
# assumed: a guard parsing a different file than the workflow builds is green
# over an entirely unlisted input set.
dockerfile_rel="$(workflow_build_dockerfile "$workflow" || true)"
assert_nonempty "the build step names the Dockerfile it builds" "$dockerfile_rel"
dockerfile="$DEV_BASE/$dockerfile_rel"
[ -f "$dockerfile" ] || { echo "  FAIL: Dockerfile not found at $dockerfile"; exit 1; }

mapfile -t push_paths < <(workflow_event_paths "$workflow" push)
mapfile -t pr_paths < <(workflow_event_paths "$workflow" pull_request)

assert_true "the push paths list was found" test "${#push_paths[@]}" -gt 0
assert_true "the pull_request paths list was found" test "${#pr_paths[@]}" -gt 0

# The two lists must stay identical. A path added to push but not pull_request
# means the classic build runs only after merge, which is the wrong end.
assert_eq "push and pull_request trigger on the same paths" \
    "$(printf '%s\n' "${push_paths[@]}")" "$(printf '%s\n' "${pr_paths[@]}")"

covered() {
    workflow_path_covered "$1" "${push_paths[@]}"
}

# The Dockerfile itself is a build input. Without this, deleting `- Dockerfile`
# from both paths lists left the guard green at 12/12 while the workflow
# stopped running on changes to the very file it builds — bump NODE_MAJOR with
# a stale NODESOURCE_SHA256, merge with no build, and the next unrelated build
# on main dies at `sha256sum -c`.
if covered "$dockerfile_rel"; then
    _pass "$dockerfile_rel is itself a trigger path"
else
    _fail "$dockerfile_rel is itself a trigger path" \
        "the workflow builds $dockerfile_rel, so a change to it must trigger" \
        "the build that exists to verify it."
fi

# Default-context COPY sources, via the shared parser (tests/lib/dockerfile.sh)
# so continuations, mixed case, leading flags and multi-source COPYs are
# handled in one place.
mapfile -t sources < <(dockerfile_default_copy_sources "$dockerfile")
assert_true "found default-context COPYs in the root Dockerfile" \
    test "${#sources[@]}" -gt 0

for src in "${sources[@]}"; do
    if covered "$src"; then
        _pass "$src is a trigger path"
    else
        _fail "$src is a trigger path" \
            "the root Dockerfile COPYs $src from the default context, but" \
            "docker-build.yml's paths do not match it — a change to that file" \
            "skips the classic build that exists to verify it."
    fi
done

# The additional build context the build step passes. Derived from the
# workflow rather than hardcoded, so moving ./defaults fails here instead of
# leaving a stale assertion quietly passing.
# `|| true`: without it, pipefail aborts the suite here with no FAIL line and no
# Results line — red for CI but silent for a reader, and the assert below is
# dead code on the one path it was written for.
project_ctx="$(grep -oP -- '--build-context project=\./\K\S+' "$workflow" | head -n1 || true)"
assert_nonempty "the build step names a project build context" "$project_ctx"
if covered "${project_ctx}/x"; then
    _pass "${project_ctx}/** covers the --from=project build context"
else
    _fail "${project_ctx}/** covers the --from=project build context" \
        "the classic build reads ./${project_ctx} as the 'project' context," \
        "so a change there must trigger the workflow."
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
        "the workflow defines the classic build — its build command, contexts and args —" \
        "so a change to it must re-run the verification it configures."
fi

# Not a COPY source, but it filters the repo-root context the build uses:
# adding a pattern here can break a COPY without any COPY source changing.
if covered .dockerignore; then
    _pass ".dockerignore is a trigger path"
else
    _fail ".dockerignore is a trigger path" \
        "the classic build's context is the repo root, so .dockerignore gates" \
        "every default-context COPY; a new deny pattern breaks the build with" \
        "no COPY source touched and no workflow run to catch it (#92)."
fi

echo ""
finish
