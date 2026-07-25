#!/usr/bin/env bash
#
# hm-output.sh - the strongest behavior gate, the home-manager generated output.
#
# The activation package is a pure function of the flake, so what Nix generates
# from it is the ground truth of the machine's declarative behavior. This captures
# five views of it and masks store hashes so a pure rebuild does not read as
# drift:
#   PACKAGE SET     the closure of home.packages, name and version, sorted. Catches
#                   any package added, removed, or version-bumped.
#   SYSTEMD UNITS   every generated user service and timer, verbatim. Catches a
#                   changed ExecStart, path, or schedule, which is what a unit does.
#   config.fish     the generated fish entry point, which fixes the sourcing order.
#   git config      the generated ~/.config/git/config and the per-account identity
#                   files. Catches a changed commit identity, signing key, gpg
#                   program, hooks path, or includeIf rule.
#   ssh config      the generated ~/.ssh/config. Catches a changed host block,
#                   identity file, or agent setting.
#
# This is SLOW, a full nix build, and because the repo carries untracked files
# (parts/drive-mount.nix, scripts/drive-mount.sh) it builds from a throwaway git
# worktree copy so the flake can see them. That is why it is NOT in run.sh. Run it
# deliberately around a change to any .nix file.
#
#   ./hm-output.sh capture   write the golden
#   ./hm-output.sh check     rebuild and diff against the golden (default)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GOLDEN="${GOLDEN:-$HERE/golden/hm-output.txt}"
ATTR='.#homeConfigurations."samuelstidham@x86_64-linux".activationPackage'

mask() { sed -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/HASH-#g'; }

# build_out builds from a copy that stages the working tree, so untracked files
# are visible to the flake. The built path lands in /nix/store and outlives the
# copy. It moved to lib-build.sh when git-identity.sh needed the same build.
# shellcheck source=lib-build.sh
. "$HERE/lib-build.sh"

snapshot() {
  local out
  out="$(build_out)"
  if [ -z "$out" ] || [ ! -e "$out" ]; then
    echo "hm-output: nix build produced no path" >&2
    return 1
  fi
  echo "# ===== PACKAGE SET (home.packages closure) ====="
  nix-store -q --references "$out/home-path" | sed -E 's#/nix/store/[a-z0-9]{32}-##' | sort
  echo "# ===== SYSTEMD USER UNITS ====="
  while IFS= read -r u; do
    echo "## $(basename "$u")"
    mask < "$u"
  done < <(find "$out/home-files/.config/systemd/user" -maxdepth 1 \( -name '*.service' -o -name '*.timer' \) | sort)
  echo "# ===== GENERATED config.fish ====="
  mask < "$out/home-files/.config/fish/config.fish"
  echo "# ===== GENERATED git config ====="
  mask < "$out/home-files/.config/git/config"
  echo "# ===== GENERATED git identity files ====="
  while IFS= read -r f; do
    echo "## $(basename "$f")"
    mask < "$f"
  done < <(find "$out/home-files/.config/git" -maxdepth 1 -name 'identity-*' | sort)
  echo "# ===== GENERATED ssh config ====="
  mask < "$out/home-files/.ssh/config"
}

mode="${1:-check}"
case "$mode" in
  capture)
    mkdir -p "$(dirname "$GOLDEN")"
    snapshot > "$GOLDEN" || exit 1
    echo "hm-output captured: $GOLDEN ($(wc -l < "$GOLDEN") lines)"
    ;;
  check)
    if [ ! -f "$GOLDEN" ]; then
      echo "no golden at $GOLDEN. run: $0 capture" >&2
      exit 2
    fi
    tmp="$(mktemp)"
    snapshot > "$tmp" || { rm -f "$tmp"; exit 1; }
    if diff -u "$GOLDEN" "$tmp"; then
      echo "hm-output: IDENTICAL to golden"
      rm -f "$tmp"
    else
      echo "hm-output: DRIFT from golden (diff above)"
      rm -f "$tmp"
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [capture|check]" >&2
    exit 2
    ;;
esac
