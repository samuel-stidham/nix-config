{ config, pkgs, lib, ... }:

# Monthly btrfs scrub, with an email only when something is actually wrong.
#
# Scrub is the reason these drives are btrfs. Checksums are passive, they are
# only verified when something reads the block, so cold data like the Roms is
# never checked on its own. Scrub is the active sweep. Nothing runs it for you.
#
# Monthly, not nightly: a scrub reads the whole filesystem, hours of solid I/O on
# a spinning multi-TB disk. Bit rot does not happen nightly.
#
# This is a USER timer, not a system one, on purpose. The Gmail app password
# lives in passage, which is the user's. A root unit would have to reach into the
# user's store to read it. Running as the user means msmtp's passwordeval just
# works, and only the scrub itself needs root, through one narrow sudo rule that
# bootstrap.sh installs.

let
  scrubScript = "${config.home.homeDirectory}/nix-config/scripts/btrfs-scrub.sh";
in
{
  home.packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.msmtp ];

  # msmtp, pointed at the same Gmail account Forgejo already mails through.
  #
  # passwordeval is the whole point: msmtp shells out to passage for the password
  # at send time, so no plaintext credential is ever written to disk. That makes
  # this file a reference, not a secret, which is why it is tracked in this repo.
  # See .agents/rules.md.
  home.file.".msmtprc" = lib.mkIf pkgs.stdenv.isLinux {
    # 0600 is not optional, msmtp refuses to run on a world readable config.
    executable = false;
    text = ''
      defaults
      auth           on
      tls            on
      tls_starttls   off
      logfile        ${config.home.homeDirectory}/.local/state/msmtp.log

      account        gmail
      host           smtp.gmail.com
      port           465
      from           dqfan2012@gmail.com
      user           dqfan2012@gmail.com
      passwordeval   "passage show forgejo/mailer-passwd"

      account default : gmail
    '';
  };

  systemd.user.services.btrfs-scrub = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Scrub every btrfs mount and mail on failure";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${scrubScript}";
      # The script needs passage, msmtp, btrfs, findmnt, and sudo. A user unit
      # gets a minimal PATH, so hand it the profile explicitly.
      Environment = [
        "PATH=${config.home.profileDirectory}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      ];
      # A scrub is heavy I/O. Yield to anything the user is actually doing.
      IOSchedulingClass = "idle";
      Nice = 19;
    };
  };

  systemd.user.timers.btrfs-scrub = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Monthly btrfs scrub";
    Timer = {
      OnCalendar = "monthly";
      # The machine is not always on. Persistent means a missed month runs at the
      # next boot instead of being skipped silently, which is the difference
      # between a scrub schedule and the idea of one.
      Persistent = true;
      # Do not have it start the moment the month ticks over.
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
