#!/usr/bin/env bash
#
# keep-awake.sh - hold the machine awake while a long job runs, like the first
# restic backup. Run it in its own shell and press Ctrl-C when the job is done.
#
#   ./keep-awake.sh                     # generic
#   ./keep-awake.sh "restic first run"  # label it, shows up in systemd-inhibit --list
#
# This deliberately does NOT jiggle the mouse. systemd-inhibit asks logind to
# block idle, suspend, and hibernate directly, which is the thing that actually
# stops the machine from going down. A jiggler only simulates activity and hopes
# the idle timer notices.
#
# It is also the portable choice. A mouse jiggler needs xdotool and only works on
# X11, so it would silently do nothing on Wayland once this box is Bazzite.
#
# Screen locking is not blocked, and does not need to be: a locked screen does not
# stop a running backup. Only suspend and hibernate do.
set -euo pipefail

WHY="${1:-long running job}"

if ! command -v systemd-inhibit >/dev/null 2>&1; then
  echo "systemd-inhibit not found. Is this a systemd machine?" >&2
  exit 1
fi

echo "Holding the machine awake."
echo "  reason:  $WHY"
echo "  blocked: idle, sleep, hibernate, lid switch"
echo "  release: Ctrl-C"
echo "  inspect: systemd-inhibit --list   (from another shell)"
echo

# --mode=block is a hard block, not a delay. sleep/hibernate are refused outright
# until this process exits, rather than merely postponed.
exec systemd-inhibit \
  --what=idle:sleep:handle-lid-switch \
  --who="keep-awake" \
  --why="$WHY" \
  --mode=block \
  bash -c '
    start=$SECONDS
    trap "echo; echo \"released, the machine can sleep again\"; exit 0" INT TERM
    while true; do
      e=$(( SECONDS - start ))
      printf "\r  awake for %02d:%02d:%02d" $(( e/3600 )) $(( (e%3600)/60 )) $(( e%60 ))
      sleep 1
    done
  '
