#!/usr/bin/env bash
# Tests for devcontainer bump-nix — version resolution, the coupled
# NIX_VERSION/NIX_INSTALLER_SHA256 rewrite in lib/nix-seed.sh, and argument
# handling.
#
# The script targets lib/nix-seed.sh one level up from its own path, so we run
# a copy from a disposable sandbox and stub `curl` on PATH — no real file is
# touched and no network is required. The curl stub serves both endpoints the
# script hits: the GitHub releases API (latest version) and
# releases.nixos.org (installer download, deterministic per-URL content so the
# expected sha256 is computable in the test).
set -euo pipefail

# --- inlined test harness ---------------------------------------------------
# This suite is intentionally self-contained: rather than sourcing the shared
# tests/lib/harness.sh, it inlines only the helpers it uses (PASS/FAIL
# accounting, the assert helpers it calls, temp-dir cleanup, and finish) so it
# runs standalone with no harness dependency.
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
SRC="$DEV_BASE/dev/bump-nix"

# ---------- setup: disposable sandbox ----------
SANDBOX="$(mktemp -d)"
_cleanup_dirs+=("$SANDBOX")
mkdir -p "$SANDBOX/dev" "$SANDBOX/lib" "$SANDBOX/bin" "$SANDBOX/bin-badnet"
cp "$SRC" "$SANDBOX/dev/bump-nix"
BUMP="$SANDBOX/dev/bump-nix"
SEEDLIB="$SANDBOX/lib/nix-seed.sh"

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
    *api.github.com*) printf '{"tag_name":"9.9.9"}\n' ;;
    *releases.nixos.org*)
        content="fake installer for $url"
        if [ -n "$out" ]; then printf '%s\n' "$content" > "$out"; else printf '%s\n' "$content"; fi
        ;;
    *) exit 22 ;;
esac
EOF
# API reachable but the installer download fails — the bump must abort without
# writing either half of the pin.
cat > "$SANDBOX/bin-badnet/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
    *api.github.com*) printf '{"tag_name":"9.9.9"}\n' ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin-badnet/curl"

# Expected sha for a given version = sha of the stub's deterministic content.
expected_sha() {
    printf 'fake installer for %s\n' "https://releases.nixos.org/nix/nix-$1/install" | sha256sum | cut -d' ' -f1
}

write_seedlib() {
    cat > "$SEEDLIB" <<EOF
#!/usr/bin/env bash
NIX_VERSION="\${NIX_VERSION:-$1}"
NIX_INSTALLER_SHA256="\${NIX_INSTALLER_SHA256:-$2}"
EOF
}
pin_version() { grep -oP '^NIX_VERSION="\$\{NIX_VERSION:-\K[^}]*' "$SEEDLIB"; }
pin_sha() { grep -oP '^NIX_INSTALLER_SHA256="\$\{NIX_INSTALLER_SHA256:-\K[^}]*' "$SEEDLIB"; }

OLD_SHA="0000000000000000000000000000000000000000000000000000000000000000"

# Run the script with the curl stub on PATH, capturing output and exit code
# without tripping `set -e`. Results land in the globals `out` and `rc`.
run_bump() {
    set +e
    out="$(PATH="$SANDBOX/bin:$PATH" "$BUMP" "$@" 2>&1)"
    rc=$?
    set -e
}
run_bump_badnet() {
    set +e
    out="$(PATH="$SANDBOX/bin-badnet:$PATH" "$BUMP" "$@" 2>&1)"
    rc=$?
    set -e
}

# ---------- test: default bump to latest release ----------
echo "--- bump-nix (default: latest release) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump
assert_eq "exit 0" "0" "$rc"
assert_contains "reports the bump" "1.0.0 → 9.9.9" "$out"
assert_eq "version pin updated" "9.9.9" "$(pin_version)"
assert_eq "sha pin updated in lockstep" "$(expected_sha 9.9.9)" "$(pin_sha)"

# ---------- test: explicit version ----------
echo "--- bump-nix (explicit version) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_eq "version pin set to explicit version" "2.5.0" "$(pin_version)"
assert_eq "sha matches the explicit version's installer" "$(expected_sha 2.5.0)" "$(pin_sha)"

# ---------- test: leading 'v' on explicit version is stripped ----------
echo "--- bump-nix (leading v stripped) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump "v2.6.1"
assert_eq "exit 0" "0" "$rc"
assert_eq "leading v stripped from pin" "2.6.1" "$(pin_version)"

# ---------- test: failed installer download writes nothing ----------
# The pin is a coupled pair: if the sha can't be computed, neither half may
# change.
echo "--- bump-nix (installer download fails) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump_badnet "2.9.9"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports the failed download" "could not download" "$out"
assert_eq "version pin untouched" "1.0.0" "$(pin_version)"
assert_eq "sha pin untouched" "$OLD_SHA" "$(pin_sha)"

# ---------- test: idempotent (explicit, already current) ----------
echo "--- bump-nix (idempotent explicit) ---"
write_seedlib "2.5.0" "$OLD_SHA"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_contains "reports already pinned" "already pinned to 2.5.0" "$out"
assert_eq "seed lib unchanged" "$OLD_SHA" "$(pin_sha)"

# ---------- test: --check (default) reports without editing ----------
echo "--- bump-nix (--check default) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump --check
assert_eq "exit 0" "0" "$rc"
assert_contains "shows current" "$(printf '%-11s%s' 'current:' '1.0.0')" "$out"
assert_contains "shows latest" "$(printf '%-11s%s' 'latest:' '9.9.9')" "$out"
assert_eq "version not edited" "1.0.0" "$(pin_version)"
assert_eq "sha not edited" "$OLD_SHA" "$(pin_sha)"

# ---------- test: --check with explicit target labels it 'requested' ----------
echo "--- bump-nix (--check explicit) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump "3.0.0" --check
assert_eq "exit 0" "0" "$rc"
assert_contains "labels the target as requested" "$(printf '%-11s%s' 'requested:' '3.0.0')" "$out"
assert_eq "version not edited" "1.0.0" "$(pin_version)"

# ---------- test: --check on an already-current pin still reports ----------
echo "--- bump-nix (--check already current) ---"
write_seedlib "9.9.9" "$OLD_SHA"
run_bump --check
assert_eq "exit 0" "0" "$rc"
assert_contains "notes up to date" "already up to date" "$out"

# ---------- test: invalid explicit version rejected ----------
echo "--- bump-nix (invalid version) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump "not-a-version"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports invalid version" "invalid version" "$out"
assert_eq "version untouched" "1.0.0" "$(pin_version)"

# ---------- test: sed-delimiter injection attempt rejected ----------
echo "--- bump-nix (sed injection guard) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump '1.2|3'
assert_eq "exit nonzero" "1" "$rc"
assert_contains "rejects delimiter in version" "invalid version" "$out"
assert_eq "version untouched" "1.0.0" "$(pin_version)"

# ---------- test: unknown flag ----------
echo "--- bump-nix (unknown flag) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump --bogus
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports unknown flag" "unknown flag" "$out"

# ---------- test: extra positional argument ----------
echo "--- bump-nix (extra argument) ---"
write_seedlib "1.0.0" "$OLD_SHA"
run_bump "1.2.3" "4.5.6"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports extra argument" "unexpected extra argument" "$out"

# ---------- test: missing pin line in nix-seed.sh ----------
echo "--- bump-nix (missing pin line) ---"
printf '#!/usr/bin/env bash\n' > "$SEEDLIB"
run_bump "2.0.0"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports missing pin" "could not find" "$out"

# ---------- test: the real lib's pin is parseable by this tool ----------
# Guards the grep contract between dev/bump-nix and lib/nix-seed.sh: if the
# assignment shape in the real file changes, this catches it without network.
echo "--- bump-nix (real lib parseable) ---"
real_version="$(grep -oP '^NIX_VERSION="\$\{NIX_VERSION:-\K[^}]*' "$DEV_BASE/lib/nix-seed.sh")"
assert_true "real NIX_VERSION default parseable" test -n "$real_version"
real_sha="$(grep -oP '^NIX_INSTALLER_SHA256="\$\{NIX_INSTALLER_SHA256:-\K[^}]*' "$DEV_BASE/lib/nix-seed.sh")"
assert_true "real NIX_INSTALLER_SHA256 default parseable" test -n "$real_sha"

finish
