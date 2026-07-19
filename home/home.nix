{ config, pkgs, lib, ... }:

{
  imports = [
    ./languages.nix
    ./libraries.nix
    ./filesystems.nix
    ./btrfs-scrub.nix
    ./package-audit.nix
    ./python.nix
    ./fish.nix
    ./jdks.nix
    ./cli.nix
    ./apps.nix
    ./graphics.nix
    ./emacs.nix
    ./theme.nix
    ./fonts.nix
    ./terminals.nix
    ./secrets.nix
    ./steam.nix
    ./flameshot.nix
    ./editors.nix
    ./syncthing.nix
    ./home-certs.nix
    ./web.nix
  ];

  home.username = "samuelstidham";
  home.homeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/samuelstidham" else "/home/samuelstidham";

  # Bump only when the release notes tell you to.
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  # Non-NixOS integration. Wires XDG_DATA_DIRS so Nix .desktop files, icons, and
  # mime types are picked up by the Cinnamon menu, not just the shell. Only takes
  # full effect for the graphical session once ~/.profile also includes the Nix
  # profile share, since the display manager reads ~/.profile.
  #
  # Guarded to Linux. The flake applies this same home.nix to aarch64-darwin, and
  # the generic-linux target module asserts its own platform. Its config sits
  # under `mkIf cfg.enable` with an `assertPlatform "targets.genericLinux" pkgs
  # lib.platforms.linux`, so a bare `enable = true` aborts darwin eval loudly. The
  # option only exists to bridge Nix into a non-NixOS Linux desktop, so off Linux
  # it has no job. mkIf leaves it unset on darwin rather than false, which is the
  # same result and keeps the assertion from ever firing. Unverified on darwin, no
  # such machine available.
  targets.genericLinux.enable = lib.mkIf pkgs.stdenv.isLinux true;
}
