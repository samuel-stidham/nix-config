{ self, system, pkgs, lib, ... }:

# nixGLNvidia on PATH so nix-built OpenGL/Vulkan apps run GPU-accelerated on this
# non-NixOS (Ubuntu) box without the `nix run --impure … -- app` dance. A nix
# binary links nix's libglvnd, which can't load Ubuntu's /usr/lib NVIDIA driver
# (that would pull Ubuntu's glibc into a nix-glibc process), so nixGL bridges it
# with a nix-built copy of the matching driver.
#
# The wrapper is pinned + hashed in flake.nix (legacyPackages.nixGLNvidia), which
# makes it PURE — no --impure to build or switch, and it stays out of the way of
# `nix flake check`. We install it here rather than redefining it, so the driver
# version lives in exactly one place.
#
# The upstream binary is version-suffixed (nixGLNvidia-580.173.02); we re-expose
# it under the stable name `nixGLNvidia` so Makefiles/scripts don't hardcode the
# version and don't break on a driver bump.
#
# Linux-only: the same home.nix is applied to aarch64-darwin, where there is no
# NVIDIA and no nixGL. lib.optionals keeps the darwin path from evaluating it.

let
  nixGLNvidia = pkgs.runCommand "nixGLNvidia" { } ''
    mkdir -p "$out/bin"
    ln -s ${self.legacyPackages.${system}.nixGLNvidia}/bin/nixGLNvidia-* \
      "$out/bin/nixGLNvidia"
  '';
in
{
  home.packages = lib.optionals pkgs.stdenv.isLinux [ nixGLNvidia ];
}
