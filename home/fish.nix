{ config, pkgs, lib, ... }:

# Fish module. home-manager generates config.fish, and that generated file
# sources my fish tree at ~/fish. The tree holds env.fish, configure_path.fish,
# aliases.fish, and functions.fish, now tracked in this repo under ../fish and
# linked into place by the home.file block below, so it is reproducible.
#
# What is intentionally dropped from the old config.fish: pyenv init (no pyenv),
# nvm loading (Nix owns node), and the conda initialize block plus
# `conda activate pysci-ai`. The conda role went to devenv inside the
# pysci-ai repo, so no shell init replaces it here. micromamba was the
# plan once and is gone. See home/python.nix for the tombstone.

{
  programs.fish = {
    enable = true;

    # Every shell, login or not, sources the whole fish tree here, so aliases and
    # functions exist in scripts and non-interactive shells too, not only in a
    # terminal. Anything that must stay interactive-only guards itself with
    # `status is-interactive` inside these files. Each file is sourced exactly
    # ONCE. env.fish used to also source aliases and functions itself, which
    # loaded them a second time in interactive shells. That source is gone now.
    #
    # ORDER IS LOAD BEARING. functions.fish comes before configure_path.fish,
    # because configure_path.fish calls add_to_path, which functions.fish
    # defines. env.fish is first because it sets the variables the rest read.
    # secrets.fish is last because its reveal command needs safetybox on PATH.
    # secrets.fish holds no secret values, only the reveal command, so it is
    # tracked in this repo like any other config.
    shellInit = ''
      source $HOME/fish/env.fish
      source $HOME/fish/functions.fish
      source $HOME/fish/configure_path.fish
      source $HOME/fish/aliases.fish
      source $HOME/fish/secrets.fish
    '';

    # secure_sites generates a one-year self-signed TLS cert for every folder in
    # ~/sites, named <folder>.test, into the certs dir the sites nginx reads.
    # Run it after adding a site, or yearly to renew. Re-run overwrites.
    functions.secure_sites = ''
      set -l certdir "$HOME/.local/share/dev-services/certs"
      mkdir -p $certdir
      if not test -d "$HOME/sites"
        echo "no ~/sites folder, nothing to secure"
        return 1
      end
      set -l count 0
      for dir in $HOME/sites/*/
        test -d "$dir"; or continue
        set -l name (basename "$dir")
        set -l host "$name.test"
        if openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
            -keyout "$certdir/$host.key" -out "$certdir/$host.crt" \
            -subj "/CN=$host" -addext "subjectAltName=DNS:$host" 2>/dev/null
          echo "secured $host for one year"
          set count (math $count + 1)
        else
          echo "FAILED $host"
        end
      end
      echo "$count site(s) secured in $certdir"
    '';
    # The `servers` launcher for the zellij layout (terminals.nix) lives in
    # ~/fish/functions.fish instead, alongside the other hand-written functions.
  };

  # The fish tree, tracked in ../fish and linked into ~/fish so config.fish's
  # source lines above resolve to reproducible files. rvm.fish,
  # update-clang-llvm-symlinks.fish, and .wakatime-project were dropped as dead.
  home.file = {
    "fish/env.fish".source = ../fish/env.fish;
    "fish/configure_path.fish".source = ../fish/configure_path.fish;
    "fish/aliases.fish".source = ../fish/aliases.fish;
    "fish/functions.fish".source = ../fish/functions.fish;
    "fish/secrets.fish".source = ../fish/secrets.fish;
  };
}
