{ config, pkgs, ... }:

# C and C++ development libraries. The distro packages lag, so Nix owns these and
# they lead for ad hoc builds. Confirmed on nixpkgs-unstable on 2026-08-25:
#   SDL2 2.32.70, sdl3 3.4.12, raylib 6.0, boost 1.89.0
#
# Attribute names are not what you would guess. SDL2 is capitalized, sdl3 is not,
# and there is no SDL3 attribute at all.
#
# These are a convenience layer for quick compiles, not a substitute for a
# per-project flake. When a project needs a pinned library set, give it its own
# devShell with these in buildInputs. A profile install is global and unpinned,
# which is exactly what you do not want inside a real project.

{
  home.packages = with pkgs; [
    SDL2      # 2.32.70
    sdl3      # 3.4.12, lowercase attr on purpose
    raylib    # 6.0
    boost     # 1.89.0, swap to boost187 here if a project needs 1.87

    # The c-project-skeleton family finds Check through pkg-config at CMake
    # configure time, so it belongs here with the PKG_CONFIG_PATH wiring below.
    # It reads as a tool, but what the build consumes is a library plus check.pc.
    check     # 0.15.2, C unit test framework
  ];

  # On a non-NixOS system nothing teaches the toolchain about the Nix profile, so
  # a plain `gcc main.c $(pkg-config --cflags --libs sdl2)` fails even with the
  # library installed. These point pkg-config, cmake, and the raw compilers at the
  # profile. Each one appends, so a project's own devShell still wins.
  home.sessionVariables = {
    PKG_CONFIG_PATH = "${config.home.profileDirectory}/lib/pkgconfig:${config.home.profileDirectory}/share/pkgconfig:\${PKG_CONFIG_PATH}";
    CMAKE_PREFIX_PATH = "${config.home.profileDirectory}:\${CMAKE_PREFIX_PATH}";
    # For compiles that do not go through pkg-config or cmake.
    C_INCLUDE_PATH = "${config.home.profileDirectory}/include:\${C_INCLUDE_PATH}";
    CPLUS_INCLUDE_PATH = "${config.home.profileDirectory}/include:\${CPLUS_INCLUDE_PATH}";
    LIBRARY_PATH = "${config.home.profileDirectory}/lib:\${LIBRARY_PATH}";
  };
}
