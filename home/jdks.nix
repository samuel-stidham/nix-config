{ pkgs, lib, ... }:

# Java toolchain. This replaces sdkman, which managed Temurin 8, 11, 17, 21, 25,
# and 26 plus leiningen. Nix owns every JDK now. leiningen and clojure live in
# languages.nix, since they are language tooling that rides on the default JDK.
#
# Two needs are served here. First, a default java on PATH for general dev.
# sdkman's current was 21, so temurin-bin-21 leads. Second, every JDK version is
# exposed at a stable path under ~/.local/share/jdks so PrismLauncher can run a
# different Java per Minecraft instance. The symlinks are stable across rebuilds,
# which the raw /nix/store paths are not.
#
# All versions confirmed on nixpkgs-unstable on 2026-08-25:
#   temurin-bin-8  8.0.492    temurin-bin-21 21.0.11
#   temurin-bin-11 11.0.31    temurin-bin-25 25.0.3
#   temurin-bin-17 17.0.19    temurin-bin-26 26.0.1

{
  # GUARDED ON LINUX. Temurin JDK 8 has no aarch64-darwin build: Adoptium never
  # shipped JDK 8 for Apple Silicon, so an unguarded temurin-bin-8 aborts the
  # darwin eval with "unsupported CPU aarch64", which allowUnsupportedSystem does
  # not silence. The flake declares aarch64-darwin and applies this same module,
  # so the whole JDK set has to be Linux-only. PrismLauncher and the multi-JDK
  # layout are Linux workflows anyway. The pattern is the one CLAUDE.md names:
  # lib.optionals for home.packages, lib.mkIf for home.file.

  # Default JDK on PATH. Only one java can lead, so only this one goes in
  # packages. The rest are reached through the stable symlinks below.
  home.packages =
    lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.temurin-bin-21 ];

  # Stable per-version JDK homes. Point a PrismLauncher instance at
  # ~/.local/share/jdks/temurin-<N>/bin/java. Minecraft version to Java version:
  #   1.16 and older        -> temurin-8
  #   1.17 through 1.20.4   -> temurin-17
  #   1.20.5 and newer      -> temurin-21
  # 11, 25, and 26 are kept for other JVM work.
  home.file = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    ".local/share/jdks/temurin-8".source = pkgs.temurin-bin-8;
    ".local/share/jdks/temurin-11".source = pkgs.temurin-bin-11;
    ".local/share/jdks/temurin-17".source = pkgs.temurin-bin-17;
    ".local/share/jdks/temurin-21".source = pkgs.temurin-bin-21;
    ".local/share/jdks/temurin-25".source = pkgs.temurin-bin-25;
    ".local/share/jdks/temurin-26".source = pkgs.temurin-bin-26;
  };
}
