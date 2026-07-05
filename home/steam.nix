{ ... }:

# Steam-on-Nix compatibility shim.
#
# Steam is an apt app (system layer, see bootstrap.sh), not a Nix package. It
# ships its own runtime that pins the SYSTEM glibc, yet its launcher scripts call
# bare coreutils like dirname and readlink. Because the Nix profile leads PATH,
# Steam picks up Nix's coreutils, which are built against a newer glibc than
# Ubuntu 24.04 ships. Under Steam's system-glibc runtime they fail to load with
# "GLIBC_2.42 not found", steamwebhelper never starts, and the 32-bit-library
# probe misfires into a false "missing libc.so.6" warning.
#
# The fix is to launch Steam with a system-first PATH so its scripts resolve
# /usr/bin coreutils. Steam's children, steamwebhelper and games, inherit this
# PATH, so the whole tree is covered. This handles both launch paths: the Cinnamon
# menu (desktop entry override) and the terminal (fish function).

let
  # The default Ubuntu session PATH, without the Nix profile.
  cleanPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games";
  steamEnv = "env -u LD_LIBRARY_PATH PATH=${cleanPath}";
  steamExec = args: "${steamEnv} /usr/bin/steam ${args}";
in
{
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
