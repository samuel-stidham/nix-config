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
    # Ghostty's own (GTK) tabs along the bottom.
    gtk-tabs-location = bottom
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

  # "servers" layout: boot the whole dev backend at once.
  #
  # Tab 1 (servers): a 2x2 grid. Left column holds the two process-compose stacks
  # stacked one above the other (services on top, sites below). Right column is
  # two free shells; the top-right one is focused so you land in a working
  # terminal. close_on_exit keeps a crashed stack visible instead of vanishing.
  # Tab 2 (term): a single full-window terminal.
  #
  # Launch with the `servers` fish function (fish.nix), which names the session so
  # a second launch attaches instead of starting a conflicting copy.
  xdg.configFile."zellij/layouts/servers.kdl".text = ''
    // zellij --layout servers  (or the `servers` fish function)
    layout {
        tab name="servers" focus=true {
            pane split_direction="vertical" {
                pane split_direction="horizontal" {
                    pane command="nix" close_on_exit=false {
                        args "run" "/home/samuelstidham/nix-config#services"
                    }
                    pane command="nix" close_on_exit=false {
                        args "run" "/home/samuelstidham/nix-config#sites"
                    }
                }
                pane split_direction="horizontal" {
                    pane focus=true
                    pane
                }
            }
        }
        tab name="term" {
            pane
        }
    }
  '';

  home.packages = [ pkgs.ghostty ];
}
