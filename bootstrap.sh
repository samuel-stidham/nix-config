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

fish_login_shell() {
  log "fish as login shell"
  # home-manager installs fish into the user profile. Make that the login shell,
  # so terminals and TTYs use the Nix fish, not an apt one. The apt fish and its
  # PPA are intentionally absent, see .agents/outside-nix.md. Must run after
  # apply_home, since the profile fish has to exist first.
  local nix_fish="$HOME/.nix-profile/bin/fish"
  if [ ! -x "$nix_fish" ]; then
    echo "Nix fish not found at $nix_fish. Run apply_home first."
    return 1
  fi
  # Register it as a valid login shell, once.
  grep -qxF "$nix_fish" /etc/shells || echo "$nix_fish" | sudo tee -a /etc/shells >/dev/null
  # Set it as this user's login shell.
  sudo chsh -s "$nix_fish" "$USER"
  # Expose it at the conventional path, so any hardcoded #!/usr/bin/fish shebang
  # still resolves. This symlink is not apt-owned, since the apt fish is purged.
  sudo ln -sf "$nix_fish" /usr/bin/fish
}

apt_system() {
  log "apt system layer"
  # Extra system-layer packages that a fresh Ubuntu install does not already
  # include. The HWE kernel and the desktop environment come with the ISO, so
  # they are not listed here. That keeps this DE-agnostic. See
  # .agents/outside-nix.md.
  #
  # Docker is not in the default Ubuntu repos, so add Docker's apt repo.
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  # steam-launcher and virtualbox live in the multiverse component.
  sudo add-apt-repository -y multiverse

  sudo apt update
  sudo apt install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    openssh-server linux-headers-generic-hwe-24.04 \
    virtualbox virtualbox-dkms \
    steam-launcher \
    libfuse2t64 xdg-desktop-portal-gtk \
    mit-scheme

  # NVIDIA driver, picked automatically for the installed GPU. This survives a
  # release upgrade better than a pinned version.
  sudo ubuntu-drivers autoinstall
}

system_logs() {
  log "system logs: logrotate size caps + journald retention"
  # Keep system logs bounded without the old ulimit hack. Two layers:
  #
  # 1. rsyslog text logs: rotate daily, and also whenever a file crosses 10M,
  #    keeping 7. Worst case ~70M per log. The stock config only rotated weekly,
  #    so a chatty log (Docker's HTTP polling firehose) grew to ~760M/week.
  sudo tee /etc/logrotate.d/rsyslog >/dev/null <<'EOF'
/var/log/syslog
/var/log/mail.log
/var/log/kern.log
/var/log/auth.log
/var/log/user.log
/var/log/cron.log
{
	rotate 7
	daily
	maxsize 10M
	missingok
	notifempty
	compress
	delaycompress
	sharedscripts
	postrotate
		/usr/lib/rsyslog/rsyslog-rotate
	endscript
}
EOF

  # 2. Run logrotate hourly instead of daily, so the 10M cap is checked often
  #    enough to hold between rotations even under a flood.
  sudo mkdir -p /etc/systemd/system/logrotate.timer.d
  sudo tee /etc/systemd/system/logrotate.timer.d/override.conf >/dev/null <<'EOF'
[Timer]
OnCalendar=
OnCalendar=hourly
EOF

  # journald: keep 1G of real history instead of a 10M clamp, and stop forwarding
  # the journal firehose into /var/log/syslog. Comment out any old inline
  # SystemMax* first so this drop-in is authoritative.
  sudo sed -ri 's/^\s*(SystemMax(Use|FileSize|Files)=)/#\1/' /etc/systemd/journald.conf
  sudo mkdir -p /etc/systemd/journald.conf.d
  sudo tee /etc/systemd/journald.conf.d/00-sane-limits.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=1G
SystemMaxFiles=10
ForwardToSyslog=no
EOF

  sudo systemctl daemon-reload
  sudo systemctl restart systemd-journald
  sudo systemctl restart logrotate.timer
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
  # Bruno, Obsidian, Spotify, KeePassXC, and Halloy moved to Nix, see
  # home/apps.nix. Only pure desktop apps stay on Flatpak here.
  flatpak install -y --user flathub \
    com.github.tchx84.Flatseal \
    com.calibre_ebook.calibre \
    org.gimp.GIMP \
    org.prismlauncher.PrismLauncher
  echo "If PrismLauncher runs from Flatpak, grant it the Nix JDK folder with Flatseal:"
  echo "  filesystem access to ~/.local/share/jdks"
}

doom_emacs() {
  log "Doom Emacs"
  # Pinned to a specific commit for reproducibility. Doom pins most of its own
  # packages per-module, so pinning Doom itself also pins those. Bump this SHA
  # to update Doom.
  local doom_rev="8e4fbbae048a9abe897bf1878cbd32732a6d41d7"
  if [ ! -d "$HOME/.config/emacs" ]; then
    git clone https://github.com/doomemacs/doomemacs ~/.config/emacs
    git -C ~/.config/emacs -c advice.detachedHead=false checkout "$doom_rev"
  fi
  # The Doom user config comes from this repo through home-manager. Sync it.
  ~/.config/emacs/bin/doom install
}

lazyvim() {
  log "LazyVim (neovim config)"
  # neovim is from Nix (cli.nix); LazyVim is just its config. Cloned to
  # ~/.config/nvim, not Nix-managed, so LazyVim can write its own lazy-lock.json.
  # It becomes yours to customize after the clone. lvim/LunarVim was dropped, it
  # is abandoned upstream and does not support current neovim.
  # Pinned to a specific starter commit, and plugin versions pinned by the
  # committed lazy-lock.json, for reproducibility. Bump the SHA and re-copy the
  # lock (cp ~/.config/nvim/lazy-lock.json nvim/) to update.
  local lazyvim_rev="803bc181d7c0d6d5eeba9274d9be49b287294d99"
  if [ -d "$HOME/.config/nvim" ]; then
    echo "~/.config/nvim exists, skipping clone. Move it aside to reinstall."
  else
    git clone https://github.com/LazyVim/starter "$HOME/.config/nvim"
    git -C "$HOME/.config/nvim" -c advice.detachedHead=false checkout "$lazyvim_rev"
    rm -rf "$HOME/.config/nvim/.git"
    cp "$FLAKE_DIR/nvim/lazy-lock.json" "$HOME/.config/nvim/lazy-lock.json"
  fi
  # Install exactly the locked plugin versions (restore honours lazy-lock.json).
  nvim --headless "+Lazy! restore" +qa || true
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
  fish_login_shell
  apt_system
  system_logs
  vendor_debs
  flatpaks
  doom_emacs
  lazyvim
  monogame
  savvy
  log "Done. Reboot if the NVIDIA driver was reinstalled."
}

# Run one named section, or everything.
"${1:-all}"
