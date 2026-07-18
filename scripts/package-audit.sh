#!/usr/bin/env bash
#
# package-audit.sh - reconcile language-manager installs against the Nix record.
#
# The dev-machine rule is: install packages with each language's own package
# manager freely, but RECORD what sticks so a fresh machine rebuilds it. This is
# the honesty check for that rule. It walks every language's install location and
# sorts each tool into one of three buckets:
#
#   redundant   Nix already provides a binary of this name. The manager copy is a
#               duplicate that shadows or races the flake's version. Delete it.
#   recorded    Listed in docs/recorded-packages.txt as a deliberate, uncodified
#               install. Fine, nothing to do.
#   unrecorded  Neither in Nix nor recorded. Codify it into a Nix module, add it
#               to the record file, or delete it. This is the drift to act on.
#
# The Nix check is `~/.nix-profile/bin/<name>`, which sidesteps name matching:
# Nix's go-tools provides the `staticcheck` binary under that exact name, so a go
# install of staticcheck is correctly seen as redundant.
#
# No -e. Like btrfs-scrub.sh, this must survive a failing probe so it can still
# report and mail. Usage:
#   package-audit.sh            # print the report, exit 1 if there is drift
#   package-audit.sh --quiet    # print only when there is drift
set -uo pipefail

# The record of deliberately-uncodified installs. The systemd unit overrides this
# with the immutable store copy. This default is for a hand run from the checkout,
# and like bootstrap.sh's FLAKE_DIR it can simply be wrong off the checkout.
RECORD="${RECORDED_PACKAGES:-$HOME/code/samuel-stidham/nix-config/docs/recorded-packages.txt}"
NIXBIN="$HOME/.nix-profile/bin"
MAILTO="${AUDIT_MAILTO:-}"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

redundant=()
unrecorded=()

# recorded? matches a `manager:name` line, ignoring a trailing comment.
is_recorded() {
  grep -qE "^[[:space:]]*$1:$2([[:space:]]|#|\$)" "$RECORD" 2>/dev/null
}

classify() { # manager name
  local mgr="$1" name="$2"
  if [ -e "$NIXBIN/$name" ]; then
    redundant+=("$mgr:$name  (nix provides '$name')")
  elif is_recorded "$mgr" "$name"; then
    : # recorded, deliberate, nothing to do
  else
    unrecorded+=("$mgr:$name")
  fi
}

# Managers that install discrete binaries into a dedicated directory. Enumerating
# the directory needs no manager binary at runtime, so the timer stays light.
audit_bindir() { # manager dir
  local mgr="$1" dir="$2" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    classify "$mgr" "$(basename "$f")"
  done
}

audit_bindir cargo    "$HOME/.cargo/bin"
audit_bindir go       "$HOME/go/bin"
audit_bindir deno     "$HOME/.deno/bin"
audit_bindir bun      "$HOME/.bun/bin"
audit_bindir composer "$HOME/.config/composer/vendor/bin"

# npm globals live under the prefix's node_modules, classified by package name.
# @scope packages nest one level deeper. .bin, npm and corepack are not installs.
npm_modules="$HOME/.local/lib/node_modules"
if [ -d "$npm_modules" ]; then
  for e in "$npm_modules"/*; do
    [ -e "$e" ] || continue
    b="$(basename "$e")"
    case "$b" in .bin | npm | corepack) continue ;; esac
    if [ "${b#@}" != "$b" ]; then
      for s in "$e"/*; do
        [ -e "$s" ] && classify npm "$b/$(basename "$s")"
      done
    else
      classify npm "$b"
    fi
  done
fi

# opam is a managed switch, not a bin dir of ad-hoc installs, and its compiler
# binaries deliberately overlap Nix, so the redundant rule does NOT apply. Only
# the explicitly-requested root packages beyond the compiler base are checked,
# against the record alone. No opam, no problem.
if command -v opam >/dev/null 2>&1; then
  opam_base="ocaml ocaml-base-compiler ocaml-compiler ocaml-config ocaml-options-vanilla base-bigarray base-domains base-effects base-nnp base-threads base-unix dune ocamlfind"
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    case " $opam_base " in *" $pkg "*) continue ;; esac
    is_recorded opam "$pkg" || unrecorded+=("opam:$pkg")
  done < <(opam list --installed --roots --short 2>/dev/null)
fi

# ---- report ----------------------------------------------------------------
if [ "${#redundant[@]}" -eq 0 ] && [ "${#unrecorded[@]}" -eq 0 ]; then
  [ "$QUIET" -eq 1 ] || echo "package-audit: clean. Every managed install is in Nix or recorded."
  exit 0
fi

report() {
  echo "package-audit found drift on $(uname -n) at $(date '+%Y-%m-%d %H:%M')."
  echo
  if [ "${#unrecorded[@]}" -gt 0 ]; then
    echo "UNRECORDED (${#unrecorded[@]}), neither in Nix nor in the record."
    echo "Codify it in a Nix module, add it to docs/recorded-packages.txt, or delete it."
    printf '  %s\n' "${unrecorded[@]}" | sort
    echo
  fi
  if [ "${#redundant[@]}" -gt 0 ]; then
    echo "REDUNDANT (${#redundant[@]}), Nix already provides the same binary."
    echo "Delete the manager copy so the flake's version is the only one."
    printf '  %s\n' "${redundant[@]}" | sort
  fi
}

body="$(report)"
echo "$body"

if [ -n "$MAILTO" ]; then
  {
    printf 'To: %s\n' "$MAILTO"
    printf 'Subject: package-audit: %d unrecorded, %d redundant on %s\n\n' \
      "${#unrecorded[@]}" "${#redundant[@]}" "$(uname -n)"
    printf '%s\n' "$body"
  } | msmtp "$MAILTO" 2>/dev/null || echo "package-audit: mail to $MAILTO failed" >&2
fi

exit 1
