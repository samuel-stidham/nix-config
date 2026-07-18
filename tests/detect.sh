#!/usr/bin/env bash
#
# detect.sh - drive bootstrap.sh detect_os against synthetic os-release files and
# assert the family, package manager, and atomic flag for each distro.
#
# This is a pure-function test. detect_os reads OS_RELEASE_FILE and OSTREE_MARKER,
# which default to the real /etc/os-release and /run/ostree-booted but here point
# at fixtures, so the whole matrix runs with no root, no VM, and no network. It is
# the regression net for the bootstrap-core rewrite: SUSE must resolve, and the
# RHEL-likes must fail closed to unknown even though they name fedora in ID_LIKE.
set -uo pipefail

BOOTSTRAP="$(cd "$(dirname "$0")/.." && pwd)/bootstrap.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/ostree-yes"          # exists, so ATOMIC becomes 1
NOMARK="$TMP/ostree-absent"    # never created, so ATOMIC stays 0

fail=0

# check NAME OSRELEASE-BODY ATOMIC(0|1) EXPECTED-FAMILY-LINE
check() {
  local name="$1" body="$2" atomic="$3" expect="$4"
  printf '%s\n' "$body" > "$TMP/os-release"
  local marker="$NOMARK"
  [ "$atomic" = 1 ] && marker="$TMP/ostree-yes"
  local got
  got="$(OS_RELEASE_FILE="$TMP/os-release" OSTREE_MARKER="$marker" \
         bash "$BOOTSTRAP" detect 2>/dev/null | grep '^FAMILY=')"
  if [ "$got" = "$expect" ]; then
    printf 'ok    %-14s %s\n' "$name" "$got"
  else
    printf 'FAIL  %-14s want [%s]  got [%s]\n' "$name" "$expect" "$got"
    fail=1
  fi
}

# debian family means the Ubuntu-derived apt distros, by ID or by *ubuntu* ID_LIKE
check ubuntu     $'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"'                0 "FAMILY=debian PKG=apt ATOMIC=0"
check mint       $'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="22"'        0 "FAMILY=debian PKG=apt ATOMIC=0"
check pop        $'ID=pop\nID_LIKE="ubuntu debian"\nVERSION_ID="22.04"'           0 "FAMILY=debian PKG=apt ATOMIC=0"

# base Debian, Raspbian and non-Ubuntu apt derivatives fail closed to unknown,
# because Debian has no VirtualBox in its repos. See the tombstone in detect_os.
check debian12   $'ID=debian\nVERSION_ID="12"'                                    0 "FAMILY=unknown PKG=none ATOMIC=0"
check debian-sid $'ID=debian'                                                      0 "FAMILY=unknown PKG=none ATOMIC=0"
check kali       $'ID=kali\nID_LIKE=debian'                                        0 "FAMILY=unknown PKG=none ATOMIC=0"
# LMDE shares ID=linuxmint with the Ubuntu-based Mint above, but carries
# ID_LIKE=debian (no ubuntu), so it must drop while mint stays debian. Real
# os-release read off chef/os_release issue 68 and the linuxmint_22 fixture.
check lmde       $'ID=linuxmint\nID_LIKE=debian\nVERSION_ID="6"'                    0 "FAMILY=unknown PKG=none ATOMIC=0"
check raspbian   $'ID=raspbian\nID_LIKE=debian\nVERSION_ID="12"'                    0 "FAMILY=unknown PKG=none ATOMIC=0"

# fedora family, plus atomic promotion to rpm-ostree
check fedora     $'ID=fedora\nVERSION_ID="42"'                                     0 "FAMILY=fedora PKG=dnf ATOMIC=0"
check bazzite    $'ID=bazzite\nID_LIKE=fedora\nVERSION_ID="42"'                   1 "FAMILY=fedora PKG=rpm-ostree ATOMIC=1"
check silverblue $'ID=fedora\nVARIANT_ID=silverblue\nVERSION_ID="42"'             1 "FAMILY=fedora PKG=rpm-ostree ATOMIC=1"
# Amazon Linux 2023 names fedora in ID_LIKE, so detection claims it as fedora. It
# is NOT supported: the `rpm -E %fedora` integer guard in _system_fedora fails it
# closed at install (a literal %fedora would poison the RPM Fusion URL). This pins
# that KNOWN LEAK so dropping it in detect_os later is a conscious change, not a
# surprise. It is documentation of current behavior, not an endorsement.
check amzn       $'ID=amzn\nID_LIKE="fedora"\nVERSION_ID="2023"'                   0 "FAMILY=fedora PKG=dnf ATOMIC=0"

# suse family, by ID (SLES carries no ID_LIKE) and by the opensuse IDs
check tumbleweed $'ID=opensuse-tumbleweed\nID_LIKE="opensuse suse"'               0 "FAMILY=suse PKG=zypper ATOMIC=0"
check leap       $'ID=opensuse-leap\nID_LIKE="suse opensuse"\nVERSION_ID="15.6"'  0 "FAMILY=suse PKG=zypper ATOMIC=0"
# SLES by ID. SLES 12 ships NO ID_LIKE, matched by the `sles` ID token alone, and
# SLES 15 adds ID_LIKE=suse. Both resolve to suse via the ID token, so the pair
# proves the token catches SLES across the ID_LIKE cutover. The 15 row's ID_LIKE is
# per the round-2 review, not browse-confirmed here; the assertion holds either
# way, since ID=sles matches before any ID_LIKE fallback.
check sles12     $'ID=sles\nVERSION_ID="12.5"'                                     0 "FAMILY=suse PKG=zypper ATOMIC=0"
check sles15     $'ID=sles\nID_LIKE="suse"\nVERSION_ID="15.6"'                     0 "FAMILY=suse PKG=zypper ATOMIC=0"
# openSUSE MicroOS: atomic via btrfs snapshots, no ostree marker. It resolves to
# suse through ID_LIKE=suse. ATOMIC stays 0 here because detect_os probes the REAL
# /usr, writable on the test box; on real MicroOS the read-only /usr sets ATOMIC=1
# via the findmnt check in detect_os, which no fixture can drive.
check microos    $'ID=opensuse-microos\nID_LIKE="suse opensuse"'                    0 "FAMILY=suse PKG=zypper ATOMIC=0"

# the dropped RHEL-likes must fail closed, though they name fedora in ID_LIKE
check rocky      $'ID=rocky\nID_LIKE="rhel centos fedora"\nVERSION_ID="9"'        0 "FAMILY=unknown PKG=none ATOMIC=0"
check rhel       $'ID=rhel\nID_LIKE="fedora"\nVERSION_ID="9"'                      0 "FAMILY=unknown PKG=none ATOMIC=0"
check alma       $'ID=almalinux\nID_LIKE="rhel centos fedora"'                    0 "FAMILY=unknown PKG=none ATOMIC=0"
check centos     $'ID=centos\nID_LIKE="rhel fedora"\nVERSION_ID="9"'              0 "FAMILY=unknown PKG=none ATOMIC=0"

# genuinely unsupported, no matching ID and no matching ID_LIKE
check arch       $'ID=arch'                                                        0 "FAMILY=unknown PKG=none ATOMIC=0"

if [ "$fail" = 0 ]; then
  echo "detect: all cases passed"
else
  echo "detect: FAILURES above"
fi
exit $fail
