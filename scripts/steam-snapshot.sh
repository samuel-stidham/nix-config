#!/usr/bin/env bash
#
# steam-snapshot.sh - record the appids of every installed Steam game into
# steam/appids.txt, so a fresh machine can reinstall the same set. Run it
# whenever your library changes, then commit the file. Steam's own runtimes,
# redistributables, and Proton builds install themselves, so they are skipped.
set -euo pipefail

out="${1:-$(dirname "$0")/../steam/appids.txt}"
mkdir -p "$(dirname "$out")"

# WHERE STEAM KEEPS ITS LIBRARY DEPENDS ON HOW IT WAS PACKAGED.
#
# The old list held only the two native paths, ~/.local/share/Steam and the
# ~/.steam compat symlink. Those are what the deb and rpm builds use. Bazzite
# ships Steam as a Flatpak, and Flatpak relocates an app's data under
# ~/.var/app/<app-id>/data, so the tree lives at
# ~/.var/app/com.valvesoftware.Steam/data/Steam instead. Neither native path
# exists there.
#
# The old code guarded each root with `[ -d ] || continue`, so on Bazzite both
# were skipped, the pipeline wrote zero lines, and the default $out is this
# repo's own steam/appids.txt. A Bazzite user refreshing the list silently
# truncated a good committed library to empty, and "wrote 0 appids" read like
# success. The empty file then made steam-restore a no-op.
#
# The obvious fix, branching on $FAMILY, is the wrong one. Packaging does not
# follow the distro. Someone runs the Flatpak on Ubuntu or the deb on Fedora.
# So probe the filesystem for the roots that actually exist, and if none does,
# abort loudly rather than overwrite a good file with nothing. That directory probe
# is necessary but not sufficient: a library can exist and still hold no real game.
# The output is staged to a temp file below and only moved over $out when it is
# non-empty, so an empty result never truncates the committed list either.
#
# The Flatpak data path is read off the Flatpak XDG convention, app id
# com.valvesoftware.Steam. Unverified on Bazzite, no such machine available.
candidates=(
  "$HOME/.local/share/Steam/steamapps"
  "$HOME/.steam/steam/steamapps"
  "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps"
  "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam/steamapps"
)

libs=()
for m in "${candidates[@]}"; do
  [ -d "$m" ] && libs+=("$m")
done

if [ "${#libs[@]}" -eq 0 ]; then
  echo "No Steam library found. Looked in:" >&2
  printf '  %s\n' "${candidates[@]}" >&2
  echo "Refusing to overwrite $out with an empty list." >&2
  exit 1
fi

# Stage to a temp file in the same dir as $out, NOT straight to $out. The library
# guard above proves a steamapps tree EXISTS, not that it holds a real game. An
# empty tree, or a library with only runtimes and Proton (all skipped below), emits
# zero lines, and `> "$out"` would truncate the committed list to empty and print
# "wrote 0" as success, the exact overwrite-with-nothing this script promises never
# to do. Even a mid-pipeline death leaves the temp empty, not $out. Same dir keeps
# the final mv atomic.
tmp="$(mktemp "$(dirname "$out")/.appids.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  for m in "${libs[@]}"; do
    for f in "$m"/appmanifest_*.acf; do
      [ -e "$f" ] || continue
      # `|| true` then a presence check, because set -euo pipefail turns a no-match
      # grep (exit 1) into a subshell death. Steam leaves empty and half-written
      # .acf files during interrupted downloads, so skip a manifest with no appid
      # rather than die on it.
      id=$(grep -oP '"appid"\s*"\K[0-9]+' "$f" | head -1) || true
      [ -n "$id" ] || continue
      nm=$(grep -oP '"name"\s*"\K[^"]+' "$f" | head -1) || true
      # Skip the plumbing that Steam manages on its own.
      case "$nm" in
        *"Steam Linux Runtime"*|*"Steamworks Common"*|"Proton"*) continue ;;
      esac
      printf '%s\t%s\n' "$id" "$nm"
    done
  done
} | sort -n -u > "$tmp"

if [ ! -s "$tmp" ]; then
  echo "Found a Steam library but no installed game (empty, or only runtimes and" >&2
  echo "Proton). Refusing to overwrite $out with an empty list." >&2
  exit 1
fi

count=$(wc -l < "$tmp")
mv "$tmp" "$out"
echo "wrote $count appids to $out"
