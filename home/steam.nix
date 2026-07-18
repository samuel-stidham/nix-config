{ lib, pkgs, ... }:

# Steam-on-Nix compatibility shim.
#
# Steam is a SYSTEM app (installed by bootstrap.sh through the distro package
# manager), not a Nix package. It ships its own runtime that pins the SYSTEM
# glibc, yet its launcher scripts call bare coreutils like dirname and readlink.
# Because the Nix profile leads PATH, Steam picks up Nix's coreutils, which are
# built against a newer glibc than Ubuntu 24.04 ships. Under Steam's system-glibc
# runtime they fail to load with "GLIBC_2.42 not found", steamwebhelper never
# starts, and the 32-bit-library probe misfires into a false "missing libc.so.6"
# warning. The shim is not Ubuntu-only: it helps on any distro whose system glibc
# is older than nixpkgs', and is harmless where it is not.
#
# The fix is to launch Steam with a system-first PATH so its scripts resolve
# /usr/bin coreutils. Steam's children, steamwebhelper and games, inherit this
# PATH, so the whole tree is covered. This handles both launch paths: the Cinnamon
# menu (desktop entry override) and the terminal (fish function).
#
# DISTRO PARITY. Two things were wrong before, both silent.
#
# 1. NO PLATFORM GUARD. The module wrote its desktop entry and fish function
#    unconditionally. On darwin, where flake.nix applies this same home.nix, that
#    is a dead steam.desktop and a dead fish function pointing at /usr/bin/steam,
#    a path macOS does not have. Nothing crashed, so nobody noticed. The whole
#    attrset is now wrapped in lib.mkIf pkgs.stdenv.isLinux, matching the sibling
#    modules home/syncthing.nix and home/btrfs-scrub.nix. That is why the module
#    signature had to widen from { ... } to { lib, pkgs, ... }.
#
# 2. HARDCODED /usr/bin/steam. That path is correct on debian (steam-installer),
#    fedora (steam from RPM Fusion) and openSUSE (steam from non-oss). It does NOT
#    exist on Bazzite, an atomic base where Steam ships as the Flatpak
#    com.valvesoftware.Steam and bootstrap.sh _system_atomic installs no native
#    steam at all. There the module wrote a second, dead "Steam" menu entry with
#    Exec=/usr/bin/steam beside the working Flatpak one, the same class of bug as
#    commit 653f771's two PrismLaunchers. The clicked duplicate did nothing.
#
# The fix for 2 is a runtime probe, not an eval-time branch. Home Manager eval is
# pure and cannot read /etc/os-release, so the module cannot know at build time
# whether it is on Bazzite. Instead steamLaunch below probes the clean PATH: if a
# native steam resolves there, run it with the clean PATH, otherwise fall back to
# flatpak run com.valvesoftware.Steam. The Flatpak id was read off the canonical
# Flathub page https://flathub.org/apps/com.valvesoftware.Steam through browse.
#
# One residue is accepted. Because atomic cannot be detected at eval time, the
# override still writes a steam.desktop on Bazzite, so a cosmetic duplicate menu
# entry remains beside the Flatpak's own com.valvesoftware.Steam.desktop. With the
# probe both entries now WORK (both reach the Flatpak), where before the duplicate
# was dead. Removing the duplicate itself would need an impure eval-time read,
# which the flake forbids. That trade is the reason the probe lives at runtime.
#
# UNVERIFIED on fedora, openSUSE, Bazzite and darwin: no such machine here. The
# eval was checked on x86_64-linux only. See the writer log for the exact output.

let
  # System dirs only, Nix profile deliberately absent. This used to append
  # /usr/games:/usr/local/games, which are Debian Policy 11.8.3 paths that exist
  # on no other family. They were harmless, a missing PATH dir is simply skipped,
  # but they were also Debian-specific noise in a module meant to be family
  # agnostic, so they are dropped.
  cleanPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

  # A launcher in the Nix store, referenced by both the desktop entry and the fish
  # function. It exists to hold the probe. It also solves a quoting problem: a
  # probe inlined into a desktop Exec line would need the freedesktop double-quote
  # escaping and would fight the field codes, so the Exec line just names this
  # script and the shell logic lives here where sh owns the quoting.
  #
  # writeShellScript, NOT writeShellApplication, on purpose. writeShellApplication
  # prepends its runtimeInputs to PATH from the Nix store, which is the exact
  # coreutils leak this module exists to prevent. This script must run steam and
  # flatpak from the SYSTEM, so it sets a clean PATH itself and takes nothing from
  # Nix. The probe runs against that clean PATH, so it never matches a Nix binary
  # and never matches the fish function of the same name, only /usr/bin/steam.
  steamLaunch = pkgs.writeShellScript "steam-launch" ''
    export PATH=${cleanPath}
    if command -v steam >/dev/null 2>&1; then
      exec env -u LD_LIBRARY_PATH steam "$@"
    fi
    # No native steam. On an atomic base like Bazzite, Steam is the Flatpak.
    if command -v flatpak >/dev/null 2>&1; then
      exec flatpak run com.valvesoftware.Steam "$@"
    fi
    echo "steam-launch: no native steam and no flatpak Steam found" >&2
    exit 1
  '';

  steamExec = args: "${steamLaunch} ${args}";
in
lib.mkIf pkgs.stdenv.isLinux {
  # Override the system steam.desktop with a clean-PATH launcher. This wins over
  # /usr/share/applications/steam.desktop because ~/.local/share is earlier in
  # XDG_DATA_DIRS. The right-click actions are reproduced so nothing is lost;
  # localized strings are dropped since the session locale is English.
  xdg.desktopEntries.steam = {
    name = "Steam";
    comment = "Application for managing and playing games on Steam";
    exec = steamExec "%U";
    icon = "steam";
    terminal = false;
    type = "Application";
    categories = [ "Network" "FileTransfer" "Game" ];
    mimeType = [ "x-scheme-handler/steam" "x-scheme-handler/steamlink" ];
    prefersNonDefaultGPU = true;
    settings.X-KDE-RunOnDiscreteGpu = "true";
    actions = {
      Store.exec = steamExec "steam://store";
      Community.exec = steamExec "steam://url/CommunityHome/";
      Library.exec = steamExec "steam://open/games";
      Servers.exec = steamExec "steam://open/servers";
      Screenshots.exec = steamExec "steam://open/screenshots";
      News.exec = steamExec "steam://openurl/https://store.steampowered.com/news";
      Settings.exec = steamExec "steam://open/settings";
      BigPicture = {
        name = "Big Picture";
        exec = steamExec "steam://open/bigpicture";
      };
      Friends.exec = steamExec "steam://open/friends";
    };
  };

  # Terminal launches get the same clean PATH through an autoloaded function.
  programs.fish.functions.steam = {
    description = "Steam with a system-first PATH (Nix coreutils break the Steam runtime)";
    body = steamExec "$argv";
  };
}
