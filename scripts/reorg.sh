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
#   - The 117G Roms delete is GUARDED. Read that guard's own comment before
#     trusting it. It refuses on any doubt, including doubt about itself.
#   - ~/snap is never touched. It holds the Firefox profile.
#   - Moves never clobber: if the destination exists, it skips and warns.
#
# ONE honest exception to "changes nothing". The Roms guard reads both trees
# and writes a manifest into a private mktemp directory, in dry run too. A dry
# run whose guard did not really run would tell you nothing about --apply, and
# the guard's verdict is the whole reason to do a dry run first. The directory
# is removed on exit. That is the only write a dry run performs. The old code
# made the same exception without saying so, and it wrote to a fixed
# /tmp/.roms_d instead, which is the bug described at the Roms guard below.

# set -e is deliberately ABSENT, and that needs writing down, because "add
# set -e" is the obvious review note on a script that deletes 117G.
#
# It would not have saved the ROMs. Every failure path in the old guard
# returned ZERO. comm succeeded and printed nothing, wc -l honestly reported
# 0 lines. Nothing raised a status for -e to catch. Reproduced here: the old
# guard with -e turned on still printed "verified: WorkDrive is a superset"
# against a WorkDrive holding two 0-byte stubs, and exited 0. -e changes
# nothing about that.
#
# It would also make this script worse. Under -e a failed mkdir aborts the run
# mid-reorg, leaving the home directory half-moved and no record of where it
# stopped. This script is restartable by design. Every move refuses to clobber
# and every delete skips an absent path, so re-running it is safe and is the
# recovery procedure. That property is worth more than an early exit.
#
# The guard does not lean on -e. It checks the status of every step itself and
# refuses on any nonzero. Fail closed beats fail fast when the failure mode is
# rm -rf against 117G that restic has never backed up.
set -uo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

# WorkDrive: ASK THE KERNEL where it is. Do not name a path and hope.
#
# This line used to read:
#
#   WORKDRIVE="/media/samuelstidham/WorkDrive"
#
# That literal is not wrong so much as incomplete, and the difference matters.
# bootstrap.sh mount_drives() pins both drives to /media/samuelstidham/LABEL by
# UUID in /etc/fstab, on EVERY family, exactly so this repo's paths stop
# depending on the distro. Its comment at bootstrap.sh:526 argues the case. So
# the literal is right AFTER bootstrap has run. Do not "port" it to
# /run/media/$USER. That fights the repo's own design and would break Ubuntu.
#
# The failure is the window BEFORE bootstrap has run, and nothing in this file
# ever stated that ordering. On a fresh Fedora or Bazzite, udisks mounts the
# drive at /run/media/samuelstidham/WorkDrive. The literal then names a path
# that does not exist, the old `[ -d "$WORKDRIVE" ]` was false, and the script
# printed "SKIP: ... is not mounted" and moved nothing. The drive is mounted
# and sitting right there. The script reports done and exits 0. Same commands,
# different machine, no warning. That is the silent parity failure this repo
# exists to kill.
#
# The obvious fix is to branch on $FAMILY and pick /media or /run/media. It
# cannot work, because the right answer is neither: it is "wherever it is
# mounted right now", which turns on whether bootstrap has run yet. A $FAMILY
# branch cannot know that, and it is one more list to keep correct.
#
# findmnt reads the kernel's mount table. One answer, no family list, and it is
# the same call on Ubuntu, Fedora, SUSE and Bazzite because none of them get a
# vote. bootstrap.sh:546 already reaches past blkid to lsblk on this same
# reasoning.
#
# SECOND thing this buys, and it is the bigger one. `[ -d "$WORKDRIVE" ]` could
# not tell a mounted drive from an empty leftover directory. bootstrap.sh:566
# runs `sudo mkdir -p` on the mount point BEFORE mounting, and :553 mounts with
# nofail so a dead drive never blocks boot. Boot with the drive dead and an
# empty root-owned /media/samuelstidham/WorkDrive survives on the nvme. Checked
# here: `[ -d ]` says TRUE for it. smart-partition then moved onto the nvme
# while the script announced a move to WorkDrive, landing it on the one drive a
# reinstall wipes. That is the precise outcome the comment below says the block
# exists to prevent. findmnt returns nothing for an unmounted drive, so "where
# is it" and "is it there at all" become one question with one answer.
#
# The literal username goes with it, which CLAUDE.md bans. Nine other sites in
# this repo still carry it. The later mount-root resolver supersedes this local
# probe. Until it lands, this file no longer needs to know who you are.
#
# First line only, because a btrfs label can answer more than once, for instance
# the same subvolume mounted twice. Taken with a parameter expansion below, not a
# pipe to `head`: under `set -o pipefail` findmnt would take SIGPIPE when head
# exits, the pipeline would be rc=141, and `|| return 1` would then read a mounted
# drive as absent. scripts/drive-mount.sh documents the same hazard.
#
# Verified on this Ubuntu machine only: `findmnt -rn -o TARGET -S
# LABEL=WorkDrive` printed /media/samuelstidham/WorkDrive at rc=0, and printed
# nothing at rc=1 for a label that does not exist. Unverified on fedora and
# suse, no such machine available.
workdrive_mount() {
  command -v findmnt >/dev/null 2>&1 || return 1
  local out
  out="$(findmnt -rn -o TARGET -S LABEL=WorkDrive 2>/dev/null)" || out=""
  local target="${out%%$'\n'*}"
  [ -n "$target" ] || return 1
  printf '%s\n' "$target"
}
WORKDRIVE="$(workdrive_mount)" || WORKDRIVE=""

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
# Was `[ -d "$WORKDRIVE" ]`, which answered the wrong question. See the
# workdrive_mount comment: an empty root-owned mount point left behind by a
# nofail boot satisfies -d, and the move then lands on the nvme. An empty
# $WORKDRIVE here means findmnt found no mounted filesystem labelled WorkDrive.
if [ -n "$WORKDRIVE" ]; then
  say "  WorkDrive is mounted at $WORKDRIVE"
  move "$DESKTOP/smart-partition"     "$WORKDRIVE/Projects"
  move "$DOCS/SmartPartition Backup"  "$WORKDRIVE/Projects"
else
  say "  SKIP: no mounted filesystem is labelled WorkDrive"
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
# Roms: 117G. This guard is the only thing between --apply and permanent loss.
# Read the whole comment before you change one line of it.
#
# WHY THE STAKES ARE ASYMMETRIC. This sets every decision below.
#
# backup.sh:60-74 is BACKUP_PATHS. It lists $HOME/Desktop. It lists no /media
# path at all. So restic protects the Desktop copy and has never once seen the
# WorkDrive copy. This block deletes the copy restic protects and keeps the
# copy restic has never heard of. There is no restore behind it. A wrong
# REFUSAL costs a re-run. A wrong DELETE costs 117G forever. So the guard
# refuses on any doubt, including doubt about its own machinery.
#
# WHAT THE OLD GUARD DID. It deleted on three separate inputs, and the first
# needed nothing to be wrong with the machine at all.
#
# It compared NAMES and never content. `find . -type f | sort` emits relative
# pathnames, and `comm -23` compared those pathnames. Nothing looked at a size,
# an mtime, or a checksum. So a 0-byte stub on WorkDrive satisfied the guard
# for a real ROM on the Desktop. That is precisely what an interrupted cp or a
# full drive leaves behind, and it is the likeliest way to reach this code for
# real. Reproduced: Desktop held two 100000-byte ROMs, WorkDrive held two
# 0-byte files of the same names, and the guard printed "verified: WorkDrive is
# a superset. safe to delete the nvme copy."
#
# It read `missing` from `comm ... | wc -l`, and `wc -l` on empty input prints
# 0. comm prints nothing on every error path too. So "zero files missing" and
# "comm could not run" were THE SAME VALUE, and that value authorised the
# delete. The failure did not merely fail to protect. It manufactured the
# confirmation. Reproduced three ways: both inputs absent, one input absent,
# and file1 empty, all yielding 0.
#
# It wrote manifests to the fixed paths /tmp/.roms_d and /tmp/.roms_w. /tmp is
# world writable. A root-owned leftover from an earlier sudo run made the
# redirect fail, which left the OLD file intact, and comm on two stale but
# mutually consistent files returned zero differences. Reproduced: the script
# printed "3 files" and "1 files" on adjacent lines, printed two Permission
# denied errors, then concluded superset and deleted.
#
# It counted with `-type f`, while `rm -rf` removes symlinks, fifos and
# directories. Desktop-only content in any of those forms was invisible to the
# guard and destroyed by it. Emulator trees carry symlink farms and save
# directories. Reproduced: a Desktop-only symlink and fifo, guard said superset.
#
# THE OBVIOUS FIXES THAT DO NOT WORK. Worth naming because they are obvious.
#
# `set -e` does not help. Every path above returns zero. See the tombstone at
# the top of this file, where it was tested rather than assumed.
#
# Dropping `2>/dev/null` does not help either, and the old audit was wrong
# about why. Bash opens the stdout target before applying 2>/dev/null, so the
# redirect diagnostic already reached the terminal. The evidence was ON SCREEN
# and the script overruled its own stderr two lines later. A warning the
# program itself contradicts is not a safety feature. Never fix this class by
# assuming the operator reads stderr.
#
# Checksumming both trees is the correct answer and it is rejected on cost.
# 117G on a spinning drive is tens of minutes, twice, for an interactive
# script, and nobody would run the dry run. Type plus size plus symlink target
# catches every failure above at the price of a stat. State the limit plainly:
# THIS GUARD DOES NOT PROVE THE BYTES MATCH. It cannot see bit rot or a corrupt
# file of the right length. It proves a same-named, same-typed, same-sized twin
# exists. That is the trade, and it is a real one.
#
# HOW IT FAILS CLOSED NOW.
#
# mktemp, so a stale root-owned file cannot be mistaken for our manifest. A
# fresh name cannot collide, which removes the whole stale-file path rather
# than warning about it. Nothing is suppressed, and no step's status is assumed.
#
# The entry counts come FROM the manifest, not from a separate find. So a find
# that failed yields an empty manifest, yields zero entries, and refuses. The
# old code took the count from one command and the verdict from another, which
# is how it printed "3 files" and deleted anyway.
#
# The `matched` check is the one that kills the inversion. Zero missing is a
# NEGATIVE result and a broken comm produces it for free. So the guard also
# demands a POSITIVE one: comm -12 must match every single Desktop entry. A
# comm that prints nothing now scores 0 of N and refuses. Verified by replacing
# comm with a no-op that exits 0: the guard refused, where the old one deleted.
#
# `! -type d` rather than `-type f`, so symlinks, fifos and devices all count.
# Empty directories stay out on purpose. A directory carries no data and its
# contents are counted individually, so requiring it would refuse on cosmetic
# differences and buy nothing.
#
# NUL-terminated records throughout, so a newline in a ROM name cannot split
# one entry into two. GNU find -printf, sort -z and comm -z are all needed for
# this. That is a GNU dependency, and it is fine: debian, fedora and suse all
# ship GNU findutils and coreutils. This script reads /media and udisks mount
# points, so it was never going to run on darwin.
#
# LC_ALL=C on both the sort and the comm, so their collation cannot disagree.
# Today they inherit one locale and agree by luck. Pinning it costs nothing.
#
# Verified on this Ubuntu machine, coreutils 9.11: the interrupted-copy input,
# the Desktop-only symlink and fifo input, the unreadable-WorkDrive input, and
# a comm replaced by a no-op ALL now refuse. A genuine superset, including one
# with a matching symlink and an extra file on WorkDrive, still passes and
# deletes. Unverified on fedora and suse, no such machine available.

# One record per entry: type, size, symlink target, relative path, NUL ended.
# The size is what the old guard lacked. pipefail is on, so a failed cd or a
# find that could not read a subdirectory makes this whole function nonzero.
roms_manifest() {
  local root="$1" out="$2"
  ( cd "$root" && LC_ALL=C find . ! -type d -printf '%y|%s|%l|%p\0' ) \
    | LC_ALL=C sort -z > "$out"
}

# Count NUL-terminated records. `wc -l` cannot, and `wc -l` on empty input
# printing 0 is the bug this guard exists to undo.
nul_count() { tr -cd '\0' < "$1" | wc -c; }

ROMS_TMP=""
roms_cleanup() { [ -n "$ROMS_TMP" ] && rm -rf -- "$ROMS_TMP"; return 0; }
trap roms_cleanup EXIT

# Returns 0 ONLY if WorkDrive/Roms is proven a superset of Desktop/Roms.
# Prints its own reason on every refusal. Every other path returns nonzero,
# including every path where it simply could not tell.
roms_superset_proven() {
  local d_man w_man d_entries w_entries missing matched

  ROMS_TMP="$(mktemp -d)" || {
    say "  REFUSING: mktemp -d failed. Cannot build a manifest to compare."
    return 1
  }
  d_man="$ROMS_TMP/desktop"
  w_man="$ROMS_TMP/workdrive"

  roms_manifest "$DESKTOP/Roms" "$d_man" || {
    say "  REFUSING: could not read ~/Desktop/Roms in full."
    return 1
  }
  roms_manifest "$WORKDRIVE/Roms" "$w_man" || {
    say "  REFUSING: could not read $WORKDRIVE/Roms in full."
    return 1
  }

  d_entries="$(nul_count "$d_man")"
  w_entries="$(nul_count "$w_man")"
  say "  ~/Desktop/Roms : $d_entries entries"
  say "  WorkDrive/Roms : $w_entries entries"

  # An empty Desktop manifest is not "nothing to miss". It is "the scan told us
  # nothing", and it must never authorise rm -rf on the directory it failed to
  # read.
  [ "$d_entries" -gt 0 ] || {
    say "  REFUSING: the Desktop manifest is empty. Nothing was proven."
    return 1
  }

  missing="$(LC_ALL=C comm -z -23 "$d_man" "$w_man" | tr -cd '\0' | wc -c)" || {
    say "  REFUSING: comm failed while listing Desktop-only entries."
    return 1
  }
  matched="$(LC_ALL=C comm -z -12 "$d_man" "$w_man" | tr -cd '\0' | wc -c)" || {
    say "  REFUSING: comm failed while listing matched entries."
    return 1
  }

  say "  on Desktop with no identical twin on WorkDrive: $missing"

  [ "$missing" -eq 0 ] || {
    say "  REFUSING to delete: $missing Desktop entr(y/ies) have no twin."
    say "  A twin means same relative path, same type, and same size."
    return 1
  }
  # Zero missing AND an incomplete match is arithmetically impossible, so it
  # means the compare itself misfired. Refuse rather than reason about it.
  [ "$matched" -eq "$d_entries" ] || {
    say "  REFUSING: comm matched $matched of $d_entries Desktop entries."
    say "  Zero missing with an incomplete match means the compare misfired."
    return 1
  }
  return 0
}

head_ "Roms duplicate (GUARDED)"
if [ ! -d "$DESKTOP/Roms" ]; then
  say "  skip: ~/Desktop/Roms already gone"
elif [ -z "$WORKDRIVE" ]; then
  say "  REFUSING: no mounted filesystem is labelled WorkDrive."
  say "  Not deleting the only copy on the word of a path that may be empty."
elif [ ! -d "$WORKDRIVE/Roms" ]; then
  say "  REFUSING: $WORKDRIVE/Roms does not exist. Not deleting the only copy."
elif roms_superset_proven; then
  say "  verified: every Desktop entry has a same-type same-size twin on"
  say "  WorkDrive. This does NOT prove the bytes match. See the comment."
  del "$DESKTOP/Roms"
else
  say "  Reconcile onto WorkDrive first, then re-run."
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
# NOT auto-deleted, on purpose. This 18G directory is an OLD manual Minecraft
# backup, and the premise "superseded by restic mc-backup" is wrong in a way that
# loses data. mc-backup in scripts/backup.sh snapshots the LIVE PrismLauncher
# instances at ~/.local/share/PrismLauncher/instances, a DIFFERENT source. Any old
# world in here that is not in a current live instance is in no restic snapshot at
# all, so deleting on that premise is the exact inverted-guard failure the Roms
# guard was rewritten to prevent. Verify by hand, restore anything worth keeping
# into a live instance and back THAT up, then delete it yourself.
say "  SKIP (unverified premise, delete by hand): $DOCS/Minecraft Backup  (18G)"
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
