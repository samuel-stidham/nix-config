#!/usr/bin/env bash
#
# steam-restore.sh - queue every game in steam/appids.txt for install on a fresh
# machine. Steam must be installed and logged in. Each line triggers a download
# through the steam:// URL handler. Steam dedups, so re-running is safe and
# already-installed titles are left alone.
set -euo pipefail

list="${1:-$(dirname "$0")/../steam/appids.txt}"

[ -f "$list" ] || { echo "no appid list at $list, run steam-snapshot first" >&2; exit 1; }

# HOW TO REACH STEAM DEPENDS ON HOW IT WAS PACKAGED, SO ASK THE DESKTOP, NOT PATH.
#
# The old check was `command -v steam`, and the old install used the `steam`
# binary directly. Both assume a native deb or rpm build that drops a `steam`
# launcher on PATH. Bazzite ships Steam as a Flatpak, launched with
# `flatpak run com.valvesoftware.Steam`, so there is no `steam` on PATH and the
# old guard aborted with "steam is not on PATH" on a machine that has Steam.
#
# Branching on the packaging is the obvious fix and it is the wrong one. The
# deb, the rpm, and the Flatpak all register the same steam:// URL scheme
# handler with the desktop, because the Flatpak is a thin wrapper around the
# same upstream Steam client. So drive installs through the scheme handler with
# xdg-open, which routes to whichever Steam is registered. That covers all three
# packagings in one path and needs no `steam` binary.
#
# Guard on the handler, not the binary, so a machine with no Steam at all still
# fails loudly. On this deb machine `xdg-mime query default x-scheme-handler/steam`
# returns steam.desktop. The Flatpak exports the same handler to the host, but
# that is unverified on Bazzite, no such machine available.
command -v xdg-open >/dev/null 2>&1 || { echo "xdg-open not found. Install xdg-utils first." >&2; exit 1; }
handler=$(xdg-mime query default x-scheme-handler/steam 2>/dev/null || true)
if [ -z "$handler" ] && ! command -v steam >/dev/null 2>&1; then
  echo "No steam:// URL handler is registered and no steam binary is on PATH." >&2
  echo "Install Steam (deb, rpm, or Flatpak) and log in, then re-run." >&2
  exit 1
fi

count=0
while IFS=$'\t' read -r id name; do
  [ -n "${id:-}" ] || continue
  case "$id" in \#*) continue ;; esac   # allow comment lines
  echo "queueing $id  ${name:-}"
  xdg-open "steam://install/$id" >/dev/null 2>&1 || true
  count=$((count + 1))
  sleep 1
done < "$list"

echo "Queued $count titles. Keep Steam open and logged in while it downloads."
