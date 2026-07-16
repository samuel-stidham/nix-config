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
    dbeaver-bin            # SQL GUI. Binary: dbeaver
    eclipses.eclipse-java  # Eclipse IDE for Java
    ghidra                 # reverse engineering
    halloy                 # IRC client
    keepassxc              # password manager
    obsidian               # notes, Electron and unfree
    racket                 # Racket language and DrRacket
    spotify                # music, Electron and unfree
    # TablePlus was here before as a vendor apt repo, since the nixpkgs build
    # lagged. It is replaced by dbeaver-bin above, which Nix owns and installs
    # the same way on every distro. That removed the TablePlus vendor branch
    # from bootstrap.sh. dbeaver-bin covers the same databases and more.

    # PrismLauncher from Nix, so it reads the Nix JDKs under ~/.local/share/jdks
    # directly with no Flatpak sandbox grant. Replaces the apt prismlauncher.
    # It needs /run/opengl-driver to exist, see the note below.
    prismlauncher
  ];

  # PrismLauncher needs no wrapper. It needs /run/opengl-driver to exist.
  #
  # Its wrapper hardcodes `--set LD_LIBRARY_PATH /run/opengl-driver/lib:...`,
  # which is the NixOS path for the GPU driver. That directory does not exist on
  # this machine, so Prism found no GLX vendor and died four seconds into a
  # launch with "Fatal: Could not initialize GLX".
  #
  # nixGL cannot fix that, which is worth writing down because it is the obvious
  # thing to reach for and it is a dead end. The wrapper uses --set, not
  # --prefix, so it REPLACES LD_LIBRARY_PATH and discards whatever nixGL exported
  # before the app runs its first instruction.
  #
  # The fix is `./bootstrap.sh nix_opengl_driver`, which symlinks the Ubuntu
  # NVIDIA libs into /run/opengl-driver/lib at boot. It is a system concern, not
  # a per-app one: every Nix GUI app that touches the GPU looks there.
}
