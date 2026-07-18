#!/usr/bin/env bash
#
# backup.sh - restic backups to AWS S3. One tool covers Minecraft worlds and
# JourneyMap, the Calibre library, the Forgejo data, and the safetybox vault.
#
# Secrets never touch disk or the environment from this file. The restic
# password and the AWS keys come from the safetybox vault, unlocked by the
# passphrase that passage holds. safetybox exec injects them only for the child
# restic process.
#
# Required safetybox entries, set once with these exact env names:
#   printf '%s' "$PW"  | safetybox set global/restic-password      --env-name RESTIC_PASSWORD
#   printf '%s' "$AKID"| safetybox set global/aws-access-key-id    --env-name AWS_ACCESS_KEY_ID
#   printf '%s' "$SAK" | safetybox set global/aws-secret-access-key --env-name AWS_SECRET_ACCESS_KEY
#
# Usage:
#   ./backup.sh init                 # one-time repo creation
#   ./backup.sh backup               # snapshot every path below
#   ./backup.sh mc-backup            # Minecraft only, refuses if it is running
#   ./backup.sh mc-restore           # restore latest Minecraft snapshot in place
#   ./backup.sh snapshots            # list snapshots
#   ./backup.sh restore <id> <dir>   # restore a snapshot to a target dir
set -euo pipefail

# The shared drive-mount resolver. backup.sh is hand-run from the checkout, never
# readFile'd into the Nix store, so sourcing the sibling is safe here. drive_mount
# answers where a labelled drive IS right now, which is /media on this Ubuntu box,
# /run/media on Fedora and SUSE, and /var/mnt on Bazzite. See its header for why a
# single hardcoded /media/$USER path was wrong on every family but this one.
. "$(dirname "${BASH_SOURCE[0]}")/drive-mount.sh"

# ---- config. This bucket is provisioned by the infra-backups OpenTofu repo.
# It is separate from samuelstidham-backups, which is the website's Litestream
# and archive bucket. ----
BUCKET="${RESTIC_BUCKET:-samuelstidham-restic}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export RESTIC_REPOSITORY="s3:s3.${REGION}.amazonaws.com/${BUCKET}"
export AWS_DEFAULT_REGION="$REGION"

# Minecraft lives with the Nix PrismLauncher at the first path below. On Bazzite
# PrismLauncher is the Flatpak and its data is at the second path, which the old
# single default ignored, so mc-backup there snapshotted an absent directory and
# still exited 0. Probe for the first path that exists rather than branch on the
# distro, and fall back to the Nix path so mc_running and mc-backup still have a
# target on a machine where no instance has been created yet. MC_DIR in the
# environment overrides the probe.
MC_DIR="${MC_DIR:-}"
if [ -z "$MC_DIR" ]; then
  for _mc_candidate in \
    "$HOME/.local/share/PrismLauncher/instances" \
    "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances"; do
    if [ -d "$_mc_candidate" ]; then
      MC_DIR="$_mc_candidate"
      break
    fi
  done
  MC_DIR="${MC_DIR:-$HOME/.local/share/PrismLauncher/instances}"
fi

# The Firefox profile. This is Tier 1 and easy to miss: Firefox Sync carries
# bookmarks, history, and the list of add-ons, but NOT each extension's own
# configuration. Simple Tab Groups' groups, the Multi-Account Container
# assignments, and uBlock's settings live only here. Backing up the profile is
# what actually makes Firefox come back identical, with no export/import dance.
#
# The old default was the snap path, which exists only where Firefox is a snap,
# meaning Ubuntu and Pop. On Debian, Mint, Fedora, SUSE and Bazzite that directory
# is absent, so restic warned about the snap path the operator never had and the
# real profile was never a backup target. That is the worst kind of miss: the
# warning points at the wrong thing while Tier 1 data goes uncaptured. The probe in
# resolve_backup_paths tries snap, then Flatpak, then the native path, and fails
# loudly if none exist rather than hand restic a phantom path. FIREFOX_PROFILE in
# the environment overrides the probe.
FIREFOX_PROFILE="${FIREFOX_PROFILE:-}"

# The Calibre library lives on StoragePrime, not the nvme. It is still Tier 1 and
# still backed up: StoragePrime survives a reinstall, but it does not survive a
# drive failure, and the library is irreplaceable.
#
# The old default hardcoded /media/samuelstidham/StoragePrime, which is Ubuntu's
# udisks path with a username baked in. Fedora and SUSE mount at /run/media/$USER
# and Bazzite at /var/mnt, so on every family but this one the literal named a
# directory that does not exist and the library was silently omitted. The mount
# point is resolved at backup time through drive_mount instead, in
# resolve_backup_paths, so the path follows the drive on whatever family this is.
#
# Keep this in step with Calibre's own library_path in
# ~/.config/calibre/global.py.json. If they drift, restic keeps backing up an
# empty or stale directory and nobody notices until a restore. CALIBRE_LIBRARY in
# the environment overrides the resolver.
CALIBRE_LIBRARY="${CALIBRE_LIBRARY:-}"

# Tier 1 only: the irreplaceable set. Everything else is rebuilt by bootstrap.sh,
# home-manager, and steam-restore.sh, or lives on WorkDrive which a reinstall
# never touches. See "Machine File Structure" in the obsidian vault.
#
# Built in a function, not at file scope, on purpose. Resolving CALIBRE_LIBRARY and
# FIREFOX_PROFILE can abort when StoragePrime is not mounted or no Firefox profile
# exists, and that abort is correct for backup: omitting an irreplaceable set
# silently is the worse outcome. But it must NOT block the read-only subcommands,
# so snapshots, restore, forget, init, mc-backup and mc-restore never call this and
# run without the drive. Only backup does.
resolve_backup_paths() {
  # The Firefox profile. First existing candidate wins: snap (Ubuntu, Pop), then
  # Flatpak (Bazzite and others), then the native RPM or deb path. An explicit
  # FIREFOX_PROFILE skips the probe. Fail loud if nothing is found, rather than
  # feed restic a phantom path that it would warn about and skip.
  if [ -z "$FIREFOX_PROFILE" ]; then
    for _ff_candidate in \
      "$HOME/snap/firefox/common/.mozilla/firefox" \
      "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" \
      "$HOME/.mozilla/firefox"; do
      if [ -d "$_ff_candidate" ]; then
        FIREFOX_PROFILE="$_ff_candidate"
        break
      fi
    done
  fi
  if [ -z "$FIREFOX_PROFILE" ]; then
    echo "No Firefox profile found at the snap, Flatpak, or native path." >&2
    echo "Set FIREFOX_PROFILE to its location, or launch Firefox once." >&2
    exit 1
  fi

  # The Calibre library mountpoint. drive_mount prints where StoragePrime IS and
  # returns nonzero when it is not mounted. Under set -e a bare assignment would
  # abort with no word, so declare first, assign second, and catch the failure to
  # say why. An explicit CALIBRE_LIBRARY skips the resolver.
  if [ -z "$CALIBRE_LIBRARY" ]; then
    local _sp_root
    _sp_root="$(drive_mount StoragePrime)" || {
      echo "StoragePrime is not mounted, so the Calibre library cannot be found." >&2
      echo "Refusing to run a backup that would silently omit it. Mount the drive," >&2
      echo "or set CALIBRE_LIBRARY to override." >&2
      exit 1
    }
    CALIBRE_LIBRARY="$_sp_root/Books/Calibre Library"
  fi

  BACKUP_PATHS=(
    "$HOME/code"                 # all source. the whole point
    "$HOME/Documents"            # Education, Employment, Vital, obsidian-vaults
    "$CALIBRE_LIBRARY"           # library + metadata.db
    "$HOME/forgejo"              # critical infra: stack, repos, DB, runner config
    "$HOME/sites"                # the *.test project roots
    "$MC_DIR"                    # worlds + journeymap + the exact mod versions
    "$FIREFOX_PROFILE"           # extension configs Sync does not carry
    "$HOME/Desktop"              # safety net. Should be near empty after the reorg
    "$HOME/Sync"                 # syncthing: SNHU coursework + library, see docs/sync.md
    # XDG defaults, not hardcoded. safetybox reads $XDG_DATA_HOME and
    # $XDG_CONFIG_HOME, so a machine that relocates either would drop the two files
    # every other secret is recovered from. These two are the whole vault.
    "${XDG_DATA_HOME:-$HOME/.local/share}/safetybox/vault.db"
    "${XDG_CONFIG_HOME:-$HOME/.config}/safetybox/identity.age"
    "$HOME/.passage"
    "$HOME/.ssh"
    "$HOME/.gnupg"
  )
}

# Junk that must never enter a snapshot, even from inside the paths above.
EXCLUDES=(
  --exclude "$HOME/Documents/Minecraft Backup"   # 18G, superseded by mc-backup
  --exclude '*/node_modules'
  --exclude '*/.terraform'
  --exclude '*/target'                          # rust build output
  # The raw forgejo data is owned by a podman subuid and is unreadable here.
  # forgejo_archive() captures it as forgejo-data.tar instead, which IS readable.
  --exclude "$HOME/forgejo/forgejo-data"
  # Syncthing's own history and folder markers. .stversions is a second copy of
  # every file syncthing ever replaced or deleted, which is exactly what restic
  # snapshots already are. Backing it up would store that history twice.
  --exclude '*/.stversions'
  --exclude '*/.stfolder'
)

# Forgejo keeps its metadata in a live SQLite database: users, issues, PRs,
# webhooks, Actions secrets, and the push mirror config. The git repos are
# mirrored to GitHub, but none of that metadata is, so the database is the
# irreplaceable part.
#
# Copying a live SQLite file can capture a torn write, which restores to a corrupt
# Forgejo. Stopping the stack for the run is the simple, unambiguous fix: nothing
# is writing, so the files on disk are coherent by definition. This machine is
# single user, so the downtime costs nothing.
# podman ships compose two ways. The Python podman-compose script is one binary on
# PATH. The newer Go `podman compose` is a subcommand of podman itself. Ubuntu
# tends to package the script, and Fedora and SUSE lean toward the subcommand, so
# probing only for podman-compose skipped the quiesce on a machine where the stack
# runs fine through the subcommand. That skip was silent, and the next line tarred
# a live SQLite database, which is the torn write this whole dance exists to avoid.
# Print whichever implementation exists, or return 1 with nothing.
forgejo_compose_impl() {
  if command -v podman-compose >/dev/null 2>&1; then
    printf 'podman-compose\n'
    return 0
  fi
  if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    printf 'podman compose\n'
    return 0
  fi
  return 1
}

forgejo_stop() {
  [ -d "$HOME/forgejo" ] || return 0
  local compose
  compose="$(forgejo_compose_impl)" || {
    echo "The forgejo stack is present but neither podman-compose nor" >&2
    echo "'podman compose' is available. Refusing to archive a live SQLite" >&2
    echo "database, which can capture a torn write. Install a compose front end." >&2
    exit 1
  }
  # $compose is "podman-compose" or the two words "podman compose", so it must
  # word-split. That is the one place unquoted expansion is intended here.
  # shellcheck disable=SC2086
  (cd "$HOME/forgejo" && $compose down >/dev/null 2>&1) && echo "forgejo stack stopped"
}

forgejo_start() {
  [ -d "$HOME/forgejo" ] || return 0
  local compose
  compose="$(forgejo_compose_impl)" || return 0
  # direnv exec loads the passage-backed secrets the compose file interpolates.
  # shellcheck disable=SC2086
  (cd "$HOME/forgejo" && direnv exec . $compose up -d >/dev/null 2>&1) && echo "forgejo stack started"
}

# Forgejo runs as uid 1000 INSIDE its container, which rootless podman maps to a
# subuid on the host (100999, from the 100000:65536 range in /etc/subuid). Those
# files are therefore owned by a uid this user is not, and several are 0700:
#
#   forgejo-data/gitea/jwt/private.pem
#   forgejo-data/gitea/actions_id_token/private.pem
#   forgejo-data/git/.ssh              <- forgejo's ssh host keys
#   forgejo-data/gitea/sessions, indexers
#
# A plain restic run cannot read them and exits 3, silently omitting the signing
# keys and host keys. Restoring that would invalidate every session and token and
# hand out new ssh host keys.
#
# The fix is to archive forgejo-data from inside that same user namespace.
#
# podman unshare re-enters the namespace, where those files map back to this user,
# so tar can read them. It also solves a subtler problem: tar records the
# namespace-relative uid, and untarring inside the namespace maps it back to
# 100999 on the host. The round trip preserves ownership exactly.
#
# Reading with `podman unshare restic` would NOT do that: restic would record uid
# 1000, restore would write files owned by this user, and forgejo (running as
# 100999) could not read its own data. It would look fine and be broken.
#
# The archive is UNCOMPRESSED on purpose. restic already dedups and compresses in
# the repo. A gzip stream changes wholesale on any edit, which defeats both.
# forgejo-data is only ~49M, so this costs nothing.
FORGEJO_DATA="$HOME/forgejo/forgejo-data"
FORGEJO_ARCHIVE="$HOME/forgejo/forgejo-data.tar"

forgejo_archive() {
  [ -d "$FORGEJO_DATA" ] || return 0
  if ! command -v podman >/dev/null 2>&1; then
    echo "podman not found, cannot archive forgejo-data safely." >&2
    return 1
  fi
  podman unshare tar -cf "$FORGEJO_ARCHIVE" -C "$HOME/forgejo" forgejo-data
  # The archive is written as namespace root, which maps to this user on the
  # host, so restic can read it without any further help.
  echo "forgejo-data archived: $(du -h "$FORGEJO_ARCHIVE" 2>/dev/null | cut -f1)"
}

# Restore is the mirror image, and MUST go through unshare too:
#   podman unshare tar -xf ~/forgejo/forgejo-data.tar -C ~/forgejo

# ---- helpers ----
# Run restic with its secrets injected from the vault. The passphrase is fed
# through a process substitution, so it is never a file on disk.
sb_restic() {
  safetybox exec --passphrase-file <(passage show safetybox/passphrase) -- restic "$@"
}

mc_running() {
  pgrep -fi 'prismlauncher|net\.minecraft|minecraft.*\.jar' >/dev/null 2>&1
}

case "${1:-}" in
  init)
    sb_restic init
    ;;
  backup)
    # Resolve the Tier 1 set first. This aborts loudly if StoragePrime is not
    # mounted or no Firefox profile exists, before anything is stopped, so a
    # missing library never turns into forgejo left down.
    resolve_backup_paths
    # Quiesce forgejo so its SQLite database is coherent on disk, archive its
    # subuid-owned data while it is still, and bring it back up no matter how
    # restic exits. The trap is armed BEFORE the stop, not after: forgejo_stop can
    # fail partway, and under set -e that abort used to skip the trap and leave the
    # stack down with no restart. Arming first means any exit path restarts it.
    trap forgejo_start EXIT
    forgejo_stop
    forgejo_archive
    sb_restic backup --verbose "${EXCLUDES[@]}" "${BACKUP_PATHS[@]}"
    ;;
  mc-backup)
    if mc_running; then
      echo "Minecraft or PrismLauncher is running. Close it first, a live save can corrupt." >&2
      exit 1
    fi
    sb_restic backup --tag minecraft --verbose "$MC_DIR"
    ;;
  mc-restore)
    if mc_running; then
      echo "Close Minecraft or PrismLauncher first." >&2
      exit 1
    fi
    # restic stores absolute paths. --target / restores them to their original
    # location, recreating the instances directory.
    sb_restic restore latest --tag minecraft --target /
    ;;
  snapshots)
    sb_restic snapshots
    ;;
  restore)
    shift
    [ $# -eq 2 ] || { echo "usage: ./backup.sh restore <snapshot-id> <target-dir>" >&2; exit 1; }
    sb_restic restore "$1" --target "$2"
    ;;
  # Age out old snapshots, then reclaim the blobs nothing references any more.
  #
  # forget alone only removes the snapshot POINTER, it does not free a single
  # byte in S3. --prune is what actually deletes unreferenced data, and it is
  # the reason this is one subcommand rather than a raw restic invocation.
  #
  # Run `./backup.sh forget` first. It is a DRY RUN and prints exactly which
  # snapshots would go. Only `./backup.sh forget --apply` destroys anything.
  # This asymmetry is deliberate: forget is the one irreversible operation here,
  # a snapshot removed is a restore path that no longer exists.
  #
  # The policy keeps more than feels necessary on purpose, because dedup makes
  # history nearly free. A 92 GiB backup added 405 MiB to the repo, since the
  # unchanged blobs are shared with every earlier snapshot. Keeping a year of
  # monthlies costs a rounding error and buys "restore it as it was in March".
  forget)
    shift
    POLICY=(--keep-last 3 --keep-daily 7 --keep-weekly 4 --keep-monthly 12)
    if [ "${1:-}" = "--apply" ]; then
      echo "forgetting snapshots outside the policy, then pruning ..."
      sb_restic forget "${POLICY[@]}" --prune
    else
      echo "DRY RUN. Nothing is removed. Re-run with --apply to actually forget."
      echo "policy: ${POLICY[*]}"
      echo
      sb_restic forget "${POLICY[@]}" --dry-run
    fi
    ;;
  *)
    echo "usage: ./backup.sh {init|backup|mc-backup|mc-restore|snapshots|restore <id> <dir>|forget [--apply]}" >&2
    exit 1
    ;;
esac
