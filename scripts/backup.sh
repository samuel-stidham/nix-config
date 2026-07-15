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

# ---- config. This bucket is provisioned by the infra-backups OpenTofu repo.
# It is separate from samuelstidham-backups, which is the website's Litestream
# and archive bucket. ----
BUCKET="${RESTIC_BUCKET:-samuelstidham-restic}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export RESTIC_REPOSITORY="s3:s3.${REGION}.amazonaws.com/${BUCKET}"
export AWS_DEFAULT_REGION="$REGION"

# Minecraft lives here with the Nix PrismLauncher. For the Flatpak build it is
# ~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances, so set
# MC_DIR in the environment on Bazzite.
MC_DIR="${MC_DIR:-$HOME/.local/share/PrismLauncher/instances}"

# The Firefox profile. This is Tier 1 and easy to miss: Firefox Sync carries
# bookmarks, history, and the list of add-ons, but NOT each extension's own
# configuration. Simple Tab Groups' groups, the Multi-Account Container
# assignments, and uBlock's settings live only here. Backing up the profile is
# what actually makes Firefox come back identical, with no export/import dance.
#
# On Bazzite this becomes the Flatpak path, so override it there:
#   ~/.var/app/org.mozilla.firefox/.mozilla/firefox
FIREFOX_PROFILE="${FIREFOX_PROFILE:-$HOME/snap/firefox/common/.mozilla/firefox}"

# Tier 1 only: the irreplaceable set. Everything else is rebuilt by bootstrap.sh,
# home-manager, and steam-restore.sh, or lives on WorkDrive which a reinstall
# never touches. See "Machine File Structure" in the obsidian vault.
BACKUP_PATHS=(
  "$HOME/code"                 # all source. the whole point
  "$HOME/Documents"            # Education, Employment, Vital, obsidian-vaults
  "$HOME/Calibre Library"      # library + metadata.db
  "$HOME/forgejo"              # critical infra: stack, repos, DB, runner config
  "$HOME/sites"                # the *.test project roots
  "$MC_DIR"                    # worlds + journeymap + the exact mod versions
  "$FIREFOX_PROFILE"           # extension configs Sync does not carry
  "$HOME/Desktop"              # safety net. Should be near empty after the reorg
  "$HOME/.local/share/safetybox/vault.db"
  "$HOME/.config/safetybox/identity.age"
  "$HOME/.passage"
  "$HOME/.ssh"
  "$HOME/.gnupg"
)

# Junk that must never enter a snapshot, even from inside the paths above.
EXCLUDES=(
  --exclude "$HOME/Documents/Minecraft Backup"   # 18G, superseded by mc-backup
  --exclude '*/node_modules'
  --exclude '*/.terraform'
  --exclude '*/target'                          # rust build output
  # The raw forgejo data is owned by a podman subuid and is unreadable here.
  # forgejo_archive() captures it as forgejo-data.tar instead, which IS readable.
  --exclude "$HOME/forgejo/forgejo-data"
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
forgejo_stop() {
  [ -d "$HOME/forgejo" ] || return 0
  command -v podman-compose >/dev/null 2>&1 || return 0
  (cd "$HOME/forgejo" && podman-compose down >/dev/null 2>&1) && echo "forgejo stack stopped"
}

forgejo_start() {
  [ -d "$HOME/forgejo" ] || return 0
  command -v podman-compose >/dev/null 2>&1 || return 0
  # direnv exec loads the passage-backed secrets the compose file interpolates.
  (cd "$HOME/forgejo" && direnv exec . podman-compose up -d >/dev/null 2>&1) && echo "forgejo stack started"
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
    # Quiesce forgejo so its SQLite database is coherent on disk, archive its
    # subuid-owned data while it is still, and bring it back up no matter how
    # restic exits.
    forgejo_stop
    trap forgejo_start EXIT
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
  *)
    echo "usage: ./backup.sh {init|backup|mc-backup|mc-restore|snapshots|restore <id> <dir>}" >&2
    exit 1
    ;;
esac
