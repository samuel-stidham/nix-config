#!/usr/bin/env bash
#
# steam-restore.sh - queue every game in steam/appids.txt for install on a fresh
# machine. Steam must be installed and logged in. Each line triggers a download
# through the steam:// URL handler. Steam dedups, so re-running is safe and
# already-installed titles are left alone.
set -euo pipefail

list="${1:-$(dirname "$0")/../steam/appids.txt}"

[ -f "$list" ] || { echo "no appid list at $list, run steam-snapshot first" >&2; exit 1; }
command -v steam >/dev/null 2>&1 || { echo "steam is not on PATH, install it first" >&2; exit 1; }

count=0
while IFS=$'\t' read -r id name; do
  [ -n "${id:-}" ] || continue
  case "$id" in \#*) continue ;; esac   # allow comment lines
  echo "queueing $id  ${name:-}"
  steam "steam://install/$id" >/dev/null 2>&1 || true
  count=$((count + 1))
  sleep 1
done < "$list"

echo "Queued $count titles. Keep Steam open and logged in while it downloads."
