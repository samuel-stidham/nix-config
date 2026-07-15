{ pkgs, lib, ... }:

# Filesystem tooling. Everything here is Linux only, so it is guarded by
# stdenv.isLinux rather than listed unconditionally.
#
# The guard is not decoration. `pkgs.btrfs-progs.version` evaluates perfectly
# well on aarch64-darwin, because reading an attribute never consults
# meta.platforms. An unguarded entry would evaluate clean and then fail at BUILD
# time, on the Mac, long after the mistake was made. That is the worst kind of
# breakage, so the platform check is explicit.
#
# There is no Mac equivalent to add. btrfs is a Linux kernel filesystem, and
# macOS cannot mount it at all. The Mac side of this flake simply has no
# filesystem tooling, which is correct rather than incomplete.

{
  home.packages =
    lib.optionals pkgs.stdenv.isLinux (with pkgs; [
      # btrfs. Both bulk drives are being converted from their Windows era
      # filesystems, WorkDrive from exfat and StoragePrime from ntfs.
      # `scrub` is the whole reason for the switch: the Roms are deliberately not
      # backed up, so being told which file rotted is the only defense against
      # silent bit rot. Run it monthly:
      #   sudo btrfs scrub start /media/samuelstidham/StoragePrime
      btrfs-progs

      # Reports the real compression ratio of a btrfs path, which the usual du
      # and df cannot see. Worth having when compression is set to zstd:
      #   compsize /media/samuelstidham/StoragePrime
      compsize

      # exfat tooling. Still needed until WorkDrive is converted, and useful for
      # any exfat card or stick after that.
      exfatprogs
    ])
    # smartmontools is one of the few that builds on darwin too, so it is not
    # inside the guard. Drive health matters here, since bit rot on unbacked Roms
    # is the risk btrfs checksums are meant to catch:
    #   sudo smartctl -a /dev/sda
    ++ [ pkgs.smartmontools ];
}
