{ config, pkgs, lib, ... }:

# Fish module. home-manager generates config.fish, and that generated file
# sources my fish tree at ~/fish. The tree holds env.fish, configure_path.fish,
# aliases.fish, and functions.fish, now tracked in this repo under ../fish and
# linked into place by the home.file block below, so it is reproducible.
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

    # Boot (or reattach to) the dev backend in zellij. Attaching first means a
    # second call joins the running session instead of launching a second copy
    # of the stacks and colliding on ports/data dirs. See the servers layout in
    # terminals.nix.
    functions.servers = ''
      zellij attach servers 2>/dev/null
      or zellij --session servers --layout servers
    '';
  };

  # The fish tree, tracked in ../fish and linked into ~/fish so config.fish's
  # source lines above resolve to reproducible files. rvm.fish,
  # update-clang-llvm-symlinks.fish, and .wakatime-project were dropped as dead.
  home.file = {
    "fish/env.fish".source = ../fish/env.fish;
    "fish/configure_path.fish".source = ../fish/configure_path.fish;
    "fish/aliases.fish".source = ../fish/aliases.fish;
    "fish/functions.fish".source = ../fish/functions.fish;
  };
}
