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
assert_contains "shows current" "current: 1.0.0" "$out"
assert_contains "shows latest" "latest:  9.9.9" "$out"
assert_eq "Dockerfile not edited" "1.0.0" "$(pin)"

# ---------- test: --check with explicit target labels it 'requested' ----------
echo "--- bump-claude-code (--check explicit) ---"
write_dockerfile "1.0.0"
run_bump "3.0.0" --check
assert_eq "exit 0" "0" "$rc"
assert_contains "labels the target as requested" "requested: 3.0.0" "$out"
assert_eq "Dockerfile not edited" "1.0.0" "$(pin)"

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
