{ config, pkgs, lib, ... }:

# Hardening tools and the global secret-scanning guard. This codifies the
# secrets-install programs and makes gitleaks and trufflehog global, so they are
# available and enforced in every repo. The full secrets workflow is planned in
# ../SECRETS.md and ../SCANNING.md.
#
# This module also takes over the global git config, so the gitleaks pre-commit
# hook can be set through core.hooksPath. It replicates the current ~/.gitconfig
# faithfully, so no identity or signing setting regresses. This advances the git
# config half of the ssh-git-identity phase. The ssh matchBlocks come later.

{
  home.packages = with pkgs; [
    # Secret store and backend. Confirmed passage 1.7.4 and age 1.3.1.
    passage
    age
    # Secret scanners, global. Confirmed gitleaks 8.30.1 and trufflehog 3.95.7.
    gitleaks
    trufflehog
  ];

  # Global pre-commit guard. core.hooksPath below points every repo at this hook,
  # so no secret can be committed in any repo. It calls the pinned gitleaks by
  # absolute store path, so it runs even with a bare hook PATH. A non-zero exit
  # blocks the commit. The invocation matches gitleaks 8.30.1.
  xdg.configFile."git/hooks/pre-commit" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      exec ${pkgs.gitleaks}/bin/gitleaks git --staged --redact --no-banner
    '';
  };

  # Git config, managed by home-manager. This mirrors the current ~/.gitconfig,
  # including the nix-config snhu override that already exists, and adds the
  # global hooks path. trufflehog is not wired as a hook, since it is the deep
  # pre-publish auditor, not a per-commit tool. It is global as an installed
  # command for on-demand scans in any repo. See ../SCANNING.md.
  programs.git = {
    enable = true;
    userName = "Samuel Stidham";
    userEmail = "dqfan2012@gmail.com";
    # Current signing is GPG key 693484A30BCFADFA with sign by default. Kept as
    # is, so nothing regresses. Whether to move to SSH signing per identity is a
    # decision for the ssh-git-identity phase, see ../SECRETS.md.
    signing = {
      key = "693484A30BCFADFA";
      signByDefault = true;
    };
    extraConfig = {
      init.defaultBranch = "main";
      core.hooksPath = "${config.xdg.configHome}/git/hooks";
    };
    # Directory-tree identity. snhu email under snhu-projects, and the nix-config
    # override that already lives in the current config.
    includes = [
      { condition = "gitdir:~/code/snhu-projects/"; path = "~/.gitconfig-snhu"; }
      { condition = "gitdir:~/nix-config/"; path = "~/.gitconfig-snhu"; }
    ];
  };
}
