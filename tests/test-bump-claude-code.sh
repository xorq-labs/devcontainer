#!/usr/bin/env bash
# Tests for devcontainer bump-claude-code — version resolution, the grep/sed
# round-trip on the Dockerfile pin, and argument handling.
#
# The script targets the Dockerfile one level up from its own path, so we run a
# copy from a disposable sandbox ($SANDBOX/dev/bump-claude-code against
# $SANDBOX/Dockerfile) and stub `npm` on PATH — no real Dockerfile is touched
# and no network is required.
set -euo pipefail

PASS=0 FAIL=0
_cleanup_dirs=()

cleanup() {
    for d in "${_cleanup_dirs[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected to contain: $needle"
        echo "    got: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SRC="$DEV_BASE/dev/bump-claude-code"

# ---------- setup: disposable sandbox ----------
SANDBOX="$(mktemp -d)"
_cleanup_dirs+=("$SANDBOX")
mkdir -p "$SANDBOX/dev" "$SANDBOX/bin"
cp "$SRC" "$SANDBOX/dev/bump-claude-code"
BUMP="$SANDBOX/dev/bump-claude-code"
DOCKERFILE="$SANDBOX/Dockerfile"

# Stub npm so the default (latest-from-npm) path is deterministic and offline.
# Shadows any real npm because we prepend $SANDBOX/bin to PATH.
cat > "$SANDBOX/bin/npm" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "view" ] && [ "$3" = "version" ]; then
    echo "9.9.9"
fi
EOF
chmod +x "$SANDBOX/bin/npm"

# Second stub set for the HTTPS-fallback path: npm is present but its lookup
# fails, so the script must fall through to querying the registry over curl.
# The curl stub returns the shape of registry.npmjs.org/<pkg>/latest.
mkdir -p "$SANDBOX/bin-fallback"
cat > "$SANDBOX/bin-fallback/npm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$SANDBOX/bin-fallback/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"version":"7.7.7"}'
EOF
chmod +x "$SANDBOX/bin-fallback/npm" "$SANDBOX/bin-fallback/curl"

write_dockerfile() {
    printf 'FROM scratch\nARG CLAUDE_CODE_VERSION=%s\nRUN true\n' "$1" > "$DOCKERFILE"
}
pin() { grep -oP '^ARG CLAUDE_CODE_VERSION=\K.*' "$DOCKERFILE"; }

# Run the script with the npm stub on PATH, capturing output and exit code
# without tripping `set -e`. Results land in the globals `out` and `rc`.
run_bump() {
    set +e
    out="$(PATH="$SANDBOX/bin:$PATH" "$BUMP" "$@" 2>&1)"
    rc=$?
    set -e
}

# Same, but with the failing-npm + curl stub set, to exercise the fallback.
run_bump_fallback() {
    set +e
    out="$(PATH="$SANDBOX/bin-fallback:$PATH" "$BUMP" "$@" 2>&1)"
    rc=$?
    set -e
}

# ---------- test: default bump to latest from npm ----------
echo "--- bump-claude-code (default: latest from npm) ---"
write_dockerfile "1.0.0"
run_bump
assert_eq "exit 0" "0" "$rc"
assert_contains "reports the bump" "1.0.0 → 9.9.9" "$out"
assert_eq "Dockerfile pin updated" "9.9.9" "$(pin)"

# ---------- test: explicit version ----------
echo "--- bump-claude-code (explicit version) ---"
write_dockerfile "1.0.0"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_eq "Dockerfile pin set to explicit version" "2.5.0" "$(pin)"

# ---------- test: explicit prerelease version accepted ----------
echo "--- bump-claude-code (prerelease version) ---"
write_dockerfile "1.0.0"
run_bump "2.1.0-beta.1"
assert_eq "exit 0" "0" "$rc"
assert_eq "Dockerfile pin set to prerelease" "2.1.0-beta.1" "$(pin)"

# ---------- test: leading 'v' on explicit version is stripped ----------
echo "--- bump-claude-code (leading v stripped) ---"
write_dockerfile "1.0.0"
run_bump "v2.1.201"
assert_eq "exit 0" "0" "$rc"
assert_eq "leading v stripped from pin" "2.1.201" "$(pin)"

# ---------- test: bumps the Nix base pin alongside the Dockerfile ----------
# These tests copy the repo's real claude-code.nix into the sandbox (with only
# its version value rewritten to stage drift) so a reformat of the real file
# breaks these tests instead of silently breaking the sync.
echo "--- bump-claude-code (syncs Nix base pin) ---"
NIX_SRC="$DEV_BASE/nix/base/pkgs/claude-code.nix"
NIX_PIN_DIR="$SANDBOX/nix/base/pkgs"
NIX_PIN="$NIX_PIN_DIR/claude-code.nix"
mkdir -p "$NIX_PIN_DIR"
nix_version() { grep -oP '^  version = "\K[^"]*' "$NIX_PIN"; }
# Seed the sandbox base pin from the real file, pinned to a known version.
seed_nix_pin() {
    cp "$NIX_SRC" "$NIX_PIN"
    sed -i "s|^  version = \".*\";|  version = \"$1\";|" "$NIX_PIN"
}
write_dockerfile "1.0.0"
seed_nix_pin "1.0.0"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_eq "base pin version bumped" "2.5.0" "$(nix_version)"
assert_contains "base pin hash reset to fakeHash" 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$(cat "$NIX_PIN")"
assert_contains "reports the base pin bump" "Also bumped Nix base pin" "$out"

# ---------- test: Dockerfile already pinned but Nix pin drifted → repaired ----------
echo "--- bump-claude-code (repairs drifted Nix pin) ---"
write_dockerfile "2.5.0"
seed_nix_pin "1.0.0"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_contains "reports the repair" "repairing the drifted Nix base pin" "$out"
assert_eq "base pin version repaired" "2.5.0" "$(nix_version)"
assert_contains "base pin hash reset to fakeHash" 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$(cat "$NIX_PIN")"
assert_eq "Dockerfile unchanged" "2.5.0" "$(pin)"

# ---------- test: both pins in sync → already pinned, hash untouched ----------
echo "--- bump-claude-code (Dockerfile and Nix pin both current) ---"
write_dockerfile "2.5.0"
seed_nix_pin "2.5.0"
hash_before="$(grep -oP '^    hash = "\K[^"]*' "$NIX_PIN")"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_contains "reports already pinned" "already pinned to 2.5.0" "$out"
assert_eq "valid src.hash not clobbered" "$hash_before" "$(grep -oP '^    hash = "\K[^"]*' "$NIX_PIN")"

# ---------- test: --check reports Nix pin drift ----------
echo "--- bump-claude-code (--check reports Nix pin drift) ---"
write_dockerfile "9.9.9"
seed_nix_pin "1.0.0"
run_bump --check
assert_eq "exit 0" "0" "$rc"
assert_contains "shows the drifted nix pin" "$(printf '%-11s%s' 'nix pin:' '1.0.0')" "$out"
assert_contains "suggests a repair run" "repair the Nix base pin" "$out"
assert_eq "nix pin not edited" "1.0.0" "$(nix_version)"
assert_eq "Dockerfile not edited" "9.9.9" "$(pin)"

# ---------- test: --check with both pins in sync stays quiet about nix ----------
echo "--- bump-claude-code (--check with Nix pin in sync) ---"
write_dockerfile "9.9.9"
seed_nix_pin "9.9.9"
run_bump --check
assert_eq "exit 0" "0" "$rc"
assert_contains "notes up to date" "already up to date" "$out"
assert_eq "no nix drift line" "" "$(grep 'nix pin:' <<<"$out" || true)"

# ---------- test: reformatted Nix pin makes the sync fail loudly ----------
echo "--- bump-claude-code (reformatted Nix pin fails loudly) ---"
write_dockerfile "1.0.0"
seed_nix_pin "1.0.0"
# Simulate a reformat: re-indent the version line so the sed anchor misses.
sed -i 's|^  version = |    version = |' "$NIX_PIN"
run_bump "2.5.0"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports the failed sync" "could not update the Nix base pin" "$out"
assert_contains "points at a manual fix" "manually" "$out"
rm -rf "$SANDBOX/nix"

# ---------- test: no-op (and no error) when the Nix base pin is absent ----------
echo "--- bump-claude-code (no base pin present) ---"
write_dockerfile "1.0.0"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_eq "Dockerfile still bumped" "2.5.0" "$(pin)"

# ---------- test: HTTPS fallback when npm lookup fails ----------
echo "--- bump-claude-code (npm fails, HTTPS fallback) ---"
write_dockerfile "1.0.0"
run_bump_fallback
assert_eq "exit 0" "0" "$rc"
assert_contains "falls through to registry" "1.0.0 → 7.7.7" "$out"
assert_eq "Dockerfile pin from fallback" "7.7.7" "$(pin)"

# ---------- test: idempotent (explicit, already current) ----------
echo "--- bump-claude-code (idempotent explicit) ---"
write_dockerfile "2.5.0"
run_bump "2.5.0"
assert_eq "exit 0" "0" "$rc"
assert_contains "reports already pinned" "already pinned to 2.5.0" "$out"
assert_eq "Dockerfile unchanged" "2.5.0" "$(pin)"

# ---------- test: idempotent (default, already latest) ----------
echo "--- bump-claude-code (idempotent default) ---"
write_dockerfile "9.9.9"
run_bump
assert_eq "exit 0" "0" "$rc"
assert_contains "notes latest published" "(latest published version)" "$out"
assert_eq "Dockerfile unchanged" "9.9.9" "$(pin)"

# ---------- test: --check (default) reports without editing ----------
echo "--- bump-claude-code (--check default) ---"
write_dockerfile "1.0.0"
run_bump --check
assert_eq "exit 0" "0" "$rc"
assert_contains "shows current" "$(printf '%-11s%s' 'current:' '1.0.0')" "$out"
assert_contains "shows latest" "$(printf '%-11s%s' 'latest:' '9.9.9')" "$out"
assert_eq "Dockerfile not edited" "1.0.0" "$(pin)"

# ---------- test: --check on an already-current pin still reports ----------
echo "--- bump-claude-code (--check already current) ---"
write_dockerfile "9.9.9"
run_bump --check
assert_eq "exit 0" "0" "$rc"
assert_contains "still prints the report" "$(printf '%-11s%s' 'current:' '9.9.9')" "$out"
assert_contains "notes up to date" "already up to date" "$out"
assert_eq "Dockerfile not edited" "9.9.9" "$(pin)"

# ---------- test: --check with explicit target labels it 'requested' ----------
echo "--- bump-claude-code (--check explicit) ---"
write_dockerfile "1.0.0"
run_bump "3.0.0" --check
assert_eq "exit 0" "0" "$rc"
assert_contains "labels the target as requested" "$(printf '%-11s%s' 'requested:' '3.0.0')" "$out"
assert_eq "Dockerfile not edited" "1.0.0" "$(pin)"
# Value columns of current:/requested: must line up (regression on alignment).
cur_col="$(awk '/^current:/{print index($0, "1.0.0")}' <<<"$out")"
req_col="$(awk '/^requested:/{print index($0, "3.0.0")}' <<<"$out")"
assert_eq "report columns aligned" "$cur_col" "$req_col"

# ---------- test: invalid explicit version rejected ----------
echo "--- bump-claude-code (invalid version) ---"
write_dockerfile "1.0.0"
run_bump "not-a-version"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports invalid version" "invalid version" "$out"
assert_eq "Dockerfile untouched" "1.0.0" "$(pin)"

# ---------- test: sed-delimiter injection attempt rejected ----------
echo "--- bump-claude-code (sed injection guard) ---"
write_dockerfile "1.0.0"
run_bump '1.2|3'
assert_eq "exit nonzero" "1" "$rc"
assert_contains "rejects delimiter in version" "invalid version" "$out"
assert_eq "Dockerfile untouched" "1.0.0" "$(pin)"

# ---------- test: unknown flag ----------
echo "--- bump-claude-code (unknown flag) ---"
write_dockerfile "1.0.0"
run_bump --bogus
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports unknown flag" "unknown flag" "$out"

# ---------- test: extra positional argument ----------
echo "--- bump-claude-code (extra argument) ---"
write_dockerfile "1.0.0"
run_bump "1.2.3" "4.5.6"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports extra argument" "unexpected extra argument" "$out"

# ---------- test: missing ARG line in Dockerfile ----------
echo "--- bump-claude-code (missing ARG line) ---"
printf 'FROM scratch\nRUN true\n' > "$DOCKERFILE"
run_bump "2.0.0"
assert_eq "exit nonzero" "1" "$rc"
assert_contains "reports missing pin" "could not find" "$out"

# ---------- summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
