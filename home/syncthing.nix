{ config, pkgs, lib, ... }:

# Syncthing: the MacBook is the source of truth for books, coursework goes both
# ways.
#
# WHY TWO FOLDERS INSTEAD OF ONE
#
# "The MacBook is the definitive source" and "I can work from both machines" are
# mutually exclusive in Syncthing's model, so they are split rather than fudged:
#
#   books   Mac sendonly -> Linux receiveonly.  One definitive copy. Linux reads.
#   snhu    sendreceive both ways.              Edit anywhere, resolve conflicts.
#
# A receiveonly folder does NOT silently delete files that exist only on Linux.
# It flags them as "Local Additions" and waits. They disappear only if you press
# "Revert Local Changes" in the UI. That button is the one destructive thing
# here, see the migration note in docs/sync.md before pressing it.
#
# WHAT IS DELIBERATELY NOT SYNCED
#
# The Calibre library. metadata.db is SQLite, and two machines writing it
# produces .sync-conflict copies of the database and a corrupted library. The
# whole point of consolidating onto StoragePrime was to have exactly one. Use
# Calibre's content server to read the library from the Mac.
#
# TRANSPORT
#
# Over Tailscale. No port forwarding (22000/tcp+udp, 21027/udp discovery stay
# shut), no public relay servers, and it behaves the same at home or on campus.
# Syncthing is already end-to-end encrypted; Tailscale is about reachability and
# not having to punch holes in anything.
#
# THE GUI
#
# 127.0.0.1:8384, reachable as http://syncthing.test:8384 because the dnsmasq in
# `nix run .#sites` answers *.test with 127.0.0.1. Bare host:port is not how we
# work here.

let
  # The MacBook's device ID, from `syncthing cli show system` or Actions -> Show
  # ID in its GUI.
  #
  # A device ID is a PUBLIC KEY fingerprint, not a secret. Knowing it lets you
  # *offer* to sync; the other side must still accept the introduction. So it is
  # a reference and belongs in this repo. See .agents/rules.md.
  #
  # Empty until the Mac exists. While empty, the folders are still created and
  # versioned locally, they are just not shared with anything, so this module
  # evaluates and switches cleanly before the Mac is ever paired.
  macbookId = "";
  paired = macbookId != "";

  edu = "${config.home.homeDirectory}/Documents/Education";

  # Keep a year of replaced/deleted files, thinning out as they age. This is the
  # safety net for the one-way folder: if something is deleted on the Mac, that
  # deletion propagates here, and without versioning the Linux copy is simply
  # gone. .stversions is excluded from restic in scripts/backup.sh.
  versioning = {
    type = "staggered";
    params = {
      cleanInterval = "3600";
      maxAge = "31536000"; # 1 year, in seconds
    };
  };
in
{
  # Linux only, on purpose: ~/nix-config is only applied on this machine. The
  # darwin config stays in the flake in case that changes, but the Mac side of
  # Syncthing is set up through its own GUI. See docs/sync.md.
  services.syncthing = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;

    # Take ownership of the config. Without these, hand edits in the GUI drift
    # away from this file and the repo stops describing the machine.
    overrideDevices = true;
    overrideFolders = true;

    settings = {
      gui.address = "127.0.0.1:8384";

      # Do not announce to Syncthing's public discovery servers or fall back to
      # public relays. Tailscale is the transport, so neither is needed, and
      # both would leak that this machine exists to third parties.
      options = {
        globalAnnounceEnabled = false;
        relaysEnabled = false;
        urAccepted = -1; # decline usage reporting
      };

      devices = lib.optionalAttrs paired {
        macbook = { id = macbookId; };
      };

      folders = {
        # Coursework. Two way, because it is actively edited on both machines.
        # Simultaneous edits to the same file produce .sync-conflict-* files
        # rather than silently picking a winner.
        "snhu" = {
          id = "snhu";
          path = "${edu}/SNHU";
          type = "sendreceive";
          devices = lib.optionals paired [ "macbook" ];
          inherit versioning;
        };

        # Books. One way. The Mac decides what exists; this machine reads.
        "books" = {
          id = "books";
          path = "${edu}/Books";
          type = "receiveonly";
          devices = lib.optionals paired [ "macbook" ];
          inherit versioning;
        };
      };
    };
  };
}
