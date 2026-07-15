{ config, pkgs, lib, ... }:

{
  imports = [
    ./languages.nix
    ./libraries.nix
    ./filesystems.nix
    ./python.nix
    ./fish.nix
    ./jdks.nix
    ./cli.nix
    ./apps.nix
    ./emacs.nix
    ./theme.nix
    ./fonts.nix
    ./terminals.nix
    ./secrets.nix
    ./steam.nix
    ./flameshot.nix
    ./editors.nix
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
  targets.genericLinux.enable = true;
}
