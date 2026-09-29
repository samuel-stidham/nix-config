{ config, pkgs, lib, ... }:

# CUDA for Nix-built programs on a non-NixOS host. The GPU driver is the
# host's, installed by the distro package manager. A Nix-built process cannot
# see it. Nix's glibc loader never reads /etc/ld.so.cache and never searches
# /usr/lib/x86_64-linux-gnu or /usr/lib64, so libcuda.so.1 is simply absent
# from its world.
#
# THE FAILURE
#
# pysci-ai runs a Nix-built CPython 3.14 with the PyTorch 2.14.0+cu130 wheel.
# torch.cuda.is_available() was False with "Found no NVIDIA driver", and
# ctypes.CDLL("libcuda.so.1") failed with "cannot open shared object file".
# nvidia-smi, the device nodes and the driver were all fine. Linking only
# libcuda.so.1, libnvidia-ml.so.1 and libnvidia-ptxjitcompiler.so.1 into one
# dir and putting that dir on LD_LIBRARY_PATH made torch run a CUDA matmul.
# That proven set is exactly what this module links.
#
# WHAT WAS REJECTED
#
# targets.genericLinux.gpu, home-manager's own answer. It builds a Nix copy of
# the NVIDIA userspace from a pinned version and hash, then a sudo script
# points /run/opengl-driver at it through tmpfiles. Every apt driver bump then
# needs a new pin, a rebuild and another sudo run, or CUDA breaks on a version
# mismatch. That is the same treadmill nixGLNvidia already puts graphics.nix
# on. It also only fills /run/opengl-driver, which a pip wheel never searches.
#
# nixGL. Same pinned-driver treadmill, and it only helps a process you
# remember to wrap. It cannot make `devenv shell -- python` just work.
#
# /run/opengl-driver/lib ALONE. bootstrap.sh nix_opengl_driver already fills
# it at boot with the host's NVIDIA libs, and nixpkgs-built CUDA packages find
# it through their RUNPATH. A pip wheel carries no such RUNPATH. torch's
# dlopen("libcuda.so.1") consults LD_LIBRARY_PATH and nothing else useful.
#
# All of /run/opengl-driver/lib on LD_LIBRARY_PATH. It also holds the GLX, EGL
# and Vulkan vendor libs. Every Nix GUI app's libglvnd would then pick up the
# host driver behind nixGL's back. The compute libs are all CUDA needs, so the
# graphics stack is left alone.
#
# WHAT THIS DOES INSTEAD
#
# A small dir, ~/.local/lib/nvidia-compute, holds the three compute libs and
# goes on LD_LIBRARY_PATH for the whole session. Each link points at the
# same-named entry in /run/opengl-driver/lib, which bootstrap.sh resolved
# through ldconfig at boot. So no Debian multiarch path appears here, and
# fedora and suse get /usr/lib64 without a branch. The links use the stable
# .so.1 sonames, never 595.91.07. apt repoints libcuda.so.1 on a driver
# upgrade, so the chain survives it untouched.
#
# Only these three libs are on the path. Host glibc and libstdc++ never are,
# so a Nix program keeps its own. Host programs see their own driver, which
# they would have loaded anyway.
#
# THE GUARD
#
# Linux only, through lib.mkIf. Darwin evaluates this module and gets nothing.
# On a Linux host with no NVIDIA driver the links dangle. The loader skips a
# dangling entry with ENOENT and moves on, which is the same outcome as the
# dir not existing. Pure eval cannot probe the host, so a runtime no-op is
# the guard available.
#
# THE TRAP FOR PROJECTS
#
# A devenv `env.LD_LIBRARY_PATH = ...` REPLACES the inherited value, it does
# not prepend. `devenv print-dev-env` in pysci-ai showed a bare
# `LD_LIBRARY_PATH='/nix/store/...'` followed by `export LD_LIBRARY_PATH`.
# Inside such a shell this module's dir is gone. The project has to append
# a driver dir itself. Nothing in this repo can reach past that.
#
# Unverified on fedora and suse, no such machine available.

let
  # The compute-only driver dir. Kept under ~/.local/lib so it sits beside
  # the other per-user runtime paths and is owned by home-manager, not root.
  nvidiaComputeDir = "${config.home.homeDirectory}/.local/lib/nvidia-compute";

  # libcuda is the driver API itself. libnvidia-ml is NVML, the management
  # library torch and friends query for device state. libnvidia-ptxjitcompiler
  # JITs any kernel a wheel shipped as PTX without SASS for this card.
  computeLibs = [
    "libcuda.so.1"
    "libnvidia-ml.so.1"
    "libnvidia-ptxjitcompiler.so.1"
  ];
in
{
  home.file = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (lib.listToAttrs
    (map
      (name: {
        name = ".local/lib/nvidia-compute/${name}";
        value.source =
          config.lib.file.mkOutOfStoreSymlink "/run/opengl-driver/lib/${name}";
      })
      computeLibs));

  home.sessionSearchVariables = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    LD_LIBRARY_PATH = [ nvidiaComputeDir ];
  };

  # OFF ON PURPOSE. targets.genericLinux.enable in home.nix turns this on by
  # default, in Mesa-only mode. Its setup was never run here. Its activation
  # check reads `readlink /run/opengl-driver`, which is empty for the plain
  # directory bootstrap.sh makes, so every switch warns "This non-NixOS
  # system is not yet set up to use the GPU".
  # Following that advice would be worse. Its tmpfiles rule is
  # `L+ /run/opengl-driver`, which replaces the directory bootstrap.sh fills
  # with a symlink to a Nix Mesa env. The NVIDIA libs would vanish at the next
  # boot, taking PrismLauncher and every CUDA program with them. One owner of
  # /run/opengl-driver, and it is bootstrap.sh.
  targets.genericLinux.gpu.enable =
    lib.mkIf pkgs.stdenv.hostPlatform.isLinux false;
}
