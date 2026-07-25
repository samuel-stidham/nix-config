# lib-build.sh - build the activation package from a copy of the working tree.
#
# SOURCED, NEVER EXECUTED. It defines build_out and nothing else. Callers set
# REPO and ATTR first.
#
# The copy exists because flakes ignore untracked files and this repo carries
# them on purpose. Building $REPO in place evaluates a tree missing whatever is
# unstaged, so a test would gate a config nobody has.
#
# THE `git add -A` BELOW IS SAFE ONLY BECAUSE OF WHERE IT RUNS. It stages inside
# the throwaway copy's own index, which is deleted seconds later. The identical
# command in $REPO would stage the files that are untracked on purpose. Never
# lift it out of the copy.
#
# This lives in one file because it used to live in two. A subtlety like the
# line above gets fixed in one copy and not the other, and the copy that still
# swallows the Nix error is the one someone debugs at 3am.

build_out() {
  local tmp out err
  tmp="$(mktemp -d)"
  err="$tmp/build.err"
  cp -a "$REPO"/. "$tmp"/
  ( cd "$tmp" && git add -A ) >/dev/null 2>&1
  out="$( cd "$tmp" && nix build "$ATTR" --no-link --print-out-paths 2>"$err" | head -1 )"
  # Surface the Nix error on failure instead of swallowing it. The old 2>/dev/null
  # left a failed build reporting only "produced no path" with no cause.
  if [ -z "$out" ]; then
    echo "build_out: nix build failed, stderr follows:" >&2
    cat "$err" >&2
  fi
  rm -rf "$tmp"
  printf '%s' "$out"
}
