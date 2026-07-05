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
  # listed once in home.packages at the bottom, alongside rmux.
  xdg.configFile."ghostty/config".text = ''
    theme = catppuccin-frappe
    font-family = ${nerdFont}
    font-size = 12
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

  # Zellij, the terminal multiplexer. This is where you run several AI agent
  # sessions side by side. Confirmed 0.44.3. It ships Catppuccin themes built in,
  # so the Frappe theme is just a name, no external module needed.
  programs.zellij = {
    enable = true;
    settings.theme = "catppuccin-frappe";
  };

  # rmux drives the multiplexer with a typed SDK, so you can script and lay out
  # concurrent agent panes. Confirmed 0.7.0. Point it at the zellij backend
  # through its own config, per its docs.
  home.packages = [ pkgs.ghostty pkgs.rmux ];
}
