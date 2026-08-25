{ pkgs, config, lib, ... }:

let
  # Where this repo lives. One binding, so moving the checkout is one edit here
  # rather than a hunt through every module. Referenced by the zellij layout below.
  flakeRef = "${config.home.homeDirectory}/Code/samuel-stidham/nix-config";
in

# Terminals, themed Catppuccin Frappe and set to a Nerd Font. Ghostty and
# alacritty are the dev terminals. The Cinnamon default, gnome-terminal, stays
# on the system and is not themed here.

let
  nerdFont = "JetBrainsMono Nerd Font";

  # The attach-or-create launcher for the dev session, as a store command. Ghostty
  # opens into it (initial-command below) and the `servers` fish function calls it,
  # so both routes land in the SAME named session instead of racing to build two.
  #
  # In the store rather than referenced out of the checkout, for the reason
  # home/btrfs-scrub.nix spells out: a path into a git checkout breaks the moment
  # the repo moves, and this one is load-bearing for opening a terminal at all.
  # The trade is that editing the script needs a `home-manager switch` to take
  # effect, which is right for something reviewed once and then run constantly.
  devSession = pkgs.writeShellApplication {
    name = "dev-session";
    # zellij does the work; gnugrep and gawk parse the session list. Ghostty gives
    # initial-command a minimal PATH, so a missing tool here is a build error
    # rather than a terminal that will not open.
    runtimeInputs = with pkgs; [ zellij gnugrep gawk ];
    text = builtins.readFile ../scripts/dev-session.sh;
  };
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

    # OPEN STRAIGHT INTO THE DEV SESSION.
    #
    # The ask was two GHOSTTY tabs, one per zellij layout. Ghostty 1.3.1 cannot do
    # that and it is not a config gap, it is missing plumbing. There is no startup
    # option that opens a second tab; `ghostty +new-window` opens a WINDOW and its
    # man page says so; and the running instance's D-Bus action list is exactly
    # open-config, present-surface, quit, new-window-command, new-window,
    # reload-config, with no new-tab among them. `new-tab` exists in 1.3.1 only as
    # a value of macos-dock-drop-behavior, which does nothing on Linux. The only
    # way to get a real second Ghostty tab is injecting ctrl+shift+t with xdotool,
    # which is a race against window mapping and is not installed here anyway.
    #
    # So the two tabs are ZELLIJ's, from the servers layout below: tab one the 2x2
    # grid, tab two a single full-window pane. Same shape, one process cheaper,
    # and it survives Ghostty upgrades because it does not depend on Ghostty.
    #
    # initial-command, NOT command. command would apply to every surface, so
    # ctrl+shift+t would open another zellij inside the terminal instead of a
    # shell. initial-command applies only to the first surface of each Ghostty
    # process, which is exactly "when I open Ghostty, put me in my session".
    initial-command = ${devSession}/bin/dev-session
  '';

  # Alacritty. Font here, colors from the catppuccin module.
  programs.alacritty = {
    enable = true;
    settings.font.normal.family = nerdFont;
  };
  catppuccin.alacritty.enable = true;

  # Zellij, the one terminal multiplexer. Panes, tabs, floating, and stacked
  # resize are all built in, which is where several AI agent sessions run side by
  # side. Confirmed 0.45.0. It ships Catppuccin themes built in, so the Frappe
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
                    // The flake ref is built from homeDirectory and flakeDir,
                    // not hardcoded. This pointed at ~/nix-config and broke the
                    // moment the repo moved under ~/Code/samuel-stidham.
                    pane command="nix" close_on_exit=false {
                        args "run" "${flakeRef}#services"
                    }
                    pane command="nix" close_on_exit=false {
                        args "run" "${flakeRef}#sites"
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

  # Guarded to Linux. The flake applies this home.nix to aarch64-darwin too, and
  # `pkgs.ghostty` carries Linux-only `meta.platforms`. Forcing it on darwin
  # throws "not available on the requested hostPlatform" and aborts eval. On macOS
  # Ghostty ships as a Homebrew cask outside Nix, so there is nothing to install
  # here anyway. lib.optionals drops the package to an empty list off Linux. The
  # ghostty config file above stays unguarded on purpose, since a cask Ghostty
  # would still read ~/.config/ghostty. Unverified on darwin, no such machine
  # available.
  #
  # devSession is OUTSIDE the guard on purpose. It is a shell script over zellij,
  # and zellij is enabled unguarded above, so it builds and runs on darwin too. It
  # is in home.packages, not merely referenced by initial-command, because the
  # `servers` fish function calls it by name from PATH.
  home.packages =
    [ devSession ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.ghostty ];
}
