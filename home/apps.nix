{ pkgs, ... }:

# Desktop and dev applications that Nix owns. These are deliberate exceptions or
# additions to the Flatpak-first rule in .agents/install-policy.md, chosen
# because Nix has them, no good Flatpak exists, or the native build integrates
# better. Pure desktop apps like calibre, gimp, hexchat, and pidgin still go
# through Flatpak. See .agents/install-policy.md for the full mapping.

{
  home.packages = with pkgs; [
    # Screenshot tool. Confirmed 14.0.0, newer than apt 12.1.0. The native build
    # keeps global hotkeys working, which the Flatpak build fumbles through the
    # portal. This replaces the apt flameshot.
    flameshot

    # JetBrains IDE manager. Confirmed 3.5.0. It is not on Flathub, so Nix is the
    # cleanest channel. Note it still self-updates the IDEs it installs into
    # ~/.local/share/JetBrains, outside Nix. If you prefer fully declarative
    # IDEs, drop this and use nixpkgs jetbrains.* attributes instead.
    jetbrains-toolbox

    # Octave for scientific work. Confirmed 11.3.0. Replaces the apt octave.
    octave

    # Wine for the MonoGame shader compiler. MonoGame is not packaged in nixpkgs,
    # so it stays a .NET tool and template set installed with the dotnet SDK from
    # languages.nix. mgfxc needs Wine on Linux, and Nix provides it here. Set
    # MGFXC_WINE_PATH to this wine once built. See MIGRATION.md for the steps.
    wineWow64Packages.stable
  ];
}
