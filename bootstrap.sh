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
#   debian  Ubuntu, Linux Mint, Pop!_OS through apt. Base Debian is dropped, it
#           has no VirtualBox in its repos. See the tombstone in detect_os.
#   fedora  Fedora and Nobara through dnf
#   suse    openSUSE Tumbleweed and Leap through zypper
#   atomic  Bazzite, Silverblue, Bluefin, Aurora through rpm-ostree and Flatpak
#
# RHEL, CentOS, Rocky and Alma are deliberately NOT supported. Red Hat removed
# btrfs in RHEL 8, and this repo's storage design is btrfs end to end, so
# `btrfs-progs` in the system layer has nowhere to come from. detect_os used to
# claim those four IDs as FAMILY=fedora and had no working body for any of them.
# Claiming a distro you cannot serve is worse than refusing it, so they now fall
# through to "Unknown family" and abort. See the tombstone in detect_os.
#
# The non-Nix software and the reason for each is not codified in a separate doc.
# .agents/outside-nix.md was cited here but never written. This script plus the
# flake are the record, and together they make the system reproducible.
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

FLAKE_DIR="${FLAKE_DIR:-$HOME/Code/samuel-stidham/nix-config}"
# Arch from uname -m, not hardcoded. The flake declares x86_64-linux (and darwin),
# so on x86_64 this resolves to the real config. An aarch64-linux box would ask for
# samuelstidham@aarch64-linux, not declared yet, and home-manager fails with a
# clear "no such configuration" rather than this silently targeting the wrong arch.
# The -linux suffix stays literal: bootstrap.sh drives apt/dnf/zypper and is not run
# on darwin.
HM_TARGET="samuelstidham@$(uname -m)-linux"

# The labelled-drive resolver, shared with the scripts and with the store.
# Defines drive_mount and drive_fstab_target. The whole argument, including why
# the drives are pinned under /mnt rather than under Ubuntu's /media/$USER, is in
# the header of that file. Read it before touching any drive path.
#
# Relative to THIS file, not to FLAKE_DIR. FLAKE_DIR is a default that can simply
# be wrong, and this repo has been moved before, see the tombstone in
# home/btrfs-scrub.nix. bootstrap.sh always knows where bootstrap.sh is.
#
# Sourced, not run as a command. all() at the bottom calls install_nix and then
# mount_drives in ONE shell, and install_nix itself admits the Nix profile is not
# on PATH until you open a new shell. main() also lets you run
# `./bootstrap.sh mount_drives` on a machine where Nix was never installed. So
# nothing here can depend on the store, and the resolver has to arrive as text.
# shellcheck source=scripts/drive-mount.sh
. "$(dirname "${BASH_SOURCE[0]}")/scripts/drive-mount.sh"

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
# VERSION_ID as os-release reported it, or empty when the key is absent. Captured
# HERE so no caller has to source /etc/os-release again. Debian testing and sid
# ship NO VERSION_ID key at all, and line 27 sets `set -u`, which the command
# substitution subshell inherits. _system_debian used to expand it inline and died
# with `VERSION_ID: unbound variable` on those releases. The message named
# VERSION_ID and not the real problem, so it read as a bug in this script rather
# than an unsupported distro. One `${VERSION_ID:-}` in one place fixes every
# caller.
OS_VERSION_ID=""

detect_os() {
  # OS_RELEASE_FILE and OSTREE_MARKER are test seams. Both default to the real
  # paths, so runtime behavior is byte-for-byte unchanged. tests/detect.sh points
  # them at fixture files to drive this function across every distro with no root
  # and no virtual machine. A shell rc must never assert a path a test cannot
  # redirect, and detection is the one function the whole script hinges on.
  local os_release="${OS_RELEASE_FILE:-/etc/os-release}"
  if [ ! -r "$os_release" ]; then
    echo "No $os_release. Cannot detect the distro." >&2
    return 1
  fi
  # Clear any inherited ID/ID_LIKE/VERSION_ID before sourcing. Sourcing os-release
  # only SETS the keys the file contains, it never clears one it omits, so an
  # exported ID_LIKE=ubuntu in the caller's environment would survive and forge the
  # family on a base-Debian box. The ${VAR:-} guards below protect against unset,
  # not against inherited, so they cannot catch this. Measured: `ID_LIKE=ubuntu
  # ./bootstrap.sh detect` returned FAMILY=debian on a base-Debian fixture until
  # this unset was added. detect_os is the one function the whole script hinges on,
  # so it reads the file and nothing else.
  unset ID ID_LIKE VERSION_ID
  # shellcheck disable=SC1091
  . "$os_release"
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_VERSION_ID="${VERSION_ID:-}"

  # TOMBSTONE: rhel, centos, rocky and almalinux used to be claimed here as
  # FAMILY="fedora". They are gone on purpose. RHEL 8 dropped btrfs, this repo is
  # btrfs end to end, and no body in this file ever handled them. They are not
  # coming back, so do not "restore" them.
  #
  # DROPPING THEM TAKES THREE EDITS, NOT ONE, and this is the part that bites.
  # Deleting the four IDs from the fedora arm is COSMETIC on its own. Rocky and
  # Alma ship ID_LIKE="rhel centos fedora" and RHEL 9 itself ships ID_LIKE="fedora",
  # so all three fall straight back into the fedora family through the ID_LIKE
  # fallback below. Removing the `*rhel*` glob from that fallback is ALSO not
  # enough, for the same reason: the `*fedora*` glob still catches every one of
  # them, because they all name fedora in ID_LIKE.
  #
  # So the deny arm below is load bearing and must stay AHEAD of the fallback.
  # I did not reason this out, I measured it. A harness driving this function with
  # real os-release values reported `rocky 9 rc=0 FAMILY=fedora PKG=dnf` after the
  # first two edits, which is precisely the "claims support it does not have"
  # failure this was meant to delete.
  case "$OS_ID" in
    # BASE DEBIAN AND RASPBIAN ARE DROPPED. Debian removed VirtualBox from its
    # archive over Oracle's security-patch policy, VERIFIED in a debian:trixie
    # container where `apt-cache search virtualbox` lists no virtualbox package. A
    # base-Debian box cannot get it from its own repos, only from Oracle by hand.
    # Sam's apt targets are Ubuntu, Mint and Pop, all Ubuntu-derived with multiverse,
    # where virtualbox and steam both resolve. So bare `debian` and `raspbian` are
    # gone, and the `*debian*` ID_LIKE fallback with them: a non-Ubuntu apt distro
    # falls to Unknown rather than a half-working install that aborts on virtualbox.
    #
    # linuxmint is NOT in this ID arm on purpose. LMDE (Linux Mint Debian Edition)
    # and the regular Ubuntu-based Mint BOTH ship ID=linuxmint, so the ID alone
    # cannot tell them apart. ID_LIKE splits them, VERIFIED off real os-release
    # files through browse: Ubuntu-based Mint 21 and 22 carry ID_LIKE="ubuntu
    # debian", while LMDE 6 (faye) and 7 (gigi) carry ID_LIKE=debian with no
    # ubuntu. So linuxmint falls through to the `*ubuntu*` fallback below, which
    # claims Ubuntu-based Mint and drops LMDE to Unknown, exactly like base Debian
    # and for the same VirtualBox reason.
    ubuntu|pop|elementary|zorin|neon) FAMILY="debian" ;;
    # silverblue and kinoite are NOT tokens here: both ship ID=fedora with a
    # VARIANT_ID, so they match the `fedora` token already and a bare
    # `silverblue|kinoite` arm was dead. bazzite, nobara, bluefin and aurora do
    # ship their own ID, so they stay. The atomic promotion happens below via the
    # ostree marker, not the ID.
    fedora|nobara|bazzite|bluefin|aurora) FAMILY="fedora" ;;
    # Tumbleweed is ID="opensuse-tumbleweed", Leap 15 and 16 are
    # ID="opensuse-leap", SLES is ID="sles". Read off captured os-release files,
    # not recalled. SLES 12 carries NO ID_LIKE, so it has to match by ID here or
    # it matches nothing at all.
    opensuse-tumbleweed|opensuse-leap|opensuse|sles|sled) FAMILY="suse" ;;
    # The deny arm. Refusing loudly beats claiming a distro with no btrfs.
    rhel|centos|rocky|almalinux|ol|scientific) FAMILY="unknown" ;;
    *)
      case " $OS_LIKE " in
        *ubuntu*) FAMILY="debian" ;;   # *ubuntu* only, base Debian is dropped above
        # BEFORE *fedora*, on purpose. An unknown RHEL rebuild names both rhel and
        # fedora in ID_LIKE, so whichever glob is tested first wins. This one has
        # to be it, or the rebuild gets claimed as fedora.
        *rhel*|*centos*)   FAMILY="unknown" ;;
        *fedora*)          FAMILY="fedora" ;;
        # Tumbleweed is ID_LIKE="opensuse suse", Leap is ID_LIKE="suse opensuse".
        # `*suse*` alone catches both, and catches "opensuse" too. Spelling out
        # *opensuse* as well is dead code, which shellcheck flags as SC2222.
        *suse*) FAMILY="suse" ;;
        *)                 FAMILY="unknown" ;;
      esac
      ;;
  esac

  # An atomic base has an immutable, read-only /usr. Two signals detect it. The
  # ostree marker is definitive for the ostree images this repo targets (Bazzite,
  # Silverblue), and OSTREE_MARKER is the test seam described at the top.
  if [ -f "${OSTREE_MARKER:-/run/ostree-booted}" ]; then
    ATOMIC=1
  fi
  # But atomicity is not only ostree. openSUSE MicroOS is atomic via btrfs
  # snapshots and transactional-update, ships NO /run/ostree-booted, and still
  # mounts /usr read-only, so the marker alone would call it mutable and every /usr
  # write downstream would fail on it. So also ask the real question: is the mount
  # backing /usr read-only. NOT `[ ! -w /usr ]`, which tests the CURRENT user's
  # permission and is true for every unprivileged user on every distro, atomic or
  # not. findmnt reports the effective mount options, where a `ro` token means even
  # root cannot write. Captured then case-matched, never piped into grep, to dodge
  # the SIGPIPE-under-pipefail trap. This only flags a read-only /usr, it does not
  # make MicroOS fully supported: MicroOS still needs transactional-update rather
  # than zypper, a separate gap this repo does not fill, MicroOS not being a target.
  local usr_opts
  usr_opts="$(findmnt -rno OPTIONS --target /usr 2>/dev/null)" || usr_opts=""
  case ",$usr_opts," in
    *,ro,*) ATOMIC=1 ;;
  esac

  if [ "$FAMILY" = "debian" ]; then
    PKG="apt"
  elif [ "$FAMILY" = "fedora" ] && [ "$ATOMIC" = 1 ]; then
    PKG="rpm-ostree"
  elif [ "$FAMILY" = "fedora" ]; then
    PKG="dnf"
  elif [ "$FAMILY" = "suse" ]; then
    PKG="zypper"
  fi

  # FAIL FAST, and this return is the whole point. Before it, an unsupported
  # distro sailed through: detect_os returned 0 with FAMILY=unknown, every
  # family-gated section hit its "skipping" arm and returned 0, and main printed
  # "Done. Reboot if a driver or a layered package changed." The operator saw a
  # clean run on a machine where nothing had been installed. openSUSE did exactly
  # this, because no arm above used to match it.
  #
  # Returning 1 lets `set -e` abort main before any section runs. The obvious
  # alternative, softening pkg_install to return 0 on an unknown manager, is
  # backwards: it converts every install site into a silent no-op, which is the
  # failure this is deleting.
  if [ "$FAMILY" = "unknown" ]; then
    echo "Unknown family: ID=${OS_ID:-none} ID_LIKE=${OS_LIKE:-none}" >&2
    echo "Supported: debian, fedora (incl. atomic), suse. RHEL-likes are not." >&2
    return 1
  fi
}

detect() {
  # `|| true`, and it is load bearing. detect_os returns 1 on an unsupported
  # distro, and this call is a non-final command under `set -e`, so a bare
  # `detect_os` would kill the shell before either printf ran. The one command
  # whose entire job is to tell you what you are running would print NOTHING on
  # exactly the distro you are trying to diagnose. A diagnostic must never abort.
  detect_os || true
  printf 'ID=%s ID_LIKE=%s\n' "${OS_ID:-none}" "${OS_LIKE:-none}"
  printf 'FAMILY=%s PKG=%s ATOMIC=%s\n' "$FAMILY" "$PKG" "$ATOMIC"
}

# --------------------------------------------------------------------------
# Package helpers. Every section calls these instead of a raw package manager,
# so the per distro branching lives in one place.
#
# THE CONTRACT, because other sections depend on it. pkg_install and pkg_refresh
# return 1 when PKG is unknown, and that is correct, not a bug. Every caller is
# shaped `if ! command -v x; then pkg_install x; fi`, where the call is the last
# command of the `then` block, so nothing consumes its status and `set -e` kills
# the script. That is the DESIRED behaviour. The fix for FAMILY=unknown belongs in
# detect_os, which now refuses to return at all on an unsupported distro, so these
# `*)` arms should be unreachable. They stay as the backstop for a caller that
# somehow runs without the probe.
# --------------------------------------------------------------------------
pkg_refresh() {
  case "$PKG" in
    apt)         sudo apt update ;;
    dnf)         sudo dnf makecache ;;
    rpm-ostree)  sudo rpm-ostree refresh-md ;;
    zypper)      sudo zypper --non-interactive refresh ;;
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
    zypper) sudo zypper --non-interactive install --auto-agree-with-licenses "$@" ;;
    *) echo "pkg_install: no package manager for FAMILY=$FAMILY" >&2; return 1 ;;
  esac
}

# Print the first candidate name apt can actually install, or return 1. This is
# the probe that replaces a per-release name table in _system_debian. It answers
# "what is this package called on the machine I am standing on", which is the only
# question that matters, and it does it without a list of releases to maintain.
#
# apt-cache policy, NOT apt-cache show. `apt-cache show libfuse2` on Ubuntu 24.04
# prints nothing at all and EXITS 0, because libfuse2 there is a pure virtual
# package provided by libfuse2t64. A probe built on `show` picks the virtual name
# and looks like it worked. Verified on this box: `apt-cache show libfuse2` gives
# exit=0 with empty output, while `apt-cache policy libfuse2` gives
# `Candidate: (none)`. So the real signal is a Candidate that is present and is
# not the literal string "(none)". A missing package prints no Candidate line.
_apt_pick() {
  local cand ver
  for cand in "$@"; do
    ver="$(apt-cache policy "$cand" 2>/dev/null | awk '/^  Candidate:/{print $2; exit}')"
    if [ -n "$ver" ] && [ "$ver" != "(none)" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# The fedora and suse peers of _apt_pick, so name resolution is symmetric across
# families instead of debian probing the archive while the others hardcode. Same
# contract: print the first candidate that resolves, or return 1. Most fedora and
# suse names in this repo are single-candidate, so these act mainly as a pre-flight
# existence check that turns "one absent package aborts the whole transaction with
# a cryptic message" into a named, per-package failure, the parity _apt_pick gives
# debian. UNVERIFIED on fedora and suse, no such machine here: the query verbs are
# read off dnf5 and zypper docs, not run.
#
# `dnf list <name>` exits 0 when the name is a known package, installed or in an
# enabled repo, and nonzero otherwise. --quiet suppresses the listing.
_dnf_pick() {
  local cand
  for cand in "$@"; do
    if dnf list --quiet "$cand" >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# `zypper --quiet search --match-exact <name>` exits 0 on an exact name match and
# 104 when nothing matches, so the exit status is the signal.
_zypper_pick() {
  local cand
  for cand in "$@"; do
    if zypper --quiet search --match-exact "$cand" >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

flatpak_install() {
  # NOTHING used to install flatpak. This function assumed the binary was already
  # there, and on Bazzite and Fedora Workstation it is, because the image ships
  # it. On a fresh Ubuntu or openSUSE it is not, and the remote-add below died
  # with command-not-found eighteen sections into `all`, after twenty minutes of
  # work. A probe answers this on any distro without a FAMILY branch, and it
  # correctly does nothing on an atomic base where flatpak is already present.
  # `flatpak` is a real package name on debian, fedora and suse, each checked
  # against that distro's own package index.
  if ! command -v flatpak >/dev/null 2>&1; then
    pkg_install flatpak
  fi
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
  # also handles the /nix mount correctly on atomic distros like Bazzite. curl is
  # required and not guaranteed on a minimal install, so probe it rather than let
  # the pipe die with a cryptic "command not found | sh".
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to install Nix and is not on PATH. Install it first:" >&2
    echo "  apt/dnf/zypper install curl" >&2
    return 1
  fi
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
  #
  # SKIPPED ON OSTREE, and this gate is load bearing. On an atomic base like
  # Bazzite /usr is mounted read-only, and /usr/bin is NOT one of the toplevels
  # ostree remaps into the writable /var. So this ln failed with
  #   ln: cannot create symbolic link '/usr/bin/fish': Read-only file system
  # and returned 1. That was fatal, not cosmetic. all() runs fish_login_shell as
  # step three, under `set -euo pipefail`, so a non-zero return here aborted the
  # WHOLE run and Bazzite ended with Nix and home-manager and nothing after. The
  # header above claims this section is OS agnostic, and this one line was not.
  # The obvious fix, moving the link to /usr/local/bin (which ostree DOES remap to
  # /var/usrlocal), does not work: root's sudo secure_path is
  # /usr/sbin:/usr/bin:/sbin:/bin only on this box, see home/filesystems.nix, so a
  # link there is not on root's PATH anyway. The symlink exists to satisfy a
  # #!/usr/bin/fish shebang, and no script in this repo carries one, so skipping it
  # on atomic costs nothing that is present. Unverified on Bazzite, no such machine
  # available.
  if [ "$ATOMIC" = 1 ]; then
    echo "Atomic base: /usr is read-only, skipping the /usr/bin/fish symlink."
    echo "No repo script uses a #!/usr/bin/fish shebang, so nothing needs it."
  else
    sudo ln -sf "$nix_fish" /usr/bin/fish
  fi
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
  # MULTIVERSE IS UBUNTU-ONLY. This used to be an unconditional
  # `sudo add-apt-repository -y multiverse`. Debian's components are main,
  # contrib, non-free and non-free-firmware, and there is no multiverse anywhere
  # in that list. Two failures stacked. add-apt-repository lives in
  # software-properties-common and is not guaranteed on a minimal Debian, so the
  # call could be command-not-found. If it WAS present it wrote a component whose
  # Release files never resolve, and the pkg_refresh on the next line then failed
  # `apt update` under `set -e`. Gate on the ID, the way system_logs already does.
  if [ "$OS_ID" = "ubuntu" ] || case " $OS_LIKE " in *ubuntu*) true ;; *) false ;; esac; then
    sudo add-apt-repository -y multiverse
  fi
  pkg_refresh

  # Kernel headers for DKMS, so virtualbox can build modules. TWO packages, on
  # purpose, and the pair is the point.
  #
  # linux-headers-$(uname -r) is an exact match for the kernel booted right now,
  # so dkms can build TODAY. That name exists on every apt distro because it is
  # generated per kernel build.
  #
  # A tracking metapackage then pulls fresh headers when the kernel updates,
  # which the exact name cannot do. Which metapackage is the per-distro part, so
  # probe rather than derive.
  #
  # WHAT WAS HERE BEFORE, and why it was wrong three ways:
  #   hwe_headers="linux-headers-generic-hwe-$(. /etc/os-release && echo "$VERSION_ID")"
  # HWE is an Ubuntu concept and the expansion is only correct when VERSION_ID
  # happens to look like an Ubuntu LTS number. Mint 22 reports VERSION_ID="22",
  # yielding linux-headers-generic-hwe-22. Debian 12 reports "12", yielding
  # hwe-12. Neither package exists. Debian testing and sid report no VERSION_ID
  # at all, and `set -u` then killed the subshell outright. Ubuntu 24.04 was the
  # only input that ever produced a real name.
  #
  # The hwe candidate stays FIRST because on Ubuntu proper it is genuinely the
  # right answer, and it is the only one that tracks an HWE kernel. It is guarded
  # by a shape test, so Mint's "22" never reaches it. Everything else falls to
  # linux-headers-generic (Ubuntu family, Mint, Pop, Zorin) and then to
  # linux-headers-amd64 (Debian). Verified on this box: the probe picks
  # linux-headers-generic-hwe-24.04 here, and picks linux-headers-generic when
  # fed Mint's hwe-22 shape.
  local hdr_candidates="linux-headers-generic linux-headers-amd64"
  case "$OS_VERSION_ID" in
    # An Ubuntu LTS VERSION_ID is NN.NN. Mint's "22" and Debian's "12" do not
    # match, which is exactly what keeps them out of the hwe name.
    [0-9][0-9].[0-9][0-9])
      hdr_candidates="linux-headers-generic-hwe-$OS_VERSION_ID $hdr_candidates"
      ;;
  esac
  local hdr_track
  # shellcheck disable=SC2086
  if ! hdr_track="$(_apt_pick $hdr_candidates)"; then
    echo "No kernel header metapackage found. Tried: $hdr_candidates" >&2
    return 1
  fi

  # STEAM. This used to be `steam-launcher`, and the reason that name is here at
  # all is worth recording. steam-launcher is VALVE's package name, from
  # repo.steampowered.com, NOT Ubuntu's. Verified on this box: `apt-cache madison
  # steam-launcher` lists only repo.steampowered.com, and this machine has Valve's
  # repo configured by hand. bootstrap.sh never adds that repo, so the old line
  # could not have worked on a fresh Ubuntu either, multiverse or not. It only
  # ever worked HERE, which is why nobody noticed. steam-installer is the name in
  # Ubuntu multiverse and in Debian, verified in both.
  local steam_pkg
  if ! steam_pkg="$(_apt_pick steam-installer steam-launcher)"; then
    echo "No steam package found. Tried: steam-installer steam-launcher" >&2
    return 1
  fi

  # LIBFUSE. libfuse2t64 is the 64-bit time_t name and exists on Ubuntu 24.04 and
  # Debian trixie forward. Bookworm and older Ubuntu call it libfuse2. This is a
  # per-RELEASE cutover, not a per-family one, so no FAMILY branch can express it
  # and the probe is the only honest answer. See _apt_pick for why this must not
  # use apt-cache show: libfuse2 is a virtual package on 24.04 and `show` exits 0
  # on it.
  local fuse_pkg
  if ! fuse_pkg="$(_apt_pick libfuse2t64 libfuse2)"; then
    echo "No libfuse2 compat package found." >&2
    return 1
  fi

  # Filesystem tools live HERE, not in a home-manager module. Every one of them
  # needs root, and sudo's secure_path excludes the nix profile, so a nix-installed
  # smartctl is on PATH and invisible to sudo at the same time. Root's tools come
  # from the distro. See home/filesystems.nix for the full reasoning.
  pkg_install \
    podman podman-compose podman-docker \
    openssh-server "linux-headers-$(uname -r)" "$hdr_track" \
    "$steam_pkg" \
    "$fuse_pkg" xdg-desktop-portal-gtk \
    btrfs-progs smartmontools hdparm exfatprogs

  # VirtualBox on its own, soft-failing, for the same reason steam is split out on
  # suse: one absent package must not take the whole transaction down. Every apt
  # target (Ubuntu, Mint, Pop) carries it in multiverse, so this normally succeeds.
  # It is separated as defense in depth for a non-Ubuntu apt derivative that slipped
  # past detect_os, where virtualbox has no candidate and would otherwise abort
  # podman, steam, the filesystem tools and everything else in one blast, the exact
  # single-absent-package failure the mit-scheme tombstone in _system_fedora records.
  if ! pkg_install virtualbox virtualbox-dkms; then
    echo "virtualbox did not resolve on this apt distro. It is in Ubuntu multiverse" >&2
    echo "(Ubuntu, Mint, Pop). Debian dropped it from its archive, so a base-Debian" >&2
    echo "derivative has none. Install it from Oracle's own apt repo by hand." >&2
  fi
  # TOMBSTONE: `mit-scheme` was the last entry here. Scheme is guile now, from
  # Nix, see home/languages.nix. guile is in nixpkgs and packaged on every distro,
  # so Scheme needs no system-layer package and no per-distro name at all.

  # TAURI AND GTK APP DEV LIBRARIES. pacer is a Tauri v2 app and does not compile
  # without these. Tauri resolves webkit2gtk 4.1 through pkg-config, so the -dev
  # packages are the requirement, not the runtime shared objects.
  #
  # These come from the DISTRO and not from Nix, which is a deliberate reversal of
  # how this repo usually treats a development library. Every one of them exists in
  # nixpkgs, verified: webkitgtk_4_1 is 2.52.4 there and ships webkit2gtk-4.1.pc.
  # The reason to refuse it is that this is not NixOS. A Nix webkitgtk links Nix's
  # Mesa while the running GPU driver is the distro's, and the app then comes up
  # with a blank window or loses its WebProcess at launch. The distro build links
  # the system loader and matches the driver already on the machine.
  #
  # There is a second reason, specific to this repo. home/libraries.nix appends the
  # Nix profile to C_INCLUDE_PATH and LIBRARY_PATH for EVERY compile on the machine.
  # SDL2 and boost are self-contained and safe there. A full GTK stack is not, and
  # putting glib, cairo, pango and gdk-pixbuf on the global include path would
  # shadow the system copies for unrelated builds.
  #
  # pkg-config is NOT in Tauri's published list and is still required, because the
  # Rust system-deps crate shells out to it. Checked on this box: `apt-cache depends
  # libwebkit2gtk-4.1-dev` lists no pkg-config among its direct dependencies, so
  # nothing in the list above is guaranteed to pull it.
  #
  # libatomic1 is here for pnpm rather than Tauri. See the pnpm function.
  #
  # Its OWN pkg_install, not the transaction above, for the reason the mit-scheme
  # tombstone in _system_fedora records at length. One absent name here must not
  # take podman, steam and every filesystem tool down with it.
  #
  # VERIFIED on this box, Ubuntu 24.04: every name below has a real candidate under
  # `apt-cache policy`, libwebkit2gtk-4.1-dev at 2.52.3-0ubuntu0.24.04.1 and
  # libayatana-appindicator3-dev at 0.5.93-1build3. Not verified as behaviour, no
  # Tauri build was run from these packages.
  if ! pkg_install \
    libwebkit2gtk-4.1-dev build-essential pkg-config \
    curl wget file \
    libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev \
    libatomic1; then
    echo "Tauri build dependencies did not install. A Tauri app will fail at" >&2
    echo "'cargo build' with a pkg-config error naming webkit2gtk-4.1." >&2
  fi
}

_system_fedora() {
  # RPM Fusion gives the nonfree bits, Steam, and the VirtualBox akmods.
  #
  # VERIFIED in a Fedora container: detect returns FAMILY=fedora PKG=dnf, every
  # base name resolves with `dnf install --assumeno`, and once these two RPM Fusion
  # release RPMs are installed, VirtualBox, akmod-VirtualBox and steam resolve too.
  # Not verified as behaviour: nothing was installed or booted, no Fedora machine
  # here, only a container that proves the names resolve against the real repos.
  # rpm -E %fedora expands to the release number on Fedora, but on another rpm
  # host that leaked past detect_os it yields the literal string "%fedora". Amazon
  # Linux 2023 ships ID_LIKE=fedora and would reach here that way. That literal
  # would build a bogus rpmfusion-free-release-%fedora.noarch.rpm URL and abort
  # cryptically. Fail closed on anything that is not a bare integer, a backstop
  # for the detection leak rather than a substitute for fixing it.
  local rel
  rel="$(rpm -E %fedora)"
  case "$rel" in
    ''|*[!0-9]*)
      echo "rpm -E %fedora did not expand to a release number (got '$rel')." >&2
      echo "This is not a Fedora host. Refusing to build an RPM Fusion URL." >&2
      return 1
      ;;
  esac
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
  #
  # TOMBSTONE: `mit-scheme` used to be the last entry in this list. It does not
  # exist on Fedora. Verified by search rather than by a 404: a search for
  # "scheme" on packages.fedoraproject.org returns chez-scheme, chibi-scheme and
  # the texlive scheme-* packages, and no mit-scheme. The bare URL /pkgs/mit-scheme/
  # also 404s, but that alone proves nothing, because that URL form only accepts
  # SOURCE names and 404s plenty of packages that do exist.
  #
  # WHY ITS ABSENCE WAS EXPENSIVE. This whole list is one pkg_install, so one
  # `dnf install -y` and one dnf TRANSACTION. `No match for argument: mit-scheme`
  # fails the entire command, so podman, openssh-server, kernel-devel, VirtualBox,
  # steam, the portal and every filesystem tool never installed either. One absent
  # package took out the complete Fedora system layer. Loud, but the message named
  # only mit-scheme, so the blast radius was invisible.
  #
  # Scheme comes from Nix now, and the choice is guile, not mit-scheme. guile is
  # in nixpkgs and packaged on every distro, so Scheme needs no system-layer entry
  # on any family. See home/languages.nix. Verified: `nix eval --raw
  # nixpkgs#guile.name` prints `guile-3.0.11`.
  # fuse2 compat lib, probed for parity with the debian arm. fuse-libs is the
  # Fedora name, VERIFIED in a container. The probe turns a future rename into a
  # named failure instead of a cryptic transaction abort.
  local fuse_pkg
  if ! fuse_pkg="$(_dnf_pick fuse-libs)"; then
    echo "No fuse2 compat lib (fuse-libs) resolves on this fedora." >&2
    return 1
  fi
  pkg_install \
    podman podman-compose podman-docker \
    openssh-server kernel-devel \
    VirtualBox akmod-VirtualBox \
    steam \
    "$fuse_pkg" xdg-desktop-portal-gtk \
    btrfs-progs smartmontools hdparm exfatprogs

  # RPM distros use systemd presets and do NOT start a daemon on package install,
  # unlike Debian's apt. openssh-server above is inert until enabled, so an
  # ssh-reachable debian box is unreachable on fedora, which is not the same
  # machine. Enable it, --now so it also starts this session.
  sudo systemctl enable --now sshd

  # TAURI AND GTK APP DEV LIBRARIES, the fedora peer of the block in _system_debian.
  # That function carries the full reasoning for why these come from the distro and
  # not from Nix. Read it there rather than duplicating it here.
  #
  # WGET DOES NOT EXIST ON FEDORA and that is the surprise in this list. Tauri's
  # published fedora command says `wget`, and it is wrong on current Fedora.
  # VERIFIED in a fedora:latest container: `dnf list wget` fails, while
  # `dnf provides /usr/bin/wget` answers with two shim packages, wget2-wget and
  # wget1-wget. So the binary is real and only the package name moved. Copying
  # upstream's list verbatim would have aborted the whole transaction on a name
  # that has not existed for releases.
  #
  # APPINDICATOR has two spellings here. Tauri publishes libappindicator-gtk3-devel
  # and Fedora also carries libayatana-appindicator-gtk3-devel, the maintained
  # ayatana fork that the debian and suse arms both use. VERIFIED in the same
  # container: BOTH resolve. The ayatana name leads so all three families land on
  # the same library, with upstream's name as the fallback.
  #
  # gcc, gcc-c++ and make are spelled out rather than `dnf group install
  # "c-development"`, which is what Tauri publishes for fedora. A group is a dnf
  # concept and pkg_install dispatches to rpm-ostree on Bazzite, where that group
  # form does not apply. Three explicit names work identically on both.
  local tauri_appind tauri_wget
  # The picks fall back to upstream's name rather than `return 1`. A pick can fail
  # for a reason that is not a missing package: _dnf_pick shells out to `dnf`, and
  # on an ostree host dnf may not be present at all. Aborting there would skip the
  # libraries over a probe failure instead of a real absence.
  if ! tauri_appind="$(_dnf_pick libayatana-appindicator-gtk3-devel libappindicator-gtk3-devel)"; then
    tauri_appind="libappindicator-gtk3-devel"
    echo "appindicator probe failed on this fedora. Falling back to $tauri_appind." >&2
  fi
  if ! tauri_wget="$(_dnf_pick wget2-wget wget1-wget wget)"; then
    tauri_wget="wget2-wget"
    echo "wget probe failed on this fedora. Falling back to $tauri_wget." >&2
  fi
  # VERIFIED in a fedora:latest container: this exact set builds a transaction with
  # `dnf install --assumeno`, 467 packages to install, before it aborts as asked.
  # Not verified as behaviour, nothing was installed and no Tauri build was run.
  if ! pkg_install \
    webkit2gtk4.1-devel gcc gcc-c++ make pkgconf-pkg-config \
    curl "$tauri_wget" file \
    libxdo-devel openssl-devel "$tauri_appind" librsvg2-devel \
    libatomic; then
    echo "Tauri build dependencies did not install. A Tauri app will fail at" >&2
    echo "'cargo build' with a pkg-config error naming webkit2gtk-4.1." >&2
  fi
}

_system_suse() {
  # NEW. openSUSE was never detected at all before this run, so this function had
  # no reason to exist and the whole family silently got nothing. See detect_os.
  #
  # Every package name below was VERIFIED to resolve in an openSUSE Tumbleweed
  # container with `zypper install --dry-run`, which is stronger than reading the
  # index. detect returns FAMILY=suse PKG=zypper there, and kernel-default-devel,
  # virtualbox-kmp-default, libfuse2, btrfsprogs and the rest all resolve. What is
  # STILL unverified is BEHAVIOUR: nothing was installed, booted, or run, so
  # "resolves" is not "produces the same machine". No openSUSE machine exists here
  # for that, only a container that proves the names are real and current.
  #
  # NAME DIFFERENCES from the fedora list, each verified in the index:
  #   btrfsprogs            not btrfs-progs. One hyphen, and it is real.
  #   libfuse2              not fuse-libs.
  #   virtualbox-kmp-*      not akmod-VirtualBox, and lowercase here.
  # Names that are the SAME and needed no change: podman, podman-docker,
  # openssh-server, xdg-desktop-portal-gtk, smartmontools, hdparm, exfatprogs,
  # flatpak, steam, virtualbox, virtualbox-qt.
  #
  # steam is in the non-oss repo, not oss. Tumbleweed enables non-oss by default,
  # CONFIRMED in a container where `zypper lr` shows repo-non-oss enabled and steam
  # resolves with no repo step. But Leap is DIFFERENT, also confirmed in a Leap
  # container: steam does not resolve there at all. So steam cannot sit in the main
  # transaction, or its Leap absence would abort the whole suse system layer. It
  # installs on its own below, soft-failing to Flatpak.
  pkg_refresh

  # KERNEL FLAVOR, probed rather than hardcoded. SUSE builds kernel-devel per
  # flavor and there is no unversioned kernel-devel at all. The index carries
  # kernel-default-devel, kernel-longterm-devel, kernel-vanilla-devel and
  # kernel-kvmsmall-devel. Copying fedora's `kernel-devel` would have failed
  # loudly on every openSUSE machine.
  #
  # uname -r answers which flavor is actually booted, e.g. 6.11.0-1-default, so
  # the suffix after the last hyphen IS the flavor. That is a probe, and it beats
  # hardcoding `default` for the same reason the HWE suffix in _system_debian was
  # wrong: a hardcoded flavor is a guess about a machine you are not standing on.
  local kflavor
  kflavor="$(uname -r)"
  kflavor="${kflavor##*-}"
  # VirtualBox ships a kmp per flavor too, and only for SOME flavors. The index
  # has virtualbox-kmp-default and virtualbox-kmp-longterm, but no vanilla or
  # kvmsmall build. So the kmp is separate from the rest, and its absence must not
  # take the whole transaction with it. See the mit-scheme tombstone in
  # _system_fedora for what one absent package costs in a single call.
  # fuse2 compat lib, probed for parity with the debian arm. libfuse2 is the name
  # on both Tumbleweed and Leap, VERIFIED in containers.
  local fuse_pkg
  if ! fuse_pkg="$(_zypper_pick libfuse2)"; then
    echo "No fuse2 compat lib (libfuse2) resolves on this openSUSE." >&2
    return 1
  fi
  pkg_install \
    podman podman-docker \
    openssh-server "kernel-${kflavor}-devel" \
    virtualbox virtualbox-qt \
    "$fuse_pkg" xdg-desktop-portal-gtk \
    btrfsprogs smartmontools hdparm exfatprogs

  # flatpak is NOT in the transaction above. Like debian and fedora, suse gets it
  # from flatpak_install's probe when flatpaks() runs, so it need not sit here where
  # a resolve failure could take the whole transaction down with it.

  # RPM distros do not start sshd on install (systemd presets), unlike Debian's
  # apt. Enable it so an ssh-reachable debian box is reachable here too. --now
  # starts it this session as well.
  sudo systemctl enable --now sshd

  # steam on its own, because it resolves on Tumbleweed but NOT on Leap, both
  # confirmed in containers. Left in the main transaction, its Leap absence would
  # abort every package above it. On Leap, Steam comes from Flatpak instead.
  if ! pkg_install steam; then
    echo "steam did not resolve on this openSUSE. It is in non-oss on Tumbleweed" >&2
    echo "but absent from Leap's default repos. Install it from Flatpak:" >&2
    echo "  flatpak install flathub com.valvesoftware.Steam" >&2
  fi

  if ! pkg_install "virtualbox-kmp-${kflavor}"; then
    echo "No virtualbox-kmp for kernel flavor '${kflavor}'." >&2
    echo "VirtualBox is installed but has no kernel module. Only the 'default'" >&2
    echo "and 'longterm' flavors ship one. Switch flavor or skip VirtualBox." >&2
  fi

  # PODMAN-COMPOSE, the one suse name that needs a probe. Confirmed in a Tumbleweed
  # container: `python3-podman-compose` does NOT resolve, not as a package name and
  # not as a capability. `zypper install python3-podman-compose` errors "not found
  # in package names", and the capability search finds no provider. The only real
  # packages are version-pinned, python313-podman-compose and python314-podman-compose
  # today, and the python version moves. Hardcoding one is the HWE-suffix mistake
  # again, a guess about a machine you are not on.
  #
  # So resolve the NEWEST flavor at run time. `zypper se` lists every
  # pythonNN-podman-compose, sort -V picks the highest, and only then does it
  # install. If none is found, say so rather than fail the run. Verified: on
  # Tumbleweed `zypper se podman-compose` lists python313- and python314-podman-compose.
  # grep -oE, not awk. A minimal openSUSE image ships neither gawk nor mawk, and
  # this must run on a fresh install. grep is always present. It pulls the package
  # name straight out of `zypper se`'s table, whatever the column spacing.
  # `|| true` inside the substitution. On Leap nothing matches, grep -oE exits 1,
  # and under set -euo pipefail the failed substitution would abort _system_suse
  # right here, dead-coding the "install it by hand" guidance below that exists
  # for exactly the no-match case. Same guard detect uses at the top of the file.
  local compose_pkg
  compose_pkg="$(zypper -q se podman-compose 2>/dev/null \
    | grep -oE 'python[0-9]+-podman-compose' | sort -V | tail -1 || true)"
  if [ -n "$compose_pkg" ]; then
    pkg_install "$compose_pkg" || echo "podman-compose ($compose_pkg) failed to install" >&2
  else
    echo "No pythonNN-podman-compose found on suse. Install podman-compose by hand:" >&2
    echo "  zypper se podman-compose   # then install the newest pythonNN- flavor" >&2
  fi

  # Scheme is guile from Nix now (home/languages.nix), not mit-scheme, so suse
  # installs no Scheme package. mit-scheme had no openSUSE package anyway, verified
  # absent from both the x86_64 and noarch oss indexes. guile is in nixpkgs, so one
  # Nix package closes the gap on every family and there is nothing to do here.

  # TAURI AND GTK APP DEV LIBRARIES, the suse peer of the block in _system_debian.
  # That function carries the full reasoning for taking these from the distro rather
  # than from Nix.
  #
  # THE WEBKIT DEVEL NAME IS INVERTED BETWEEN TUMBLEWEED AND LEAP. This is the one
  # genuinely surprising row in this whole change, and no FAMILY branch can express
  # it, because both releases are FAMILY=suse. VERIFIED in containers, both ways
  # round:
  #   Tumbleweed   webkitgtk3-devel   exists, webkit2gtk3-devel does NOT
  #   Leap         webkit2gtk3-devel  exists, webkitgtk3-devel  does NOT
  # On each release `zypper se --provides "pkgconfig(webkit2gtk-4.1)"` names the one
  # that is present, so both really are the Tauri 4.1 devel package under two names.
  # This is the libfuse2t64 situation again, a per-RELEASE cutover inside one family,
  # and the probe is the only honest answer.
  #
  # Tauri's published openSUSE command says webkit2gtk3-devel, which is correct on
  # Leap and simply absent on Tumbleweed. Following upstream verbatim would abort
  # the transaction on the release this machine family is most likely to run.
  #
  # TWO MORE DEPARTURES from Tauri's published suse list, both deliberate. It says
  # libappindicator3-1, which is a RUNTIME library and the old non-ayatana one, so
  # it cannot satisfy a build. libayatana-appindicator3-devel is the devel package
  # and matches what the debian and fedora arms install, VERIFIED present on both
  # Tumbleweed and Leap. Upstream also omits libxdo for suse entirely, though Tauri
  # v2 links it on Linux. xdotool-devel is the provider of pkgconfig(libxdo) here,
  # confirmed with `zypper se --provides`.
  local tauri_webkit
  if ! tauri_webkit="$(_zypper_pick webkitgtk3-devel webkit2gtk3-devel)"; then
    echo "No webkit2gtk 4.1 devel package resolves on this openSUSE." >&2
    echo "Tried webkitgtk3-devel (Tumbleweed) and webkit2gtk3-devel (Leap)." >&2
    echo "A Tauri app will not build until one of them is installed." >&2
    return 0
  fi
  # VERIFIED on Tumbleweed: this exact set resolves with `zypper install --dry-run`,
  # 1.13 GiB of packages, no unresolved name. Every individual name was also checked
  # on Leap with --match-exact. Not verified as behaviour, nothing was installed and
  # no Tauri build was run on either release.
  if ! pkg_install \
    "$tauri_webkit" gcc gcc-c++ make pkgconf-pkg-config \
    curl wget file \
    xdotool-devel libopenssl-devel libayatana-appindicator3-devel librsvg-devel \
    libatomic1; then
    echo "Tauri build dependencies did not install. A Tauri app will fail at" >&2
    echo "'cargo build' with a pkg-config error naming webkit2gtk-4.1." >&2
  fi
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

  # THIS FUNCTION USED TO ONLY ECHO, and that was the bug. It ASSERTED parity
  # instead of checking for it. The claims about Steam, podman and distrobox are
  # plausible for Bazzite. The claims it never made are the problem: smartmontools,
  # hdparm, exfatprogs, podman-compose and the podman-docker `docker` shim are all
  # in the debian and fedora lists and were simply absent from the atomic story,
  # present or not. The forgejo runner calls `docker`, and podman ships without
  # that shim unless podman-docker adds it, so this probes for the binary too.
  #
  # WHY THIS IS NOT COSMETIC. drives_stay_awake writes a udev rule whose RUN+=
  # hardcodes /usr/sbin/hdparm. If Bazzite has no hdparm, udev MATCHES the rule,
  # fails to execute it, and the drives keep parking. That is the btrfs_scrub_sudo
  # pattern exactly: a rule that validates and never fires. A comment asserting
  # hdparm is present cannot catch that. `command -v hdparm` can, and it is
  # distro agnostic, so it also holds if Bazzite's manifest changes under us.
  #
  # Report only, deliberately. Layering on an atomic base costs a reboot, so this
  # must not install anything behind the operator's back. It names what is missing
  # and the exact command to fix it. Which of these Bazzite actually ships is
  # unverified, no atomic machine available here, which is precisely why this
  # probes at runtime instead of hardcoding an answer.
  # The tool names are the BINARIES, not the packages, because a binary is what
  # can actually be probed. mkfs.exfat is the exfatprogs one, verified off that
  # package's own file list: exfatprogs ships dump.exfat, exfat2img, exfatlabel,
  # fsck.exfat, mkfs.exfat and tune.exfat. It does NOT ship a binary called
  # `exfatfsck`, which is the older exfat-utils name and is easy to reach for.
  #
  # _have checks the sbin directories explicitly, and does not trust PATH alone.
  # smartctl and hdparm both live in /usr/sbin, and sbin is not on a non-root
  # user's PATH on every distro. A bare `command -v smartctl` would then report a
  # tool as missing on a machine that has it, which is a false alarm in the one
  # function whose entire job is reporting accurately.
  _have() {
    command -v "$1" >/dev/null 2>&1 || [ -x "/usr/sbin/$1" ] || [ -x "/sbin/$1" ]
  }
  local tool missing=""
  for tool in smartctl hdparm mkfs.exfat podman-compose docker; do
    _have "$tool" || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    echo "MISSING on this atomic base:$missing" >&2
    echo "Those come from smartmontools, hdparm, exfatprogs, podman-compose, podman-docker." >&2
    echo "drives_stay_awake needs hdparm, and its udev rule fails SILENTLY" >&2
    echo "without it. To layer them: sudo rpm-ostree install <pkg>, then reboot." >&2
  else
    echo "Filesystem and compose tools all present, nothing to layer."
  fi
  # TAURI AND GTK APP DEV LIBRARIES, reported and never layered. The rest of this
  # function explains why: layering on an atomic base costs a reboot, so it names
  # what is missing rather than installing it. Tauri publishes a dedicated OSTree
  # command, and it is reproduced verbatim below so the operator can paste it.
  #
  # A LIBRARY IS PROBED BY ITS pkg-config MODULE, not by a binary. There is no
  # `webkit2gtk-4.1` executable to look for, and `rpm -q` would ask about a package
  # name rather than about what the build actually needs. pkg-config answers the
  # real question, which is whether `cargo build` can resolve the module. The five
  # module names were read off the packages themselves rather than recalled:
  # webkit2gtk-4.1.pc, libxdo.pc and ayatana-appindicator3-0.1.pc from the webkitgtk,
  # xdotool and libayatana-appindicator dev outputs, librsvg-2.0.pc and openssl.pc
  # from librsvg and openssl.
  #
  # pkg-config itself is checked FIRST and separately. Without it every module probe
  # below returns false, and the report would then blame five libraries when the
  # real answer is one missing tool. That is the kind of misleading output this
  # function exists to avoid.
  local tauri_missing=""
  if ! _have pkg-config; then
    tauri_missing=" pkg-config(and therefore every module below is unknown)"
  else
    local mod
    for mod in webkit2gtk-4.1 libxdo ayatana-appindicator3-0.1 librsvg-2.0 openssl; do
      pkg-config --exists "$mod" 2>/dev/null || tauri_missing="$tauri_missing $mod"
    done
  fi
  local btool
  for btool in gcc g++ make; do
    _have "$btool" || tauri_missing="$tauri_missing $btool"
  done
  if [ -n "$tauri_missing" ]; then
    echo "MISSING for Tauri builds on this atomic base:$tauri_missing" >&2
    echo "A Tauri app fails at 'cargo build' with a pkg-config error until these" >&2
    echo "are layered. Tauri's own OSTree command, then a reboot:" >&2
    echo "  sudo rpm-ostree install webkit2gtk4.1-devel openssl-devel curl wget \\" >&2
    echo "    file libappindicator-gtk3-devel librsvg2-devel libxdo-devel \\" >&2
    echo "    gcc gcc-c++ make libatomic" >&2
    echo "  sudo systemctl reboot" >&2
    echo "libatomic is not Tauri's, it is pnpm's. See the pnpm function." >&2
  else
    echo "Tauri build dependencies all present, nothing to layer."
  fi

  # _have was defined inside this function, and bash leaks such definitions to
  # global scope, so unset it to keep the namespace clean.
  unset -f _have
}

atomic_extras() {
  log "atomic layered extras"
  # TOMBSTONE. This used to be `pkg_install mit-scheme`, and it could never have
  # worked. An atomic base is Fedora, which has no mit-scheme package, so the one
  # section whose whole point was mit-scheme would fail on exactly the machine it
  # was meant to serve.
  #
  # Scheme is guile now, and it comes from Nix, which this same script installs and
  # which works on an atomic base through the Determinate installer's /nix mount.
  # So there is nothing to layer, and the answer is the same on every distro.
  # Verified: `nix eval --raw nixpkgs#guile.name` prints `guile-3.0.11`.
  #
  # Kept as a named section so `./bootstrap.sh atomic_extras` explains itself
  # rather than dying with "command not found".
  echo "Nothing to layer. Scheme is guile from Nix, installed by home-manager on"
  echo "every distro including this atomic base. No rpm-ostree layering needed."
}

system_layer() {
  log "system layer ($FAMILY)"
  case "$FAMILY" in
    debian) _system_debian ;;
    fedora) if [ "$ATOMIC" = 1 ]; then _system_atomic; else _system_fedora; fi ;;
    suse) _system_suse ;;
    # This arm used to be reachable, and reaching it was a disaster. It only
    # echoed, so it returned 0, so `all` carried on and printed "Done" on a
    # machine that got nothing. openSUSE hit this every time. detect_os now
    # refuses to return on an unknown family, so this should be unreachable.
    # `return 1` rather than a bare echo, so that if it ever IS reached, it fails
    # loudly instead of lying.
    *) echo "Unknown family '$FAMILY', refusing to guess a system layer." >&2; return 1 ;;
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
  # This section assumes system_layer already ran. `all` runs it first, so the
  # fedora arm has RPM Fusion enabled and the suse arm has zypper refreshed.
  # Running `./bootstrap.sh nvidia_driver` on its own on Fedora will fail to
  # resolve akmod-nvidia, because nothing enabled RPM Fusion yet. That is a
  # standalone-invocation trap, loud, not a same-machine bug.
  case "$FAMILY" in
    debian)
      # ubuntu-drivers ships in ubuntu-drivers-common, an UBUNTU package. Pure
      # Debian and Raspbian are in this family too and carry no such binary, so
      # the old unconditional `sudo ubuntu-drivers autoinstall` died there with
      # "ubuntu-drivers: command not found". Probe for the tool rather than
      # branch on the distro ID, which keeps Mint, Pop and the rest working.
      if command -v ubuntu-drivers >/dev/null 2>&1; then
        # Picked automatically for the installed GPU. This survives a release
        # upgrade better than a pinned version.
        sudo ubuntu-drivers autoinstall
      else
        # DEFENSIVE, and should now be unreachable. The debian family is Ubuntu,
        # Mint and Pop, all of which ship ubuntu-drivers-common, because base
        # Debian, Raspbian and LMDE are dropped at detect_os for lacking VirtualBox.
        # This stays as a loud fallback rather than a silent skip in case an
        # ubuntu-drivers-less apt box ever reaches here. nvidia-driver from Debian
        # non-free is the manual path, left as guidance since it needs the non-free
        # component and a reboot, and pushing a driver onto a working display blind
        # is worse than a named step.
        echo "No ubuntu-drivers here. The debian family should be Ubuntu, Mint or" >&2
        echo "Pop, which all ship it. If you see this, enable non-free and install:" >&2
        echo "  sudo apt-get install nvidia-driver   # Debian non-free" >&2
      fi
      ;;
    fedora)
      # akmod-nvidia from RPM Fusion, which was enabled in _system_fedora. The
      # cuda subpackage covers compute and the open kernel modules for Blackwell.
      # Both names confirmed off the RPM Fusion nonfree Fedora 42 mirror.
      pkg_install akmod-nvidia xorg-x11-drv-nvidia-cuda
      echo "Wait for the akmod to build before rebooting: modinfo -F version nvidia"
      ;;
    suse)
      # openSUSE ships NVIDIA from its own community repo, not oss, so oss alone
      # left FAMILY=suse falling through to the Unknown arm below. That printed
      # "Unknown family" and installed NOTHING on a supported distro with the
      # same 5090. SILENT parity gap, now filled.
      #
      # WHY install-new-recommends AND NOT A HARDCODED PACKAGE. The repo carries
      # both a G06 and a G07 driver generation, and the 5090 is Blackwell, which
      # needs G07. Hardcoding nvidia-video-G07 would rot the moment a card needs
      # G06, the same branch-not-probe mistake this repo keeps deleting. The repo
      # ships a `check` package whose job is to match the installed card, and
      # install-new-recommends lets it pick. That is a probe, not a branch.
      #
      # The repo path differs for Tumbleweed and Leap, so probe os-release for
      # the one booted. Leap uses the $releasever zypper variable, single-quoted
      # so zypper expands it and bash does not.
      #
      # VERIFIED off the repo index through browse: download.nvidia.com/opensuse
      # lists tumbleweed/ and leap/, and tumbleweed/x86_64/ carries the G06 and
      # G07 package families plus the `check` recommender. UNVERIFIED as
      # behaviour: the exact zypper incantation is the openSUSE wiki's, and the
      # wiki is behind a proof-of-work wall. No suse machine here to run it.
      # Branch on the already-parsed OS_ID, not a fresh grep of /etc/os-release.
      # detect_os runs before every section (see main), so OS_ID is set here, and
      # the raw re-read both bypassed the OS_RELEASE_FILE test seam and could never
      # be driven by tests/detect.sh. Tumbleweed is ID=opensuse-tumbleweed, Leap is
      # ID=opensuse-leap.
      local nvrepo
      if [ "$OS_ID" = opensuse-tumbleweed ]; then
        nvrepo="https://download.nvidia.com/opensuse/tumbleweed"
      else
        nvrepo='https://download.nvidia.com/opensuse/leap/$releasever'
      fi
      # Only add the repo if the NVIDIA alias is not already present. The old
      # `|| true` made addrepo idempotent but also swallowed real failures (bad URL,
      # network). `zypper lr NVIDIA` exits 0 when the alias exists, so this re-runs
      # cleanly and a genuine addrepo error now surfaces. Unverified on suse.
      if ! sudo zypper lr NVIDIA >/dev/null 2>&1; then
        sudo zypper --non-interactive addrepo --refresh "$nvrepo" NVIDIA
      fi
      sudo zypper --gpg-auto-import-keys --non-interactive refresh
      sudo zypper --non-interactive install-new-recommends --repo NVIDIA
      echo "Reboot after the kmp builds so the nvidia module loads."
      ;;
    *) echo "Unknown family, skipping NVIDIA." >&2; return 1 ;;
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
    fedora|suse)
      # Neither Fedora nor openSUSE packages the Oracle ext-pack, it is
      # proprietary, so fetch the pack matching the installed VirtualBox version.
      # --version prints 7.0.16r162802, trim the revision. _system_fedora and
      # _system_suse both install VirtualBox, so VBoxManage is present and this
      # section assumes system_layer ran first. suse used to fall to the Unknown
      # arm below, whose `return` also skipped the vboxusers step, so openSUSE
      # got neither the pack nor USB device access. SILENT, now fixed by sharing
      # the fedora path and reaching the usermod. Unverified on suse, no machine.
      # VBoxManage must be present, and its absence must be a message, not a silent
      # death. It comes from the VirtualBox package system_layer installs, so a full
      # run has it. A standalone invocation or a failed install would not, and then
      # `VBoxManage --version` exits 127. The old code piped that through sed under
      # pipefail with 2>/dev/null, so set -e aborted the section printing NOTHING.
      # Report and skip, so the rest of all() still runs.
      if ! command -v VBoxManage >/dev/null 2>&1; then
        echo "VBoxManage not found, skipping the extension pack. Install VirtualBox" >&2
        echo "first (it comes from system_layer), then re-run virtualbox_extras." >&2
        return
      fi
      local ver f td
      ver="$(VBoxManage --version 2>/dev/null | sed 's/r.*//')"
      f="Oracle_VM_VirtualBox_Extension_Pack-${ver}.vbox-extpack"
      # mktemp dir, not a predictable /tmp/$f. The file is fetched then handed to a
      # sudo install, and a predictable name in a world-writable dir is a symlink
      # swap risk on the privileged step. Cleaned on return.
      td="$(mktemp -d)"
      trap 'rm -rf "$td"' RETURN
      curl -fL -o "$td/$f" "https://download.virtualbox.org/virtualbox/${ver}/${f}"
      sudo VBoxManage extpack install --replace "$td/$f"
      ;;
    *) echo "Unknown family, skipping VirtualBox extras." >&2; return 1 ;;
  esac
  # Grant USB device access. A group change needs a fresh login to apply.
  sudo usermod -aG vboxusers "$USER"
  echo "Log out and back in so the vboxusers group applies, then USB devices appear."
}

# --------------------------------------------------------------------------
# Vendor GUI apps. Electron and Chromium apps that Nix does not own well.
# apt and dnf use each vendor's own repo. Atomic uses Flatpak, which matches
# the Flatpak-first house rule. That rule has no separate doc, it is stated in
# the header of home/apps.nix.
# --------------------------------------------------------------------------
_vendor_debian() {
  # Google Chrome. `--yes` on the dearmor is load bearing: without it a re-run
  # finds the keyring already there and gpg blocks on an overwrite prompt, or dies
  # with "cannot open '/dev/tty'" when there is no terminal. vendor_apps is the one
  # section that bricked on re-run in an otherwise idempotent script. fedora and
  # suse use `rpm --import`, which is already idempotent, so this is apt-only.
  wget -qO- https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
  # VS Code
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
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

_vendor_suse() {
  # suse had NO arm and fell through to "Unknown family, skipping", so Chrome and
  # VS Code never installed on openSUSE and the run still reported success. That is
  # the exact silent parity gap this job exists to kill. Both vendors ship one rpm
  # repo that zypper reads, so this mirrors _vendor_fedora with two differences.
  #
  # FIRST, zypper reads /etc/zypp/repos.d, not /etc/yum.repos.d, so the repo files
  # land there. SECOND, the keys are imported with `rpm --import` up front rather
  # than left to the repo's gpgkey line, because `zypper --non-interactive refresh`
  # DECLINES an untrusted gpg key instead of prompting, which would fail the
  # refresh and then the install. dnf auto-imports, so _vendor_fedora does not need
  # this. Unverified on suse, no such machine available.
  #
  # Google Chrome. Google publishes one rpm repo for every rpm distro, the same
  # baseurl and key _vendor_fedora already uses and the reviewer verified.
  sudo rpm --import https://dl.google.com/linux/linux_signing_key.pub
  sudo tee /etc/zypp/repos.d/google-chrome.repo >/dev/null <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
  # VS Code. Repo config taken verbatim from Microsoft's own openSUSE install page
  # (code.visualstudio.com/docs/setup/linux, read 2026-07-16), which writes exactly
  # this file to /etc/zypp/repos.d and then runs `zypper install code`.
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
  sudo tee /etc/zypp/repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  pkg_refresh
  pkg_install google-chrome-stable code
  echo "Add 1password, discord, signal, slack from their vendor repos."
}

vendor_apps() {
  log "vendor GUI apps ($FAMILY)"
  case "$FAMILY" in
    debian) _vendor_debian ;;
    fedora) if [ "$ATOMIC" = 1 ]; then _vendor_atomic; else _vendor_fedora; fi ;;
    suse) _vendor_suse ;;
    *) echo "Unknown family, skipping vendor apps." >&2; return 1 ;;
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
  # This function used to gate its whole body on "FAMILY != debian -> return".
  # That was a SILENT parity gap. The journald half is portable and it was being
  # skipped on fedora, suse and atomic, so those builds kept journald's default
  # retention, where SystemMaxUse is 10% of the filesystem and can sit near 4G,
  # instead of this 1G cap. The function printed "use journald only" and returned
  # 0, which reads as handled when nothing was applied. The obvious minimal fix,
  # widening the gate, does not work: the rsyslog half below is genuinely Debian
  # only and must stay gated. So the function is split. Journald runs everywhere.
  # rsyslog stays behind the debian gate.
  #
  # SYSTEM journald retention. Portable. Every supported family runs
  # systemd-journald, and /etc/systemd/journald.conf.d is writable even on an
  # ostree base, where only /usr is read only. Keep 1G of real history instead of
  # a 10M clamp, and stop forwarding the journal firehose into /var/log/syslog.
  # Comment out any old inline SystemMax* first so this drop-in is authoritative.
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

  # SYSTEM rsyslog text logs. Debian only. The logrotate file below names
  # /var/log/syslog, /var/log/mail.log and /usr/lib/rsyslog/rsyslog-rotate, which
  # are Debian policy paths. rsyslog is not installed by default on Fedora or
  # openSUSE, and where it is present it writes /var/log/messages, not
  # /var/log/syslog. So this half gates on debian, the pattern CLAUDE.md calls
  # the model. Unverified on fedora and suse, no such machine available.
  if [ "$FAMILY" != "debian" ]; then
    echo "Not a debian rsyslog layout. journald retention applied above, skipping logrotate."
    return
  fi
  # rotate daily, and also whenever a file crosses 10M, keeping 7. Worst case
  # ~70M per log. The stock config only rotated weekly, so a chatty log
  # (Docker's HTTP polling firehose) grew to ~760M/week.
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

  # Run logrotate hourly instead of daily, so the 10M cap is checked often enough
  # to hold between rotations even under a flood.
  sudo mkdir -p /etc/systemd/system/logrotate.timer.d
  sudo tee /etc/systemd/system/logrotate.timer.d/override.conf >/dev/null <<'EOF'
[Timer]
OnCalendar=
OnCalendar=hourly
EOF

  # daemon-reload picks up the timer override, then restart applies the new
  # schedule. The journald half above ran its own reload and restart, since it
  # runs on every family and this block does not.
  sudo systemctl daemon-reload
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
  dotnet new install MonoGame.Templates.CSharp || true
  dotnet tool install --global dotnet-mgcb || true
  dotnet tool install --global dotnet-mgcb-editor || true
  echo "Set MGFXC_WINE_PATH to the Nix wine in ~/fish for the shader compiler."
}

godot_tooling() {
  log "Godot tooling (GodotEnv + Chickensoft templates)"
  # Not Nix packages. Chickensoft ships only through NuGet: a global dotnet
  # tool (GodotEnv) plus two dotnet templates. None are in nixpkgs, so they
  # install through the Nix dotnet SDK, exactly as MonoGame does above.
  #
  # Godot itself is deliberately NOT a Nix package. GodotEnv is the version
  # manager. fish/env.fish already sets $GODOT to
  # ~/.config/godotenv/godot/bin/godot, the path GodotEnv installs a build into.
  # So the engine is whatever `godotenv godot install` put there, not a store
  # path. The wiring existed already. Installing GodotEnv was the missing half.
  #
  # Distro-agnostic by construction. The SDK is from Nix and every command here
  # hits NuGet, so it runs the same on debian, fedora, and suse. Only
  # ~/.dotnet/tools and ~/.config/godotenv are written, both under $HOME.
  #
  # `|| true` keeps a re-run green. Under set -euo pipefail a second run would
  # otherwise abort here. Both `dotnet tool install --global` and `dotnet new
  # install` exit non-zero when the tool or template already exists.
  dotnet tool install --global Chickensoft.GodotEnv || true
  dotnet new install Chickensoft.GodotGame || true
  dotnet new install Chickensoft.GodotPackage || true
  # LogicBlocks is intentionally not here. It is a per-project library added
  # with `dotnet add package Chickensoft.LogicBlocks` inside a game's .csproj,
  # not a machine tool. The Chickensoft.GodotGame template already references it
  # in every project it scaffolds, which is the correct layer for it.
  echo "Install a Godot build with: godotenv godot install <version>"
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
    # /etc is writable on an ostree base, and the mountpoint now lives under /mnt,
    # which symlinks to the writable /var/mnt there. So both the fstab entry and
    # the mkdir below land on writable storage. This echo used to say only that
    # /etc was writable, which reassured about the wrong half: the old
    # /media/samuelstidham path could not be created on the read-only ostree root
    # at all. See drive_fstab_target in scripts/drive-mount.sh for the argument.
    # Unverified on Bazzite, no such machine available.
    echo "Atomic base: /etc is writable and the mount lands under /mnt, fstab applies here."
  fi

  # lsblk, not blkid. blkid needs root to probe and returns an empty string for a
  # normal user, which would make this skip both drives while reporting success.
  # lsblk reads the same data unprivileged.
  # `|| ...=""` is load bearing. lsblk exits 32 when the label does not exist, and
  # a fresh box lacks both labels by definition. Under `set -euo pipefail` the
  # failed substitution would abort mount_drives right here, and all() calls it
  # bare, so the fourteen sections after it would silently never run. _add_mount's
  # "not found by label, skipping" branch below exists precisely to handle an empty
  # UUID, so keep the failure a value, not a death. Same guard as sp_mnt below.
  local sp_uuid wd_uuid
  sp_uuid="$(lsblk -no UUID /dev/disk/by-label/StoragePrime 2>/dev/null | head -1)" || sp_uuid=""
  wd_uuid="$(lsblk -no UUID /dev/disk/by-label/WorkDrive 2>/dev/null | head -1)" || wd_uuid=""

  local opts="compress=zstd:3,noatime,nofail,x-systemd.device-timeout=10"
  local changed=0

  _add_mount() {
    local uuid="$1" label="$2"
    if [ -z "$uuid" ]; then
      echo "  $label not found by label, skipping"
      return
    fi
    if grep -q "$uuid" /etc/fstab 2>/dev/null; then
      echo "  $label already in fstab"
      return
    fi
    # WHERE the fstab entry points. The two call sites used to pass a literal
    # /media/samuelstidham/LABEL, which is Ubuntu's udisks path with a username
    # baked in. On Bazzite's read-only ostree root `sudo mkdir -p /media/...`
    # returns "Read-only file system", the nofail option then skips the mount at
    # every boot with no word, and the two btrfs drives go unscrubbed and
    # unbacked-up. drive_fstab_target returns /mnt/LABEL on every family, and on
    # Bazzite /mnt symlinks to the writable /var/mnt. Declare-then-assign, never
    # local mnt="$(...)", because local's own rc=0 would mask a resolver failure
    # under set -e. Unverified on fedora and suse, no such machine available.
    local mnt
    mnt="$(drive_fstab_target "$label")"
    sudo mkdir -p "$mnt"
    printf 'UUID=%s  %s  btrfs  %s  0 0\n' "$uuid" "$mnt" "$opts" | sudo tee -a /etc/fstab >/dev/null
    echo "  added $label -> $mnt"
    changed=1
  }

  _add_mount "$sp_uuid" StoragePrime
  _add_mount "$wd_uuid" WorkDrive

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
  #
  # Chown only a drive that is actually mounted. The old line hardcoded the
  # /media/samuelstidham path, ran unconditionally, and wrapped 2>/dev/null || true
  # around it. That is three failures in one: the wrong path on a /mnt machine, a
  # chown of the empty mountpoint directory on the nvme when nothing mounted, and a
  # swallow that hid every real chown error. drive_mount reports where each drive
  # IS right now and returns rc=1 when a label is not mounted, so we decline to
  # touch an unmounted directory. Once only a confirmed mount is chowned, the
  # || true is gone and a genuine failure surfaces. Declare-then-assign, never
  # local x="$(drive_mount ...)", because local's rc=0 hides the resolver status
  # under set -e. The if form, not `[ -n "$m" ] && chown`, because an empty $m
  # would make that && the function's last command and return 1, and mount_drives
  # runs bare under set -e in all(). Unverified on fedora and suse, no such
  # machine available.
  local sp_mnt wd_mnt
  sp_mnt="$(drive_mount StoragePrime)" || sp_mnt=""
  if [ -n "$sp_mnt" ]; then sudo chown "$USER:$USER" "$sp_mnt"; fi
  wd_mnt="$(drive_mount WorkDrive)" || wd_mnt=""
  if [ -n "$wd_mnt" ]; then sudo chown "$USER:$USER" "$wd_mnt"; fi
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

  # Install hdparm if it is missing. The case here listed only debian and fedora
  # and had no suse arm and no *) arm, so on openSUSE it matched nothing, installed
  # nothing, and returned 0. The udev rule below and the inline `sudo hdparm ...
  # && echo` then did nothing with no error printed, because a missing binary
  # prints neither the "APM off" line nor a failure. The WD80EZAZ kept parking its
  # heads, which is wear. The probe `command -v hdparm` already answers whether an
  # install is needed, so a $FAMILY case inside it is a list to maintain and get
  # wrong, which it did. pkg_install branches on $PKG internally and covers apt,
  # dnf, zypper and rpm-ostree. The package is named hdparm on debian, fedora and
  # suse alike, read off each database, so there is no rename to carry. On a full
  # all() run system_layer installs hdparm first, so this only bites a standalone
  # ./bootstrap.sh drives_stay_awake. Unverified on fedora and suse, no such
  # machine available.
  #
  # On an atomic base pkg_install would route to rpm-ostree install, which layers
  # behind the operator's back and needs a reboot. _system_atomic deliberately
  # reports a missing hdparm rather than layering it, so match that here: report
  # loudly and return, rather than run the udev rule and inline hdparm that both
  # need the binary and would fail silently without it. Return, not abort. This
  # runs bare under set -e in all(), and a return 1 would halt tailscale, the
  # firewall and every later section over one missing spin-down tool. _system_atomic
  # reports and lets all() continue, so match that.
  if ! command -v hdparm >/dev/null 2>&1; then
    if [ "$ATOMIC" = 1 ]; then
      echo "hdparm missing on this atomic base. Layer it and reboot:" >&2
      echo "  sudo rpm-ostree install hdparm" >&2
      echo "Without it this function's udev rule matches but never fires, and the" >&2
      echo "bulk drives keep parking. Re-run drives_stay_awake after the reboot." >&2
      return 0
    fi
    pkg_install hdparm
  fi

  # A udev rule rather than a one shot service: it fires on boot AND on hotplug,
  # and it survives the drive being unplugged and returned. Matched on serial, so
  # it can never apply to the wrong disk if sda and sdb ever swap.
  # Resolve hdparm's real path for the udev rule. A hardcoded /usr/sbin/hdparm is
  # wrong wherever the binary is only in /usr/bin, and udev then MATCHES the rule
  # and silently fails to run it, so the drives keep parking with no error. This is
  # the btrfs_scrub_sudo path-probe shape. command -v answers where it actually is.
  local hdparm_bin
  hdparm_bin="$(command -v hdparm 2>/dev/null || true)"
  if [ -z "$hdparm_bin" ]; then
    for d in /usr/sbin /sbin /usr/bin /bin; do
      [ -x "$d/hdparm" ] && hdparm_bin="$d/hdparm" && break
    done
  fi
  : "${hdparm_bin:=/usr/sbin/hdparm}"   # last-resort default, correct on most distros

  # Unquoted heredoc so ${hdparm_bin} bakes in. Nothing else here uses $, and %k is
  # a udev substitution, not a shell one, so it survives untouched.
  sudo tee /etc/udev/rules.d/69-drives-stay-awake.rules >/dev/null <<EOF
# Keep the bulk spinners awake. -B 255 disables APM, -S 0 disables the standby
# timer. Matched by serial so a device rename cannot misapply these.
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_SERIAL_SHORT}=="ZRT0TGY0", RUN+="${hdparm_bin} -B 255 -S 0 /dev/%k"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_SERIAL_SHORT}=="1EK7ET2Z", RUN+="${hdparm_bin} -B 255 -S 0 /dev/%k"
EOF
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=block --action=change
  echo "udev rule installed and triggered"

  # Apply now too, so it takes effect without waiting for a reboot.
  # Surface an hdparm failure instead of swallowing it. `cmd && echo` hides a
  # nonzero rc, because set -e never fires on a non-final member of an AND list, so
  # a drive that rejects the command used to fail in total silence. The if form
  # reports it and still does not abort the run.
  if sudo hdparm -B 255 -S 0 "$sp" >/dev/null 2>&1; then
    echo "  StoragePrime: APM and standby off"
  else
    echo "  StoragePrime: hdparm did not apply (drive absent or not ATA?)" >&2
  fi
  if sudo hdparm -B 255 -S 0 "$wd" >/dev/null 2>&1; then
    echo "  WorkDrive: APM and standby off"
  else
    echo "  WorkDrive: hdparm did not apply (drive absent or not ATA?)" >&2
  fi

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
  # The sudoers command path must equal the path SUDO resolves, so probe for it
  # rather than hardcode. The old rule wrote /usr/bin/btrfs, which is correct only
  # on this Ubuntu box. openSUSE's btrfsprogs ships the binary at /usr/sbin/btrfs
  # and has no /usr/bin/btrfs at all, so the NOPASSWD spec matched nothing. sudo -n
  # in scripts/btrfs-scrub.sh then got "a password is required", the scrub never
  # ran, and the monthly bit-rot sweep reported nothing wrong having read nothing.
  # visudo -cf still passed, because a spec that matches no path is legal syntax,
  # not a parse error. SILENT, and it validated green, which is why it stood.
  #
  # THE OBVIOUS FIX THAT IS WRONG. `command -v btrfs` reads the operator's PATH,
  # not sudo's. It can hand back ~/.nix-profile/bin/btrfs, a store path sudo's
  # secure_path can never resolve, and the bug returns. It also disagrees with
  # sudo on Fedora 42+, where /usr/sbin is merged into /usr/bin: sudo scans
  # secure_path sbin BEFORE bin and does not follow symlinks, so it records the
  # command as /usr/sbin/btrfs while the operator's PATH finds /usr/bin/btrfs. A
  # rule keyed off the operator's answer misses again. So scan sudo's OWN search
  # path, in sudo's order, and take the first executable btrfs. That is
  # /usr/sbin/btrfs on openSUSE, /usr/bin/btrfs on Ubuntu, and matches whatever
  # sudo records on Fedora. openSUSE half CONFIRMED off btrfsprogs' file list.
  # Fedora half unverified, no such machine available.
  if [ "$FAMILY" = "unknown" ]; then
    echo "Unknown family, skipping." >&2
    return
  fi
  local dir btrfs_bin=""
  for dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    if [ -x "$dir/btrfs" ]; then
      btrfs_bin="$dir/btrfs"
      break
    fi
  done
  if [ -z "$btrfs_bin" ]; then
    # Loud, never silent. system_layer installs btrfs-progs before this in all(),
    # and on an atomic base it is part of the image, so the binary is normally
    # here. A standalone ./bootstrap.sh btrfs_scrub_sudo on a machine where it is
    # not yet installed reaches this, and a NOPASSWD rule for an absent binary is
    # the exact silent-skip this probe removes. Fail rather than write it.
    echo "btrfs not found in sudo's secure_path, cannot write scrub rule" >&2
    return 1
  fi
  local f=/etc/sudoers.d/btrfs-scrub
  printf '%s ALL=(root) NOPASSWD: %s scrub *\n' "$USER" "$btrfs_bin" | sudo tee "$f" >/dev/null
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
  # break on a network change. The upstream installer is distro aware. I read the
  # served tailscale.com/install.sh end to end: it has working apt, dnf and
  # zypper arms, so the non-atomic branch installs on debian, fedora and suse and
  # enables tailscaled itself on the dnf and zypper paths.
  #
  # WHY THE ATOMIC BRANCH DOES NOT ASSERT PRESENCE
  #
  # The old code said "Atomic base ships tailscale. Enable it" for every
  # ATOMIC=1 machine. That is true for the universal-blue images this repo
  # targets, Bazzite, Bluefin and Aurora, which bake tailscale in. It is SILENTLY
  # false on vanilla Fedora Silverblue and Kinoite, which are also ATOMIC=1 and
  # ship no tailscale. There the enable line the user was told to run gives
  # "Unit tailscaled.service not found". The obvious fix, piping to install.sh on
  # atomic too, does not work: install.sh has a hardcoded bazzite arm and no
  # generic ostree arm, so it takes the dnf path and fails on the read-only /usr.
  # So the present check on line below already covers the ublue images, and the
  # ATOMIC branch only fires where tailscale is genuinely missing, where the
  # honest answer is to layer it, which costs a reboot. Unverified on fedora and
  # suse, no such machine available.
  if command -v tailscale >/dev/null 2>&1; then
    echo "tailscale already present."
  elif [ "$ATOMIC" = 1 ]; then
    echo "Atomic base without tailscale, e.g. vanilla Silverblue. Layering needs"
    echo "a reboot, so it is a state change you run yourself:"
    echo "  sudo rpm-ostree install tailscale && sudo systemctl reboot"
    echo "After the reboot: sudo systemctl enable --now tailscaled"
  else
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  # Authentication is a state change, so it is yours to run, not the script's.
  echo "Authenticate once: sudo tailscale up"
  echo "Then reach services by their tailnet name, e.g. forgejo, from any network."
}

nix_opengl_driver() {
  log "expose the GPU driver at /run/opengl-driver for Nix apps"
  # Every Nix GUI app that touches the GPU looks for the driver at
  # /run/opengl-driver/lib. That is the NixOS convention, and NixOS populates it.
  # On this machine it does not exist, so the apps find no GLX vendor and die.
  #
  # PrismLauncher is how this surfaced. Its wrapper hardcodes:
  #
  #   --set LD_LIBRARY_PATH /run/opengl-driver/lib:/nix/store/...
  #
  # so Minecraft launched, hit "Failed to create Vulkan instance: -9" and then
  # "Fatal: Could not initialize GLX", and Prism died four seconds in. The real
  # driver is Ubuntu's, in /usr/lib/x86_64-linux-gnu.
  #
  # WHY NOT nixGL
  #
  # nixGL is an input in flake.nix for exactly this class of problem, and it
  # cannot help here. That wrapper uses --set, not --prefix, so it REPLACES
  # LD_LIBRARY_PATH and throws away anything nixGL exported before the app's
  # first instruction. Wrapping prismlauncher in nixGL changes nothing. This was
  # confirmed the slow way.
  #
  # WHY ONLY THE NVIDIA LIBS, NOT ALL OF /usr/lib
  #
  # Symlinking the whole directory is the obvious shortcut and it is a trap.
  # /run/opengl-driver/lib is FIRST on that LD_LIBRARY_PATH, ahead of every Nix
  # store path, so the system's glibc and friends would shadow the ones the app
  # was built against. Link the driver and nothing else.
  #
  # WHY A SERVICE AND NOT tmpfiles
  #
  # /run is a tmpfs, so this has to be recreated every boot. systemd-tmpfiles
  # cannot glob a source, and the lib names carry the driver version
  # (libGLX_nvidia.so.580.159.03), so a static list would rot on the next driver
  # update. A oneshot that re-links at boot survives both.
  if [ "$FAMILY" = "unknown" ]; then
    echo "Unknown family, skipping." >&2
    return
  fi

  # WHY PROBE THE LIBDIR INSTEAD OF HARDCODING IT
  #
  # This used to test /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 and bake that
  # same path into the ExecStart. That directory is Debian/Ubuntu multiarch and
  # exists on NO other family. Fedora, openSUSE and Bazzite put the 64-bit NVIDIA
  # userspace in /usr/lib64. So on those the test was always false, the function
  # printed "No NVIDIA userspace libs found. Skipping" and returned 0 on a
  # machine with a working 5090, reproducing the exact GLX crash it exists to
  # prevent. SILENT, the worst kind, a supported distro trusting a lie for a year.
  #
  # ldconfig knows where the lib actually is, so ask it. TRAP, do NOT call bare
  # `ldconfig`: on any machine with Nix on PATH, and every machine this repo
  # builds has one, the first ldconfig is Nix's glibc build. It reads a cache
  # inside the Nix store that does not exist, errors to stderr and exits 1 with
  # empty stdout. That empty result reads exactly like "no NVIDIA libs" and
  # brings the silent skip back. Call the system linker at /usr/sbin/ldconfig by
  # absolute path. Filter for the x86-64 entry, because the cache also lists the
  # i386 libGLX_nvidia under /lib/i386-linux-gnu, and linking the 32-bit lib
  # would collide with and shadow the 64-bit one on LD_LIBRARY_PATH.
  #
  # Bazzite is atomic but NOT skipped, unlike nvidia_driver and virtualbox_extras.
  # It ships the kernel driver, but Nix GUI apps on it still find no
  # /run/opengl-driver/lib and still crash. /etc and /run are writable on ostree
  # and this only READS /usr, so it runs fine on atomic with the /usr/lib64 path
  # the probe returns. The bug was always the path, never a missing atomic guard.
  #
  # The resolved DIRECTORY is baked into the unit below, the filenames are not.
  # The dir is stable across reboots, only the lib names carry the driver version
  # (libGLX_nvidia.so.580.159.03), which is why the ExecStart still globs at boot.
  local nvlib nvdir
  nvlib="$(/usr/sbin/ldconfig -p 2>/dev/null | awk '/libGLX_nvidia\.so/ && /x86-64/ {print $NF; exit}' || true)"
  if [ -z "$nvlib" ]; then
    echo "No NVIDIA userspace libs found. Skipping, this is an NVIDIA-only fix."
    return
  fi
  nvdir="$(dirname "$nvlib")"

  # Unquoted heredoc so $nvdir bakes in. The find's {} and \; carry no $, so they
  # survive expansion untouched, and there is no other $ or backtick in the body.
  local u=/etc/systemd/system/nix-opengl-driver.service
  sudo tee "$u" >/dev/null <<EOF
[Unit]
Description=Expose the system NVIDIA driver at /run/opengl-driver for Nix apps
Documentation=https://github.com/NixOS/nixpkgs/issues/9415
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Only the nvidia libs. Everything else in /usr/lib would shadow the Nix store
# paths that come after it on LD_LIBRARY_PATH.
ExecStart=/bin/sh -c 'mkdir -p /run/opengl-driver/lib && find ${nvdir} -maxdepth 1 -name "lib*nvidia*" -exec ln -sf {} /run/opengl-driver/lib/ \;'

[Install]
WantedBy=graphical.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now nix-opengl-driver.service
  echo "linked $(ls /run/opengl-driver/lib 2>/dev/null | wc -l) driver libs into /run/opengl-driver/lib"
  echo "Verify: prismlauncher should now launch an instance without 'Could not initialize GLX'."
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
  # WHY PROBE FOR firewalld, NOT INSTALL ufw EVERYWHERE
  #
  # The old code was "if ! command -v ufw; then pkg_install ufw; fi" followed by
  # ufw-only instructions. ufw is Ubuntu's default and no firewalld is present
  # there, so on debian it is right. On fedora and suse it is a parity failure.
  # Both families ship firewalld installed and enabled out of the box, so
  # pkg_install ufw put a SECOND netfilter daemon beside a running firewalld,
  # which is undefined and unsupported, and then the printed steps walked the
  # operator into "ufw enable", the actual conflict. I confirmed through browse
  # that ufw and firewalld both exist as packages on both families, so the
  # install succeeds rather than failing, which is what made it silent.
  #
  # The obvious fix, branching on $FAMILY, is worse than a probe. A debian user
  # can install firewalld and a fedora user can in theory prefer ufw, so the
  # family does not answer "which firewall is this". "command -v firewall-cmd"
  # does. So probe firewalld first and speak firewalld, else ufw, and only when
  # NEITHER is present fall back to installing the family's native one. That last
  # branch is where pkg_install can run. It cannot crash the run today: fedora
  # and suse ship firewalld so the probe short-circuits before pkg_install, and
  # debian resolves ufw. detect_os aborts on FAMILY=unknown before any section
  # starts, so PKG=none never reaches here. A caller that skips detect_os would
  # reintroduce the set -e death, hence this note.
  #
  # The firewalld posture reproduces the ufw end state, tailnet-only ingress, it
  # does not translate ufw verbs. Default zone "drop" drops all inbound with no
  # reply, the same as "ufw default deny incoming". tailscale0 goes in the
  # "trusted" zone, which accepts everything, the same as "ufw allow in on
  # tailscale0". 41641/udp opens in the drop zone for NAT traversal. I read the
  # zone semantics and every firewall-cmd flag off firewalld.org. Unverified on
  # fedora and suse, no such machine available.
  local fw=""
  if command -v firewall-cmd >/dev/null 2>&1; then
    fw=firewalld
  elif command -v ufw >/dev/null 2>&1; then
    fw=ufw
  elif [ "$FAMILY" = "debian" ]; then
    pkg_install ufw
    fw=ufw
  else
    pkg_install firewalld
    fw=firewalld
  fi

  echo "These change the firewall, so they are yours to run, not the script's."
  echo "Read them first. If you are on ssh over the LAN, keep the ssh rule below"
  echo "or you lock yourself out."
  echo

  if [ "$fw" = firewalld ]; then
    cat <<'EOF'
1. The posture. firewalld's "drop" zone drops all inbound with no reply, which
   is the "default deny incoming" you want, and leaves outbound open. Bring
   tailscale up first, so tailscale0 exists before you bind it.

  # Start firewalld first. It ships enabled on Fedora and openSUSE, but the
  # fallback arm above installs it on a minimal box where it is not running yet,
  # and every firewall-cmd below errors "FirewallD is not running" until it is.
  sudo systemctl enable --now firewalld

  sudo firewall-cmd --set-default-zone=drop

  # The tailnet is just your own devices. Put its interface in the "trusted"
  # zone, which accepts everything, so a new service is covered without touching
  # the firewall again. This is the interface trust that replaces per-port rules.
  sudo firewall-cmd --permanent --zone=trusted --change-interface=tailscale0

  # Tailscale's own NAT traversal. Open it in the default drop zone so peers
  # reach you directly instead of falling back to relays, disabled here.
  sudo firewall-cmd --permanent --zone=drop --add-port=41641/udp

  # OPTIONAL. Only if you ssh to this box from the LAN rather than the tailnet.
  # This opens ssh on every interface still in the drop zone, both LAN NICs.
  sudo firewall-cmd --permanent --zone=drop --add-service=ssh

  sudo firewall-cmd --reload

2. There is nothing to delete, unlike ufw. firewalld is zone based, so once the
   default zone is "drop" nothing inbound is accepted except the tailscale0 trust
   and the port above. This is why http://192.168.1.200:3000 stops answering a
   phone on the WiFi: the LAN NICs sit in the drop zone. Confirm the layout:

  sudo firewall-cmd --get-active-zones
  sudo firewall-cmd --zone=drop --list-all
  sudo firewall-cmd --zone=trusted --list-all

EOF
  else
    cat <<'EOF'
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

EOF
  fi

  cat <<'EOF'
3. Verify FROM ANOTHER DEVICE. A phone on the WiFi with tailscale off is the
   whole test.

   Do NOT test by curling this box's own LAN address from this box. Linux routes
   traffic to a local address over loopback:

     $ ip route get 192.168.1.200
     local 192.168.1.200 dev lo ...

   The firewall allows loopback unconditionally and the LAN interface rules are
   never consulted, so it answers 200 whether the firewall blocks the LAN or not.
   It proves nothing and reads like a failure.

   On the phone, WiFi on, tailscale off:

     http://192.168.1.200:4141   must NOT load     (atlantis)
     http://192.168.1.200:3000   must NOT load     (forgejo)

   On the phone, tailscale ON:

     https://forgejo.home.samuelstidham.me   must load, no cert warning

4. Then check syncthing, because closing 22000 and 21027 removes its LAN path
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
  #
  # This helper is NetworkManager shaped, and that is right for the desktop this
  # machine targets. Desktop openSUSE Tumbleweed defaults to NetworkManager now,
  # as does Fedora and Ubuntu. The gap is that openSUSE server profiles and some
  # Leap installs still run wicked, where nmcli is the wrong tool and the printed
  # commands are inert rather than wrong. The guarded read below degrades to a
  # message there, so it fails softly. It stays print-only, so no branch is worth
  # adding. The one-line note in the output covers the wicked case. Unverified on
  # suse, no such machine available.
  local ip="192.168.1.200/24" gw="192.168.1.1" dns="192.168.1.1,1.1.1.1"
  echo "Your NetworkManager connections:"
  nmcli -t -f NAME,TYPE connection show 2>/dev/null || echo "  (nmcli not available here)"
  echo "If this is a wicked-managed openSUSE, nmcli does nothing. Switch to"
  echo "NetworkManager, or pin the address through wicked's ifcfg instead."
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

pnpm_cli() {
  log "pnpm"
  # pnpm from its own installer and NOT from Nix, so it can self-update. Same trade
  # as Claude Code above and the AWS CLI below: a pinned nixpkgs build cannot run
  # `pnpm self-update`, and rolling updates are the whole point of choosing it.
  #
  # This is a DELIBERATE reversal of what home/languages.nix does for the other
  # JavaScript tooling, where nodejs, bun and deno each replaced a curl installer
  # precisely to get them into the store. It is recorded here so the next reader
  # does not tidy the inconsistency away. pnpm is the exception on purpose, and
  # nixpkgs does carry it, verified at 11.9.0, so the choice is not availability.
  #
  # NAMED pnpm_cli AND NOT pnpm, which matters more than it looks. A bash function
  # shadows a binary of the same name for the rest of the script, so a function
  # called `pnpm` would make the `command -v pnpm` guard below match ITSELF and
  # report pnpm as already present on a machine that has never had it. main()
  # dispatches on any defined function, so `./bootstrap.sh pnpm_cli` still works.
  if command -v pnpm >/dev/null 2>&1; then
    echo "pnpm already present: $(pnpm --version 2>/dev/null). It self-updates"
    echo "with 'pnpm self-update', so leaving it."
    return
  fi

  # THE ENV PREFIX GOES ON THE INTERPRETER, not on curl. `FOO=bar curl ... | sh -`
  # sets FOO for curl, which is the process that does not read it, and the variable
  # never reaches the script being piped in. The `| env FOO=bar sh -` form below is
  # the one pnpm's own "In a Docker container" recipe uses, and it is the only one
  # that works.
  #
  # SHELL and ENV are load bearing here. pnpm's installer edits a shell rc to export
  # PNPM_HOME and extend PATH, and pnpm's own uninstall documentation names
  # $HOME/.config/fish/config.fish as the file it writes for fish users. On this
  # machine that path is a SYMLINK INTO THE NIX STORE, generated by home-manager
  # and read only. Verified here: `test -w ~/.config/fish/config.fish` fails. So the
  # installer would either die writing it or, worse, appear to work while the next
  # `home-manager switch` threw the edit away.
  #
  # Pointing SHELL at sh and ENV at ~/.profile sends that write somewhere harmless
  # and unmanaged by this repo. fish gets PNPM_HOME from fish/env.fish and its PATH
  # entry from fish/configure_path.fish, both tracked here, which is where shell
  # configuration belongs on this machine anyway.
  #
  # PNPM_HOME is passed rather than left to default, and the installer honours a
  # pre-set value. fish/env.fish declares the same path, so the repo owns the
  # location instead of inheriting whatever the installer picked. Change it in one
  # place and the other is wrong, so the two are commented as a pair.
  #
  # curl and libatomic both come from the system layer, which runs earlier in all().
  # The glibc build of pnpm dlopens libatomic.so.1 and dies with "error while
  # loading shared libraries" without it, which is why libatomic1 on debian and suse
  # and libatomic on fedora sit in those Tauri blocks.
  curl -fsSL https://get.pnpm.io/install.sh \
    | env PNPM_HOME="$HOME/.local/share/pnpm" SHELL=sh ENV="$HOME/.profile" sh -

  # The installer put pnpm on PATH only for shells started AFTER it ran, so this
  # shell still cannot see it. Report rather than probe, because `command -v pnpm`
  # would fail here for that reason alone and read as a failed install.
  echo "pnpm installed to \$PNPM_HOME (~/.local/share/pnpm)."
  echo "Open a new shell to pick it up, or run: exec fish"
}

calibre() {
  log "Calibre"
  # Calibre's own binary installer, which upstream considers the supported path:
  # "Please do not use your distribution provided calibre package, as those are
  # often buggy/outdated." The binary install bundles private copies of every
  # dependency, which is exactly why the distro and Nix builds lag.
  #
  # It is deliberately not a Flatpak. The Flatpak is sandboxed and cannot see the
  # library on the StoragePrime drive without an explicit --filesystem grant, so
  # it would start up unable to find the books.
  #
  # It is deliberately not in Nix either. Calibre updates itself, and pinning it
  # in the flake would fight that, the same reasoning as Claude Code and the AWS
  # CLI. It installs to /opt/calibre and symlinks into /usr/bin.
  #
  # The library itself lives on StoragePrime, at /mnt/StoragePrime/Books/Calibre
  # Library, and is set in ~/.config/calibre/global.py.json as library_path. The
  # mount-root unit pins fresh drives under /mnt, not Ubuntu's /media/$USER, so the
  # old /media path is gone. Keep the library_path in step with CALIBRE_LIBRARY in
  # scripts/backup.sh. No code here writes global.py.json, a human sets it once.
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
  # The name differs per distro. Debian and openSUSE both ship libxcb-cursor0,
  # Fedora ships the same shared object inside xcb-util-cursor.
  #
  # suse used to fall through to "Unknown family", so the library was never
  # installed and calibre then installed anyway and died at FIRST LAUNCH with
  # "You are missing the system library libxcb-cursor.so.0", a deferred crash the
  # bootstrap run never saw. VERIFIED in containers: libxcb-cursor0 resolves with
  # `zypper install --dry-run` on BOTH Tumbleweed and Leap 16.0, the same name as
  # Debian. An earlier note here claimed Leap 16.0 lacked it, but that was read off
  # a web page, not a real zypper, and it is wrong. So `suse) pkg_install
  # libxcb-cursor0` is correct on both. Still unverified as behaviour, nothing was
  # installed or launched.
  case "$FAMILY" in
    debian) pkg_install libxcb-cursor0 ;;
    suse) pkg_install libxcb-cursor0 ;;
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

  # The installer form differs on an atomic base. The DEFAULT form runs as root
  # and calibre_postinstall symlinks launchers into /usr/bin and writes /usr/share,
  # both read-only on ostree, so it fails there. On Bazzite that failure lands at
  # the very last step of all() under `set -e`, so it either aborts the run or
  # leaves calibre half-installed at /opt with no launcher on PATH. calibre's own
  # download page (calibre-ebook.com/download_linux, read 2026-07-16) documents an
  # "isolated" form that "only touches files inside the installation folder and
  # does not need to be run as root", so atomic gets that, into the writable
  # $HOME/calibre-bin. The obvious alternative, layering calibre with rpm-ostree,
  # fights upstream's own advice against distro packages and needs a reboot, so it
  # is offered as a fallback in the message rather than run. The trade the isolated
  # form accepts is no menu entry and no /usr/bin/calibre, so the binary must be
  # put on PATH by hand. Unverified on Bazzite, no such machine available.
  if [ "$ATOMIC" = 1 ]; then
    wget -nv -O- https://download.calibre-ebook.com/linux-installer.sh | sh /dev/stdin install_dir="$HOME/calibre-bin" isolated=y
    echo "Isolated calibre installed to $HOME/calibre-bin, no menu entry."
    echo "Add $HOME/calibre-bin to PATH, or layer it: sudo rpm-ostree install calibre."
  else
    sudo -v && wget -nv -O- https://download.calibre-ebook.com/linux-installer.sh | sudo sh /dev/stdin
  fi
}

aws_cli() {
  log "AWS CLI v2"
  # From AWS's own bundled installer, not Nix, so it rolls forward on its own
  # like Claude Code. AWS recommends this over any distro package. It is self
  # contained and OS agnostic, and on the atomic base /usr/local is writable, so
  # it works on Bazzite too. unzip comes from Nix (cli.nix).
  local tmp arch
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN   # clean up even if a step below fails under set -e
  # Arch from uname -m, not hardcoded x86_64. AWS names the zip
  # awscli-exe-linux-<arch> where arch is x86_64 or aarch64, exactly what uname -m
  # prints on those, so an aarch64 box no longer downloads and runs the x86_64
  # binary. Checksum verification is still not done: AWS ships a GPG signature
  # rather than a plain hash, a heavier step left for later.
  arch="$(uname -m)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  if [ -d /usr/local/aws-cli ]; then
    # Existing install. The --update form needs the original paths restated.
    sudo "$tmp/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update
  else
    sudo "$tmp/aws/install"
  fi
  aws --version || true
}

ocaml() {
  log "OCaml (opam)"
  # OCaml is NOT from Nix, see the tombstone in home/languages.nix. opam is the
  # toolchain manager the OCaml project itself ships, installed the way upstream
  # recommends rather than pinned in the flake, the same self-managed pattern as
  # Claude Code and the AWS CLI. The installer only drops the opam binary. `opam
  # init` and the switch are stateful and interactive, they compile a compiler and
  # write shell hooks, so they are a named manual step here, not run behind your
  # back. OS agnostic: the installer detects the platform, and fish puts the active
  # switch on PATH through the `opam env` line in fish/configure_path.fish.
  #
  # Process substitution, not `curl | sh`, is deliberate and it is opam's own
  # recommendation. The installer prompts for the install location, and a pipe
  # would tie up stdin so it could not read the answer. `<()` keeps stdin free,
  # which is why this section is bash.
  if command -v opam >/dev/null 2>&1; then
    echo "opam already present ($(opam --version 2>/dev/null)). It self-manages, leaving it."
  else
    sh <(curl -fsSL https://opam.ocaml.org/install.sh)
  fi
  echo "Initialize once, which creates the default switch and the shell hooks:"
  echo "  opam init"
  echo "Then install the tools the old Nix set provided:"
  echo "  opam install dune utop ocaml-lsp-server ocamlformat"
}

all() {
  detect_os
  echo "Detected FAMILY=$FAMILY PKG=$PKG ATOMIC=$ATOMIC"
  install_nix
  apply_home
  fish_login_shell
  system_layer
  nvidia_driver
  nix_opengl_driver
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
  godot_tooling
  savvy
  claude_code
  pnpm_cli
  aws_cli
  ocaml
  calibre
  log "Done. Reboot if a driver or a layered package changed."
}

# Every named section needs the OS probe first, except detect and all which run
# it themselves. Run the probe, then the requested section.
main() {
  local section="${1:-all}"
  case "$section" in
    detect|all) "$section" ;;
    *)
      # Validate the section names a real function before running it, so a typo
      # fails with a clear message instead of detect_os running and then a "command
      # not found" for the bogus name, or worse an unintended external command.
      if ! declare -F "$section" >/dev/null; then
        echo "Unknown section: $section" >&2
        echo "Pass a defined section name, or 'all', or 'detect'." >&2
        exit 2
      fi
      detect_os
      "$section"
      ;;
  esac
}

main "$@"
