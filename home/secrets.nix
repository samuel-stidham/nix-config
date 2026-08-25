{ config, pkgs, lib, ... }:

let
  # Your own age-encrypted vault CLI, built from the tagged GitHub release. See
  # parts/safetybox.nix. This is the secret store going forward.
  safetybox = import ../parts/safetybox.nix pkgs;

  # SSH keys by GitHub account, bound once so the paths are not repeated inline
  # and no literal /home/<user> lands in a module. These are the PUBLIC halves'
  # private counterparts on disk, referenced by path only. No key material is in
  # this repo. The mapping was read off the live keys, not assumed:
  #   ssh -i id_ed25519_snhu -T git@github.com            -> Hi samuel-stidham!
  #   ssh -i id_ed25519_github_personal -T git@github.com -> Hi dqfan2012!
  sshKeys = {
    samuel-stidham = "${config.home.homeDirectory}/.ssh/id_ed25519_snhu";
    dqfan2012 = "${config.home.homeDirectory}/.ssh/id_ed25519_github_personal";
  };
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
# It also manages ~/.ssh/config through settings. The github.com block is shared
# by both accounts, and the per-account SSH key is selected by core.sshCommand in
# the git identity files, not by a host alias in the remote URL. The private keys
# are never in any repo. This completes the ssh-git-identity phase.

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
    # recovery codes, NOT this identity. Confirmed passage 1.7.4a2 and age 1.3.1.
    passage
    age
    # Secret scanners, global. Confirmed gitleaks 8.30.1 and trufflehog 3.97.0.
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
    # Directory-tree identity. ~/Code is laid out by IDENTITY, each folder named
    # for its GitHub account:
    #
    #   ~/Code/samuel-stidham/   samuel.stidham@snhu.edu
    #   ~/Code/dqfan2012/        dqfan2012@gmail.com
    #
    # Each rule includes a generated identity file (below) by path, mirroring the
    # hand-written layout exactly: [includeIf] -> ~/.config/git/identity-<account>.
    includes = [
      { condition = "gitdir:~/Code/samuel-stidham/"; path = "${config.xdg.configHome}/git/identity-samuel-stidham"; }
      { condition = "gitdir:~/Code/dqfan2012/"; path = "${config.xdg.configHome}/git/identity-dqfan2012"; }
    ];
  };

  # The per-identity include files, generated so nothing is hand-written. Each
  # carries the email, the signing key, and the SSH key for its account tree.
  #
  # SSH KEY SELECTION LIVES HERE, NOT IN ~/.ssh/config. The hand-written config
  # this module replaced had two host blocks. github.com carried the personal
  # key and github.com-snhu carried the snhu key, so the remote URL chose the
  # account. That mapping was dropped when the ssh block below was written, and
  # what replaced it is one github.com block with no IdentityFile at all. ssh
  # then offers whatever the agent holds, in agent order, and dqfan2012 is
  # loaded first:
  #
  #   $ git push origin main
  #   ERROR: Permission to samuel-stidham/nix-config.git denied to dqfan2012.
  #
  # Both keys authenticate against github.com, so nothing fails at the
  # handshake. Only writes fail, and only to the other account's repos. Reads
  # and clones kept working throughout, which is why this survived a switch.
  #
  # Restoring the github.com-snhu alias is the obvious fix and it is worse. It
  # writes the identity into every remote URL. A clone made with the plain URL
  # is then wrong forever, and the URL GitHub offers on the page is the plain
  # one. ~/Code is already laid out by account, so the directory already answers
  # the question. Putting core.sshCommand under the same includeIf that sets the
  # email keeps one source of truth for both.
  #
  # IdentitiesOnly=yes is load bearing. Without it ssh still offers every agent
  # key, and the wrong one authenticates before the -i key is ever tried.
  #
  # Verified 2026-07-24 on this machine. With the snhu key pinned this way,
  # git push --dry-run against github.com:samuel-stidham/nix-config printed
  # "5c25344..f374ec7  main -> main". The same push without it was denied.
  #
  # A repo outside ~/Code/<account>/ matches no rule and still picks by agent
  # order. That gap is unchanged here and is not fixed by this module.
  xdg.configFile."git/identity-samuel-stidham".text = ''
    [user]
      email = samuel.stidham@snhu.edu
      signingkey = 693484A30BCFADFA
    [core]
      sshCommand = "ssh -i ${sshKeys.samuel-stidham} -o IdentitiesOnly=yes"
  '';
  xdg.configFile."git/identity-dqfan2012".text = ''
    [user]
      email = dqfan2012@gmail.com
      signingkey = 693484A30BCFADFA
    [core]
      sshCommand = "ssh -i ${sshKeys.dqfan2012} -o IdentitiesOnly=yes"
  '';

  # SSH host config, managed here. One github.com block shared by both accounts,
  # with AddKeysToAgent so a key is loaded into the agent on first use. That is
  # the Linux stand-in for the mac Keychain, since there is no UseKeychain here.
  # The private keys are never in any repo.
  #
  # NO IdentityFile HERE, ON PURPOSE. A host block names one key, and naming one
  # would make that account the answer for every repo on the box. That is the
  # shape of the bug this module already caused once. The key is chosen per
  # account tree by core.sshCommand in the identity files above, because the
  # tree is what knows the account.
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
