#!/usr/bin/env sh
# Install a claude-profile setup-token (a raw CLAUDE_CODE_OAUTH_TOKEN bearer) for
# a container, reading the token from stdin.
#
# Usage: install-claude-token.sh <dest> <owner>
#
# Reads a raw bearer on stdin, validates it *looks like a bearer* (non-empty,
# a single line, no whitespace/control chars), and atomically replaces <dest>
# with a private regular file owned by <owner> (e.g. vscode:vscode). A failed
# validation leaves any existing token untouched and removes the temp — nothing
# is half-written.
#
# This is the token-shaped sibling of install-claude-credentials.sh, used by
# `devcontainer set-token` (docs/adr/0002-devcontainer-setup-token-env-delivery.md).
# It is DELIBERATELY not the same program: an OAuth credential is a JSON object
# validated with json.load; a setup-token is an opaque single-line bearer and
# must NOT pass through the JSON validator (it would be rejected) nor be written
# where a `.credentials.json` is expected — the token is consumed from the
# environment (CLAUDE_CODE_OAUTH_TOKEN), never read from this file by claude.
#
# Kept as a standalone POSIX-sh program (fed to `sh -c` by `devcontainer
# set-token` via `dc exec`) so this logic can be unit-tested off-container.
# See tests/test-set-token.sh.
set -eu

dest="$1"
owner="$2"

umask 077
dir="$(dirname "$dest")"
tmp="$(mktemp "$dir/.tok.XXXXXX")"
trap 'rm -f "$tmp"' EXIT INT TERM

# Read the whole stream, then strip trailing newline(s) defensively — a token
# piped via `export-to --token -` may or may not carry a trailing newline
# depending on how it was produced. Command substitution strips all trailing
# newlines; we then validate what remains.
token="$(cat)"

if [ -z "$token" ]; then
  echo "error: no token on stdin (empty input)" >&2
  exit 1
fi
# A bearer is a single line with no whitespace/control chars. Anything else —
# an embedded newline (a multi-value paste), a space or tab (a JSON blob) —
# means we were handed something other than one raw token; refuse rather than
# store it. The trailing newline was already stripped by the command
# substitution above, so any newline left here is embedded.
if [ "$(printf '%s' "$token" | wc -l)" -ne 0 ]; then
  echo "error: token spans multiple lines (not a single raw bearer)" >&2
  exit 1
fi
if printf '%s' "$token" | LC_ALL=C grep -q '[[:space:][:cntrl:]]'; then
  echo "error: token contains whitespace or control characters (not a single raw bearer)" >&2
  exit 1
fi

printf '%s' "$token" >"$tmp"
chown "$owner" "$tmp"
mv -f "$tmp" "$dest"
trap - EXIT INT TERM
