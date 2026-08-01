#!/usr/bin/env bash
# Guard: every lib/ file a Dockerfile COPYs from the default build context
# must be re-included in .dockerignore. BOTH Dockerfiles are checked — the nix
# route (nix/base/Dockerfile.nix-default) builds from the same repo-root
# context under the same .dockerignore.
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
dockerignore="$DEV_BASE/.dockerignore"

echo "--- .dockerignore lib/ allowlist covers Dockerfile COPYs ---"

[ -f "$dockerignore" ] || { echo "  FAIL: .dockerignore not found at $dockerignore"; exit 1; }

for dockerfile in "$DEV_BASE/Dockerfile" "$DEV_BASE/nix/base/Dockerfile.nix-default"; do
    df_name="${dockerfile#"$DEV_BASE/"}"
    [ -f "$dockerfile" ] || { echo "  FAIL: Dockerfile not found at $dockerfile"; exit 1; }

    # Source paths of lib/ files COPYd from the default context (skip `--from=`).
    mapfile -t copied < <(grep -oP '^COPY (?!--from=)\Klib/\S+' "$dockerfile" || true)

    if [ "${#copied[@]}" -eq 0 ]; then
        _fail "found lib/ COPYs in $df_name" "none matched — anchor missed? file moved?"
        continue
    fi

    for src in "${copied[@]}"; do
        if grep -qxF "!$src" "$dockerignore"; then
            _pass "$df_name: $src allowlisted in .dockerignore"
        else
            _fail "$df_name: $src allowlisted in .dockerignore" \
                "$df_name COPYs $src but .dockerignore has no '!$src' line;" \
                "the file is excluded from the build context and COPY will fail."
        fi
    done
done

echo ""
finish
