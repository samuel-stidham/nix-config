#!/usr/bin/env bash
#
# steam-snapshot.sh - record the appids of every installed Steam game into
# steam/appids.txt, so a fresh machine can reinstall the same set. Run it
# whenever your library changes, then commit the file. Steam's own runtimes,
# redistributables, and Proton builds install themselves, so they are skipped.
set -euo pipefail

out="${1:-$(dirname "$0")/../steam/appids.txt}"
mkdir -p "$(dirname "$out")"

libs=("$HOME/.local/share/Steam/steamapps" "$HOME/.steam/steam/steamapps")

{
  for m in "${libs[@]}"; do
    [ -d "$m" ] || continue
    for f in "$m"/appmanifest_*.acf; do
      [ -e "$f" ] || continue
      id=$(grep -oP '"appid"\s*"\K[0-9]+' "$f" | head -1)
      nm=$(grep -oP '"name"\s*"\K[^"]+' "$f" | head -1)
      # Skip the plumbing that Steam manages on its own.
      case "$nm" in
        *"Steam Linux Runtime"*|*"Steamworks Common"*|"Proton"*) continue ;;
      esac
      printf '%s\t%s\n' "$id" "$nm"
    done
  done
} | sort -n -u > "$out"

echo "wrote $(wc -l < "$out") appids to $out"
