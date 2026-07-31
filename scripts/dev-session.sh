#!/usr/bin/env bash
#
# dev-session.sh - the command a fresh Ghostty window opens into, and the body of
# the `servers` fish function. Attaches to the dev zellij session when it is
# alive, otherwise builds a fresh one from the `servers` layout: tab one a 2x2
# grid, tab two a single full-window pane.
#
# WHY THIS IS NOT JUST `zellij -n servers`
#
# That was the old `servers` fish function, and it passes no session name, so
# zellij invents one. Every launch therefore built a NEW session rather than
# returning to the existing one. Six dead ones had piled up before this was
# written (cubic-newt, verdant-magpie, erudite-zebra, effulgent-iguanadon,
# kind-galaxy, tremendous-capsicum), the oldest 25 days old.
#
# That was survivable while a human typed `servers` occasionally. It is not
# survivable wired into Ghostty startup, where every new terminal would boot
# another copy of the services and sites stacks and they would fight over ports.
# Naming the session is what makes the second launch return instead of duplicate.
#
# THE OBVIOUS FIX THAT DOES NOT WORK
#
# `zellij attach --create servers` looks exactly right and is wrong. `attach` has
# no --layout flag (0.44.3: -b, -c, -f, --forget, --index, -r, -t and the TLS
# ones, that is the whole list). So the session it creates gets the DEFAULT
# layout, one bare pane, and the 2x2 never appears. The layout can only be
# supplied at creation time, through -n, which is why this splits into two paths.
#
# THE SECOND OBVIOUS FIX THAT ALSO DOES NOT WORK
#
# `zellij list-sessions --short | grep -qx servers` to test whether the session
# exists. --short prints dead sessions in exactly the same form as live ones: all
# six corpses above are listed by --short with no marker distinguishing them.
# Only the long form carries "(EXITED - attach to resurrect)". Testing existence
# rather than LIVENESS means attaching to a corpse, which resurrects stale panes
# instead of building the layout, and does not rerun the stacks without -f.
set -euo pipefail

# Overridable so this is testable against a throwaway session without touching
# the real one. Defaults are the pair the Ghostty config and fish function use.
SESSION="${DEV_SESSION_NAME:-servers}"
LAYOUT="${DEV_SESSION_LAYOUT:-servers}"

# Nested zellij is a broken state: the inner session captures the prefix key and
# neither responds properly. Refuse rather than produce it. Exiting nonzero here
# is safe because when run by hand this is a child of the pane's shell, so the
# prompt survives; the Ghostty path never has ZELLIJ set.
if [ -n "${ZELLIJ:-}" ]; then
  echo "Already inside zellij. Run this from a plain terminal." >&2
  exit 1
fi

# Live sessions only, by stripping the EXITED lines before taking the name field.
#
# Built as a variable rather than piped straight into `grep -q` on purpose. With
# `set -o pipefail`, `grep -q` exits at the first match and closes the pipe, the
# upstream process dies of SIGPIPE with 141, and pipefail then reports 141 for a
# pipeline that actually SUCCEEDED. The match would be read as a miss and a live
# session would get duplicated. The herestring below has no pipeline to poison.
#
# `|| true` because grep -v exits 1 when every session is dead, which is the
# ordinary cold-boot case, not an error.
live="$(zellij list-sessions --no-formatting 2>/dev/null | grep -v '(EXITED' | awk '{print $1}' || true)"

if grep -qxF "$SESSION" <<<"$live"; then
  # Deliberately not exec: see the fallback at the bottom.
  zellij attach "$SESSION" && exit 0
else
  # A dead session of this name would block creation, so clear it first. It is
  # already known dead, the liveness test above is what put us on this branch.
  # `|| true` covers the common case of there being nothing to delete.
  zellij delete-session "$SESSION" >/dev/null 2>&1 || true
  zellij --new-session-with-layout "$LAYOUT" --session "$SESSION" && exit 0
fi

# FALLBACK. Reached only when zellij exited nonzero, e.g. a malformed layout.
#
# This matters because this script is Ghostty's initial-command. Without it, a
# broken layout means the window opens, zellij dies, the surface closes, and with
# quit-after-last-window-closed the whole terminal vanishes before the error can
# be read. Dropping to a shell keeps the window and the message on screen.
echo >&2
echo "zellij exited nonzero (layout '$LAYOUT', session '$SESSION')." >&2
echo "Dropping to a shell so this window stays open." >&2
exec "${SHELL:-/bin/sh}"
