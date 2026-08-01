#!/usr/bin/env bash
# Tests for devcontainer bump-hadolint — version resolution, the coupled
# HADOLINT_VERSION / HADOLINT_SHA256_AMD64 / HADOLINT_SHA256_ARM64 rewrite in
# projects/devcontainer/install-system.sh, the paired .pre-commit-config.yaml
# hook rev, and argument handling.
#
# The gap this tool exists to close: those four values were coupled by nothing.
# tests/test-lint-config-sync.sh compares the two VERSIONS, so a hand bump that
# updated HADOLINT_VERSION, the pre-commit rev and the amd64 sha stayed green
# while leaving a stale ARM64 sha that breaks the arm64 container build at
# `sha256sum -c`. A hermetic test cannot verify a checksum (that needs the real
# artifact), so the coupling is enforced by the tool — and this suite is what
# guards the tool.
#
# The script targets install-system.sh and .pre-commit-config.yaml relative to
# its own path, so we run a copy from a disposable sandbox and stub `curl` on
# PATH — no real file is touched and no network is required. The curl stub
# serves both endpoints the script hits: the GitHub releases API (latest
# version) and the release-download URLs (deterministic per-URL content, so the
# expected sha256 is computable in the test).
set -euo pipefail

# --- inlined test harness ---------------------------------------------------
# Self-contained, like tests/test-bump-nix.sh: inlines only the helpers it uses
# (PASS/FAIL accounting, the assert helpers it calls, temp-dir cleanup, finish)
# so it runs standalone with no harness dependency.
PASS=0 FAIL=0
_cleanup_dirs=()

cleanup() {
    for d in "${_cleanup_dirs[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

_pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

_fail() {
    echo "  FAIL: $1"
    shift
    local line
    for line in "$@"; do
        echo "    $line"
    done
    FAIL=$((FAIL + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$label"
    else
        _fail "$label" "expected: $expected" "actual:   $actual"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label" "expected to contain: $needle" "got: $haystack"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label" "expected NOT to contain: $needle" "got: $haystack"
    fi
}

# assert_true "label" <command...> — asserts the command exits 0.
assert_true() {
    local label="$1"
    shift
    if "$@"; then
        _pass "$label"
    else
        _fail "$label" "command failed: $*"
    fi
}

finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] || exit 1
}
# --- end inlined test harness -----------------------------------------------

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SRC="$DEV_BASE/dev/bump-hadolint"

# ---------- setup: disposable sandbox ----------
SANDBOX="$(mktemp -d)"
_cleanup_dirs+=("$SANDBOX")
mkdir -p "$SANDBOX/dev" "$SANDBOX/projects/devcontainer" \
    "$SANDBOX/bin" "$SANDBOX/bin-badnet" "$SANDBOX/bin-empty" "$SANDBOX/bin-noarm"
cp "$SRC" "$SANDBOX/dev/bump-hadolint"
BUMP="$SANDBOX/dev/bump-hadolint"
INSTALL_SYS="$SANDBOX/projects/devcontainer/install-system.sh"
PRECOMMIT="$SANDBOX/.pre-commit-config.yaml"

cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; prev=""; continue; fi
    case "$a" in
        -o) prev="-o" ;;
        http*) url="$a" ;;
    esac
done
case "$url" in
    *api.github.com*) printf '{"tag_name":"v9.9.9"}\n' ;;
    *github.com/hadolint/hadolint/releases/download/*)
        content="fake hadolint binary for $url"
        if [ -n "$out" ]; then printf '%s\n' "$content" > "$out"; else printf '%s\n' "$content"; fi
        ;;
    *) exit 22 ;;
esac
EOF
# API reachable but every binary download fails — the bump must abort without
# writing any of the coupled values.
cat > "$SANDBOX/bin-badnet/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
    *api.github.com*) printf '{"tag_name":"v9.9.9"}\n' ;;
    *) exit 22 ;;
esac
EOF
# Downloads "succeed" but produce an empty artifact (a 404 page served as an
# empty body, a truncated transfer). Hashing that would commit a valid-looking
# checksum for a file nobody can install.
cat > "$SANDBOX/bin-empty/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; prev=""; continue; fi
    case "$a" in
        -o) prev="-o" ;;
        http*) url="$a" ;;
    esac
done
case "$url" in
    *api.github.com*) printf '{"tag_name":"v9.9.9"}\n' ;;
    *github.com/hadolint/hadolint/releases/download/*)
        [ -n "$out" ] && : > "$out"
        ;;
    *) exit 22 ;;
esac
exit 0
EOF
# amd64 downloads fine, arm64 does not. This is the exact shape of the bug the
# tool exists to prevent: half the checksums resolvable must write NOTHING.
cat > "$SANDBOX/bin-noarm/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; prev=""; continue; fi
    case "$a" in
        -o) prev="-o" ;;
        http*) url="$a" ;;
    esac
done
case "$url" in
    *api.github.com*) printf '{"tag_name":"v9.9.9"}\n' ;;
    *hadolint-Linux-x86_64)
        content="fake hadolint binary for $url"
        if [ -n "$out" ]; then printf '%s\n' "$content" > "$out"; else printf '%s\n' "$content"; fi
        ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin-badnet/curl" \
    "$SANDBOX/bin-empty/curl" "$SANDBOX/bin-noarm/curl"

# Expected sha for (version, asset) = sha of the stub's deterministic content.
expected_sha() {
    printf 'fake hadolint binary for %s\n' \
        "https://github.com/hadolint/hadolint/releases/download/v$1/hadolint-Linux-$2" \
        | sha256sum | cut -d' ' -f1
}

# write_install_sys <version> <amd64-sha> <arm64-sha>
write_install_sys() {
    cat > "$INSTALL_SYS" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# hadolint (Dockerfile linter)
HADOLINT_VERSION=$1
HADOLINT_SHA256_AMD64=$2
HADOLINT_SHA256_ARM64=$3
RUFF_VERSION=0.15.14
EOF
}

# write_precommit <hadolint-rev>
write_precommit() {
    cat > "$PRECOMMIT" <<EOF
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.15.14
    hooks:
      - id: ruff

  - repo: https://github.com/AleksaC/hadolint-py
    rev: v$1
    hooks:
      - id: hadolint
EOF
}

# Read back through the same anchors tests/test-lint-config-sync.sh uses.
pin_version() { grep -m1 -oP '^HADOLINT_VERSION=\K\S+' "$INSTALL_SYS" || true; }
pin_amd64() { grep -m1 -oP '^HADOLINT_SHA256_AMD64=\K[0-9a-f]{64}' "$INSTALL_SYS" || true; }
pin_arm64() { grep -m1 -oP '^HADOLINT_SHA256_ARM64=\K[0-9a-f]{64}' "$INSTALL_SYS" || true; }
pc_rev() {
    awk -v repo="${2:-hadolint-py}" '
        $0 ~ "repo: .*" repo "$" { want = 1; next }
        want && /rev:/ { sub(/^.*rev:[[:space:]]*v?/, ""); print; exit }
    ' "${1:-$PRECOMMIT}"
}

OLD_AMD64="1111111111111111111111111111111111111111111111111111111111111111"
OLD_ARM64="2222222222222222222222222222222222222222222222222222222222222222"

# Run the script with a given curl stub on PATH, capturing output and exit code
# without tripping `set -e`. Results land in the globals `out` and `rc`.
run_with() {
    local stub="$1"
    shift
    set +e
    out="$(PATH="$SANDBOX/$stub:$PATH" "$BUMP" "$@" 2>&1)"
    rc=$?
    set -e
}
run_bump() { run_with bin "$@"; }

# Reset both files to the same known drifted state: version 1.0.0 everywhere,
# both shas stale.
reset_files() {
    write_install_sys "1.0.0" "$OLD_AMD64" "$OLD_ARM64"
    write_precommit "1.0.0"
}

# ---------- test: default bump to latest release ----------
echo "--- bump-hadolint (default: latest release) ---"
reset_files
run_bump
assert_eq "exit 0" "0" "$rc"
assert_contains "reports the bump" "1.0.0 → 9.9.9" "$out"
assert_eq "version pin updated" "9.9.9" "$(pin_version)"
assert_eq "amd64 sha updated in lockstep" "$(expected_sha 9.9.9 x86_64)" "$(pin_amd64)"
assert_eq "arm64 sha updated in lockstep" "$(expected_sha 9.9.9 arm64)" "$(pin_arm64)"
assert_eq "pre-commit hadolint rev updated" "9.9.9" "$(pc_rev)"
assert_eq "pre-commit ruff rev untouched" "0.15.14" "$(pc_rev "$PRECOMMIT" ruff-pre-commit)"

# ---------- test: explicit version ----------
echo "--- bump-hadolint (explicit version) ---"
reset_files
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_eq "version pin set to explicit version" "2.5.0" "$(pin_version)"
assert_eq "amd64 sha matches the explicit version" "$(expected_sha 2.5.0 x86_64)" "$(pin_amd64)"
assert_eq "arm64 sha matches the explicit version" "$(expected_sha 2.5.0 arm64)" "$(pin_arm64)"
assert_eq "pre-commit rev set to explicit version" "2.5.0" "$(pc_rev)"

# ---------- test: leading 'v' on explicit version is stripped ----------
echo "--- bump-hadolint (leading v stripped) ---"
reset_files
run_bump "v2.6.1"
assert_eq "exit 0" "0" "$rc"
assert_eq "leading v stripped from the version pin" "2.6.1" "$(pin_version)"
assert_eq "pre-commit rev carries exactly one v" "2.6.1" "$(pc_rev)"
assert_contains "pre-commit line written as v-prefixed" "rev: v2.6.1" "$(cat "$PRECOMMIT")"

# ---------- test: a stale ARM64 sha alone is repaired ----------
# The headline gap: version and amd64 sha correct, arm64 sha stale. Nothing in
# the tree caught this before; a plain run must fix it.
echo "--- bump-hadolint (stale arm64 sha only) ---"
write_install_sys "9.9.9" "$(expected_sha 9.9.9 x86_64)" "$OLD_ARM64"
write_precommit "9.9.9"
run_bump
assert_eq "exit 0" "0" "$rc"
assert_contains "reports a checksum refresh, not a version bump" "refreshed the per-arch checksums" "$out"
assert_eq "version left alone" "9.9.9" "$(pin_version)"
assert_eq "amd64 sha left alone" "$(expected_sha 9.9.9 x86_64)" "$(pin_amd64)"
assert_eq "stale arm64 sha repaired" "$(expected_sha 9.9.9 arm64)" "$(pin_arm64)"

# ---------- test: a drifted pre-commit rev alone is repaired ----------
echo "--- bump-hadolint (pre-commit rev drift only) ---"
write_install_sys "9.9.9" "$(expected_sha 9.9.9 x86_64)" "$(expected_sha 9.9.9 arm64)"
write_precommit "1.0.0"
run_bump
assert_eq "exit 0" "0" "$rc"
assert_contains "reports the hook rev bump" "pre-commit hadolint hook: v1.0.0 → v9.9.9" "$out"
assert_eq "pre-commit rev repaired" "9.9.9" "$(pc_rev)"
assert_eq "version still correct" "9.9.9" "$(pin_version)"

# ---------- test: failed download writes nothing ----------
echo "--- bump-hadolint (binary download fails) ---"
reset_files
run_with bin-badnet "2.9.9"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports the failed download" "could not download" "$out"
assert_eq "version pin untouched" "1.0.0" "$(pin_version)"
assert_eq "amd64 sha untouched" "$OLD_AMD64" "$(pin_amd64)"
assert_eq "arm64 sha untouched" "$OLD_ARM64" "$(pin_arm64)"
assert_eq "pre-commit rev untouched" "1.0.0" "$(pc_rev)"

# ---------- test: only the amd64 artifact resolves — still writes nothing ----
# Half the pair is exactly the state the tool exists to make unrepresentable.
echo "--- bump-hadolint (arm64 artifact missing) ---"
reset_files
run_with bin-noarm "2.9.9"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "names the arm64 asset in the error" "hadolint-Linux-arm64" "$out"
assert_eq "version pin untouched" "1.0.0" "$(pin_version)"
assert_eq "amd64 sha NOT written despite resolving" "$OLD_AMD64" "$(pin_amd64)"
assert_eq "arm64 sha untouched" "$OLD_ARM64" "$(pin_arm64)"
assert_eq "pre-commit rev untouched" "1.0.0" "$(pc_rev)"

# ---------- test: an empty artifact is a checksum failure, not a checksum ----
echo "--- bump-hadolint (empty artifact) ---"
reset_files
run_with bin-empty "2.9.9"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports the empty artifact" "it is empty" "$out"
assert_eq "version pin untouched" "1.0.0" "$(pin_version)"
assert_eq "amd64 sha untouched" "$OLD_AMD64" "$(pin_amd64)"
assert_eq "arm64 sha untouched" "$OLD_ARM64" "$(pin_arm64)"

# ---------- test: idempotent (explicit, already fully in sync) ----------
echo "--- bump-hadolint (idempotent explicit) ---"
write_install_sys "2.5.0" "$(expected_sha 2.5.0 x86_64)" "$(expected_sha 2.5.0 arm64)"
write_precommit "2.5.0"
before="$(cat "$INSTALL_SYS")"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_contains "reports already pinned" "already pinned to 2.5.0" "$out"
assert_eq "install-system.sh unchanged" "$before" "$(cat "$INSTALL_SYS")"

# ---------- test: --check reports drift and exits non-zero ----------
echo "--- bump-hadolint (--check drift) ---"
reset_files
run_bump --check
assert_eq "exit nonzero on drift" "1" "$rc"
assert_contains "shows current" "$(printf '%-14s%s' 'current:' '1.0.0')" "$out"
assert_contains "shows latest" "$(printf '%-14s%s' 'latest:' '9.9.9')" "$out"
assert_contains "names the version drift" "drift: HADOLINT_VERSION" "$out"
assert_contains "names the amd64 sha drift" "drift: HADOLINT_SHA256_AMD64" "$out"
assert_contains "names the arm64 sha drift" "drift: HADOLINT_SHA256_ARM64" "$out"
assert_eq "version not edited" "1.0.0" "$(pin_version)"
assert_eq "amd64 sha not edited" "$OLD_AMD64" "$(pin_amd64)"
assert_eq "arm64 sha not edited" "$OLD_ARM64" "$(pin_arm64)"
assert_eq "pre-commit rev not edited" "1.0.0" "$(pc_rev)"

# ---------- test: --check catches an arm64-only drift ----------
# The case with no guard anywhere before this tool existed.
echo "--- bump-hadolint (--check arm64-only drift) ---"
write_install_sys "9.9.9" "$(expected_sha 9.9.9 x86_64)" "$OLD_ARM64"
write_precommit "9.9.9"
run_bump --check
assert_eq "exit nonzero" "1" "$rc"
assert_contains "names the arm64 sha drift" "drift: HADOLINT_SHA256_ARM64" "$out"
assert_not_contains "does not claim version drift" "drift: HADOLINT_VERSION" "$out"
assert_eq "arm64 sha not edited" "$OLD_ARM64" "$(pin_arm64)"

# ---------- test: --check catches a pre-commit rev drift ----------
echo "--- bump-hadolint (--check pre-commit drift) ---"
write_install_sys "9.9.9" "$(expected_sha 9.9.9 x86_64)" "$(expected_sha 9.9.9 arm64)"
write_precommit "1.0.0"
run_bump --check
assert_eq "exit nonzero" "1" "$rc"
assert_contains "names the pre-commit drift" "drift: .pre-commit-config.yaml hadolint rev" "$out"
assert_eq "pre-commit rev not edited" "1.0.0" "$(pc_rev)"

# ---------- test: --check is quiet and zero when fully in sync ----------
echo "--- bump-hadolint (--check in sync) ---"
write_install_sys "9.9.9" "$(expected_sha 9.9.9 x86_64)" "$(expected_sha 9.9.9 arm64)"
write_precommit "9.9.9"
before="$(cat "$INSTALL_SYS")"
run_bump --check
assert_eq "exit 0" "0" "$rc"
assert_contains "notes up to date" "already up to date" "$out"
assert_not_contains "reports no drift" "drift:" "$out"
assert_eq "install-system.sh unchanged" "$before" "$(cat "$INSTALL_SYS")"

# ---------- test: --check with explicit target labels it 'requested' ----------
echo "--- bump-hadolint (--check explicit) ---"
reset_files
run_bump "3.0.0" --check
assert_eq "exit nonzero on drift" "1" "$rc"
assert_contains "labels the target as requested" "$(printf '%-14s%s' 'requested:' '3.0.0')" "$out"
assert_eq "version not edited" "1.0.0" "$(pin_version)"

# ---------- test: invalid explicit version rejected ----------
echo "--- bump-hadolint (invalid version) ---"
reset_files
run_bump "not-a-version"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports invalid version" "invalid version" "$out"
assert_eq "version untouched" "1.0.0" "$(pin_version)"

# ---------- test: sed-delimiter injection attempt rejected ----------
echo "--- bump-hadolint (sed injection guard) ---"
reset_files
run_bump '1.2|3'
assert_eq "exit nonzero" "1" "$rc"
assert_contains "rejects delimiter in version" "invalid version" "$out"
assert_eq "version untouched" "1.0.0" "$(pin_version)"

# ---------- test: unknown flag ----------
echo "--- bump-hadolint (unknown flag) ---"
reset_files
run_bump --bogus
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports unknown flag" "unknown flag" "$out"

# ---------- test: extra positional argument ----------
echo "--- bump-hadolint (extra argument) ---"
reset_files
run_bump "1.2.3" "4.5.6"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports extra argument" "unexpected extra argument" "$out"

# ---------- test: a missing anchor fails loudly, it does not no-op ----------
# Each of the four anchors is shared with tests/test-lint-config-sync.sh. If a
# reformat moves one, the tool must refuse rather than "succeed" having changed
# nothing (or worse, changed only the values it could still find).
echo "--- bump-hadolint (missing anchors) ---"
reset_files
sed -i 's/^HADOLINT_VERSION=/# HADOLINT_VERSION=/' "$INSTALL_SYS"
run_bump "2.0.0"
assert_eq "exit nonzero (no version anchor)" "1" "$rc"
assert_contains "reports the missing version anchor" "could not find 'HADOLINT_VERSION='" "$out"

reset_files
sed -i 's/^HADOLINT_SHA256_ARM64=.*/HADOLINT_SHA256_ARM64="see the release notes"/' "$INSTALL_SYS"
run_bump "2.0.0"
assert_eq "exit nonzero (no arm64 sha anchor)" "1" "$rc"
assert_contains "reports the missing arm64 anchor" "HADOLINT_SHA256_ARM64" "$out"
assert_eq "version untouched" "1.0.0" "$(pin_version)"

reset_files
sed -i 's/^HADOLINT_SHA256_AMD64=.*/HADOLINT_SHA256_AMD64=/' "$INSTALL_SYS"
run_bump "2.0.0"
assert_eq "exit nonzero (empty amd64 sha)" "1" "$rc"
assert_contains "reports the missing amd64 anchor" "HADOLINT_SHA256_AMD64" "$out"

reset_files
sed -i 's|AleksaC/hadolint-py|AleksaC/hadolint-relocated|' "$PRECOMMIT"
run_bump "2.0.0"
assert_eq "exit nonzero (no hadolint hook)" "1" "$rc"
assert_contains "reports the missing hook rev anchor" "could not find the hadolint-py hook rev" "$out"
assert_eq "version untouched" "1.0.0" "$(pin_version)"

# ---------- test: the real tree's pins are parseable by this tool ----------
# Guards the anchor contract between dev/bump-hadolint,
# projects/devcontainer/install-system.sh and .pre-commit-config.yaml without
# network: if any assignment shape changes in the real files, this catches it.
echo "--- bump-hadolint (real tree parseable) ---"
real_install="$DEV_BASE/projects/devcontainer/install-system.sh"
real_precommit="$DEV_BASE/.pre-commit-config.yaml"
real_version="$(grep -m1 -oP '^HADOLINT_VERSION=\K\S+' "$real_install" || true)"
real_amd64="$(grep -m1 -oP '^HADOLINT_SHA256_AMD64=\K[0-9a-f]{64}' "$real_install" || true)"
real_arm64="$(grep -m1 -oP '^HADOLINT_SHA256_ARM64=\K[0-9a-f]{64}' "$real_install" || true)"
real_rev="$(pc_rev "$real_precommit")"
assert_true "real HADOLINT_VERSION parseable" test -n "$real_version"
assert_true "real HADOLINT_SHA256_AMD64 parseable" test -n "$real_amd64"
assert_true "real HADOLINT_SHA256_ARM64 parseable" test -n "$real_arm64"
assert_true "real pre-commit hadolint rev parseable" test -n "$real_rev"
assert_eq "the two real arch shas differ (not a copy-paste of one)" "1" \
    "$([ "$real_amd64" != "$real_arm64" ] && echo 1 || echo 0)"
assert_eq "real pre-commit rev == real HADOLINT_VERSION" "$real_version" "$real_rev"

finish
