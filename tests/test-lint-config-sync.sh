#!/usr/bin/env bash
# Guard: the linter-pin convention holds across its three committed sources.
#
# CLAUDE.md declares the pairing and the files carry "keep in sync" comments,
# but nothing asserted the *real* committed values match — a hand bump to one
# file would ship drift undetected (host pre-commit, in-container linters, and
# CI would silently disagree). This test asserts the invariants directly on
# the tree:
#
#   ruff:     .pre-commit-config.yaml rev  == install-system.sh RUFF_VERSION
#             == lint.yml ruff-action `version:` input (two invocations,
#             which must also agree with each other)
#   yamllint: .pre-commit-config.yaml rev  == install-system.sh YAMLLINT_VERSION
#             == lint.yml `pip install yamllint==<v>`
#   hadolint: .pre-commit-config.yaml rev  == install-system.sh HADOLINT_VERSION
#             == lint.yml release-URL version; and the lint.yml sha256 must
#             equal install-system.sh HADOLINT_SHA256_AMD64 (CI runs amd64)
#
# Plus the extensionless-shellcheck file list: the dev/ scripts enumerated in
# .pre-commit-config.yaml (`files: ^dev/(...)$`) must equal the paths listed
# in lint.yml's "extensionless" step, compared as sets.
#
# The `v` prefix pre-commit revs carry is normalized away. Every extraction is
# guarded: an empty match (anchor missed, file reformatted) fails loudly.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

# The harness has no bare non-empty asserter; this guard leans on it to prove
# the grep anchors still match (an empty capture means the anchor missed).
assert_nonempty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        _pass "$label"
    else
        _fail "$label" "empty — anchor missed? file moved?"
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
precommit="$DEV_BASE/.pre-commit-config.yaml"
install_sys="$DEV_BASE/projects/devcontainer/install-system.sh"
lint_yml="$DEV_BASE/.github/workflows/lint.yml"

echo "--- linter pin + shellcheck-list sync (committed files) ---"

for f in "$precommit" "$install_sys" "$lint_yml"; do
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

# install-system.sh: the VERSION= assignments (and the amd64 hadolint sha).
is_ruff="$(grep -m1 -oP '^RUFF_VERSION=\K\S+' "$install_sys" || true)"
is_yamllint="$(grep -m1 -oP '^YAMLLINT_VERSION=\K\S+' "$install_sys" || true)"
is_hadolint="$(grep -m1 -oP '^HADOLINT_VERSION=\K\S+' "$install_sys" || true)"
is_hadolint_sha="$(grep -m1 -oP '^HADOLINT_SHA256_AMD64=\K[0-9a-f]{64}' "$install_sys" || true)"
assert_nonempty "install-system.sh RUFF_VERSION found" "$is_ruff"
assert_nonempty "install-system.sh YAMLLINT_VERSION found" "$is_yamllint"
assert_nonempty "install-system.sh HADOLINT_VERSION found" "$is_hadolint"
assert_nonempty "install-system.sh HADOLINT_SHA256_AMD64 found" "$is_hadolint_sha"

# lint.yml: ruff is pinned via the ruff-action `version:` input (two
# invocations — check and format), yamllint via pip==, hadolint via the
# pinned release URL + sha256 of the direct binary download.
mapfile -t ci_ruff_pins < <(grep -A2 'uses: astral-sh/ruff-action' "$lint_yml" \
    | grep -oP 'version:\s*"\K[^"]+' || true)
assert_eq "lint.yml has two ruff-action version pins" "2" "${#ci_ruff_pins[@]}"
ci_ruff="${ci_ruff_pins[0]:-}"
assert_nonempty "lint.yml ruff version pin found" "$ci_ruff"
assert_eq "lint.yml ruff-action pins agree with each other" \
    "$ci_ruff" "${ci_ruff_pins[1]:-}"

ci_yamllint="$(grep -m1 -oP 'pip install yamllint==\K[0-9.]+' "$lint_yml" || true)"
ci_hadolint="$(grep -m1 -oP 'hadolint/releases/download/v\K[0-9.]+' "$lint_yml" || true)"
ci_hadolint_sha="$(grep -m1 -oP '[0-9a-f]{64}(?=\s+/usr/local/bin/hadolint)' "$lint_yml" || true)"
assert_nonempty "lint.yml yamllint pip pin found" "$ci_yamllint"
assert_nonempty "lint.yml hadolint release-URL version found" "$ci_hadolint"
assert_nonempty "lint.yml hadolint sha256 found" "$ci_hadolint_sha"

assert_eq "ruff: pre-commit == install-system.sh" "$pc_ruff" "$is_ruff"
assert_eq "ruff: pre-commit == lint.yml" "$pc_ruff" "$ci_ruff"
assert_eq "yamllint: pre-commit == install-system.sh" "$pc_yamllint" "$is_yamllint"
assert_eq "yamllint: pre-commit == lint.yml" "$pc_yamllint" "$ci_yamllint"
assert_eq "hadolint: pre-commit == install-system.sh" "$pc_hadolint" "$is_hadolint"
assert_eq "hadolint: pre-commit == lint.yml" "$pc_hadolint" "$ci_hadolint"
assert_eq "hadolint sha256: install-system.sh amd64 == lint.yml" \
    "$is_hadolint_sha" "$ci_hadolint_sha"

# Extensionless shellcheck list: the alternation inside the pre-commit
# `files: ^dev/(a|b|...)$` regex vs the dev/ paths in lint.yml's
# "extensionless" step (the only lines in the workflow that begin with dev/).
pc_scripts="$(grep -m1 -oP '^\s*files:\s*\^dev/\(\K[^)]+' "$precommit" \
    | tr '|' '\n' | sed 's|^|dev/|' | sort || true)"
ci_scripts="$(grep -oP '^\s+\Kdev/[A-Za-z0-9._/-]+' "$lint_yml" | sort || true)"
assert_nonempty "pre-commit extensionless files regex found" "$pc_scripts"
assert_nonempty "lint.yml extensionless script list found" "$ci_scripts"
assert_eq "extensionless shellcheck lists agree (as sets)" \
    "$pc_scripts" "$ci_scripts"

echo ""
echo "ruff: $pc_ruff    yamllint: $pc_yamllint    hadolint: $pc_hadolint"
finish
