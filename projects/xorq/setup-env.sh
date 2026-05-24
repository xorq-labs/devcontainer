#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-first-run}"
case "$cmd" in
    first-run)  echo "No project-specific setup configured." ;;
    sync-if-needed) ;;
    *) echo "usage: setup-env [first-run|sync-if-needed]" >&2; exit 1 ;;
esac
