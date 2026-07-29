#!/usr/bin/env bash
#
# run.sh - the behavior gate for this repo. Run it before and after any change
# that claims to be a behavior-preserving refactor. A clean run means the
# observable behavior on THIS machine did not move.
#
# What it covers today:
#   detect.sh         bootstrap.sh detect_os across every distro, via fixtures
#   fish-snapshot.sh  the realized fish shell (functions, aliases, env, PATH)
#
# What it does NOT cover yet, and why:
#   The home-manager generated output (config.fish, hm-session-vars, systemd
#   units) needs a full `nix build`, which is slow and, until the new files are
#   git tracked, needs a worktree copy. That check lives in hm-output.sh and is
#   run on request, not here. git-identity.sh builds too, for the same reason,
#   and rides along under the same flag.
#
# The two --full checks answer different questions and neither replaces the
# other. hm-output.sh asks "did the generated output move", which is a golden
# and blesses whatever it was captured on. git-identity.sh asks "is the identity
# still chosen by the directory", which is an assertion and fails on the commit
# that breaks it. A golden already held the ssh config when the key selection
# was dropped from it, and it recorded the loss as expected output.
#
# Capture the fish golden first on a known-good tree:
#   tests/fish-snapshot.sh capture
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0

run() {
  local name="$1"; shift
  printf '\n=== %s ===\n' "$name"
  if bash "$@"; then
    printf '  PASS: %s\n' "$name"
  else
    printf '  FAIL: %s\n' "$name"
    fail=1
  fi
}

run "detect (os-release matrix)" "$HERE/detect.sh"
run "fish snapshot"              "$HERE/fish-snapshot.sh" check

# The home-manager output check builds Nix, so it is opt-in. Pass --full or
# --with-nix to include it. Capture its golden first: tests/hm-output.sh capture
case "${1:-}" in
  --full|--with-nix)
    run "home-manager output (builds Nix)" "$HERE/hm-output.sh" check
    run "git identity by tree (builds Nix)" "$HERE/git-identity.sh"
    run "samba time machine (builds Nix)" "$HERE/samba-timemachine.sh"
    ;;
  "") ;;   # no flag: fast checks only, the default
  # A typo'd flag must not silently skip the Nix gate and still print ALL PASSED.
  # `./run.sh --ful` used to do exactly that. Fail loudly on anything unknown.
  *)
    echo "unknown flag: $1" >&2
    echo "usage: $0 [--full|--with-nix]" >&2
    exit 2
    ;;
esac

printf '\n'
if [ "$fail" = 0 ]; then
  echo "ALL BEHAVIOR CHECKS PASSED"
else
  echo "BEHAVIOR CHECKS FAILED (see above)"
fi
exit $fail
