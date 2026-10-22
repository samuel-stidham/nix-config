{ config, lib, pkgs, ... }:

# Catppuccin Frappe, applied everywhere it is supported. Set the flavor once,
# then enable each program. The catppuccin module themes each enabled program
# with no extra config, so it is ready on the first switch. Easy on the eyes.
#
# Enabling these programs through home-manager also moves their shell init out of
# the old ~/.config/fish/config.fish and into the generated config, so the fish
# migration in fish.nix stays clean. See fish.nix.

{
  # Master toggle on, with explicit per-program enrollment below. autoEnable is
  # false to match the prior enable default, which silences the future
  # auto-enroll deprecation notice without changing what gets themed.
  catppuccin.flavor = "frappe";
  catppuccin.enable = true;
  catppuccin.autoEnable = false;

  # Prompt, history, and directory jumping.
  programs.starship.enable = true;
  catppuccin.starship.enable = true;

  # STARSHIP INIT NEVER TOUCHES /tmp. home-manager's fish integration runs
  # `starship init fish | source`, and that prints a second command,
  # `source (starship init fish --print-full-init | psub)`. Plain psub is
  # `cat >$TMPDIR/.psub.XXXXXX`, a real file on /tmp. /tmp is a tmpfs here, and
  # on 2026-10-15 apport filled it at boot unpacking a crash dump. Every shell
  # opened in that window started with
  #   cat: write error: No space left on device
  # and fell back to fish's plain default prompt. The root cause is fixed in
  # bootstrap.sh crash_reports. This is the second layer, so a full /tmp from
  # any cause cannot take the prompt down with it.
  #
  # The obvious fix, `psub -F` as in fish/secrets.fish, still makes a fifo in
  # /tmp. Piping the full init straight into source needs no file at all. The
  # integration is switched off and the same guarded line is written by hand.
  # Verified on fish 4.9.3: `echo ... | fish -c source` ran the piped text, and
  # `starship init fish --print-full-init | grep -c psub` printed 0.
  programs.starship.enableFishIntegration = false;
  programs.fish.interactiveShellInit = lib.mkIf config.programs.starship.enable ''
    if test "$TERM" != "dumb"
      ${lib.getExe config.programs.starship.package} init fish --print-full-init | source
    end
  '';

  programs.atuin.enable = true;
  catppuccin.atuin.enable = true;

  programs.zoxide.enable = true;

  # direnv is the secret injection layer too, see the hardening plan. nix-direnv
  # caches dev shells so entering a project is fast.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Pager and fuzzy finder.
  programs.bat.enable = true;
  catppuccin.bat.enable = true;

  # atuin owns Ctrl-R for history search, since that is its whole point. Disable
  # fzf's Ctrl-R binding so they do not fight. fzf keeps Ctrl-T and Alt-C.
  programs.fzf = {
    enable = true;
    historyWidget.fish.command = "";
  };
  catppuccin.fzf.enable = true;

  # Nicer ls.
  programs.eza.enable = true;

  # System monitor, prettier than htop and themed.
  programs.btop.enable = true;
  catppuccin.btop.enable = true;

  # Fish syntax colors in Frappe.
  catppuccin.fish.enable = true;
}
