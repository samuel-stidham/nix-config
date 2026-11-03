{ config, pkgs, lib, ... }:

# Eclipse IDE for Java Developers, installed OUTSIDE Nix by bootstrap.sh
# eclipse_ide into ~/.local/opt/eclipse. This module owns only the launcher
# entry, so the IDE shows up in the application grid and leaves it again with
# one home-manager switch.
#
# WHY NOT NIX. eclipses.eclipse-java lived in apps.nix until 2026-11-02 and the
# IDE ran. The day it was asked to update, Oomph's startup setup tasks and
# Help > Check for Updates both failed with the same error:
#   session context was:(profile=epp.package.java, phase=...Uninstall,
#     operand=[R]org.eclipse.platform_root 4.41.0.v20260828-1142 --> null, ...)
#   Backup of file .../eclipse-java-4.41/eclipse/.eclipseproduct failed.
#   java.nio.file.AccessDeniedException
# p2 updates Eclipse in place, and the store is read only by design. Nix could
# pin the IDE, but every update would then wait on a lock bump. That defeats an
# IDE whose whole update path is built in. So it lives where p2 can write, the
# way Claude Code and the AWS CLI do, and bootstrap.sh records the rest.
#
# Exec is an absolute home path, not a store path, because the binary is not
# in the store. On a box where eclipse_ide has not run yet the entry fails to
# launch, loudly. That beats a missing icon nobody notices. Icon points at the
# xpm the tarball ships.

let
  # Absolute paths into $HOME, never a literal /home/samuelstidham, so the
  # module evaluates for whichever user applies it.
  homeDir = config.home.homeDirectory;
  prefix = "${homeDir}/.local/opt/eclipse";
in
lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  xdg.desktopEntries.eclipse = {
    name = "Eclipse";
    comment = "Eclipse IDE for Java Developers";
    exec = "${prefix}/eclipse %f";
    icon = "${prefix}/icon.xpm";
    terminal = false;
    type = "Application";
    categories = [ "Development" "IDE" ];
    settings.StartupWMClass = "Eclipse";
  };
}
