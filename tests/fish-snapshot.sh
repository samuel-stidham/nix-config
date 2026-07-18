#!/usr/bin/env bash
#
# fish-snapshot.sh - golden-master of the realized fish shell this repo produces.
#
# It sources the fish tree in the SAME order home/fish.nix shellInit does, then
# dumps the realized state: every function and alias name, every exported
# variable, PATH in order, and the bodies of the hand-written functions AND
# aliases. That is the observable behavior of the shell. A behavior-preserving
# refactor leaves this dump unchanged. A change that moves it changed behavior,
# full stop.
#
#   ./fish-snapshot.sh capture   write the golden from the current fish tree
#   ./fish-snapshot.sh check     re-derive and diff against the golden (default)
#
# Determinism. fish runs under env -i with a fixed base, so inherited variables
# from the calling shell cannot leak in. secrets.fish is never sourced, it reveals
# vault values. Nix store hashes are masked, so a pure rebuild that only changes a
# hash does not read as behavior drift, while a package VERSION change still does.
# The golden is specific to this machine and its fish universal variables. If you
# deliberately change a universal, for example clearing fish_user_paths, recapture.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FISHDIR="${FISHDIR:-$REPO/fish}"
GOLDEN="${GOLDEN:-$HERE/golden/fish-snapshot.txt}"
FISH="$(command -v fish)"

if [ -z "$FISH" ]; then
  echo "fish not found on PATH" >&2
  exit 2
fi

snapshot() {
  # The bodies to dump are DERIVED, not hand-listed: every `function NAME` in
  # functions.fish AND every `alias NAME` in aliases.fish. A fish alias IS a
  # function, so `functions NAME` dumps its wrapper body, which is where the alias's
  # real behavior lives. The old list covered functions only, so a genuine change to
  # an alias body, for instance wg from `wget -c` to `wget --no-check-certificate`
  # which silently disables TLS, passed this gate green: the name was captured, the
  # body was not. Both are derived now, and the ex-* family a hand-list once missed
  # stays caught. Sorted, so the golden is stable regardless of definition order.
  local fns
  fns="$( { grep -oE '^function [A-Za-z0-9_-]+' "$FISHDIR/functions.fish"
            grep -oE '^alias [A-Za-z0-9_.-]+'    "$FISHDIR/aliases.fish" ; } \
          | awk '{print $2}' | sort -u | tr '\n' ' ')"
  env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin" "$FISH" --no-config -c '
    source '"$FISHDIR"'/env.fish
    source '"$FISHDIR"'/functions.fish
    source '"$FISHDIR"'/configure_path.fish
    source '"$FISHDIR"'/aliases.fish
    echo "# ===== FUNCTION AND ALIAS NAMES ====="
    functions --names | sort
    echo "# ===== EXPORTED VARIABLES ====="
    set --export | sort
    echo "# ===== PATH (order is behavior) ====="
    printf "%s\n" $PATH
    echo "# ===== HAND-WRITTEN FUNCTION BODIES ====="
    functions '"$fns"'
  ' 2>/dev/null \
    | sed -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/HASH-#g' \
    | grep -vE '^# Defined (in|via) '
}
# The `# Defined in FILE @ line N` header that `functions NAME` prints is dropped.
# It is location, not behavior, and its line number shifts every time a comment is
# added above a function, which would read as drift when nothing actually changed.

mode="${1:-check}"
case "$mode" in
  capture)
    mkdir -p "$(dirname "$GOLDEN")"
    snapshot > "$GOLDEN"
    echo "fish snapshot captured: $GOLDEN ($(wc -l < "$GOLDEN") lines)"
    ;;
  check)
    if [ ! -f "$GOLDEN" ]; then
      echo "no golden at $GOLDEN. run: $0 capture" >&2
      exit 2
    fi
    tmp="$(mktemp)"
    snapshot > "$tmp"
    if diff -u "$GOLDEN" "$tmp"; then
      echo "fish snapshot: IDENTICAL to golden"
      rm -f "$tmp"
    else
      echo "fish snapshot: DRIFT from golden (diff above)"
      rm -f "$tmp"
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [capture|check]" >&2
    exit 2
    ;;
esac
