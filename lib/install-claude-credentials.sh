#!/usr/bin/env sh
# Install Claude credentials for a container, reading the new bytes from stdin.
#
# Usage: install-claude-credentials.sh <dest> <owner>
#
# Reads credential JSON on stdin, validates it, and atomically replaces <dest>
# with a private regular file owned by <owner> (e.g. vscode:vscode). <dest> may
# currently be the shared-mount symlink
#   ~/.claude/.credentials.json -> credentials/.credentials.json
# `mv` is rename(2): it replaces the *link itself* atomically without following
# it, so the bytes land in a real file on the container-private volume and are
# NOT written through into the shared host file. A failed validation leaves the
# existing credentials untouched and removes the temp — nothing is half-written.
#
# Kept as a standalone POSIX-sh program (fed to `sh -c` by `devcontainer
# set-credentials` via `dc exec`) so this swap logic can be unit-tested
# off-container. See tests/test-set-credentials.sh.
set -eu

dest="$1"
owner="$2"

umask 077
dir="$(dirname "$dest")"
tmp="$(mktemp "$dir/.cred.XXXXXX")"
trap 'rm -f "$tmp"' EXIT INT TERM

cat >"$tmp"

if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$tmp"; then
  echo "error: streamed credentials are not valid JSON" >&2
  exit 1
fi

chown "$owner" "$tmp"
mv -f "$tmp" "$dest"
trap - EXIT INT TERM
