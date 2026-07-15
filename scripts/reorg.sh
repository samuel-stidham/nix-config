#!/usr/bin/env bash
#
# reorg.sh - move the home directory to the canonical structure.
#
# The plan lives in "Machine File Structure" in the obsidian scratchpad vault.
# This script is the executable form of that document.
#
# Usage:
#   ./reorg.sh              # DRY RUN. prints every action, changes nothing
#   ./reorg.sh --apply      # actually do it
#
# Safety rules baked in:
#   - Dry run is the default. You have to ask for --apply.
#   - Nothing is deleted that was not on the explicit list.
#   - The 117G Roms delete is GUARDED: it verifies WorkDrive/Roms really is a
#     superset first, and refuses if it is not.
#   - ~/snap is never touched. It holds the Firefox profile.
#   - Moves never clobber: if the destination exists, it skips and warns.
set -uo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

WORKDRIVE="/media/samuelstidham/WorkDrive"
DESKTOP="$HOME/Desktop"
DOCS="$HOME/Documents"

say()  { printf '%s\n' "$*"; }
head_() { printf '\n=== %s ===\n' "$*"; }

run() {
  if [ "$APPLY" = 1 ]; then
    "$@"
  else
    say "  DRY: $*"
  fi
}

# Move src -> dstdir/, refusing to clobber.
move() {
  local src="$1" dstdir="$2"
  [ -e "$src" ] || { say "  skip (absent): ${src/#$HOME/\~}"; return 0; }
  local base; base="$(basename "$src")"
  if [ -e "$dstdir/$base" ]; then
    say "  SKIP (destination exists): ${dstdir/#$HOME/\~}/$base"
    return 0
  fi
  say "  move: ${src/#$HOME/\~}  ->  ${dstdir/#$HOME/\~}/"
  run mkdir -p "$dstdir"
  run mv "$src" "$dstdir/"
}

del() {
  local p="$1"
  [ -e "$p" ] || { say "  skip (absent): ${p/#$HOME/\~}"; return 0; }
  local sz; sz="$(du -sh "$p" 2>/dev/null | cut -f1)"
  say "  delete: ${p/#$HOME/\~}  ($sz)"
  run rm -rf "$p"
}

# --------------------------------------------------------------------------
head_ "mode"
[ "$APPLY" = 1 ] && say "  APPLY: changes are real" || say "  DRY RUN: nothing changes. re-run with --apply"

# --------------------------------------------------------------------------
head_ "Desktop -> canonical homes"
move "$DESKTOP/SNHU"             "$DOCS/Education"
move "$DESKTOP/Computer Science" "$DOCS/Education"
move "$DESKTOP/KeePassXC"        "$DOCS"

# smart-partition and its templates belong together, on the drive a reinstall
# never touches.
head_ "smart-partition -> WorkDrive"
if [ -d "$WORKDRIVE" ]; then
  move "$DESKTOP/smart-partition"     "$WORKDRIVE/Projects"
  move "$DOCS/SmartPartition Backup"  "$WORKDRIVE/Projects"
else
  say "  SKIP: $WORKDRIVE is not mounted"
fi

# --------------------------------------------------------------------------
head_ "Documents tidy"
# Consolidate the two Bruno dirs into one.
if [ -d "$DOCS/Bruno Collections/Minecraft" ]; then
  move "$DOCS/Bruno Collections/Minecraft" "$DOCS/bruno"
  if [ -d "$DOCS/Bruno Collections" ] && [ -z "$(ls -A "$DOCS/Bruno Collections" 2>/dev/null)" ]; then
    say "  rmdir: ~/Documents/Bruno Collections (now empty)"
    run rmdir "$DOCS/Bruno Collections"
  fi
fi

# The fishing license is a vital document.
move "$DOCS/License Print _ KY Dept. of Fish & Wildlife Resources.pdf" "$DOCS/Vital/Licenses"

# A joke wav is not a document.
move "$DOCS/yourmom.wav" "$HOME/Music"

# Scaffold the rest of the Vital tree so it is obvious where things go.
head_ "Vital scaffold"
for d in Identity Licenses Records; do
  say "  mkdir: ~/Documents/Vital/$d"
  run mkdir -p "$DOCS/Vital/$d"
done

# --------------------------------------------------------------------------
# Roms: 117G. This is the one delete big enough to be worth verifying instead of
# trusting. Only remove the nvme copy if WorkDrive really has it.
head_ "Roms duplicate (GUARDED)"
if [ ! -d "$DESKTOP/Roms" ]; then
  say "  skip: ~/Desktop/Roms already gone"
elif [ ! -d "$WORKDRIVE/Roms" ]; then
  say "  REFUSING: $WORKDRIVE/Roms does not exist. Not deleting the only copy."
else
  d_files=$(find "$DESKTOP/Roms" -type f 2>/dev/null | wc -l)
  w_files=$(find "$WORKDRIVE/Roms" -type f 2>/dev/null | wc -l)
  say "  ~/Desktop/Roms : $d_files files"
  say "  WorkDrive/Roms : $w_files files"
  # Every file on the desktop must exist on WorkDrive, by relative name.
  missing=$( (cd "$DESKTOP/Roms" && find . -type f 2>/dev/null | sort) > /tmp/.roms_d 2>/dev/null
             (cd "$WORKDRIVE/Roms" && find . -type f 2>/dev/null | sort) > /tmp/.roms_w 2>/dev/null
             comm -23 /tmp/.roms_d /tmp/.roms_w 2>/dev/null | wc -l )
  say "  files on Desktop but NOT on WorkDrive: $missing"
  if [ "${missing:-1}" -eq 0 ] && [ "$d_files" -gt 0 ]; then
    say "  verified: WorkDrive is a superset. safe to delete the nvme copy."
    del "$DESKTOP/Roms"
  else
    say "  REFUSING to delete: $missing file(s) exist only on the Desktop copy."
    say "  Reconcile them onto WorkDrive first, then re-run."
  fi
  rm -f /tmp/.roms_d /tmp/.roms_w
fi

# --------------------------------------------------------------------------
head_ "Desktop deletes (your explicit list)"
for p in Antigravity-x64 hytale-launcher-latest.flatpak imgui.ini logs mods \
         oot.o2r readme.txt Save shipofharkinian.json soh.appimage \
         TablePlus-x64.AppImage tmux3; do
  del "$DESKTOP/$p"
done
say "  keeping: steam.desktop (just the Steam launcher)"

# --------------------------------------------------------------------------
head_ "Other deletes"
del "$DOCS/Minecraft Backup"          # 18G, superseded by restic mc-backup
del "$HOME/.docker"                   # 21G, dead. Podman now.
del "$HOME/.local/share/Trash"        # 5.9G
del "$HOME/latex"                     # build artifacts
del "$HOME/PyCharmMiscProject"        # empty

say ""
say "NOT touching ~/snap: it holds the Firefox profile."
say "NOT touching ~/.cache: it regenerates, and removing it under a running"
say "  desktop session is more disruptive than the 13G is worth."

head_ "done"
[ "$APPLY" = 1 ] || say "  that was a DRY RUN. re-run with --apply to commit to it."
