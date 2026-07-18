#!/usr/bin/env bash
#
# drive-mount.sh - where a labelled drive IS, and where this repo wants it.
#
# Two questions that look like one question. Nine sites in this repo answered
# both of them with the literal /media/samuelstidham/StoragePrime, and that
# literal is wrong twice over. This file exists so each question has one answer,
# in one place, reachable from a shell script, from bootstrap.sh, and from a
# systemd unit built by Nix.
#
# THE FAILURE
#
# udisks mounts a filesystem at /run/media/$USER/LABEL. Its shared alternative is
# /media/LABEL, with no username at all. Ubuntu patches that to /media/$USER/LABEL.
# So the literal in this repo is one family's patch. On Fedora, openSUSE and
# Bazzite it names a directory that does not exist.
#
# The consequence is silence, not a crash. scripts/btrfs-scrub.sh tests each
# candidate with `findmnt -no FSTYPE`, finds nothing, prints "no btrfs mounts to
# scrub" and exits 0. The monthly bit-rot sweep reports success having read
# nothing. These two drives are btrfs FOR scrub, and scripts/backup.sh
# deliberately excludes them from restic. That sweep is the only thing standing
# between a rotted ROM and never being told.
#
# WHY THE OBVIOUS FIX IS WRONG
#
# The obvious fix is the one already in the tree. Pin both drives in /etc/fstab
# by UUID, as bootstrap.sh mount_drives does, and call the path distro agnostic
# because we chose it rather than inherited it. That argument is at
# bootstrap.sh:526 and it is almost right. It fails on one word, /media.
#
# On an ostree system, Bazzite included, / is mounted read only. The writable
# state directories are reached through symlinks baked into the image. ostree's
# own porting guide lists the recommended set, and /media is not in it:
#
#   /home -> /var/home, /opt -> /var/opt, /srv -> /var/srv,
#   /root -> /var/roothome, /usr/local -> /var/usrlocal,
#   /mnt -> /var/mnt, /tmp -> /sysroot/tmp
#     ostreedev.github.io/ostree/adapting-existing/, read 2026-07-16
#
# The same page's systemd-tmpfiles snippet provisions `d /var/mnt` and
# `d /run/media`, and never a writable /media. Fedora's filesystem.spec ships
# /media as a real directory, so on Bazzite it is a real directory inside a read
# only root. `sudo mkdir -p /media/samuelstidham/StoragePrime` returns
# `Read-only file system`.
#
# That failure is loud exactly once. bootstrap.sh:553 writes nofail into the
# mount options, correctly, so a dead drive never blocks a boot. The side effect
# is that a mount whose mountpoint cannot be created is skipped at every boot
# after that, without a word.
#
# Do not reach for `mount -o remount,rw /` to get around it. An ostree
# deployment is a checkout of a commit, and an upgrade is a new checkout. A
# directory created that way is gone after the next rpm-ostree upgrade. It works,
# then stops weeks later, with no change to this repo.
#
# WHY /mnt
#
# /mnt is the only root that is writable and persistent on all four targets while
# needing neither a probe nor a $FAMILY branch. FHS 3.0 requires both /media and
# /mnt in the root filesystem, neither is marked optional, and Fedora's
# filesystem.spec ships `%dir /mnt`. On ostree /mnt is the symlink to the
# writable /var/mnt quoted above.
#
# /run/media/$USER was the other candidate and it is worse. /run is a tmpfs, so a
# mountpoint under it cannot be pinned in fstab and survive a boot.
#
# systemd resolves the ostree symlink on our behalf. From
# systemd-fstab-generator(8):
#
#   Because mount units will refuse mounts where the target is a symbolic link,
#   this generator will resolve any symlinks as far as possible when processing
#   /etc/fstab in order to enhance backwards compatibility.
#     man7.org/linux/man-pages/man8/systemd-fstab-generator.8.html, read
#     2026-07-16
#
# So /mnt/StoragePrime in fstab lands at /var/mnt/StoragePrime on Bazzite and at
# /mnt/StoragePrime everywhere else. This file therefore canonicalises nothing.
# The generator already did it, and a `readlink -f` here would only duplicate it.
# It is also why the probe below is the primary verb: on one family the answer is
# a path no caller could have built by hand.
#
# THE TRADE, AND IT IS REAL
#
# FHS 3.12 calls /mnt a place "so that the system administrator may temporarily
# mount a filesystem as needed". These mounts are permanent, so this is a
# deliberate deviation from the letter of the spec. FHS 3.11 calls /media the
# mount point "for removable media such as floppy disks, cdroms and zip disks".
# StoragePrime is an internal Seagate IronWolf and WorkDrive an internal WDC
# spinner, see drives_stay_awake in bootstrap.sh. Neither is removable, so /media
# was never right either. FHS 3.0 has no slot for a permanently installed extra
# drive. There is no clean answer here, only a working one.
#
# THIS MACHINE WILL NOT MIGRATE, AND THAT IS ON PURPOSE
#
# bootstrap.sh:562 skips any UUID already present in /etc/fstab. This machine's
# fstab already pins both drives under /media/samuelstidham, so mount_drives will
# print "already in fstab" and this machine keeps /media for good. A fresh
# machine gets /mnt. Two machines, one repo, different paths.
#
# Nothing breaks, because every consumer asks drive_mount where the drive IS
# instead of building a path from a root. That is the entire reason the probe is
# the primary verb rather than a root constant. Moving this machine is a manual
# job and nothing here does it for you: edit the two fstab lines, mkdir the new
# mountpoints, `sudo mount -a`, then fix calibre.
#
# Calibre is the one thing no resolver can reach. Its library_path lives in
# ~/.config/calibre/global.py.json, which this repo has never written. See
# bootstrap.sh:951 and scripts/backup.sh:52, which both just ask a human to keep
# it in step. On a fresh machine a human sets it once, to
# /mnt/StoragePrime/Books/Calibre Library. Point it at a path that is not mounted
# and restic backs up an empty directory, and nobody finds out until a restore.
#
# THE TWO VERBS, AND WHICH ONE YOU WANT
#
#   drive_mount LABEL         where the drive IS. Almost certainly this one.
#   drive_fstab_target LABEL  where bootstrap.sh's fstab entry should point.
#
# drive_fstab_target exists for _add_mount in bootstrap.sh and for nothing else.
# It returns a constant, so it can answer before the drive is mounted, which is
# the one moment drive_mount cannot. Calling it from a consumer rebuilds the bug
# this file removes: on Bazzite it says /mnt/StoragePrime while the drive is
# really at /var/mnt/StoragePrime.
#
# A single verb would be worse than either. Feed "where is it now" into
# _add_mount on a fresh Fedora, where udisks has already mounted the drive at
# /run/media/samuelstidham/WorkDrive, and that tmpfs path gets written into
# /etc/fstab permanently. That is the exact outcome bootstrap.sh:526 exists to
# prevent.
#
# NEVER WRITE local m="$(drive_mount X)"
#
# `local` is a builtin. Its own exit status is what set -e sees, so the
# resolver's status is discarded and the caller carries on with an empty string.
# Measured on this machine: the plain assignment aborts at rc=1, the `local` form
# survives with X unset and rc=0. `set -u` does not save you either, because the
# variable is set and merely empty. Declare first, assign second, as
# bootstrap.sh:549-551 already does:
#
#   local m
#   m="$(drive_mount StoragePrime)" || m=""
#
# HOW EACH CALLER GETS AT THIS
#
# A script in scripts/ sources its sibling, since it is run by hand from the
# checkout:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/drive-mount.sh"
#
# bootstrap.sh sources it the same way, relative to itself rather than to
# FLAKE_DIR. bootstrap.sh runs before Nix exists and cannot depend on the store,
# and the repo has moved before, see the tombstone in home/btrfs-scrub.nix.
#
# A Nix built systemd unit cannot source anything, because writeShellApplication
# pastes one file into one store path and the siblings are not there. It gets the
# `drive-mount` command instead, from parts/drive-mount.nix, listed in
# runtimeInputs so a missing resolver is a build error rather than a 3am failure.
# That is also the only shape that works for home/btrfs-scrub.nix, which freezes
# its mount path into the unit at eval time. Nix cannot probe a mount table
# during a pure evaluation, so the unit must pass a LABEL and let the script
# resolve it at runtime.
#
# Usage as a command:
#   drive-mount StoragePrime      # prints the mountpoint, or nothing
#
# Exit status, and callers must tell 1 and 2 apart:
#   0  mounted. Exactly one line on stdout, no trailing directory.
#   1  not mounted, or no such label. Normal. A caller may skip, or may not:
#      an unmounted drive means "skip, nothing to move" to scripts/reorg.sh and
#      must mean "report a failure" to scripts/btrfs-scrub.sh. A bit-rot sweep
#      that exits 0 having read nothing is the bug this file was written to kill.
#   2  the question could not be asked. No label given, or findmnt is not on
#      PATH, which means util-linux is missing and the machine is broken. Never
#      skip quietly on a 2.
#
# This file sets no shell options. It is sourced into callers that set their own,
# `set -euo pipefail` in bootstrap.sh and scripts/backup.sh, `set -uo pipefail`
# in scripts/btrfs-scrub.sh and the education scripts. It must behave the same in
# all of them, which is also why parts/drive-mount.nix passes `bashOptions = [ ]`.

# Where LABEL is mounted right now, according to the kernel.
#
# findmnt, not blkid and not lsblk. bootstrap.sh:546 records that blkid needs
# root and hands a normal user an empty string, which is the silent-skip shape
# this whole file is against. findmnt reads the mount table unprivileged.
#
# No pipe to `head -1`, deliberately, and this is not style. Under
# `set -o pipefail` a pipeline reports its rightmost failure, and a producer that
# is still writing when head exits takes SIGPIPE. Measured here:
# `out="$(seq 1 200000 | head -1)"` returns rc=141 with the right answer in out.
# A caller writing `|| return 1` around that reads a mounted drive as absent.
#
# Be honest about the size of it. findmnt answers in a line or two, which fits
# the pipe buffer, so it exits 0 before head can close on it. Measured:
# `findmnt -rn -o TARGET -S LABEL=WorkDrive | head -1` gave rc=0 today. So this
# is a hazard the prior art at reorg.sh:109 has never actually hit. Bash takes
# the first line here with no second process, which costs nothing and means the
# question never has to be asked again.
#
# First line, not the only line. One line per mount of that filesystem, so the
# same subvolume mounted twice answers twice, and this returns whichever the
# kernel lists first. That is mount order rather than a decision. Measured on
# this machine: both labels answer exactly once, and FSROOT is / for both, so
# there are no subvolume mounts to be ambiguous about yet.
drive_mount() {
  local label="${1:-}"
  if [ -z "$label" ]; then
    printf 'drive_mount: no label given\n' >&2
    return 2
  fi
  # Distinct from rc=1 on purpose. "The drive is not mounted" is normal and a
  # caller may reasonably skip it. "util-linux is missing" is a broken machine
  # and no caller should ever skip quietly on it. reorg.sh's local probe, which
  # this supersedes, returned 1 for both and could not tell them apart.
  if ! command -v findmnt >/dev/null 2>&1; then
    printf 'drive_mount: findmnt is not on PATH, util-linux is missing\n' >&2
    return 2
  fi

  local out
  out="$(findmnt -rn -o TARGET -S "LABEL=$label" 2>/dev/null)" || out=""
  local target="${out%%$'\n'*}"
  [ -n "$target" ] || return 1
  printf '%s\n' "$target"
}

# Where bootstrap.sh should pin LABEL in /etc/fstab.
#
# For _add_mount and nothing else. Read the two-verbs section above before you
# reach for this. A constant, so it answers on a machine where the drive has
# never been mounted, which is the one thing drive_mount cannot do.
#
# No username in the path. The old literal hardcoded samuelstidham while
# bootstrap.sh:588 chowned it to $USER, so on any other account the two
# disagreed. udisks' own shared form carries no username either.
drive_fstab_target() {
  local label="${1:-}"
  if [ -z "$label" ]; then
    printf 'drive_fstab_target: no label given\n' >&2
    return 2
  fi
  printf '/mnt/%s\n' "$label"
}

# Executed rather than sourced? Then be the `drive-mount` command.
#
# One file, two delivery paths, no second copy to drift out of step. When
# writeShellApplication pastes this into a store path, BASH_SOURCE[0] and $0 are
# both that store path and the dispatcher fires. When bootstrap.sh sources it,
# BASH_SOURCE[0] is this file and $0 is ./bootstrap.sh, so it stays quiet and
# only defines the functions. Verified both ways, see
# .git/agent-logs/mount-root-writer.md.
#
# Only the probe is exposed as a command. drive_fstab_target has exactly one
# caller and that caller sources this file, so putting it on a PATH would only
# invite the confusion the two-verbs section warns about.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  drive_mount "$@"
fi
