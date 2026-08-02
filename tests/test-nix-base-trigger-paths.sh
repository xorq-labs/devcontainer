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
# Only default-context COPYs are checked. `COPY --from=project ...` reads the
# additional build context, which CI supplies as ./defaults — covered by the
# separate `defaults/**` entry, asserted below.
#
# Scope note: the ROOT Dockerfile's COPY sources are deliberately NOT required
# here. This workflow builds the nix tail, not the classic image. The two
# Dockerfiles must mirror each other's COPY block (a CLAUDE.md invariant), and
# tests/test-dockerignore-lib-allowlist.sh checks both against .dockerignore, so
# a shared lib added to one and not the other is already caught elsewhere.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
workflow="$DEV_BASE/.github/workflows/nix-base.yml"
dockerfile="$DEV_BASE/nix/base/Dockerfile.nix-default"

echo "--- nix-base.yml trigger paths cover the tail-build inputs ---"

[ -f "$workflow" ] || { echo "  FAIL: workflow not found at $workflow"; exit 1; }
[ -f "$dockerfile" ] || { echo "  FAIL: Dockerfile not found at $dockerfile"; exit 1; }

# Extract one event's `paths:` list. Deliberately not a YAML parse: PyYAML is
# not stdlib, and this file's shape is fixed (two-space event indent, four-space
# key, six-space list items). Comment lines inside the block are skipped.
extract_paths() {
    local event="$1"
    awk -v event="  ${event}:" '
        $0 == event { in_event = 1; next }
        in_event && /^  [a-z_]+:/ { in_event = 0 }
        in_event && /^    paths:/ { in_paths = 1; next }
        in_paths && /^      #/ { next }
        in_paths && /^      - / { sub(/^      - /, ""); gsub(/^'"'"'|'"'"'$/, ""); print; next }
        in_paths { in_paths = 0 }
    ' "$workflow"
}

mapfile -t push_paths < <(extract_paths push)
mapfile -t pr_paths < <(extract_paths pull_request)

assert_true "the push paths list was found" test "${#push_paths[@]}" -gt 0
assert_true "the pull_request paths list was found" test "${#pr_paths[@]}" -gt 0

# The two lists must stay identical. A path added to push but not pull_request
# means the tail build runs only after merge, which is the wrong end.
assert_eq "push and pull_request trigger on the same paths" \
    "$(printf '%s\n' "${push_paths[@]}")" "$(printf '%s\n' "${pr_paths[@]}")"

# Covered = listed literally, or matched by a `dir/**` entry, and not negated by
# a `!path` exclusion.
covered() {
    local needle="$1" entry
    for entry in "${push_paths[@]}"; do
        [ "$entry" = "!$needle" ] && return 1
    done
    for entry in "${push_paths[@]}"; do
        [ "$entry" = "$needle" ] && return 0
        case "$entry" in
            *'/**') [ "${needle##"${entry%'/**'}"/}" != "$needle" ] && return 0 ;;
        esac
    done
    return 1
}

# Source paths COPYd from the default context (skip `--from=`). Every argument
# but the last is a source.
mapfile -t copy_lines < <(grep -P '^COPY (?!--from=)' "$dockerfile" || true)
assert_true "found default-context COPYs in Dockerfile.nix-default" \
    test "${#copy_lines[@]}" -gt 0

for line in "${copy_lines[@]}"; do
    # shellcheck disable=SC2086 # deliberate word splitting of the COPY argv
    set -- $line
    shift          # drop "COPY"
    argc=$#
    n=1
    while [ "$n" -lt "$argc" ]; do
        src="$1"
        shift
        n=$((n + 1))
        if covered "$src"; then
            _pass "$src is a trigger path"
        else
            _fail "$src is a trigger path" \
                "Dockerfile.nix-default COPYs $src from the default context," \
                "but nix-base.yml's paths do not match it — a change to that" \
                "file skips the tail build that exists to verify it."
        fi
    done
done

# The --from=project COPYs read ./defaults in CI, so that entry is load-bearing
# even though no repo-root COPY names it.
assert_true "defaults/** covers the --from=project build context" covered "defaults/x"

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
