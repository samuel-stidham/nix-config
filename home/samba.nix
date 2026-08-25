{ config, pkgs, lib, ... }:

# Samba: a Time Machine target for the MacBook, served off StoragePrime.
#
# Syncthing already shares coursework with the Mac, but sync is not backup. A
# file deleted on the Mac propagates. Time Machine is the thing that remembers
# what the file looked like last Tuesday, and it wants a destination that is
# always there.
#
# WHY StoragePrime AND NOT WorkDrive
#
# WorkDrive is empty and StoragePrime already holds Books and Documents, so the
# empty drive looks like the obvious home for backups. It is the wrong choice,
# and the reason is how each drive is attached rather than how full it is.
#
#   sda  StoragePrime  ST12000VN0008  internal SATA, 6.0 Gbps, 11T free
#   sdb  WorkDrive     WD80EZAZ       USB behind a My Book 25EE bridge, 7.3T free
#
# StoragePrime is a Seagate IronWolf, a NAS drive built for a duty cycle exactly
# like this one. WorkDrive is a consumer disk inside an external enclosure, and
# the enclosure is the problem. The kernel says so at attach:
#
#   sd 8:0:0:0: [sdb] No Caching mode page found
#   sd 8:0:0:0: [sdb] Assuming drive cache: write through
#
# The USB bridge does not pass SCSI cache control through, so the kernel cannot
# see or manage the drive's write cache. btrfs depends on flushes actually
# reaching the platter to keep its trees consistent. A bridge that reports a
# flush it did not perform corrupts the filesystem on power loss, and USB bridges
# are also the thing that drops off the bus under sustained load. Time Machine
# writes a sparsebundle continuously for hours, and a disconnect mid-write leaves
# a sparsebundle macOS refuses to reuse.
#
# So the backup goes on the drive that is bolted to the SATA controller. The
# external drive is better used as the copy that lives unplugged, which is a
# property USB has and SATA does not.
#
# THE SHARE IS NOT THE DRIVE ROOT
#
# vfs_fruit(8) is blunt that `fruit:time machine max size` is computed by
# counting sparsebundle band files, and that nothing else may live on the volume
# or it is not accounted for. StoragePrime holds a Calibre library and a decade
# of documents, so the share is a dedicated subdirectory and the cap describes
# only what Time Machine put there.
#
# WHAT IS NOT VERIFIED
#
# Nothing here has been tested against a Mac. No backup has been taken, no
# destination has been selected in Time Machine, and no sparsebundle exists. What
# was verified on this machine is listed in the writer log: the chattr sequence,
# xattr support on btrfs, that samba is built without mDNS, the port floor, and
# that testparm accepts the generated config. The Mac side is unverified.

let
  # The label resolver, as a command in the store. The unit passes a LABEL and
  # the script asks the kernel where that drive is right now. Nix cannot probe a
  # mount table during pure evaluation, so a mountpoint frozen at eval time would
  # name the Ubuntu path and match nothing on Fedora, openSUSE or Bazzite. See
  # parts/drive-mount.nix and the tombstone in home/btrfs-scrub.nix.
  driveMount = import ../parts/drive-mount.nix pkgs;

  # Everything smbd would normally keep under /var/lib/samba and /run/samba.
  # Under the home directory because this runs as a user service with no root.
  stateDir = "${config.home.homeDirectory}/.local/share/samba";

  # A filesystem LABEL, not a path, for the reason in the driveMount comment.
  driveLabel = "StoragePrime";

  # KEEP IN SYNC. This name is the smb.conf share name AND the adVN value in the
  # _adisk._tcp record. If the two disagree, Time Machine offers a destination
  # that fails to mount, which reads as a broken drive rather than a typo.
  shareName = "timemachine";

  # What Time Machine is told the volume holds.
  #
  # Time Machine thins its own history to fit whatever it is given, so this is
  # the knob that decides how far back a restore can reach. Too small quietly
  # shortens that history, too large only risks filling a drive with 11T free.
  #
  # 2000G is Sam's number, not a measured one. Raise it if the Mac's disk grows.
  maxSize = "2000G";

  # The Finder icon and the Time Machine identity. Purely cosmetic, and named
  # here rather than in the script because the mDNS record and smb.conf both want
  # it. smb.conf's copy is written by the script, so these are two spellings of
  # one value and only this one is a knob.
  mimicModel = "TimeCapsule8,119";

  sambaTimemachine = pkgs.writeShellApplication {
    name = "samba-timemachine";
    # A systemd user unit gets a minimal PATH. Listing these makes a missing tool
    # a build error rather than a service that fails at first backup.
    #
    # e2fsprogs is here for chattr and lsattr, which do the nodatacow work.
    # driveMount is the resolver the script calls before it touches anything.
    runtimeInputs = with pkgs; [ samba e2fsprogs coreutils gnugrep gawk ]
      ++ [ driveMount ];
    text = builtins.readFile ../scripts/samba-timemachine.sh;
  };

  sambaMdns = pkgs.writeShellApplication {
    name = "samba-mdns";
    # avahi for avahi-publish-service. It talks to the SYSTEM avahi-daemon over
    # D-Bus, so this is the client only and nothing here starts a daemon.
    runtimeInputs = with pkgs; [ avahi coreutils ];
    text = builtins.readFile ../scripts/samba-mdns.sh;
  };
in
{
  # smbclient and smbpasswd on PATH. smbpasswd is needed once by hand to set the
  # samba password, and smbclient is how you check the server from this side
  # without involving the Mac.
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.samba ];

  systemd.user.services.smbd = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit = {
      Description = "smbd: Time Machine target for the MacBook";
      # No After=network.target. This is a USER unit and network.target lives in
      # the system manager, so ordering against it here is a silent no-op. The
      # same reasoning as home/web.nix's nginx unit.
    };
    Service = {
      Type = "simple";
      Environment = [ "SAMBA_STATE_DIR=${stateDir}" ];
      ExecStart =
        "${sambaTimemachine}/bin/samba-timemachine ${driveLabel} ${shareName} ${maxSize}";
      # on-failure, not always. The script exits nonzero when the drive is not
      # mounted or no samba password is set, and both are conditions a retry
      # cannot fix. Restarting anyway would bury the reason in a log nobody
      # reads. RestartSec is long enough that a genuinely transient fault does
      # not spin.
      Restart = "on-failure";
      RestartSec = "30s";
    };
    Install.WantedBy = [ "default.target" ];
  };

  # The mDNS advertisement, as its own unit.
  #
  # BindsTo, not Wants. The records must not outlive the server. If smbd stops,
  # an _adisk._tcp record still standing tells the Mac to back up to a share that
  # no longer answers, and Time Machine reports a failure against a destination
  # that looks present. Stopping together makes the destination simply disappear,
  # which is the honest signal.
  systemd.user.services.samba-mdns = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit = {
      Description = "Advertise the ${shareName} share to macOS over mDNS";
      BindsTo = [ "smbd.service" ];
      After = [ "smbd.service" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${sambaMdns}/bin/samba-mdns ${shareName} ${mimicModel} 445";
      Restart = "on-failure";
      RestartSec = "10s";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
