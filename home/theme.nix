{ pkgs, ... }:

# Catppuccin Frappe, applied everywhere it is supported. Set the flavor once,
# then enable each program. The catppuccin module themes each enabled program
# with no extra config, so it is ready on the first switch. Easy on the eyes.
#
# Enabling these programs through home-manager also moves their shell init out of
# the old ~/.config/fish/config.fish and into the generated config, so the fish
# migration in fish.nix stays clean. See fish.nix.

{
  catppuccin.flavor = "frappe";

  # Prompt, history, and directory jumping.
  programs.starship.enable = true;
  catppuccin.starship.enable = true;

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

  programs.fzf.enable = true;
  catppuccin.fzf.enable = true;

  # Nicer ls.
  programs.eza.enable = true;

  # System monitor, prettier than htop and themed.
  programs.btop.enable = true;
  catppuccin.btop.enable = true;

  # Fish syntax colors in Frappe.
  catppuccin.fish.enable = true;
}
