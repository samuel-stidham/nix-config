#!/usr/bin/env bash
#
# rex-install.sh - install Rex from its own Nix flake and set up a personal server.
#
# Rex is the Superlogical multiplexer. Its Linux docs are at
#   https://www.superlogical.com/rex/docs/linux/installation
# and this script is the "Nix and NixOS" path from that page, plus the Quickstart
# steps that follow it. Run it once on a new machine, and again to upgrade:
#
#   ./rex-install.sh                       # preview channel
#   REX_CHANNEL=snapshot ./rex-install.sh  # another channel
#
# WHY A SCRIPT AND NOT A FLAKE INPUT. Rex publishes a flake with a home-manager
# module, and the module would do all of this declaratively. It was left out on
# purpose. Rex on Linux is in testing, and its channel tarball moves with every
# release. An input would tie every `home-manager switch` of this repo to a
# preview binary's lock. Installing into the user profile keeps Rex beside the
# home-manager generation, not inside it, so a bad preview is one
# `nix profile remove` away and never blocks a switch.
#
# WHY NOT install.sh. The docs' curl installer adds an apt, dnf, zypper or pacman
# repository and needs sudo. That is a per-family body and a system change. The
# Nix path is one command on every family this repo supports, and it needs no
# root.
#
# WHAT IT DOES, in order:
#   1. `nix profile add` the channel flake, or upgrade the entry already there.
#   2. `rex terminfo setup`, which writes the xterm-rex entry to ~/.terminfo and
#      the ssh guard to ~/.config/rex/ssh_config.
#   3. `rex server install`, which writes and enables a systemd user unit, so the
#      personal server starts at boot and survives logout.
#
# THE SSH GUARD NEEDS THE REPO. The guard only takes effect once ~/.ssh/config
# includes it. That file is a home-manager symlink into the store, so Rex cannot
# edit it and says so:
#   ~/.ssh/config was left alone: it is a symbolic link
# The Include line therefore lives in home/secrets.nix, under programs.ssh. This
# script does not write it. It checks `rex terminfo status` at the end and says
# plainly when the guard is not in effect.
#
# No distro branch anywhere. Every step is Nix or a systemd user unit. Verified on
# Ubuntu 26.04 only. Unverified on fedora and suse, no such machine available.
set -euo pipefail

# stable is the docs' default, but no stable release exists yet. On 2026-11-19
# stable.tar.gz answered HTTP 404 and install.sh falls back to preview for the
# same reason. Move this default to stable once that channel has a release.
CHANNEL="${REX_CHANNEL:-preview}"
FLAKE="https://pkgs.superlogical.com/rex/nix/${CHANNEL}.tar.gz"

# The profile copy, by absolute path. A bare `rex` could resolve to (R)?ex, the
# unrelated Perl tool that Debian, Ubuntu and Fedora all package under this name.
REX="$HOME/.nix-profile/bin/rex"

if ! command -v nix >/dev/null 2>&1; then
  echo "rex-install: nix is not on PATH. Install Nix first, see bootstrap.sh." >&2
  exit 1
fi

# Rex's server install writes a systemd USER unit. Without a user manager there is
# nothing to enable, and the docs' answer is `rex server start` by hand.
if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "rex-install: no systemd user manager on this session." >&2
  echo "Install Rex with: nix profile add $FLAKE" >&2
  echo "Then start a server by hand with: rex server start" >&2
  exit 1
fi

# ---- 1. install or upgrade --------------------------------------------------
# The profile does NOT name the entry `rex`. A tarball flake has no repo name to
# borrow, so Nix 2.34 names it after the whole reference:
#   https://pkgs.superlogical.com/rex/nix/preview.tar.gz#packages.x86_64-linux.default
# The first version of this script matched `^Name: rex$`. That never matched, so
# every rerun took the install branch and printed "is already added". It looked
# like success and upgraded nothing. So match on the URL prefix and reuse the
# name the profile reports. `nix profile list` prints the name in bold, and the
# escape codes are stripped before the match.
REX_URL_PREFIX="https://pkgs.superlogical.com/rex/nix/"
entry="$(nix profile list 2>/dev/null \
  | sed -E 's/\x1b\[[0-9;]*m//g' \
  | sed -nE 's/^Name:[[:space:]]+//p' \
  | grep -F "$REX_URL_PREFIX" | head -n 1 || true)"

# An entry from another channel owns the same bin/rex, and a second add would
# collide with it. Remove it first, so a channel switch is one command.
if [ -n "$entry" ] && [ "${entry%%#*}" != "$FLAKE" ]; then
  echo "rex-install: replacing the ${entry%%#*} entry with $CHANNEL"
  nix profile remove "$entry"
  entry=""
fi

if [ -n "$entry" ]; then
  echo "rex-install: upgrading the rex profile entry from $CHANNEL"
  # The channel URL always serves the newest release, but the profile entry
  # records the locked one. --refresh drops the cached tarball so upgrade sees it.
  nix profile upgrade --refresh "$entry"
else
  echo "rex-install: installing rex from $CHANNEL"
  # Nix 2.34 calls this `add`. Older Nix only knows `install`, which newer Nix
  # still accepts with a deprecation warning. Probe for the new name first.
  if nix profile add --help >/dev/null 2>&1; then
    nix profile add "$FLAKE"
  else
    nix profile install "$FLAKE"
  fi
fi

if [ ! -x "$REX" ]; then
  echo "rex-install: $REX is missing after the install. Nothing was set up." >&2
  exit 1
fi
"$REX" version

# ---- 2. terminfo and ssh guard ----------------------------------------------
# This exits 1 when it could not finish, for example on an ssh older than 7.8.
# It also declines to edit a symlinked ~/.ssh/config. Neither should stop the
# server step, so the status is kept and reported, not fatal.
terminfo_rc=0
"$REX" terminfo setup || terminfo_rc=$?

# ---- 3. personal server at boot ---------------------------------------------
# Safe to repeat, and the docs say to repeat it after rex moves. An upgrade moves
# it to a new store path, so this runs every time, not only on first install.
"$REX" server install

# An upgrade leaves the old server running on the old binary. Restart it so the
# version that answers is the version just installed. This ends open sessions.
systemctl --user restart rex.service

# ---- report -------------------------------------------------------------------
echo
"$REX" server status || true
echo
"$REX" terminfo status || true

if [ "$terminfo_rc" -ne 0 ]; then
  echo >&2
  echo "rex-install: 'rex terminfo setup' exited $terminfo_rc. Read its output above." >&2
  exit "$terminfo_rc"
fi
