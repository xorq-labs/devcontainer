#!/usr/bin/env bash
# Tests for compose/volume name sanitization (sanitize_name). A repo whose
# basename carries a leading dot (.dotfiles) or other characters disallowed in
# a Docker Compose project name used to produce names like "-dotfiles-dev-..."
# that `docker compose -p` rejects. Runs against disposable git repos in /tmp —
# no docker required.
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DC="$DEV_BASE/dev/devcontainer"

TMPDIR_ROOT="$(mktemp -d)"
_cleanup_dirs+=("$TMPDIR_ROOT")

# ---------- test: dotted repo basename (.dotfiles) ----------
# The reported failure: `.dotfiles` -> `-dotfiles-dev-dotfiles`, rejected
# because a project name must start with a letter or number.
echo "--- dotted repo basename (.dotfiles) ---"
DOT_TREE="$(new_repo "$TMPDIR_ROOT/.dotfiles")"
out="$(cd "$DOT_TREE" && "$DC" resolve 2>&1)"
assert_contains "PROJECT_NAME drops the leading dot" "PROJECT_NAME=dotfiles" "$out"
assert_contains "CONTAINER_NAME is a valid compose project" \
    "CONTAINER_NAME=dotfiles-dev-dotfiles" "$out"
assert_not_contains "no leading-hyphen container name" "CONTAINER_NAME=-" "$out"
assert_contains "overlay tier uses the sanitized name" "projects/dotfiles/" "$out"

# ---------- test: DEV_PROJECT_NAME override is sanitized too ----------
echo "--- DEV_PROJECT_NAME override sanitization ---"
PLAIN_TREE="$(new_repo "$TMPDIR_ROOT/plainrepo")"
out="$(cd "$PLAIN_TREE" && DEV_PROJECT_NAME='.My Weird.Name' "$DC" resolve 2>&1)"
assert_contains "override lowercased, dots/spaces collapsed, no leading dash" \
    "PROJECT_NAME=my-weird-name" "$out"
assert_contains "container name derives from the sanitized override" \
    "CONTAINER_NAME=my-weird-name-dev-plainrepo" "$out"

# ---------- test: all-disallowed name falls back to "project" ----------
echo "--- all-disallowed name fallback ---"
out="$(cd "$PLAIN_TREE" && DEV_PROJECT_NAME='...' "$DC" resolve 2>&1)"
assert_contains "empty-after-sanitize falls back to project" \
    "PROJECT_NAME=project" "$out"

# ---------- regression: ordinary names are unchanged ----------
echo "--- ordinary names unchanged ---"
out="$(cd "$PLAIN_TREE" && "$DC" resolve 2>&1)"
assert_contains "plain name passes through" "PROJECT_NAME=plainrepo" "$out"
assert_contains "plain container name passes through" \
    "CONTAINER_NAME=plainrepo-dev-plainrepo" "$out"

# ---------- test: init scaffolds under the sanitized projects/<name> ----------
# dev/devcontainer sanitizes DEV_PROJECT_NAME before resolving projects/<name>,
# so init must scaffold under the same sanitized name or `up` would never find
# the shipped overlay. --dry-run keeps this from writing into the real repo.
INIT="$DEV_BASE/dev/init"
echo "--- init sanitizes the projects/<name> tier ---"
out="$(cd "$DOT_TREE" && "$INIT" --dry-run 2>&1)"
assert_contains "init derives sanitized name from a dotted basename" \
    "projects/dotfiles/" "$out"
assert_not_contains "init never scaffolds a leading-dot dir" \
    "projects/.dotfiles/" "$out"

echo "--- init sanitizes an explicit name argument ---"
out="$(cd "$PLAIN_TREE" && "$INIT" --dry-run '.Weird.Name' 2>&1)"
assert_contains "explicit dotted/uppercase name is sanitized" \
    "projects/weird-name/" "$out"

finish
