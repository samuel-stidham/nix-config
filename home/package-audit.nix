{ config, pkgs, lib, ... }:

# Weekly package audit, mailed only when there is drift.
#
# The dev-machine rule is to install packages with each language's own package
# manager freely, but to RECORD what sticks so a fresh machine rebuilds it. Left
# to memory that rule rots: a `cargo install` or `go install` from months ago is
# on PATH, works, and lives in no module, so the next machine never gets it. This
# timer is the honesty check. It sorts every managed install into redundant (Nix
# already provides it, delete the copy), recorded (deliberate, in the record
# file), or unrecorded (codify, record, or delete). See scripts/package-audit.sh.
#
# A USER timer, like btrfs-scrub, and for the same reason: it mails through the
# user's msmtp, whose Gmail password comes from the user's passage vault. It reuses
# the msmtp package and ~/.msmtprc that home/btrfs-scrub.nix already defines, so
# neither is redeclared here.

let
  # Into the store, not a checkout path, so the unit survives the repo moving.
  # Same trade as btrfs-scrub: editing the script takes effect on the next switch.
  auditScript = pkgs.writeShellApplication {
    name = "package-audit";
    # opam is the only manager queried by its own tool. The rest are read straight
    # off their bin directories, so no cargo, go, npm or deno binary is needed.
    runtimeInputs = with pkgs; [ coreutils gnugrep findutils msmtp opam ];
    text = builtins.readFile ../scripts/package-audit.sh;
    # The script sets its own `set -uo pipefail`. No -e, because it must survive a
    # failing probe to still report and mail.
    bashOptions = [ ];
  };

  # The record of deliberately-uncodified installs, copied into the store so the
  # unit reads an immutable path rather than a checkout. Editing
  # docs/recorded-packages.txt takes effect on the next home-manager switch.
  recordFile = ../docs/recorded-packages.txt;
in
{
  systemd.user.services.package-audit = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit.Description = "Audit language-manager installs against the Nix record";
    Service = {
      Type = "oneshot";
      ExecStart = "${auditScript}/bin/package-audit --quiet";
      # The script exits 1 when it finds drift, which is a normal weekly outcome,
      # not a unit failure, so both 0 and 1 count as success. A genuine crash would
      # be a different code. passage is a user profile tool that reads ~/.passage,
      # so the user profile bin plus the base dirs is the whole PATH msmtp needs.
      SuccessExitStatus = "0 1";
      Environment = [
        "PATH=${config.home.profileDirectory}/bin:/usr/bin:/bin"
        "RECORDED_PACKAGES=${recordFile}"
        "AUDIT_MAILTO=dqfan2012@gmail.com"
      ];
    };
  };

  # Weekly. This is a nudge, not a safety system like the scrub, so a loose cadence
  # is right. Persistent catches the weeks the machine was off at the trigger.
  systemd.user.timers.package-audit = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit.Description = "Weekly language-manager package audit";
    Timer = {
      OnCalendar = "Sun 10:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
