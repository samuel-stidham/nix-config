{ pkgs, ... }:

# Desktop and dev applications that Nix owns. These are deliberate exceptions or
# additions to the Flatpak-first rule in .agents/install-policy.md, chosen
# because Nix has them, no good Flatpak exists, or the native build integrates
# better. Pure desktop apps like calibre, gimp, hexchat, and pidgin still go
# through Flatpak. See .agents/install-policy.md for the full mapping.

{
  home.packages = with pkgs; [
    # Screenshot tool moved to home/flameshot.nix, which manages it through the
    # services.flameshot module (X11 legacy grab + tray daemon).

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

    # GUI apps moved off snaps to Nix during de-snap. Versions are newer or on
    # par with the snaps they replace, so exact-version matching is not needed.
    bruno                  # API client
    eclipses.eclipse-java  # Eclipse IDE for Java
    ghidra                 # reverse engineering
    halloy                 # IRC client
    keepassxc              # password manager
    obsidian               # notes, Electron and unfree
    racket                 # Racket language and DrRacket
    spotify                # music, Electron and unfree
    # TablePlus is NOT here: the nixpkgs build lags the vendor release, so it
    # comes from TablePlus's own apt repo in bootstrap.sh (vendor_debs), like
    # Chrome and VS Code.

    # PrismLauncher from Nix, so it reads the Nix JDKs under ~/.local/share/jdks
    # directly with no Flatpak sandbox grant. Replaces the apt prismlauncher.
    prismlauncher
  ];
}
