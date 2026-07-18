{ config, pkgs, lib, ... }:

let
  # Your own age-encrypted vault CLI, built from the tagged GitHub release. See
  # parts/safetybox.nix. This is the secret store going forward.
  safetybox = import ../parts/safetybox.nix pkgs;
in

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
  home.packages = [
    # Primary secret store. safetybox owns every secret and all key material,
    # including the ssh and gpg private keys, under a namespaced vault.
    safetybox
  ] ++ (with pkgs; [
    # passage is kept for one job only: it holds the safetybox passphrase at
    # safetybox/passphrase, so automation can unlock the vault non-interactively:
    #   safetybox reveal --env --prefix global \
    #     --passphrase-file (passage show safetybox/passphrase | psub)
    # passage is unlocked by its own age identity, the single root of trust,
    # carried out of band in 1Password. That is personal-login storage, kept
    # deliberately separate from the coding secret chain: safetybox holds the
    # coding secrets and passage holds only safetybox's passphrase, so no repo and
    # no automation ever touches 1Password or the `op` CLI. KeePassXC backs up
    # recovery codes, NOT this identity. Confirmed passage 1.7.4 and age 1.3.1.
    passage
    age
    # Secret scanners, global. Confirmed gitleaks 8.30.1 and trufflehog 3.95.7.
    gitleaks
    trufflehog
  ]);

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
    # Directory-tree identity. ~/code is laid out by IDENTITY, not by language and
    # not by host, and each folder is named for its GitHub account:
    #
    #   ~/code/samuel-stidham/   samuel.stidham@snhu.edu, the portfolio identity
    #   ~/code/dqfan2012/        dqfan2012@gmail.com, legacy and shrinking
    #   ~/code/sandbox/          throwaway, no identity rule
    #
    # A repo is therefore correct by LOCATION, and nothing needs a per-repo
    # override. That is the whole point. A `git config --local user.email` is
    # untracked and invisible, so it is right on this machine and silently absent
    # on a fresh clone. infra-backups had exactly that and would have committed as
    # the wrong person on the MacBook.
    #
    # ONE rule per identity. This was two, because ~/nix-config sat outside ~/code
    # and needed a line of its own. It lives under ~/code/samuel-stidham now, so
    # the exception is gone rather than maintained.
    #
    # dqfan2012 gets no rule: it is still the global default above. When that
    # identity is fully retired, the default flips and this list stays one line.
    #
    # contents rather than path means home-manager generates the included file, so
    # no hand-written ~/.gitconfig-snhu exists and the identity is declarative.
    includes = [
      { condition = "gitdir:~/code/samuel-stidham/"; contents.user.email = "samuel.stidham@snhu.edu"; }
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
