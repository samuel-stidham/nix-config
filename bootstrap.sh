#!/usr/bin/env bash
#
# bootstrap.sh - reproduce this machine from scratch.
#
# This installs Nix, applies the home-manager flake, and then installs every
# thing Nix does not own. The list of non-Nix software and the reason for each
# is codified in the migrate repo at .agents/outside-nix.md. Keep the two in
# sync. Together, this script plus the flake make the system reproducible.
#
# This is NOT part of the read-only ANALYZE pass. Run it only on a fresh machine,
# or run a single section by hand when you know you want it. Read it first. It
# uses sudo, apt, flatpak, and network installers.
#
# Usage:
#   ./bootstrap.sh            # run every section in order
#   ./bootstrap.sh nix        # run one section, by name
set -euo pipefail

FLAKE_DIR="${FLAKE_DIR:-$HOME/nix-config}"
HM_TARGET="samuelstidham@x86_64-linux"

log() { printf '\n=== %s ===\n' "$1"; }

install_nix() {
  log "Nix"
  if command -v nix >/dev/null 2>&1; then
    echo "Nix already installed, skipping."
    return
  fi
  # Determinate installer, which enables flakes and the daemon by default.
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
  echo "Open a new shell so the Nix profile loads, then re-run the next sections."
}

apply_home() {
  log "home-manager switch"
  # Flakes ignore untracked files, so stage first.
  git -C "$FLAKE_DIR" add -A
  nix run home-manager/master -- switch --flake "$FLAKE_DIR#$HM_TARGET"
}

apt_system() {
  log "apt system layer"
  # The system layer that must stay on apt. See .agents/outside-nix.md.
  sudo apt update
  sudo apt install -y \
    linux-generic-hwe-24.04 nvidia-driver-590-open \
    cinnamon-desktop-environment ubuntucinnamon-desktop \
    docker-ce docker-compose-plugin openssh-server \
    virtualbox virtualbox-dkms \
    steam-launcher \
    libfuse2t64 xdg-desktop-portal-gtk \
    mit-scheme
}

vendor_debs() {
  log "vendor .deb apps"
  # Electron and Chromium apps that ship an AppArmor profile. Each has its own
  # apt repo. This shows the pattern for Chrome and VS Code. Add 1Password,
  # Discord, Claude Desktop, Signal, Brave, and Slack the same way from their
  # own vendor repos.
  # Google Chrome
  wget -qO- https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
  # VS Code
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list
  sudo apt update
  sudo apt install -y google-chrome-stable code
  echo "Add 1password, discord, claude-desktop, signal, brave, slack from their vendor repos."
}

flatpaks() {
  log "Flatpak apps"
  flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y --user flathub \
    com.github.tchx84.Flatseal \
    com.usebruno.Bruno \
    md.obsidian.Obsidian \
    com.spotify.Client \
    org.keepassxc.KeePassXC \
    org.squidowl.halloy \
    com.calibre_ebook.calibre \
    org.gimp.GIMP \
    io.github.Hexchat \
    im.pidgin.Pidgin \
    org.prismlauncher.PrismLauncher
  echo "If PrismLauncher runs from Flatpak, grant it the Nix JDK folder with Flatseal:"
  echo "  filesystem access to ~/.local/share/jdks"
}

doom_emacs() {
  log "Doom Emacs"
  if [ ! -d "$HOME/.config/emacs" ]; then
    git clone --depth 1 https://github.com/doomemacs/doomemacs ~/.config/emacs
  fi
  # The Doom user config comes from this repo through home-manager. Sync it.
  ~/.config/emacs/bin/doom install
}

monogame() {
  log "MonoGame"
  # Not a Nix package. Templates and tools install through the Nix dotnet SDK.
  dotnet new install MonoGame.Templates.CSharp
  dotnet tool install --global dotnet-mgcb || true
  dotnet tool install --global dotnet-mgcb-editor || true
  echo "Set MGFXC_WINE_PATH to the Nix wine in ~/fish for the shader compiler."
}

savvy() {
  log "savvy"
  # No Nix package. Reinstall from its own script if you use it.
  echo "Reinstall savvy from its upstream installer into ~/.savvy."
}

all() {
  install_nix
  apply_home
  apt_system
  vendor_debs
  flatpaks
  doom_emacs
  monogame
  savvy
  log "Done. Reboot if the NVIDIA driver was reinstalled."
}

# Run one named section, or everything.
"${1:-all}"
