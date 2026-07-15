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

# Everything a full backup captures. Adjust to taste.
BACKUP_PATHS=(
  "$MC_DIR"
  "$HOME/Calibre Library"
  "$HOME/forgejo/forgejo-data"
  "$HOME/.local/share/safetybox/vault.db"
  "$HOME/.config/safetybox/identity.age"
  "$HOME/.passage"
)

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
    sb_restic backup --verbose "${BACKUP_PATHS[@]}"
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
