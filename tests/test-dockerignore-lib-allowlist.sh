#!/usr/bin/env bash
# Guard: every lib/ file the Dockerfile COPYs from the default build context
# must be re-included in .dockerignore.
#
# .dockerignore denies the whole lib/ tree and then re-includes an allowlist:
#
#   lib/
#   !lib/git.sh
#   !lib/nix-seed.sh
#   ...
#
# A new `COPY lib/foo.sh ...` without a matching `!lib/foo.sh` leaves the file
# out of the build context, so the COPY fails with "not found" (as happened for
# lib/claude-code-token-env.sh). This test asserts the invariant directly on the
# committed tree so the drift is caught at commit/CI time, not at image build.
#
# Only default-context COPYs are checked: `COPY --from=<ctx> ...` pulls from a
# named additional context, which .dockerignore does not gate.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
dockerfile="$DEV_BASE/Dockerfile"
dockerignore="$DEV_BASE/.dockerignore"

echo "--- .dockerignore lib/ allowlist covers Dockerfile COPYs ---"

[ -f "$dockerfile" ] || { echo "  FAIL: Dockerfile not found at $dockerfile"; exit 1; }
[ -f "$dockerignore" ] || { echo "  FAIL: .dockerignore not found at $dockerignore"; exit 1; }

# Source paths of lib/ files COPYd from the default context (skip `--from=`).
mapfile -t copied < <(grep -oP '^COPY (?!--from=)\Klib/\S+' "$dockerfile" || true)

if [ "${#copied[@]}" -eq 0 ]; then
    _fail "found lib/ COPYs in Dockerfile" "none matched — anchor missed? file moved?"
    finish
fi

for src in "${copied[@]}"; do
    if grep -qxF "!$src" "$dockerignore"; then
        _pass "$src allowlisted in .dockerignore"
    else
        _fail "$src allowlisted in .dockerignore" \
            "Dockerfile COPYs $src but .dockerignore has no '!$src' line;" \
            "the file is excluded from the build context and COPY will fail."
    fi
done

echo ""
finish
