# drive-mount: the labelled-drive resolver, as a command in the store.
#
# The design, the argument for /mnt, and the two verbs are all in
# scripts/drive-mount.sh. Read that first. This file is only the delivery.
#
# WHY THIS EXISTS SEPARATELY FROM THE SCRIPT
#
# The shell callers source scripts/drive-mount.sh as a sibling from the checkout.
# A Nix built systemd unit cannot. writeShellApplication pastes one file into one
# store path, so `$(dirname "$0")` there is a bin directory with no siblings in
# it. The unit needs a command on PATH instead, and this is that command.
#
# It matters most for home/btrfs-scrub.nix, which interpolates its mount path
# into the unit at eval time. No runtime environment variable can reach a frozen
# path. Nix cannot probe the mount table during evaluation either, because pure
# flake evaluation forbids it, builtins.exec is off, and an import-from-derivation
# would bake the answer into a store path, which is the same freeze with more
# steps. So the unit passes a LABEL and the script resolves it at runtime, using
# this.
#
# WHY A parts/ FUNCTION RATHER THAN A LET IN ONE MODULE
#
# home/btrfs-scrub.nix builds its writeShellApplication inline in a let, which is
# right for a package with one consumer. This one has more than one, so it
# follows parts/safetybox.nix instead and takes pkgs. Any module that needs it:
#
#   driveMount = import ../parts/drive-mount.nix pkgs;
#
# then puts driveMount in its own runtimeInputs. A missing resolver is then a
# build error rather than a 3am timer failure, which is the same reason
# home/btrfs-scrub.nix:37-40 lists its tools explicitly.
pkgs:

pkgs.writeShellApplication {
  name = "drive-mount";
  # findmnt only. Everything else the script uses is a bash builtin, on purpose:
  # a resolver that answers "where is the drive" should not itself need a drive's
  # worth of dependencies. A systemd user unit gets a minimal PATH, and
  # runtimeInputs is what puts findmnt on it.
  runtimeInputs = [ pkgs.util-linux ];
  text = builtins.readFile ../scripts/drive-mount.sh;
  # No `set -euo pipefail` prepended, and this is not the usual reason.
  # home/btrfs-scrub.nix and home/home-certs.nix pass this because their scripts
  # must survive a nonzero exit to report on it. This one passes it because the
  # same file is also SOURCED, into bootstrap.sh under `set -euo pipefail` and
  # into the education scripts under `set -uo pipefail`. Letting
  # writeShellApplication impose options here would give one file two behaviours
  # depending on how it was reached, and the store copy is the one nobody tests
  # by hand.
  bashOptions = [ ];
}
