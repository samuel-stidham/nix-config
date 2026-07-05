{ config, pkgs, lib, ... }:

{
  imports = [
    ./languages.nix
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
  ];

  home.username = "samuelstidham";
  home.homeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/samuelstidham" else "/home/samuelstidham";

  # Bump only when the release notes tell you to.
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;
}
