{ pkgs, ... }:

# Terminals, themed Catppuccin Frappe and set to a Nerd Font. Ghostty and
# alacritty are the dev terminals. The Cinnamon default, gnome-terminal, stays
# on the system and is not themed here.

let
  nerdFont = "JetBrainsMono Nerd Font";
in
{
  # Ghostty. It ships Catppuccin themes built in, so the theme is just a name.
  # This replaces the apt ghostty, so it is removed from apps.nix. The package is
  # listed once in home.packages at the bottom.
  xdg.configFile."ghostty/config".text = ''
    theme = Catppuccin Frappe
    font-family = ${nerdFont}
    font-size = 12
    # Do not flash the "cols x rows" box on every resize.
    resize-overlay = never
    # Shift+Enter sends a newline (LF), so multiline input works in Claude Code
    # and other apps. Plain Enter still submits.
    keybind = shift+enter=text:\n
  '';

  # Alacritty. Font here, colors from the catppuccin module.
  programs.alacritty = {
    enable = true;
    settings.font.normal.family = nerdFont;
  };
  catppuccin.alacritty.enable = true;

  # Zellij, the one terminal multiplexer. Panes, tabs, floating, and stacked
  # resize are all built in, which is where several AI agent sessions run side by
  # side. Confirmed 0.44.3. It ships Catppuccin themes built in, so the Frappe
  # theme is just a name, no external module needed. (rmux was dropped: it is a
  # standalone tmux-compatible multiplexer, not a layer over zellij, so it just
  # duplicated zellij's job.)
  programs.zellij = {
    enable = true;
    settings.theme = "catppuccin-frappe";
  };

  home.packages = [ pkgs.ghostty ];
}
