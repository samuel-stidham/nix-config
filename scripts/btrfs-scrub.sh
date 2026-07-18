#!/usr/bin/env bash
#
# btrfs-scrub.sh - scrub every btrfs mount, email ONLY when something is wrong.
#
# Scrub reads every allocated block and verifies it against its stored checksum.
# That is the entire reason these drives are btrfs: the Roms are deliberately not
# backed up, so being told which file rotted is the only defense against silent
# bit rot. Checksums alone are passive, they are only verified when something
# reads the block. A ROM untouched for three years is never checked. Scrub is the
# active sweep that reads everything.
#
# Cadence is MONTHLY, not nightly. A scrub reads the whole filesystem, which is
# hours of solid I/O on a spinning multi-TB disk. Bit rot does not happen
# nightly, so a nightly scrub buys nothing and just adds wear and contention.
#
# Usage:
#   ./btrfs-scrub.sh                 # every btrfs mount
#   ./btrfs-scrub.sh /path/to/mount  # just that one, which is how the timers call it
#   ./btrfs-scrub.sh --dry-run       # show what would be scrubbed, change nothing
#
# The timers pass a single mount on purpose. Each drive is scrubbed on its own
# day, because a scrub saturates the disk it is reading and the two of them at
# once would contend for the same I/O budget for hours. Staggering costs nothing
# and keeps the machine usable.
#
# Requires a passwordless sudo rule for the scrub. bootstrap.sh writes it in
# btrfs_scrub_sudo, which probes sudo's own secure_path for the btrfs binary
# rather than hardcoding a path. The rule it writes names $USER and the probed
# binary:
#   $USER ALL=(root) NOPASSWD: $btrfs_bin scrub *
# That binary is /usr/sbin/btrfs on openSUSE and Fedora, and /usr/bin/btrfs on
# Ubuntu. The old comment here named a literal /usr/bin/btrfs rule for the
# literal samuelstidham. It was wrong on both the path and the user. A Fedora
# reader would hunt a rule that was never written there.
set -uo pipefail

MAILTO="${SCRUB_MAILTO:-dqfan2012@gmail.com}"
DRY=0
TARGET=""

# A target is a bare LABEL, which the timer passes, or an absolute path, which
# the documented hand-run passes. The old case accepted only /absolute and sent
# a bare word to exit 2. home/btrfs-scrub.nix freezes its mount into the unit at
# Nix eval time and Nix cannot probe a mount table, so the unit must pass a
# LABEL and let this script resolve it at runtime. Under the old case that label
# hit the reject arm and the timer died with exit 2 every month. Still fail
# closed on an unknown OPTION, so a typo'd flag does not become a phantom label.
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -*)        echo "unknown option: $arg" >&2; exit 2 ;;
    *)         TARGET="$arg" ;;
  esac
done

# WHERE THE RESOLVER COMES FROM, AND WHY THE GUARD
#
# The candidates below are filesystem LABELS, not paths, because the mountpoint
# differs per family. udisks mounts at /media/$USER on Ubuntu, /run/media/$USER
# on Fedora and openSUSE, and /var/mnt on Bazzite's ostree root. resolve() maps
# a label to wherever the kernel has it mounted right now, so no path is baked
# in. See scripts/drive-mount.sh for the whole argument.
#
# Two delivery paths, because this script runs two ways. From a checkout it is
# run by hand and drive-mount.sh sits beside it, so source it and call the
# function. In the store the systemd unit is one file pasted by
# writeShellApplication with no siblings, so call the drive-mount command that
# home/btrfs-scrub.nix lists in runtimeInputs. If neither is reachable, fail
# loud with rc=2. A missing resolver must never read as a drive that is clean.
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_dir/drive-mount.sh" ]; then
  # shellcheck source=scripts/drive-mount.sh disable=SC1091
  # source= lets `shellcheck -x` follow the sibling from a checkout. disable is
  # for the store build: writeShellApplication runs plain shellcheck with no
  # sibling present, and SC1091 "not following" would fail the build otherwise.
  . "$_dir/drive-mount.sh"
  resolve() { drive_mount "$1"; }
elif command -v drive-mount >/dev/null 2>&1; then
  resolve() { drive-mount "$1"; }
else
  echo "drive-mount resolver not found, cannot map a label to a mountpoint" >&2
  exit 2
fi

# One drive if asked for it, otherwise both drives this machine defends with a
# scrub. Defaults are LABELS, resolved at runtime to the current mountpoint.
if [ -n "$TARGET" ]; then
  CANDIDATES=("$TARGET")
else
  CANDIDATES=(StoragePrime WorkDrive)
fi

# A drive that should be here but is not mounted is a FAILURE to report, never a
# silent skip. The old code hardcoded the Ubuntu /media path, matched nothing on
# Fedora, openSUSE and Bazzite, printed "no btrfs mounts to scrub" and exited 0.
# The monthly bit-rot sweep then reported success having read zero blocks, on
# drives that scripts/backup.sh deliberately excludes from restic. That silence
# is the exact bug this change exists to kill. So a failed resolve now feeds the
# report and mails, and the run exits nonzero like a scrub error does.
report=""
bad=0
mounts=()
for c in "${CANDIDATES[@]}"; do
  case "$c" in
    /*)
      # An absolute path, used as given. The documented hand-run form. The
      # findmnt check below still confirms it is a mounted btrfs.
      m="$c"
      ;;
    *)
      # A LABEL. Resolve it to where the drive is mounted right now. Capture the
      # status: rc=0 mounted, rc=1 not mounted, rc=2 findmnt gone. No `local`
      # here, this is top level, so nothing masks the status.
      m="$(resolve "$c")" ; rc=$?
      if [ "$rc" -eq 2 ]; then
        # findmnt is gone, so util-linux is missing and the machine is broken.
        # Never skip quietly on a 2. Abort loud rather than mail from a box that
        # cannot even read its own mount table.
        echo "cannot resolve label $c: findmnt missing, util-linux gone" >&2
        exit 2
      fi
      if [ "$rc" -ne 0 ] || [ -z "$m" ]; then
        # rc=1, the drive is not mounted. Report it, do not skip it.
        echo "FAIL: labelled drive $c is not mounted, cannot scrub it" >&2
        bad=1
        report+="=== ${c} ===
label ${c} is not mounted, so it was not scrubbed

"
        continue
      fi
      ;;
  esac

  if [ "$(findmnt -no FSTYPE "$m" 2>/dev/null)" = "btrfs" ]; then
    mounts+=("$m")
  else
    echo "FAIL: $m is not a mounted btrfs, cannot scrub it" >&2
    bad=1
    report+="=== ${m} ===
${m} is not a mounted btrfs filesystem, so it was not scrubbed

"
  fi
done

if [ "$DRY" = 1 ]; then
  if [ ${#mounts[@]} -gt 0 ]; then
    printf 'would scrub: %s\n' "${mounts[@]}"
  fi
  if [ "$bad" -ne 0 ]; then
    echo "would FAIL, these did not resolve to a mounted btrfs:" >&2
    printf '%s' "$report" >&2
    exit 1
  fi
  exit 0
fi

for m in "${mounts[@]}"; do
  echo "scrubbing $m ..."
  # -B blocks until the scrub finishes instead of backgrounding it, so the exit
  # code is meaningful. -d reports per device.
  out="$(sudo -n btrfs scrub start -B -d "$m" 2>&1)"
  rc=$?
  status="$(sudo -n btrfs scrub status "$m" 2>&1)"

  # Do NOT grep for "error" here. A clean run prints "Error summary: no errors
  # found", so a naive grep for 'error' matches every single time and the alert
  # fires forever. Check for the clean phrase and treat its ABSENCE as failure.
  if [ "$rc" -ne 0 ] || ! grep -q 'no errors found' <<<"$status"; then
    bad=1
    report+="=== ${m} ===
exit: ${rc}

${out}

${status}

"
  else
    echo "  clean: $m"
  fi
done

if [ "$bad" -eq 0 ]; then
  echo "all scrubs clean, no mail sent"
  exit 0
fi

echo "SCRUB FOUND PROBLEMS, mailing ${MAILTO}" >&2

if ! command -v msmtp >/dev/null 2>&1; then
  echo "msmtp not on PATH, cannot send the report. It is above." >&2
  printf '%s\n' "$report" >&2
  exit 1
fi

# msmtp reads the password through passwordeval -> passage, so no plaintext
# credential exists on disk. See home/btrfs-scrub.nix.
{
  printf 'To: %s\n' "$MAILTO"
  printf 'From: %s\n' "$MAILTO"
  # uname -n, not hostname. hostname is not in coreutils and is absent on a
  # minimal Fedora, which would leave the subject and body blank. uname -n prints
  # the nodename, ships in coreutils, and is already on the unit PATH.
  printf 'Subject: [btrfs] scrub found errors on %s\n' "$(uname -n)"
  printf 'Content-Type: text/plain; charset=utf-8\n'
  printf '\n'
  printf 'btrfs scrub reported problems on %s at %s.\n\n' "$(uname -n)" "$(date -Is)"
  printf 'A scrub error means a block no longer matches its checksum. These\n'
  printf 'drives are single disk, so btrfs can detect the damage but cannot\n'
  printf 'repair it. The file named below has rotted and needs to be replaced\n'
  printf 'from another copy.\n\n'
  printf '%s\n' "$report"
  printf 'Find the affected files with:\n'
  printf '  sudo dmesg | grep -i btrfs\n'
} | msmtp "$MAILTO"

echo "report mailed"
exit 1
