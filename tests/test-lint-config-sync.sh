#!/usr/bin/env bash
# Guard: the linter-pin convention holds across its two committed sources.
#
# CLAUDE.md declares the pairing and the files carry "keep in sync" comments,
# but nothing asserted the *real* committed values match — a hand bump to one
# file would ship drift undetected (host/CI pre-commit and the in-container
# linters would silently disagree). This test asserts the invariants directly
# on the tree:
#
#   ruff:     .pre-commit-config.yaml rev == install-system.sh RUFF_VERSION
#   yamllint: .pre-commit-config.yaml rev == install-system.sh YAMLLINT_VERSION
#   hadolint: .pre-commit-config.yaml rev == install-system.sh HADOLINT_VERSION
#
# It used to be a three-way sync including .github/workflows/lint.yml, which
# ran the same four linters at a separately hand-maintained set of versions.
# That workflow now has a single `pre-commit run --all-files` job, so CI takes
# its versions from .pre-commit-config.yaml and has no pins of its own — the
# lint.yml assertions (and the extensionless-shellcheck list comparison, whose
# other half was the deleted shellcheck job) went with them.
#
# The `v` prefix pre-commit revs carry is normalized away. Every extraction is
# guarded: an empty match (anchor missed, file reformatted) fails loudly.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
precommit="$DEV_BASE/.pre-commit-config.yaml"
install_sys="$DEV_BASE/projects/devcontainer/install-system.sh"

echo "--- linter pin sync (committed files) ---"

for f in "$precommit" "$install_sys"; do
    [ -f "$f" ] || { echo "  FAIL: $f not found"; exit 1; }
done

# pre-commit: the rev on the line after each hook repo's `repo:` line, v-stripped.
precommit_rev() {
    awk -v repo="$1" '
        $0 ~ "repo: .*" repo "$" { want = 1; next }
        want && /rev:/ { sub(/^.*rev:[[:space:]]*v?/, ""); print; exit }
    ' "$precommit"
}
pc_ruff="$(precommit_rev ruff-pre-commit)"
pc_yamllint="$(precommit_rev adrienverge/yamllint)"
pc_hadolint="$(precommit_rev hadolint-py)"
assert_nonempty "pre-commit ruff rev found" "$pc_ruff"
assert_nonempty "pre-commit yamllint rev found" "$pc_yamllint"
assert_nonempty "pre-commit hadolint rev found" "$pc_hadolint"

# install-system.sh: the VERSION= assignments, plus BOTH hadolint per-arch
# shas. A checksum has no committed counterpart to compare against — verifying
# one means fetching the release artifact, which no hermetic test may do — so
# the coupling to HADOLINT_VERSION lives in dev/bump-hadolint, which rewrites
# all three together. What is cheap and worth asserting here is that the values
# the bump tool anchors on are all still present and well-formed, and that the
# two arch shas are not the same string (a copy-paste of the amd64 sha into the
# arm64 slot reads fine and breaks the arm64 build at `sha256sum -c`).
is_ruff="$(grep -m1 -oP '^RUFF_VERSION=\K\S+' "$install_sys" || true)"
is_yamllint="$(grep -m1 -oP '^YAMLLINT_VERSION=\K\S+' "$install_sys" || true)"
is_hadolint="$(grep -m1 -oP '^HADOLINT_VERSION=\K\S+' "$install_sys" || true)"
is_hadolint_amd64="$(grep -m1 -oP '^HADOLINT_SHA256_AMD64=\K[0-9a-f]{64}' "$install_sys" || true)"
is_hadolint_arm64="$(grep -m1 -oP '^HADOLINT_SHA256_ARM64=\K[0-9a-f]{64}' "$install_sys" || true)"
assert_nonempty "install-system.sh RUFF_VERSION found" "$is_ruff"
assert_nonempty "install-system.sh YAMLLINT_VERSION found" "$is_yamllint"
assert_nonempty "install-system.sh HADOLINT_VERSION found" "$is_hadolint"
assert_nonempty "install-system.sh HADOLINT_SHA256_AMD64 found" "$is_hadolint_amd64"
assert_nonempty "install-system.sh HADOLINT_SHA256_ARM64 found" "$is_hadolint_arm64"
assert_false "hadolint per-arch shas are distinct" \
    test "$is_hadolint_amd64" = "$is_hadolint_arm64"

# Both shas are consumed by the `case "$arch"` dispatch a few lines below them;
# a variable renamed on one side only would leave the install unpinned.
assert_true "install-system.sh uses HADOLINT_SHA256_AMD64" \
    grep -q 'hadolint_sha=\$HADOLINT_SHA256_AMD64' "$install_sys"
assert_true "install-system.sh uses HADOLINT_SHA256_ARM64" \
    grep -q 'hadolint_sha=\$HADOLINT_SHA256_ARM64' "$install_sys"

assert_eq "ruff: pre-commit == install-system.sh" "$pc_ruff" "$is_ruff"
assert_eq "yamllint: pre-commit == install-system.sh" "$pc_yamllint" "$is_yamllint"
assert_eq "hadolint: pre-commit == install-system.sh" "$pc_hadolint" "$is_hadolint"
echo ""
echo "ruff: $pc_ruff    yamllint: $pc_yamllint    hadolint: $pc_hadolint"
finish
