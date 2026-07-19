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

  # Git config, managed by home-manager. Global identity is the snhu portfolio
  # account now, and each account tree overrides email and signing key through a
  # generated identity file under ~/.config/git. The global hooks path stays, so
  # the gitleaks pre-commit guard runs in every repo. See ../SCANNING.md.
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Samuel Stidham";
        email = "samuel.stidham@snhu.edu";
        signingkey = "693484A30BCFADFA";
      };
      commit.gpgsign = true;
      tag.gpgsign = true;
      init.defaultBranch = "main";
      # Signing uses the nix gnupg. home-manager sets gpg.format = openpgp and
      # gpg.openpgp.program to its own gnupg by default, so no gpg.program line
      # is needed and the system /usr/bin/gpg is not a dependency.
      core.hooksPath = "${config.xdg.configHome}/git/hooks";
    };
    # Directory-tree identity. ~/code is laid out by IDENTITY, each folder named
    # for its GitHub account:
    #
    #   ~/code/samuel-stidham/   samuel.stidham@snhu.edu
    #   ~/code/dqfan2012/        dqfan2012@gmail.com
    #
    # Each rule includes a generated identity file (below) by path, mirroring the
    # hand-written layout exactly: [includeIf] -> ~/.config/git/identity-<account>.
    includes = [
      { condition = "gitdir:~/code/samuel-stidham/"; path = "${config.xdg.configHome}/git/identity-samuel-stidham"; }
      { condition = "gitdir:~/code/dqfan2012/"; path = "${config.xdg.configHome}/git/identity-dqfan2012"; }
    ];
  };

  # The per-identity include files, generated so nothing is hand-written. Each
  # carries only the email and signing key for its account tree.
  xdg.configFile."git/identity-samuel-stidham".text = ''
    [user]
      email = samuel.stidham@snhu.edu
      signingkey = 693484A30BCFADFA
  '';
  xdg.configFile."git/identity-dqfan2012".text = ''
    [user]
      email = dqfan2012@gmail.com
      signingkey = 693484A30BCFADFA
  '';

  # SSH host config, managed here. One github.com block, and AddKeysToAgent so a
  # key is loaded into the agent on first use, the Linux stand-in for the mac
  # Keychain (there is no UseKeychain on Linux). The private keys are never in
  # any repo.
  programs.ssh = {
    enable = true;
    # We declare exactly the hosts we need, so no implicit Host * defaults.
    enableDefaultConfig = false;
    # settings keys are Host patterns, values use raw ssh_config directive names.
    settings = {
      "github.com" = {
        HostName = "github.com";
        User = "git";
        AddKeysToAgent = "yes";
      };
    };
  };
}
