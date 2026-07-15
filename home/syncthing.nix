{ config, pkgs, lib, ... }:

# Syncthing: SNHU coursework and course library, shared with the MacBook.
#
# This file describes what is actually running. It was rewritten to match the
# setup made on the Mac side, which replaced an earlier guess of mine that had
# books one-way and coursework two-way. The real layout is two two-way folders:
#
#   snhu-coursework   ~/Sync/snhu-coursework   assignments, submissions, notes
#   snhu-library      ~/Sync/snhu-library      per-course textbooks
#
# Both are sendreceive because both machines are worked from. Simultaneous edits
# to one file produce a .sync-conflict-<date>-* file next to it rather than a
# silent winner. That is Syncthing refusing to guess; resolve by hand.
#
# WHY overrideFolders MATTERS
#
# It is true, so this file wins and the GUI loses on every switch. That is the
# point: the repo describes the machine. It also nearly caused a disaster. This
# module used to declare folders named `snhu` and `books` that the Mac never
# shared. Left alone, the next `home-manager switch` would have deleted the real
# snhu-coursework and snhu-library folders and the Mac device from the config.
# If you set something up in the GUI, put it here in the same sitting.
#
# WHAT IS DELIBERATELY NOT SYNCED
#
# The Calibre library. metadata.db is SQLite, and two machines writing it
# produces .sync-conflict copies of the database and a corrupted library. The
# library lives once, on StoragePrime. Read it from the Mac with Calibre's
# content server.
#
# ~/Documents/Education/Books is not synced either. It is the source material we
# already imported into Calibre, not a working set.
#
# REACHABILITY, THE SHARP EDGE
#
# globalAnnounceEnabled and relaysEnabled are both off, so this machine is never
# announced to Syncthing's public infrastructure. The cost is real: discovery is
# then LOCAL ONLY. The two machines find each other over the LAN and nothing
# else. When the MacBook leaves the house, sync stops until it comes back.
#
# The fix is a static Tailscale address on the device below, not turning global
# discovery back on. See docs/sync.md.

let
  # Device IDs are public key fingerprints, not secrets. Knowing one lets you
  # *offer* to sync; the other side must still accept. So they are references
  # and belong in this repo. See .agents/rules.md.
  macbook = "4IM7O6G-XZONB7G-UUJSTYX-JR7CTR6-QQFE3HD-YTMK6IL-J66BG26-MUOMGQR";

  sync = "${config.home.homeDirectory}/Sync";
in
{
  # Linux only. This repo is applied here and nowhere else, see the note in
  # flake.nix about the darwin config being kept but unused. The Mac's side of
  # Syncthing is configured through its own GUI.
  services.syncthing = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;

    overrideDevices = true;
    overrideFolders = true;

    settings = {
      gui.address = "127.0.0.1:8384";

      options = {
        # Not announced to Syncthing's public discovery, and no public relays.
        # Local discovery still works, which is how the Mac is found today.
        globalAnnounceEnabled = false;
        relaysEnabled = false;
        urAccepted = -1; # decline usage reporting
      };

      devices."Samuels-MacBook-Pro-M4" = {
        id = macbook;
        # "dynamic" is local discovery, which only works on this LAN. The static
        # tailscale address is what makes the Mac reachable from anywhere, and it
        # is the reason global discovery and public relays can stay off.
        #
        # Both are listed, in that order, on purpose. Syncthing tries them all;
        # local discovery wins at home and the tailnet address covers everywhere
        # else. Keeping "dynamic" means the LAN still works if tailscale is down.
        #
        # The IP, not the MagicDNS name. 100.116.77.69 is assigned to this device
        # by tailscale and does not change, whereas the .ts.net name has to
        # resolve inside syncthing's own process, which is a dependency this does
        # not need. Tailscale picks the direct LAN path when both are home
        # anyway, so there is no speed cost to naming the tailnet address.
        addresses = [ "dynamic" "tcp://100.116.77.69:22000" ];
      };

      folders = {
        # Coursework. Staggered versioning keeps a year of replaced and deleted
        # files, thinning with age. This is the folder that holds submitted work,
        # so a deletion propagating from the Mac must be recoverable.
        "snhu-coursework" = {
          id = "snhu-coursework";
          path = "${sync}/snhu-coursework";
          type = "sendreceive";
          devices = [ "Samuels-MacBook-Pro-M4" ];
          versioning = {
            type = "staggered";
            params.maxAge = "31536000"; # 1 year, in seconds
          };
        };

        # Course textbooks. Trashcan rather than staggered: these are large PDFs
        # that rarely change, so keeping every historical revision buys nothing.
        # 90 days of "I deleted that by mistake" is the whole requirement.
        "snhu-library" = {
          id = "snhu-library";
          path = "${sync}/snhu-library";
          type = "sendreceive";
          devices = [ "Samuels-MacBook-Pro-M4" ];
          versioning = {
            type = "trashcan";
            params.cleanoutDays = "90";
          };
        };
      };
    };
  };
}
