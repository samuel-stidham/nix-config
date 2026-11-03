{ config, lib, pkgs, ... }:

# Open CAD Studio, a Rust CAD app (iced + winit + wgpu) with native DWG/DXF
# read and write. GPL-3.0, upstream at github.com/HakanSeven12/OpenCADStudio.
#
# WHY NIX OWNS THIS. home/apps.nix states the house rule as Flatpak-first for
# desktop apps, with Nix taking the exceptions. Checked on 2026-09-10, this is an
# exception by elimination rather than by preference:
#
#   Flathub      not published
#   Snap Store   not published. The .snap on the GitHub release is an artifact,
#                and a sideloaded snap never refreshes, so it buys nothing.
#   nixpkgs      not packaged, so this is a local derivation, not an attribute
#   AppImage     no .zsync asset, so AppImageUpdate cannot self-update it either
#
# Every channel would have needed a poller against the GitHub releases API, so
# the pin lives here where it is at least declarative and hash-checked.
#
# UPGRADING IS A TWO-STEP, ON PURPOSE. Upstream ships fast: 0.9.2 on 2026-08-03
# through 0.9.8 on 2026-08-27, then a switch to CalVer at v2026.36 on 2026-09-06,
# which is roughly weekly. open-cad-studio-update below rewrites the two pinned
# lines in this file and stops. It does not switch and it does not commit,
# because an unattended job that both edits the repo and activates it is the
# thing bellows/automation-boundaries rules out. Review the diff, then switch.

let
  # The two lines open-cad-studio-update rewrites. Their exact shape is load
  # bearing: the updater matches `^  version = "..."` and `^    hash = "sha256-..."`
  # by anchor, so do not reindent them or fold them into the fetchurl call.
  version = "2026.44";

  src = pkgs.fetchurl {
    url = "https://github.com/HakanSeven12/OpenCADStudio/releases/download/v${version}/OpenCADStudio-v${version}-linux-x86_64.AppImage";
    hash = "sha256-CH5XxCXlZzf5ucXc5XJp44zt5XpY3CsiA1GsLOVZ8Dc=";
  };

  # Unpacked separately from the wrap so the desktop file and icon can be lifted
  # out. Both derivations take the same src, so this costs one extraction, not a
  # second download.
  contents = pkgs.appimageTools.extract {
    pname = "open-cad-studio";
    inherit version src;
  };

  # The binary itself NEEDS only libc, libm, libgcc_s and libstdc++. Everything
  # below is dlopen'd at runtime and therefore invisible to autoPatchelf, so the
  # list was read off the binary's string table rather than guessed:
  #   vulkan/EGL      libvulkan.so.1, libEGL.so.1
  #   winit on X11    libX11, libX11-xcb, libxcb, libXcursor, libXi, libXrandr
  #   winit on wayland libwayland-client, libwayland-egl, libxkbcommon{,-x11}
  # A miss here is silent: wgpu just fails to find an adapter and no window ever
  # maps, with nothing on stderr.
  app = pkgs.appimageTools.wrapType2 {
    pname = "open-cad-studio-unwrapped";
    inherit version src;

    extraPkgs = p: with p; [
      vulkan-loader
      libglvnd
      libxkbcommon
      wayland
      xorg.libX11
      xorg.libXcursor
      xorg.libXi
      xorg.libXrandr
      xorg.libxcb
      fontconfig
      freetype
      dbus

      # NOT OPTIONAL. cosmic-text resolves families by name through fontconfig.
      # buildFHSEnv symlinks the HOST /etc/fonts but serves its own empty
      # /usr/share/fonts, so every lookup missed - "failed to find family
      # 'DejaVu Sans'" and so on for every fallback in the chain. The app still
      # starts; it just draws no text.
      dejavu_fonts
      liberation_ttf
      noto-fonts
      noto-fonts-color-emoji
    ];
  };

  # WHY THE LAUNCHER EXISTS. wgpu wants a real GPU and this is a non-NixOS box,
  # so the nix-built libglvnd inside the FHS env cannot load Ubuntu's NVIDIA
  # driver. That is precisely what home/graphics.nix put nixGLNvidia on PATH for,
  # and the difference is measurable rather than theoretical. Verified 2026-09-10
  # by checking which device nodes the process holds:
  #   without nixGL   no /dev/nvidia* at all, no adapter, no window
  #   with nixGL      /dev/nvidia0, /dev/nvidiactl, /dev/nvidia-modeset,
  #                   /dev/dri/renderD128, and wgpu reports
  #                   driver_info "3.3.0 NVIDIA 595.84", backend Gl
  #
  # It resolves nixGLNvidia off PATH rather than importing it. graphics.nix says
  # the driver version must live in exactly one place, and re-deriving the
  # wrapper here would be a second place to bump. The fallback runs unaccelerated
  # rather than dying, so a machine without graphics.nix still gets a usable app
  # and a reason on stderr.
  launcher = pkgs.writeShellScriptBin "open-cad-studio" ''
    if command -v nixGLNvidia >/dev/null 2>&1; then
      exec nixGLNvidia ${app}/bin/open-cad-studio-unwrapped "$@"
    fi
    echo "open-cad-studio: nixGLNvidia not on PATH, falling back to software rendering" >&2
    echo "open-cad-studio: see home/graphics.nix" >&2
    exec ${app}/bin/open-cad-studio-unwrapped "$@"
  '';

  # Renamed off the reverse-DNS id upstream ships so the desktop entry below can
  # name it plainly. StartupWMClass still has to carry the original, since that
  # is what the toolkit actually sets on the window.
  icon = pkgs.runCommand "open-cad-studio-icon" { } ''
    install -Dm444 \
      ${contents}/usr/share/icons/hicolor/256x256/apps/io.github.HakanSeven12.OpenCadStudio.png \
      "$out/share/icons/hicolor/256x256/apps/open-cad-studio.png"
  '';

  # Bound once per anvil/nix-conventions. The updater takes a path argument, so
  # this is only the default for the common case of running it bare.
  defaultModule = "${config.home.homeDirectory}/Code/samuel-stidham/nix-config/home/open-cad-studio.nix";

  updater = pkgs.writeShellApplication {
    name = "open-cad-studio-update";
    runtimeInputs = with pkgs; [ curl jq nix gnused coreutils ];
    text = ''
      MODULE="''${1:-${defaultModule}}"
      API="https://api.github.com/repos/HakanSeven12/OpenCADStudio/releases/latest"

      if [ ! -f "$MODULE" ]; then
        echo "open-cad-studio-update: no module file at $MODULE" >&2
        echo "pass the path to home/open-cad-studio.nix as the first argument" >&2
        exit 1
      fi

      json=$(curl -fsSL --max-time 30 "$API")
      tag=$(printf '%s' "$json" | jq -r '.tag_name')
      latest=''${tag#v}

      # Read the asset URL from the API rather than rebuilding it from the tag.
      # Upstream already changed its version scheme once; the filename is the
      # next thing that can move.
      url=$(printf '%s' "$json" \
        | jq -r '.assets[] | select(.name | endswith("linux-x86_64.AppImage")) | .browser_download_url' \
        | head -1)

      if [ -z "$latest" ] || [ -z "$url" ]; then
        echo "open-cad-studio-update: no linux AppImage in the latest release" >&2
        exit 1
      fi

      current=$(sed -n 's/^  version = "\(.*\)";/\1/p' "$MODULE" | head -1)
      if [ -z "$current" ]; then
        echo "open-cad-studio-update: no pinned version line in $MODULE" >&2
        exit 1
      fi

      if [ "$latest" = "$current" ]; then
        echo "open-cad-studio: already pinned at $current"
        exit 0
      fi

      echo "open-cad-studio: $current -> $latest"
      sri=$(nix hash to-sri --type sha256 "$(nix-prefetch-url --type sha256 "$url")")

      sed -i \
        -e "s|^  version = .*|  version = \"$latest\";|" \
        -e "s|^    hash = \"sha256-.*|    hash = \"$sri\";|" \
        "$MODULE"

      echo "pinned $latest"
      echo "  $sri"
      echo
      echo "review:  git -C \"$(dirname "$MODULE")/..\" diff -- home/open-cad-studio.nix"
      echo "apply:   home-manager switch"
    '';
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  home.packages = [
    launcher
    icon
    updater
  ];

  # Written here rather than lifted from the AppImage because the Exec has to
  # point at the nixGL launcher, not at the bare binary. Fields otherwise match
  # what upstream ships, MimeType included, so DWG and DXF still associate.
  xdg.desktopEntries.open-cad-studio = {
    name = "Open CAD Studio";
    comment = "A CAD application for 2D/3D drawing and design";
    exec = "open-cad-studio %F";
    icon = "open-cad-studio";
    terminal = false;
    type = "Application";
    categories = [ "Graphics" "Engineering" ];
    mimeType = [ "image/vnd.dwg" "image/vnd.dxf" ];
    settings.StartupWMClass = "io.github.HakanSeven12.OpenCadStudio";
  };
}
