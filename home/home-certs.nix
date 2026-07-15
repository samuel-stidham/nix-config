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
  certScript = "${config.home.homeDirectory}/nix-config/scripts/home-certs.sh";
in
{
  home.packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.lego ];

  systemd.user.services.home-certs = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Renew the *.home.samuelstidham.me certificate";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${certScript}";
      # The script needs lego, passage, openssl and install. A user unit gets a
      # minimal PATH, so hand it the profile explicitly.
      Environment = [
        "PATH=${config.home.profileDirectory}/bin:/usr/bin:/bin"
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
