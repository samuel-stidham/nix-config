#!/usr/bin/env bash
#
# retag-education-import.sh - repair the tags organize-education.sh failed to set.
#
# WHY THIS EXISTS
#
# organize-education.sh imported the Education collections with:
#
#   calibredb add -r "$dir" --tags "$tag"
#
# That silently does not work. `calibredb add` accepts --tags, and it honours it
# when adding a SINGLE FILE, but when adding a directory with -r it reads the
# metadata out of each file and discards the command line metadata options. No
# error, no warning, exit code 0. The books land in the library untagged.
#
# The proof is in the same run: the loose-book loop and the Godot force-add both
# added one file at a time and their tags (Unsorted, Purchased) applied fine.
# Only the eight -r imports came out bare.
#
# So the books are all safely in the library. Only the labels are missing, and
# re-adding them would just be refused as duplicates. This tags them in place.
#
# HOW THE IDS WERE ESTABLISHED
#
# calibredb prints "Added book ids: ..." for every add. Those lines are in the
# import log, one group per import_dir call, in script order. Each range below
# was then VERIFIED by reading the titles back out of the database and checking
# them against the folder they claim to come from (Obojima -> TTRPGs, Precalculus
# -> Math, and so on). The ranges are not inferred from the folder file counts,
# which do not match: calibre skips files it cannot parse and merges some, so
# "21 files in Herbalism" and "21 ids" agreeing is a coincidence worth ignoring.
#
# TAGS ARE MERGED, NOT REPLACED
#
# `calibredb set_metadata --field tags:"X"` REPLACES the whole tag list. Several
# of these books carry real tags from their own embedded metadata (Programming,
# refactoring, SOLID principles). Overwriting those to say "Computer Science"
# would destroy information the file shipped with. So each book's current tags
# are read first and the new tag is unioned in. Running this twice is a no-op.
#
# Usage:
#   ./retag-education-import.sh            # dry run, changes nothing
#   ./retag-education-import.sh --apply
set -uo pipefail

# StoragePrime has no fixed path across families. See scripts/drive-mount.sh. The
# old literal /media/samuelstidham/StoragePrime is Ubuntu's udisks path and it
# hardcodes a username. Upstream udisks and the other families use
# /run/media/$USER/LABEL, and a fresh machine pins it in fstab at
# /mnt/StoragePrime. Probe for where the drive IS instead of branching on family.
# ${SP:+...} leaves LIB empty when the drive is absent so the guard below reports
# it clearly rather than testing /metadata.db.
. "$(dirname "${BASH_SOURCE[0]}")/drive-mount.sh"
SP="$(drive_mount StoragePrime)" || SP=""

LIB="${CALIBRE_LIBRARY:-${SP:+$SP/Books/Calibre Library}}"
DB="$LIB/metadata.db"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

if ! command -v calibredb >/dev/null 2>&1; then
  echo "calibredb not on PATH" >&2; exit 1
fi
if [ -z "$LIB" ]; then
  echo "StoragePrime not mounted and CALIBRE_LIBRARY unset" >&2; exit 1
fi
if [ ! -f "$DB" ]; then
  echo "no library at $LIB" >&2; exit 1
fi

# calibredb takes a write lock. If the GUI is open it will either block or fight
# us, and a half applied tag run is worse than no tag run.
if pgrep -x calibre >/dev/null 2>&1; then
  echo "The Calibre GUI is running. Close it first, it holds the library lock." >&2
  exit 1
fi

# range:tag. Verified by title against the source folder, see the header.
RANGES=(
  "1118:1138:Herbalism"
  "1139:1156:TTRPGs"
  "1157:1163:Cicero"
  "1164:1178:Vaesen"
  "1179:1180:Harvard Classics"
  "1181:1192:Math"
  "1193:1199:Icelandic"
  "1200:1237:Computer Science"
)

changed=0
skipped=0

for spec in "${RANGES[@]}"; do
  lo="${spec%%:*}"; rest="${spec#*:}"
  hi="${rest%%:*}"; tag="${rest#*:}"

  ids="$(sqlite3 -readonly "file:$DB?immutable=1" \
    "select id from books where id between $lo and $hi order by id;" 2>/dev/null)"

  n="$(printf '%s\n' "$ids" | grep -c . )"
  echo "=== $tag  (ids $lo-$hi, $n books) ==="

  for id in $ids; do
    cur="$(sqlite3 -readonly "file:$DB?immutable=1" \
      "select coalesce(group_concat(t.name,','),'')
       from books_tags_link l join tags t on t.id=l.tag where l.book=$id;" 2>/dev/null)"

    # Already carries the tag, leave it completely alone. This is what makes the
    # script safe to re-run.
    if printf '%s' "$cur" | tr ',' '\n' | grep -qxF "$tag"; then
      skipped=$((skipped+1))
      continue
    fi

    if [ -n "$cur" ]; then new="$cur,$tag"; else new="$tag"; fi

    if [ "$APPLY" = 1 ]; then
      calibredb set_metadata "$id" --field "tags:$new" --with-library "$LIB" >/dev/null 2>&1 \
        && changed=$((changed+1)) \
        || echo "  FAILED id $id"
    else
      changed=$((changed+1))
      if [ -n "$cur" ]; then
        echo "  id $id: [$cur] + $tag"
      else
        echo "  id $id: + $tag"
      fi
    fi
  done
done

echo
if [ "$APPLY" = 1 ]; then
  echo "tagged $changed books, $skipped already correct"
else
  echo "DRY RUN: would tag $changed books, $skipped already correct"
  echo "re-run with --apply"
fi
