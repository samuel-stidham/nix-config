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
  # Filesystem tools live HERE, not in a home-manager module. Every one of them
  # needs root, and sudo's secure_path excludes the nix profile, so a nix-installed
  # smartctl is on PATH and invisible to sudo at the same time. Root's tools come
  # from the distro. See home/filesystems.nix for the full reasoning.
  pkg_install \
    podman podman-compose podman-docker \
    openssh-server "$hwe_headers" \
    virtualbox virtualbox-dkms \
    steam-launcher \
    libfuse2t64 xdg-desktop-portal-gtk \
    btrfs-progs smartmontools hdparm exfatprogs \
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
  # Root-only filesystem tools. See the note in _system_debian.
  pkg_install \
    podman podman-compose podman-docker \
    openssh-server kernel-devel \
    VirtualBox akmod-VirtualBox \
    steam \
    fuse-libs xdg-desktop-portal-gtk \
    btrfs-progs smartmontools hdparm exfatprogs \
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
  # Calibre is NOT here. It comes from its own binary installer, see calibre().
  # Upstream explicitly says not to use distro packages, and the Flatpak is
  # sandboxed, so it cannot see a library on /media without a filesystem grant.
  # PrismLauncher is NOT here. It comes from Nix, see prismlauncher in apps.nix.
  #
  # Installing both is how this machine ended up with two launchers, one holding
  # five instances and one holding none. They do not share data: the Nix build
  # keeps instances in ~/.local/share/PrismLauncher, the Flatpak keeps its own
  # under ~/.var/app/org.prismlauncher.PrismLauncher. Only the first is what
  # MC_DIR in scripts/backup.sh backs up.
  #
  # The Flatpak is also the one that cannot run the Nix JDKs, because the sandbox
  # cannot see /nix/store. That was papered over here with an instruction to
  # grant ~/.local/share/jdks in Flatseal, which is a workaround for a sandbox we
  # have no reason to be inside. The Nix build reads the JDKs directly.
  flatpak_install \
    com.github.tchx84.Flatseal \
    org.gimp.GIMP \
    io.ente.auth
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

mount_drives() {
  log "bulk drive mounts (fstab)"
  # Pin both btrfs drives to explicit mount points, by UUID.
  #
  # This is not about auto-mounting, udisks already does that. It is about the
  # PATH being the same everywhere. Ubuntu's udisks mounts at
  # /media/$USER/LABEL, Fedora and Bazzite mount at /run/media/$USER/LABEL. Six
  # files in this repo and calibre's library_path hardcode /media/samuelstidham,
  # so on Bazzite every one of them would quietly point at nothing: restic would
  # back up an empty directory, the scrubs would skip, calibre would find no
  # library. An fstab entry makes the path ours instead of the distro's.
  #
  # /etc does not survive a reinstall, which is exactly why this lives in
  # bootstrap.sh: run it on the new machine and the paths come back.
  #
  # Options that matter:
  #   nofail                     a missing drive must never block the boot
  #   x-systemd.device-timeout   fail fast instead of waiting 90s for it
  #   compress=zstd:3            belt and braces with the on-disk property
  #   noatime                    no write amplification just for reads
  if [ "$ATOMIC" = 1 ]; then
    echo "Atomic base keeps /etc writable, so fstab still applies here."
  fi

  # lsblk, not blkid. blkid needs root to probe and returns an empty string for a
  # normal user, which would make this skip both drives while reporting success.
  # lsblk reads the same data unprivileged.
  local sp_uuid wd_uuid
  sp_uuid="$(lsblk -no UUID /dev/disk/by-label/StoragePrime 2>/dev/null | head -1)"
  wd_uuid="$(lsblk -no UUID /dev/disk/by-label/WorkDrive 2>/dev/null | head -1)"

  local opts="compress=zstd:3,noatime,nofail,x-systemd.device-timeout=10"
  local changed=0

  _add_mount() {
    local uuid="$1" mnt="$2" label="$3"
    if [ -z "$uuid" ]; then
      echo "  $label not found by label, skipping"
      return
    fi
    if grep -q "$uuid" /etc/fstab 2>/dev/null; then
      echo "  $label already in fstab"
      return
    fi
    sudo mkdir -p "$mnt"
    printf 'UUID=%s  %s  btrfs  %s  0 0\n' "$uuid" "$mnt" "$opts" | sudo tee -a /etc/fstab >/dev/null
    echo "  added $label -> $mnt"
    changed=1
  }

  _add_mount "$sp_uuid" /media/samuelstidham/StoragePrime StoragePrime
  _add_mount "$wd_uuid" /media/samuelstidham/WorkDrive WorkDrive

  if [ "$changed" = 1 ]; then
    # A bad fstab can leave the machine unbootable, so prove it parses before
    # trusting it. mount -a is the honest test.
    sudo systemctl daemon-reload
    if sudo mount -a; then
      echo "fstab applied and mounted"
    else
      echo "MOUNT FAILED. Fix /etc/fstab before rebooting." >&2
      return 1
    fi
  fi
  # btrfs stores ownership, unlike exfat, so a fresh filesystem root is root:root
  # and the user cannot write to it. exfat faked it with uid= at mount time.
  sudo chown "$USER:$USER" /media/samuelstidham/StoragePrime /media/samuelstidham/WorkDrive 2>/dev/null || true
}

drives_stay_awake() {
  log "keep the bulk drives spun up"
  # Two different problems get confused here, so be explicit:
  #
  #   mounting   fstab, see mount_drives. Without it udisks only mounts when you
  #              click the drive in a file manager.
  #   spin down  this function. A mounted drive still parks itself when idle, and
  #              you wait for it to spin back up on the next access.
  #
  # And spin down is itself two mechanisms:
  #
  #   APM / standby timer   generic ATA, hdparm -B 255 -S 0 turns both off.
  #   WD IntelliPark        a SEPARATE firmware timer on WD desktop drives that
  #                         parks the heads after ~8 seconds. hdparm -B does not
  #                         touch it. Only idle3ctl does.
  #
  # WorkDrive is a WDC WD80EZAZ, which is exactly the drive IntelliPark is
  # infamous on. StoragePrime is a Seagate IronWolf, a NAS drive built for 24/7,
  # so it mostly just needs APM off.
  #
  # Parking is not only a delay, it is wear. These drives are rated for a few
  # hundred thousand load cycles, and an 8 second timer burns through them.
  local sp="/dev/disk/by-id/ata-ST12000VN0008-2YS101_ZRT0TGY0"
  local wd="/dev/disk/by-id/ata-WDC_WD80EZAZ-11TDBA0_1EK7ET2Z"

  if ! command -v hdparm >/dev/null 2>&1; then
    case "$FAMILY" in
      debian) pkg_install hdparm ;;
      fedora) pkg_install hdparm ;;
    esac
  fi

  # A udev rule rather than a one shot service: it fires on boot AND on hotplug,
  # and it survives the drive being unplugged and returned. Matched on serial, so
  # it can never apply to the wrong disk if sda and sdb ever swap.
  sudo tee /etc/udev/rules.d/69-drives-stay-awake.rules >/dev/null <<'EOF'
# Keep the bulk spinners awake. -B 255 disables APM, -S 0 disables the standby
# timer. Matched by serial so a device rename cannot misapply these.
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_SERIAL_SHORT}=="ZRT0TGY0", RUN+="/usr/sbin/hdparm -B 255 -S 0 /dev/%k"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_SERIAL_SHORT}=="1EK7ET2Z", RUN+="/usr/sbin/hdparm -B 255 -S 0 /dev/%k"
EOF
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=block --action=change
  echo "udev rule installed and triggered"

  # Apply now too, so it takes effect without waiting for a reboot.
  sudo hdparm -B 255 -S 0 "$sp" >/dev/null 2>&1 && echo "  StoragePrime: APM and standby off"
  sudo hdparm -B 255 -S 0 "$wd" >/dev/null 2>&1 && echo "  WorkDrive: APM and standby off"

  # IntelliPark is stored in the drive's own firmware, so this is a ONE TIME
  # change that persists across reboots and reinstalls. It needs a power cycle,
  # not a warm reboot, to take effect.
  echo
  # WD IntelliPark, the "idle3" timer. hdparm -B cannot reach it, but hdparm -J
  # can: it is a dedicated flag for exactly this drive family. hdparm's own man
  # page describes the default 8 second timer as "a very poor choice for use with
  # Linux" that causes "hundreds of thousands of head load/unload cycles" against
  # a mechanism rated for 300,000 to 1,000,000, plus "the performance impact of
  # the drive often having to wake-up before doing routine I/O".
  #
  # Do NOT use idle3-tools. It dates from the IDE era and drives its ioctl
  # through HDIO_DRIVE_CMD, which libata rejects on a modern SATA stack:
  #   HDIO_DRIVE_CMD(identify) failed: Invalid argument
  #
  # -J is WD specific. Never point it at the IronWolf.
  echo
  echo "WorkDrive is a WD80EZAZ, so it parks its heads on WD's idle3 firmware"
  echo "timer. Read it, then disable it. This is a one time change:"
  echo "  sudo hdparm -J $wd      # read"
  echo "  sudo hdparm -J 0 $wd    # disable"
  echo
  echo "Then FULLY POWER OFF, not reboot, for the firmware to accept it."
  echo "It is written to the drive, so unlike fstab it survives a reinstall."
  echo "hdparm upstream prefers WD's own WDIDLE3.EXE if that is an option."
  echo
  echo "Confirm parking is happening at all:"
  echo "  sudo smartctl -A $wd | grep -i load_cycle"
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

firewall_tailnet_only() {
  log "firewall: services on the tailnet only"
  # Forgejo, Atlantis and nginx all bind every interface, so today anything on
  # the WiFi reaches them:
  #
  #   http://192.168.1.200:4141  -> atlantis's UI, no TLS, no auth
  #   http://192.168.1.200:3000  -> forgejo's login page
  #
  # That was verified, not assumed. Both answered 200 from the LAN address.
  #
  # They are NOT reachable from the internet: the home lab names resolve to
  # 100.68.26.36, a CGNAT address out of 100.64.0.0/10 that nothing on the
  # public internet can route to. The exposure is the LAN, and only the LAN.
  #
  # WHY DENY BY DEFAULT RATHER THAN DENY THE PORTS
  #
  # This box has two LAN interfaces, wlp6s0 and enp7s0, and the static IP is
  # meant to follow whichever is in use. Naming interfaces to block is
  # whack-a-mole: the rule is only correct until a cable is plugged in. Deny
  # everything inbound, allow the tailnet, and the posture holds no matter which
  # NIC is live or which service someone binds next.
  #
  # Atlantis's own atlantis.yaml already assumes this: "There is no approval
  # requirement, since Forgejo blocks approving your own PR." That is only true
  # if strangers cannot reach it in the first place.
  #
  # WHAT THIS WILL BREAK, ON PURPOSE
  #
  # Anything inbound over the LAN. Most notably Syncthing, which currently talks
  # to the MacBook over a link-local address on wlp6s0. It will fall back to the
  # tailnet address pinned in home/syncthing.nix, which is why that was set up
  # first. If you later want a LAN service reachable, add one explicit rule
  # rather than turning this off.
  if ! command -v ufw >/dev/null 2>&1; then
    pkg_install ufw
  fi
  cat <<'EOF'
These change the firewall, so they are yours to run, not the script's. Read them
first. If you are on ssh over the LAN, keep the ssh rules or you lock yourself
out.

1. The posture:

  sudo ufw default deny incoming
  sudo ufw default allow outgoing

  # The tailnet is just your own devices. Trust the interface, not ports, so a
  # new service is covered without touching the firewall again.
  sudo ufw allow in on tailscale0

  # Tailscale's own NAT traversal. Without this it falls back to relays, which
  # are disabled here, and may not connect at all when you are away.
  sudo ufw allow 41641/udp

  # OPTIONAL. Only if you ssh to this box from the LAN rather than the tailnet.
  sudo ufw allow in on wlp6s0 to any port 22 proto tcp
  sudo ufw allow in on enp7s0 to any port 22 proto tcp

  sudo ufw enable

2. Then DELETE the blanket rules, which is the part that actually matters.
   "default deny incoming" does nothing while an ALLOW ... Anywhere rule sits
   above it, and these are why http://192.168.1.200:3000 answers from a phone
   on the WiFi. The tailscale0 rule already covers every one of these services
   for the devices that should reach them, so per-port rules are pure exposure:

  sudo ufw delete allow 3000/tcp    # forgejo
  sudo ufw delete allow 4141/tcp    # atlantis
  sudo ufw delete allow 222/tcp     # forgejo ssh
  sudo ufw delete allow 22000/tcp   # syncthing data
  sudo ufw delete allow 22000/udp
  sudo ufw delete allow 21027/udp   # syncthing local discovery
  sudo ufw delete allow 22/tcp      # safe: the per-interface ssh rules remain

  sudo ufw status verbose

3. Verify FROM ANOTHER DEVICE. A phone on the WiFi with tailscale off is the
   whole test.

   Do NOT test by curling this box's own LAN address from this box. Linux routes
   traffic to a local address over loopback:

     $ ip route get 192.168.1.200
     local 192.168.1.200 dev lo ...

   ufw allows loopback unconditionally and the wlp6s0 rules are never consulted,
   so it answers 200 whether the firewall blocks the LAN or not. It proves
   nothing and reads like a failure.

   On the phone, WiFi on, tailscale off:

     http://192.168.1.200:4141   must NOT load     (atlantis)
     http://192.168.1.200:3000   must NOT load     (forgejo)

   On the phone, tailscale ON:

     https://forgejo.home.samuelstidham.me   must load, no cert warning

4. Then check syncthing, because deleting 22000 and 21027 removes its LAN path
   on purpose. It should fall back to the tailnet address pinned in
   home/syncthing.nix. completion 100 is the proof, not "it looks connected":

  API=$(grep -oPm1 '(?<=<apikey>)[^<]+' ~/.local/state/syncthing/config.xml)
  MAC=4IM7O6G-XZONB7G-UUJSTYX-JR7CTR6-QQFE3HD-YTMK6IL-J66BG26-MUOMGQR
  curl -s -H "X-API-Key: $API" \
    "http://127.0.0.1:8384/rest/db/completion?folder=snhu-coursework&device=$MAC"
EOF
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

calibre() {
  log "Calibre"
  # Calibre's own binary installer, which upstream considers the supported path:
  # "Please do not use your distribution provided calibre package, as those are
  # often buggy/outdated." The binary install bundles private copies of every
  # dependency, which is exactly why the distro and Nix builds lag.
  #
  # It is deliberately not a Flatpak. The Flatpak is sandboxed and cannot see the
  # library on /media/samuelstidham/StoragePrime without an explicit
  # --filesystem grant, so it would start up unable to find the books.
  #
  # It is deliberately not in Nix either. Calibre updates itself, and pinning it
  # in the flake would fight that, the same reasoning as Claude Code and the AWS
  # CLI. It installs to /opt/calibre and symlinks into /usr/bin.
  #
  # The library itself lives on StoragePrime and is set in
  # ~/.config/calibre/global.py.json as library_path. Keep that in step with
  # CALIBRE_LIBRARY in scripts/backup.sh.
  if command -v calibre >/dev/null 2>&1; then
    echo "calibre already present: $(calibre --version 2>/dev/null | head -1)"
    echo "Re-running the installer upgrades it in place."
  fi

  # The binary build bundles its own Python and Qt, but NOT the X11 libraries
  # that Qt dlopens at startup. Without this it dies immediately with:
  #   You are missing the system library libxcb-cursor.so.0
  #
  # This cannot come from Nix. calibre lives at /opt/calibre and is not a Nix
  # build, so it links against the system loader and never sees the Nix profile.
  # It has to be a system package, which is why it is here and not in a module.
  #
  # The name differs per distro. Debian ships libxcb-cursor0, Fedora ships the
  # same shared object inside xcb-util-cursor.
  case "$FAMILY" in
    debian) pkg_install libxcb-cursor0 ;;
    fedora)
      if [ "$ATOMIC" = 1 ]; then
        # A Fedora Atomic desktop image almost certainly already has it, and
        # layering is a last resort on an immutable base. Only reach for it if
        # calibre actually complains.
        echo "Atomic base: xcb-util-cursor should already be in the image."
        echo "If calibre reports the missing library, layer it and reboot:"
        echo "  sudo rpm-ostree install xcb-util-cursor"
      else
        pkg_install xcb-util-cursor
      fi
      ;;
    *) echo "Unknown family, install libxcb-cursor.so.0 yourself if calibre fails." >&2 ;;
  esac

  sudo -v && wget -nv -O- https://download.calibre-ebook.com/linux-installer.sh | sudo sh /dev/stdin
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
  mount_drives
  drives_stay_awake
  btrfs_scrub_sudo
  tailscale_net
  firewall_tailnet_only
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
  calibre
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
