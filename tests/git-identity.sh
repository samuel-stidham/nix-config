#!/usr/bin/env bash
#
# git-identity.sh - assert that the DIRECTORY decides the git and ssh identity.
#
# WHY A GOLDEN COULD NOT CATCH THIS. hm-output.sh already captured ~/.ssh/config
# and both identity files, and it captured the regression with them. The ssh
# config moved into nix as one github.com block with no IdentityFile, the golden
# was recaptured on that tree, and "no key is named for github.com" became the
# expected output. ssh then chose by agent order, and a push from
# ~/Code/samuel-stidham authenticated as the other account:
#
#   ERROR: Permission to samuel-stidham/nix-config.git denied to dqfan2012
#
# A golden records what IS. This records what MUST BE TRUE. Only the second kind
# fails on the commit that introduces the bug, which is the whole difference.
#
# IT RESOLVES THROUGH REAL GIT, ON PURPOSE. Reading the generated files and
# matching strings would test this file's idea of includeIf instead of git's.
# gitdir patterns, trailing slashes and case folding are git's to interpret, so
# a real repo is created inside each tree and git is asked what it resolved.
#
# It builds the activation package, so it gates the REPO rather than the
# switched machine. An edit that is correct here but not switched in still
# passes. That split is deliberate: run.sh gates the tree, home-manager switch
# gates the box.
#
#   ./git-identity.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ATTR='.#homeConfigurations."samuelstidham@x86_64-linux".activationPackage'
# shellcheck source=lib-build.sh
. "$HERE/lib-build.sh"

CODE="$HOME/Code"

# tree | expected email | expected ssh key. ~/Code is laid out by GitHub
# account, so a new account is one row here plus one includeIf rule in
# home/secrets.nix. Add the row without the rule and this test says so.
ACCOUNTS=(
  "samuel-stidham|samuel.stidham@snhu.edu|$HOME/.ssh/id_ed25519_snhu"
  "dqfan2012|dqfan2012@gmail.com|$HOME/.ssh/id_ed25519_github_personal"
)

# Trees under ~/Code that hold no account repos and are meant to carry no rule.
# A tree that is in neither list takes the global identity in silence, which is
# the failure this file exists for. A name here is a decision someone made.
NO_ACCOUNT=( sandbox )

fail=0
ok()  { printf 'ok    %-30s %s\n' "$1" "${2:-}"; }
bad() { printf 'FAIL  %-30s %s\n' "$1" "$2"; fail=1; }

out="$(build_out)"
if [ -z "$out" ] || [ ! -e "$out" ]; then
  echo "git-identity: nix build produced no path" >&2
  exit 1
fi
FILES="$out/home-files"

TMP="$(mktemp -d)"
WORKTREES=()
cleanup() {
  rm -rf "$TMP"
  [ "${#WORKTREES[@]}" -gt 0 ] && rm -rf "${WORKTREES[@]}"
}
trap cleanup EXIT

# The generated config includes each identity file by absolute path under
# ~/.config/git, which resolves to whatever was last switched in. Repoint those
# at the built copies, so what is under test is this tree and not last night.
GITCONFIG="$TMP/gitconfig"
sed "s#$HOME/.config/git/identity-#$FILES/.config/git/identity-#g" \
  "$FILES/.config/git/config" > "$GITCONFIG"

# GIT_CONFIG_SYSTEM is silenced too. /etc/gitconfig is not managed by this repo,
# so letting it reach the assertions would make the result depend on the distro.
resolve() { GIT_CONFIG_GLOBAL="$GITCONFIG" GIT_CONFIG_SYSTEM=/dev/null \
            git -C "$1" config --get "$2" 2>/dev/null; }

seen_keys=""
for row in "${ACCOUNTS[@]}"; do
  IFS='|' read -r acct email key <<< "$row"
  tree="$CODE/$acct"

  if [ ! -d "$tree" ]; then
    bad "$acct" "no tree at $tree"
    continue
  fi

  # A real repo inside the real tree. The includeIf condition matches on the
  # gitdir path, so a repo anywhere else proves nothing about this one.
  work="$(mktemp -d "$tree/.git-identity-XXXXXX")"
  WORKTREES+=("$work")
  git init -q "$work" 2>/dev/null

  got="$(resolve "$work" user.email)"
  if [ "$got" = "$email" ]; then
    ok "$acct email" "$got"
  else
    bad "$acct email" "want [$email] got [$got]"
  fi

  ssh_cmd="$(resolve "$work" core.sshCommand)"
  if [ -z "$ssh_cmd" ]; then
    bad "$acct ssh key" "no core.sshCommand, ssh will pick by agent order"
  elif [[ "$ssh_cmd" != *"-i $key"* ]]; then
    bad "$acct ssh key" "want [-i $key] got [$ssh_cmd]"
  else
    ok "$acct ssh key" "$key"
  fi

  # IdentitiesOnly is load bearing, not decoration. Without it ssh offers every
  # agent key and the wrong one authenticates before the -i key is tried, which
  # is the original bug wearing a fix.
  if [[ "$ssh_cmd" == *"IdentitiesOnly=yes"* ]]; then
    ok "$acct IdentitiesOnly" "yes"
  else
    bad "$acct IdentitiesOnly" "absent, the agent can still answer first"
  fi

  # The repo names a path. The machine has to hold it, or the push dies with
  # "no such identity" at a point far from this config.
  if [ -f "$key" ]; then
    ok "$acct key present" "$key"
  else
    bad "$acct key present" "no file at $key"
  fi

  case "$seen_keys" in
    *"|$key|"*) bad "$acct key unique" "already used by another account" ;;
    *) seen_keys="$seen_keys|$key|" ;;
  esac
done

# The shared github.com block must name no IdentityFile. One host block holds
# one key, so a key named there answers for every repo on the box, and the tree
# stops deciding anything. Scoped to the github.com block, because an unrelated
# host is free to name its own key.
gh_block="$(awk '/^[[:space:]]*Host /{inb = ($2 == "github.com")} inb' "$FILES/.ssh/config")"
if [ -z "$gh_block" ]; then
  bad "ssh github.com block" "no Host github.com block in the generated config"
elif printf '%s\n' "$gh_block" | grep -qiE '^[[:space:]]*IdentityFile'; then
  bad "ssh github.com block" "names an IdentityFile, which outranks no tree"
else
  ok "ssh github.com block" "no IdentityFile, the tree decides"
fi

# A tree nobody claimed gets the global identity and agent-order keys, silently.
# Catching it here turns a wrong commit author into a failed test.
for d in "$CODE"/*/; do
  name="$(basename "$d")"
  claimed=0
  for row in "${ACCOUNTS[@]}"; do
    [ "${row%%|*}" = "$name" ] && claimed=1
  done
  for n in "${NO_ACCOUNT[@]}"; do
    [ "$n" = "$name" ] && claimed=1
  done
  if [ "$claimed" = 1 ]; then
    continue
  fi
  bad "unclaimed tree $name" "no identity rule, and not listed as account-free"
done

printf '\n'
if [ "$fail" = 0 ]; then
  echo "git-identity: all cases passed"
else
  echo "git-identity: FAILURES above"
fi
exit $fail
