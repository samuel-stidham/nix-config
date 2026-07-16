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
  # The script goes INTO the store, rather than the unit pointing at a path in a
  # git checkout. The old form was:
  #
  #   scrubScript = "${config.home.homeDirectory}/nix-config/scripts/btrfs-scrub.sh";
  #
  # which quietly hardcoded where this repo lives. Moving the repo broke all three
  # timers at once, including the cert renewal, and nothing said so: a systemd
  # oneshot pointing at a missing file just fails at 03:00 on the 1st.
  #
  # ../scripts/ is relative to THIS file and resolved at eval time, so the unit
  # ends up referencing an immutable /nix/store path. The repo can now live
  # anywhere, or be deleted, and the timers still run.
  #
  # The tradeoff is real: editing the script no longer takes effect until the next
  # `home-manager switch`. For something that runs monthly at 3am, that is the
  # right trade. It also means the script that runs is the one that was reviewed.
  scrubScript = pkgs.writeShellApplication {
    name = "btrfs-scrub";
    # The script shells out to these. A systemd user unit gets a minimal PATH, and
    # writeShellApplication puts exactly this set on it, so a missing tool is a
    # build error rather than a 3am failure.
    runtimeInputs = with pkgs; [ msmtp coreutils gnugrep util-linux ];
    text = builtins.readFile ../scripts/btrfs-scrub.sh;
    # The script sets its own `set -uo pipefail` on purpose: it must survive a
    # scrub returning nonzero so it can mail the report.
    bashOptions = [ ];
  };

  # The btrfs drives, and the day each one is scrubbed. Add a drive here and it
  # gets a service and a timer automatically.
  drives = {
    storageprime = "/media/samuelstidham/StoragePrime";
    workdrive = "/media/samuelstidham/WorkDrive";
  };

  # Staggered by a day. Both are multi-TB spinners sharing one I/O budget, so
  # scrubbing them on the same night would just make both take longer and make
  # the machine unpleasant while they run.
  schedule = {
    storageprime = "*-*-01 03:00:00";
    workdrive = "*-*-02 03:00:00";
  };
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

  # One service and one timer per drive, rather than a single unit that scrubs
  # both. A scrub saturates the disk it reads, for hours on a multi-TB spinner.
  # Running both at once would put two of those in contention for the same I/O
  # budget, so each drive gets its own day:
  #
  #   StoragePrime  the 1st of the month, 03:00
  #   WorkDrive     the 2nd of the month, 03:00
  #
  # Persistent=true matters more than the exact hour. The machine is not always
  # on, and without it a missed month is skipped in silence, which is the
  # difference between a scrub schedule and the idea of one.
  systemd.user.services = lib.mkIf pkgs.stdenv.isLinux (
    lib.mapAttrs' (name: mount: lib.nameValuePair "btrfs-scrub-${name}" {
      Unit.Description = "Scrub ${mount} and mail on failure";
      Service = {
        Type = "oneshot";
        ExecStart = "${scrubScript}/bin/btrfs-scrub ${mount}";
        # passage and sudo still come from outside: passage is a user profile tool
        # that must read ~/.passage, and btrfs/sudo are distro binaries on
        # purpose, since sudo's secure_path cannot see the nix profile. See
        # home/filesystems.nix.
        Environment = [
          "PATH=${config.home.profileDirectory}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ];
        # Heavy I/O. Yield to anything the user is actually doing.
        IOSchedulingClass = "idle";
        Nice = 19;
      };
    }) drives
  );

  systemd.user.timers = lib.mkIf pkgs.stdenv.isLinux (
    lib.mapAttrs' (name: mount: lib.nameValuePair "btrfs-scrub-${name}" {
      Unit.Description = "Monthly btrfs scrub of ${mount}";
      Timer = {
        OnCalendar = schedule.${name};
        Persistent = true;
        # Do not start on the exact stroke of the hour.
        RandomizedDelaySec = "30m";
      };
      Install.WantedBy = [ "timers.target" ];
    }) drives
  );
}
