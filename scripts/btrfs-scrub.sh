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
#   ./btrfs-scrub.sh           # scrub all btrfs mounts, mail on failure
#   ./btrfs-scrub.sh --dry-run # show what would be scrubbed, change nothing
#
# Requires a passwordless sudo rule for the scrub, see bootstrap.sh:
#   samuelstidham ALL=(root) NOPASSWD: /usr/bin/btrfs scrub *
set -uo pipefail

MAILTO="${SCRUB_MAILTO:-dqfan2012@gmail.com}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Every mount worth checking. A mount that is absent or not btrfs is skipped, so
# this stays correct while WorkDrive is still exfat.
CANDIDATES=(
  /media/samuelstidham/StoragePrime
  /media/samuelstidham/WorkDrive
)

mounts=()
for m in "${CANDIDATES[@]}"; do
  if [ "$(findmnt -no FSTYPE "$m" 2>/dev/null)" = "btrfs" ]; then
    mounts+=("$m")
  else
    echo "skip: $m is not a mounted btrfs"
  fi
done

if [ ${#mounts[@]} -eq 0 ]; then
  echo "no btrfs mounts to scrub"
  exit 0
fi

if [ "$DRY" = 1 ]; then
  printf 'would scrub: %s\n' "${mounts[@]}"
  exit 0
fi

report=""
bad=0

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
  printf 'Subject: [btrfs] scrub found errors on %s\n' "$(hostname)"
  printf 'Content-Type: text/plain; charset=utf-8\n'
  printf '\n'
  printf 'btrfs scrub reported problems on %s at %s.\n\n' "$(hostname)" "$(date -Is)"
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
