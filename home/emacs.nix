{ pkgs, lib, ... }:

# Doom Emacs. You are trying Doom as a possible move from neovim, and both stay
# installed. Nix provides the emacs binary and the fonts. Doom itself is cloned
# once and synced imperatively, since Doom likes to manage its own package tree.
# Your Doom user config lives in this repo under doom/ and is symlinked to
# ~/.config/doom, so the config is reproducible while Doom stays tinker-friendly.
#
# Evil mode. Doom enables vim keybindings through the (evil +everywhere) module,
# which is set in doom/init.el. That gives you neovim-style editing everywhere.
#
# One-time bootstrap, run it yourself, it is a state change:
#   git clone --depth 1 https://github.com/doomemacs/doomemacs ~/.config/emacs
#   ~/.config/emacs/bin/doom install
# After editing anything under doom/, run `doom sync` to apply it.

{
  home.packages = with pkgs; [
    # pgtk build, current and native-compiled. Confirmed 30.2.
    emacs-pgtk
    # Doom uses these icons in the dashboard and modeline. Run
    # `M-x nerd-icons-install-fonts` once too, for the modeline glyphs.
    emacs-all-the-icons-fonts
    # Doom's doctor wants these. ripgrep and fd already come from cli.nix.
    coreutils
    # Fast Emacs Lisp linting and shell checks Doom can use.
    shellcheck
  ];

  # Put the `doom` command on PATH after the clone above.
  home.sessionPath = [ "$HOME/.config/emacs/bin" ];

  # Reproducible Doom user config. Edit these in the repo, then run `doom sync`.
  home.file.".config/doom/init.el".source = ../doom/init.el;
  home.file.".config/doom/config.el".source = ../doom/config.el;
  home.file.".config/doom/packages.el".source = ../doom/packages.el;
}
