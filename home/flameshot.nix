{ ... }:

# Flameshot, managed.
#
# Flameshot 14 is a Qt app that chooses its capture backend from
# XDG_CURRENT_DESKTOP. On this X11 Cinnamon session it must be told to use the
# native X11 (XCB) grab, or it selects a Wayland path and dies with "Unable to
# capture screen". useX11LegacyScreenshot forces the X11 grab regardless of what
# the desktop reports. See also ~/fish/env.fish, where XDG_CURRENT_DESKTOP was
# corrected from a stale "Sway" to "X-Cinnamon" for the same reason.
#
# The other keys mirror the settings you had set through the GUI, so nothing
# regresses. Note: with the ini managed here it becomes a read-only store
# symlink, so future tweaks made in the Flameshot GUI will not persist. Change
# them in this file instead.
#
# enable also runs the Flameshot tray daemon as a user service, which is what
# backs global hotkeys. This replaces the plain apps.nix package entry.

{
  services.flameshot = {
    enable = true;
    settings.General = {
      useX11LegacyScreenshot = true;
      contrastOpacity = 188;
      undoLimit = 99;
    };
  };
}
