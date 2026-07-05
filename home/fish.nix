{ config, pkgs, lib, ... }:

# Fish module. home-manager generates config.fish, and that generated file
# sources my hand-written fish tree at ~/fish. The tree holds env.fish,
# configure_path.fish, aliases.fish, and functions.fish.
#
# What is intentionally dropped from the old config.fish: pyenv init (no pyenv),
# nvm loading (Nix owns node), and the conda initialize block plus
# `conda activate pysci-ai` (conda migrates to micromamba). Add micromamba shell
# init here once the pysci-ai env is rebuilt.

{
  programs.fish = {
    enable = true;

    # Runs for every shell, login or not. Environment and PATH first.
    shellInit = ''
      source $HOME/fish/env.fish
      source $HOME/fish/configure_path.fish
    '';

    # Runs for interactive shells only. Aliases and functions.
    interactiveShellInit = ''
      source $HOME/fish/aliases.fish
      source $HOME/fish/functions.fish
    '';
  };
}
