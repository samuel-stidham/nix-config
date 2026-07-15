#!/usr/bin/env bash
#
# bootstrap.sh - reproduce this machine from scratch, on any supported distro.
#
# This installs Nix, applies the home-manager flake, and then installs every
# thing Nix does not own. Nix owns the same set everywhere. Only the small
# non-Nix layer changes per distro, so this script detects the OS family and
# dispatches to the right package manager.
#
# Supported families:
#   debian  Ubuntu, Linux Mint, Pop!_OS, Debian, and other apt distros
#   fedora  Fedora and Nobara through dnf
#   atomic  Bazzite, Silverblue, Bluefin, Aurora through rpm-ostree and Flatpak
#
# The list of non-Nix software and the reason for each is codified in the
# migrate repo at .agents/outside-nix.md. Keep the two in sync. Together, this
# script plus the flake make the system reproducible.
#
# This is NOT part of the read-only ANALYZE pass. Run it only on a fresh machine,
# or run a single section by hand when you know you want it. Read it first. It
# uses sudo and network installers.
#
# Usage:
#   ./bootstrap.sh            # run every section in order
#   ./bootstrap.sh detect     # print what the OS probe found, change nothing
#   ./bootstrap.sh nix        # run one section, by name
set -euo pipefail

FLAKE_DIR="${FLAKE_DIR:-$HOME/nix-config}"
HM_TARGET="samuelstidham@x86_64-linux"

log() { printf '\n=== %s ===\n' "$1"; }

# --------------------------------------------------------------------------
# OS detection. Sets FAMILY, PKG, and ATOMIC from /etc/os-release. FAMILY is the
# packaging lineage. PKG is the tool that installs a package. ATOMIC is 1 on an
# image based distro like Bazzite, where the base is read only and layering is a
# last resort behind Flatpak.
# --------------------------------------------------------------------------
FAMILY="unknown"
PKG="none"
ATOMIC=0
OS_ID=""
OS_LIKE=""

detect_os() {
  if [ ! -r /etc/os-release ]; then
    echo "No /etc/os-release. Cannot detect the distro." >&2
    return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"

  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop|elementary|zorin|neon|raspbian) FAMILY="debian" ;;
    fedora|nobara|rhel|centos|rocky|almalinux|bazzite|bluefin|aurora|silverblue|kinoite) FAMILY="fedora" ;;
    *)
      case " $OS_LIKE " in
        *debian*|*ubuntu*) FAMILY="debian" ;;
        *fedora*|*rhel*)   FAMILY="fedora" ;;
        *)                 FAMILY="unknown" ;;
      esac
      ;;
  esac

  # An ostree based system is atomic. Its base filesystem is immutable.
  if [ -f /run/ostree-booted ]; then
    ATOMIC=1
  fi

  if [ "$FAMILY" = "debian" ]; then
    PKG="apt"
  elif [ "$FAMILY" = "fedora" ] && [ "$ATOMIC" = 1 ]; then
    PKG="rpm-ostree"
  elif [ "$FAMILY" = "fedora" ]; then
    PKG="dnf"
  fi
}

detect() {
  detect_os
  printf 'ID=%s ID_LIKE=%s\n' "${OS_ID:-none}" "${OS_LIKE:-none}"
  printf 'FAMILY=%s PKG=%s ATOMIC=%s\n' "$FAMILY" "$PKG" "$ATOMIC"
}

# --------------------------------------------------------------------------
# Package helpers. Every section calls these instead of a raw package manager,
# so the per distro branching lives in one place.
# --------------------------------------------------------------------------
pkg_refresh() {
  case "$PKG" in
    apt)         sudo apt update ;;
    dnf)         sudo dnf makecache ;;
    rpm-ostree)  sudo rpm-ostree refresh-md ;;
    *)           echo "pkg_refresh: no package manager for FAMILY=$FAMILY" >&2; return 1 ;;
  esac
}

pkg_install() {
  case "$PKG" in
    apt) sudo apt install -y "$@" ;;
    dnf) sudo dnf install -y "$@" ;;
    # --idempotent skips packages that are already layered. Layered packages need
    # a reboot to take effect, unless a later section forces one.
    rpm-ostree) sudo rpm-ostree install --idempotent "$@" ;;
    *) echo "pkg_install: no package manager for FAMILY=$FAMILY" >&2; return 1 ;;
  esac
}

flatpak_install() {
  flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y --user flathub "$@"
}

# --------------------------------------------------------------------------
# OS agnostic sections. These run the same on every distro.
# --------------------------------------------------------------------------
install_nix() {
  log "Nix"
  if command -v nix >/dev/null 2>&1; then
    echo "Nix already installed, skipping."
    return
  fi
  # Determinate installer, which enables flakes and the daemon by default. It
  # also handles the /nix mount correctly on atomic distros like Bazzite.
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
  # so terminals and TTYs use the Nix fish, not a distro one. Must run after
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
  # still resolves.
  sudo ln -sf "$nix_fish" /usr/bin/fish
}

# --------------------------------------------------------------------------
# System layer. Extra system packages a fresh desktop install does not ship.
# Each family gets its own function, and system_layer picks the right one.
# --------------------------------------------------------------------------
_system_debian() {
  # Containers use Podman, not Docker, standardized across every distro so the
  # stack is identical before and after the Bazzite move. Podman is in the Ubuntu
  # repos, rootless, and daemonless, so no Docker apt repo is needed.
  # podman-docker provides the `docker` command and a compatible socket, so tools
  # and the forgejo runner that expect Docker still work. podman-compose runs the
  # existing compose files until they become Quadlets.
  #
  # steam-launcher and virtualbox live in the multiverse component.
  sudo add-apt-repository -y multiverse
  pkg_refresh

  # HWE kernel headers for DKMS, so virtualbox can build modules. The suffix
  # tracks the LTS version, so derive it. This yields hwe-24.04 now and
  # hwe-26.04 automatically after the release upgrade.
  local hwe_headers
  hwe_headers="linux-headers-generic-hwe-$(. /etc/os-release && echo "$VERSION_ID")"
  pkg_install \
    podman podman-compose podman-docker \
    openssh-server "$hwe_headers" \
    virtualbox virtualbox-dkms \
    steam-launcher \
    libfuse2t64 xdg-desktop-portal-gtk \
    mit-scheme
}

_system_fedora() {
  # RPM Fusion gives the nonfree bits, Steam, and the VirtualBox akmods.
  local rel
  rel="$(rpm -E %fedora)"
  pkg_install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${rel}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${rel}.noarch.rpm"
  pkg_refresh

  # Containers use Podman, which Fedora ships in its base repos, so no Docker repo
  # is needed. podman-docker provides the `docker` command and compatible socket.
  # kernel-devel matches akmods to the running kernel, the dnf peer of the HWE
  # headers. Steam and VirtualBox come from RPM Fusion. libfuse compat is
  # fuse-libs here.
  pkg_install \
    podman podman-compose podman-docker \
    openssh-server kernel-devel \
    VirtualBox akmod-VirtualBox \
    steam \
    fuse-libs xdg-desktop-portal-gtk \
    mit-scheme
}

_system_atomic() {
  # Bazzite already ships Steam, the gaming stack, and the gtk portal, so this
  # only covers the developer extras. Podman is the container runtime here and is
  # built in, which is exactly the standardized choice, so nothing to install.
  # The forgejo and atlantis stack runs as rootless Podman Quadlets. distrobox is
  # built in for throwaway toolchains. VirtualBox does not belong on an atomic
  # base, its kernel modules fight the image, so use the built in virtualization.
  echo "Atomic base. Steam and the gaming stack are already present, skipping."
  echo "Podman and distrobox are built in. Podman runs the forgejo stack (Quadlets)."
  echo "For sshd run: systemctl enable --now sshd"
  # openssh-server is present on Bazzite. mit-scheme has no Flatpak, so layer it
  # only if you truly need Scheme on the base, otherwise reach it through Nix or
  # a distrobox. Layering needs a reboot to apply.
  echo "To layer mit-scheme on the base: ./bootstrap.sh atomic_extras"
}

atomic_extras() {
  log "atomic layered extras"
  pkg_install mit-scheme
  echo "Reboot to apply the layered package."
}

system_layer() {
  log "system layer ($FAMILY)"
  case "$FAMILY" in
    debian) _system_debian ;;
    fedora) if [ "$ATOMIC" = 1 ]; then _system_atomic; else _system_fedora; fi ;;
    *) echo "Unknown family, skipping system layer." >&2 ;;
  esac
}

# --------------------------------------------------------------------------
# NVIDIA driver. Bazzite bakes it into the image, so atomic skips this. The
# other families install the vendor driver for the detected GPU.
# --------------------------------------------------------------------------
nvidia_driver() {
  log "NVIDIA driver ($FAMILY)"
  if [ "$ATOMIC" = 1 ]; then
    echo "Atomic image ships the NVIDIA driver, skipping. Use the -nvidia image."
    return
  fi
  case "$FAMILY" in
    debian)
      # Picked automatically for the installed GPU. This survives a release
      # upgrade better than a pinned version.
      sudo ubuntu-drivers autoinstall
      ;;
    fedora)
      # akmod-nvidia from RPM Fusion, which was enabled in _system_fedora. The
      # cuda subpackage covers compute and the open kernel modules for Blackwell.
      pkg_install akmod-nvidia xorg-x11-drv-nvidia-cuda
      echo "Wait for the akmod to build before rebooting: modinfo -F version nvidia"
      ;;
    *) echo "Unknown family, skipping NVIDIA." >&2 ;;
  esac
}

# --------------------------------------------------------------------------
# VirtualBox USB. Two things are needed for USB passthrough, and this machine had
# neither: the Oracle Extension Pack, which adds the USB 2.0 and 3.0 controllers,
# and membership in vboxusers, which grants access to the USB device nodes.
# Without both, VirtualBox lists no USB devices at all. The VNC extpack alone
# does not cover USB. Docker Desktop also has to go for VMs to work, since its
# KVM VM holds AMD-V exclusively. Podman, the standardized runtime, does not run
# a VM, so it leaves AMD-V free for VirtualBox.
# --------------------------------------------------------------------------
virtualbox_extras() {
  log "VirtualBox USB + extension pack ($FAMILY)"
  if [ "$ATOMIC" = 1 ]; then
    echo "VirtualBox is not supported on the atomic base, skipping."
    return
  fi
  case "$FAMILY" in
    debian)
      # This package fetches the matching Oracle pack and accepts the PUEL
      # license through debconf.
      pkg_install virtualbox-ext-pack
      ;;
    fedora)
      # Fedora has no ext-pack package, so fetch the pack matching the installed
      # VirtualBox version. --version prints 7.0.16r162802, trim the revision.
      local ver f
      ver="$(VBoxManage --version 2>/dev/null | sed 's/r.*//')"
      f="Oracle_VM_VirtualBox_Extension_Pack-${ver}.vbox-extpack"
      curl -fL -o "/tmp/$f" "https://download.virtualbox.org/virtualbox/${ver}/${f}"
      sudo VBoxManage extpack install --replace "/tmp/$f"
      ;;
    *) echo "Unknown family, skipping VirtualBox extras." >&2 ; return ;;
  esac
  # Grant USB device access. A group change needs a fresh login to apply.
  sudo usermod -aG vboxusers "$USER"
  echo "Log out and back in so the vboxusers group applies, then USB devices appear."
}

# --------------------------------------------------------------------------
# Vendor GUI apps. Electron and Chromium apps that Nix does not own well.
# apt and dnf use each vendor's own repo. Atomic uses Flatpak, which matches
# the Flatpak first rule in .agents/install-policy.md.
# --------------------------------------------------------------------------
_vendor_debian() {
  # Google Chrome
  wget -qO- https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
  # VS Code
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list
  # TablePlus used to be here from its own apt repo. It is gone now, replaced by
  # dbeaver-bin in home/apps.nix, which Nix installs the same way everywhere.
  pkg_refresh
  pkg_install google-chrome-stable code
  echo "Add 1password, discord, signal, slack from their vendor repos."
}

_vendor_fedora() {
  # Google Chrome
  sudo tee /etc/yum.repos.d/google-chrome.repo >/dev/null <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
  # VS Code
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
  sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  pkg_refresh
  pkg_install google-chrome-stable code
  # TablePlus is gone, replaced by dbeaver-bin in home/apps.nix.
  echo "Add 1password, discord, signal, slack from their vendor repos."
}

_vendor_atomic() {
  # Flatpak first on the atomic base. These are the Flathub IDs for the same
  # apps the apt and dnf branches pull from vendor repos.
  flatpak_install \
    com.google.Chrome \
    com.visualstudio.code
  # TablePlus is gone, replaced by dbeaver-bin in home/apps.nix.
  echo "Add 1password, discord, signal, slack from Flathub."
}

vendor_apps() {
  log "vendor GUI apps ($FAMILY)"
  case "$FAMILY" in
    debian) _vendor_debian ;;
    fedora) if [ "$ATOMIC" = 1 ]; then _vendor_atomic; else _vendor_fedora; fi ;;
    *) echo "Unknown family, skipping vendor apps." >&2 ;;
  esac
}

# --------------------------------------------------------------------------
# Flatpak apps. These are the same on every distro, since Flatpak is the shared
# desktop app channel. Bruno, Obsidian, Spotify, KeePassXC, and Halloy moved to
# Nix, see home/apps.nix. Only pure desktop apps stay here.
# --------------------------------------------------------------------------
flatpaks() {
  log "Flatpak apps"
  flatpak_install \
    com.github.tchx84.Flatseal \
    com.calibre_ebook.calibre \
    org.gimp.GIMP \
    org.prismlauncher.PrismLauncher \
    io.ente.auth
  echo "If PrismLauncher runs from Flatpak, grant it the Nix JDK folder with Flatseal:"
  echo "  filesystem access to ~/.local/share/jdks"
}

# --------------------------------------------------------------------------
# System logs. rsyslog plus logrotate is a Debian layout. Fedora and atomic lean
# on journald alone, so this section only runs on the debian family.
# --------------------------------------------------------------------------
system_logs() {
  log "system logs: logrotate size caps + journald retention"
  if [ "$FAMILY" != "debian" ]; then
    echo "Not a debian family layout, skipping rsyslog logrotate."
    echo "Fedora and atomic use journald only. Adjust /etc/systemd/journald.conf if needed."
    return
  fi
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

# --------------------------------------------------------------------------
# App configs that are just git checkouts. OS agnostic.
# --------------------------------------------------------------------------
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

btrfs_scrub_sudo() {
  log "btrfs scrub sudo rule"
  # The monthly scrub runs as a USER systemd timer, so msmtp's passwordeval can
  # read the Gmail password out of passage without a root unit reaching into the
  # user's secret store. Only the scrub itself needs root, so grant exactly that
  # and nothing else.
  #
  # /usr/bin/btrfs is deliberate. sudo's secure_path strips ~/.nix-profile/bin, so
  # `sudo btrfs` would never resolve the Nix build anyway. The distro binary is
  # the stable path, and on Bazzite btrfs-progs is part of the image.
  if [ "$FAMILY" = "unknown" ]; then
    echo "Unknown family, skipping." >&2
    return
  fi
  local f=/etc/sudoers.d/btrfs-scrub
  printf '%s ALL=(root) NOPASSWD: /usr/bin/btrfs scrub *\n' "$USER" | sudo tee "$f" >/dev/null
  sudo chmod 0440 "$f"
  # An invalid sudoers file can lock you out of sudo entirely, so validate it and
  # remove it if it does not parse.
  if sudo visudo -cf "$f" >/dev/null 2>&1; then
    echo "installed $f"
  else
    sudo rm -f "$f"
    echo "sudoers rule failed validation and was removed" >&2
    return 1
  fi
  echo "Enable the timer: systemctl --user enable --now btrfs-scrub.timer"
}

tailscale_net() {
  log "Tailscale"
  # A stable overlay IP and MagicDNS name that follow this machine across
  # ethernet, WiFi, and even a move to new hardware. The forgejo and atlantis
  # webhooks and your own remote access point at the tailnet name, so they never
  # break on a network change. The installer is distro aware and covers debian
  # and fedora. Bazzite ships tailscale already, so this is a no-op there.
  if command -v tailscale >/dev/null 2>&1; then
    echo "tailscale already present."
  elif [ "$ATOMIC" = 1 ]; then
    echo "Atomic base ships tailscale. Enable it, a state change you run yourself:"
    echo "  sudo systemctl enable --now tailscaled"
  else
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  # Authentication is a state change, so it is yours to run, not the script's.
  echo "Authenticate once: sudo tailscale up"
  echo "Then reach services by their tailnet name, e.g. forgejo, from any network."
}

nm_static_ip() {
  log "static LAN IP (NetworkManager)"
  # Pin the same IPv4 on both the wired and WiFi profiles, so the LAN address
  # stays 192.168.1.200 whether the cable is in or not. Only one profile is
  # active at a time, so there is no address clash. This complements Tailscale,
  # which handles the cross-network identity. Adjust the values to your LAN.
  #
  # These are printed, not run. Changing the active connection can drop the
  # network mid-command, and the rules say propose state changes rather than run
  # them. Pick the connection names from the list, then run the pair per profile.
  local ip="192.168.1.200/24" gw="192.168.1.1" dns="192.168.1.1,1.1.1.1"
  echo "Your NetworkManager connections:"
  nmcli -t -f NAME,TYPE connection show 2>/dev/null || echo "  (nmcli not available here)"
  echo
  echo "For each wired and WiFi connection you want pinned to $ip, run:"
  echo "  nmcli connection modify <name> ipv4.method manual ipv4.addresses $ip ipv4.gateway $gw ipv4.dns \"$dns\""
  echo
  echo "Prefer wired when both are plugged, so only one holds $ip at a time:"
  echo "  nmcli connection modify <wired-name> connection.autoconnect-priority 10"
  echo "  nmcli connection modify <wifi-name>  connection.autoconnect-priority 5"
  echo "Then bring the one you want up:"
  echo "  nmcli connection up <name>"
  echo "Whichever profile is active carries $ip, so the machine keeps it on either medium."
}

claude_code() {
  log "Claude Code"
  # The Claude Code CLI. Kept out of Nix on purpose, so it can self-update. The
  # nixpkgs build is pinned and cannot update itself, and Claude Code ships often.
  # The official installer drops a self-updating binary under ~/.local. It is OS
  # agnostic, so it runs the same on every family.
  if command -v claude >/dev/null 2>&1; then
    echo "Claude Code already present. It self-updates, so leaving it."
    return
  fi
  curl -fsSL https://claude.ai/install.sh | bash
}

aws_cli() {
  log "AWS CLI v2"
  # From AWS's own bundled installer, not Nix, so it rolls forward on its own
  # like Claude Code. AWS recommends this over any distro package. It is self
  # contained and OS agnostic, and on the atomic base /usr/local is writable, so
  # it works on Bazzite too. unzip comes from Nix (cli.nix).
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  if [ -d /usr/local/aws-cli ]; then
    # Existing install. The --update form needs the original paths restated.
    sudo "$tmp/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update
  else
    sudo "$tmp/aws/install"
  fi
  rm -rf "$tmp"
  aws --version || true
}

all() {
  detect_os
  echo "Detected FAMILY=$FAMILY PKG=$PKG ATOMIC=$ATOMIC"
  install_nix
  apply_home
  fish_login_shell
  system_layer
  nvidia_driver
  virtualbox_extras
  btrfs_scrub_sudo
  tailscale_net
  nm_static_ip
  vendor_apps
  flatpaks
  system_logs
  doom_emacs
  lazyvim
  monogame
  savvy
  claude_code
  aws_cli
  log "Done. Reboot if a driver or a layered package changed."
}

# Every named section needs the OS probe first, except detect and all which run
# it themselves. Run the probe, then the requested section.
main() {
  local section="${1:-all}"
  case "$section" in
    detect|all) "$section" ;;
    *) detect_os; "$section" ;;
  esac
}

main "$@"
