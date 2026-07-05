{ config, pkgs, lib, ... }:

# Hardening tools and the global secret-scanning guard. This codifies the
# secrets-install programs and makes gitleaks and trufflehog global, so they are
# available and enforced in every repo. The full secrets workflow is planned in
# ../SECRETS.md and ../SCANNING.md.
#
# This module also takes over the global git config, so the gitleaks pre-commit
# hook can be set through core.hooksPath. It replicates the current ~/.gitconfig
# faithfully, so no identity or signing setting regresses, and it inlines the
# snhu email override so ~/.gitconfig and ~/.gitconfig-snhu are no longer needed.
# It also manages ~/.ssh/config through settings, one block per GitHub identity.
# The private keys are never in any repo. This completes the ssh-git-identity phase.

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
    # New home-manager schema. user, commit, init, and core all live under
    # settings now. Signing is GPG key 693484A30BCFADFA with sign by default,
    # kept as is so nothing regresses. Whether to move to SSH signing per
    # identity is a decision for the ssh-git-identity phase, see ../SECRETS.md.
    settings = {
      user = {
        name = "Samuel Stidham";
        email = "dqfan2012@gmail.com";
        signingkey = "693484A30BCFADFA";
      };
      commit.gpgsign = true;
      init.defaultBranch = "main";
      core.hooksPath = "${config.xdg.configHome}/git/hooks";
    };
    # Directory-tree identity. Under snhu-projects and nix-config, override the
    # email to the snhu address. Using contents instead of a path means
    # home-manager generates the included file itself, so no hand-written
    # ~/.gitconfig-snhu is needed and the identity is fully declarative.
    includes = [
      { condition = "gitdir:~/code/snhu-projects/"; contents.user.email = "samuel.stidham@snhu.edu"; }
      { condition = "gitdir:~/nix-config/"; contents.user.email = "samuel.stidham@snhu.edu"; }
    ];
  };

  # SSH host aliases, managed. github.com uses the personal key, github.com-snhu
  # uses the snhu key. IdentitiesOnly makes each host offer only its own key, so
  # they never cross. The config is managed here, the private keys never are.
  programs.ssh = {
    enable = true;
    # We declare exactly the hosts we need, so no implicit Host * defaults.
    enableDefaultConfig = false;
    # settings replaces the deprecated matchBlocks. Keys are Host patterns, and
    # the values use raw ssh_config directive names.
    settings = {
      "github.com" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = "~/.ssh/id_ed25519_github_personal";
        IdentitiesOnly = true;
      };
      "github.com-snhu" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = "~/.ssh/id_ed25519_snhu";
        IdentitiesOnly = true;
      };
    };
  };
}
