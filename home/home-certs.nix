{ config, pkgs, lib, ... }:

# The TLS cert for *.home.samuelstidham.me, and the timer that keeps it alive.
#
# Let's Encrypt certs last 90 days. A cert obtained by hand is a 90-day timer on
# an outage you will have forgotten the cause of, so the renewal is the point of
# this module, not the issuance.
#
# The whole design is explained in scripts/home-certs.sh. The short version:
# DNS-01, because the home lab names resolve to CGNAT addresses that Let's
# Encrypt can never connect to, and because DNS-01 is the only challenge that can
# issue a wildcard. The wildcard matters for privacy as much as convenience:
# every hostname in a cert is published to public Certificate Transparency logs,
# so *.home.samuelstidham.me tells the world nothing about what runs behind it.
#
# WHY DAILY, FOR A 90 DAY CERT
#
# lego renews only inside --days 30, so 60 of these runs do nothing at all and
# cost one process each. Daily means ~30 chances to notice a problem before the
# cert actually expires. A monthly timer would give roughly one, and if that run
# failed the next signal would be a browser error.
#
# This is a USER timer for the same reason btrfs-scrub is: the Cloudflare token
# lives in the user's passage store, and a root unit would have to reach into it.

let
  # In the store, not in a checkout. The old form pointed at
  # ${config.home.homeDirectory}/nix-config/scripts/home-certs.sh, which meant
  # this timer depended on the repo staying at one path forever. Moving the repo
  # broke it silently, and the failure would have surfaced in October as an
  # expired certificate with no obvious cause.
  #
  # ../scripts/ resolves at eval time relative to this file, so the unit points at
  # an immutable /nix/store path. Editing the script now needs a switch, which for
  # a daily renewal is the correct trade.
  certScript = pkgs.writeShellApplication {
    name = "home-certs";
    # jq parses safetybox's JSON, openssl reports the cert, coreutils installs it.
    # lego, passage, safetybox and systemctl come from PATH below, since they are
    # profile or system tools rather than build inputs.
    runtimeInputs = with pkgs; [ jq openssl coreutils ];
    text = builtins.readFile ../scripts/home-certs.sh;
    # The script handles its own failures and prints guidance, so do not let
    # writeShellApplication impose -e on top of its `set -uo pipefail`.
    bashOptions = [ ];
  };
in
{
  home.packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.lego ];

  systemd.user.services.home-certs = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Renew the *.home.samuelstidham.me certificate";
    Service = {
      Type = "oneshot";
      ExecStart = "${certScript}/bin/home-certs";
      # The script needs lego, passage, openssl, install, and systemctl to reload
      # nginx once the cert changes. A user unit gets a minimal PATH, so hand it
      # the profile explicitly. /run/current-system/sw/bin is where systemctl
      # lives on this non-NixOS host via /usr/bin, kept explicit so a missing
      # systemctl fails loudly rather than skipping the reload in silence.
      Environment = [
        "PATH=${config.home.profileDirectory}/bin:${pkgs.systemd}/bin:/usr/bin:/bin"
      ];
    };
  };

  systemd.user.timers.home-certs = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Daily renewal check for *.home.samuelstidham.me";
    Timer = {
      OnCalendar = "*-*-* 04:30:00";
      # The machine is not always on. Without this a missed window is skipped in
      # silence, which is the difference between a renewal schedule and the idea
      # of one.
      Persistent = true;
      RandomizedDelaySec = "45m";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
