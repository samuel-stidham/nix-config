#!/usr/bin/env bash
#
# education-redundant.sh - list Education book files that Calibre already holds.
#
# THE TEST IS CONTENT, NOT TITLES
#
# `calibredb add` COPIES the file into the library byte for byte. So a source
# file is redundant if and only if its md5 appears among the library's files.
# That is the whole method, and it is why this is trustworthy in a way that
# matching on titles is not:
#
#   - Two different editions share a title. Titles would call the 2017 and the
#     2026 Calculus Volume 2 the same book and delete the wrong one.
#   - One book has many filenames. "Calculus Volume 2_nodrm.pdf" and
#     "calculus-volume-2_-_WEB.pdf" are unrelated by name and by content.
#   - Calibre rewrites the filename on import, so names never match anyway.
#
# An md5 match means the exact bytes are in the library. Nothing is inferred.
#
# WHAT THIS DELIBERATELY DOES NOT DO
#
# It does not delete. It prints two lists and a total. Deleting is a separate,
# human decision, because "Calibre has these bytes" is necessary but not
# sufficient: the MAT-275 copy of a textbook is filed with the course that uses
# it, and being redundant is not the same as being unwanted.
#
# Usage:
#   ./education-redundant.sh              # summary
#   ./education-redundant.sh --list       # every redundant file, full paths
#   ./education-redundant.sh --missing    # book files NOT in calibre
#   ./education-redundant.sh --script     # emit rm lines to review and pipe to sh
set -uo pipefail

LIB="${CALIBRE_LIBRARY:-/media/samuelstidham/StoragePrime/Books/Calibre Library}"
EDU="${EDUCATION_DIR:-$HOME/Documents/Education}"
MODE="${1:-summary}"

[ -f "$LIB/metadata.db" ] || { echo "no calibre library at $LIB" >&2; exit 1; }
[ -d "$EDU" ]             || { echo "no education dir at $EDU" >&2; exit 1; }

BOOK_EXT=( -iname '*.pdf' -o -iname '*.epub' -o -iname '*.mobi' -o -iname '*.azw'
           -o -iname '*.azw3' -o -iname '*.djvu' -o -iname '*.cbz' -o -iname '*.cbr' )

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hash the library once. -P 8 because this is thousands of files and md5 is
# CPU bound on a warm cache.
find "$LIB" -type f \( "${BOOK_EXT[@]}" -o -iname '*.txt' -o -iname '*.rtf' -o -iname '*.doc' -o -iname '*.docx' \) -print0 2>/dev/null \
  | xargs -0 -P 8 md5sum 2>/dev/null | awk '{print $1}' | sort -u > "$TMP/lib.md5"

find "$EDU" -type f \( "${BOOK_EXT[@]}" \) -print0 2>/dev/null \
  | xargs -0 -P 8 md5sum 2>/dev/null | sort > "$TMP/edu.md5"

: > "$TMP/safe"; : > "$TMP/missing"
while IFS= read -r line; do
  h="${line%% *}"; f="${line#*  }"
  if grep -qxF "$h" "$TMP/lib.md5"; then echo "$f" >> "$TMP/safe"; else echo "$f" >> "$TMP/missing"; fi
done < "$TMP/edu.md5"

bytes() { tr '\n' '\0' < "$1" | xargs -0 du -cb 2>/dev/null | tail -1 | cut -f1; }

case "$MODE" in
  --list)    cat "$TMP/safe" ;;
  --missing) cat "$TMP/missing" ;;
  --script)
    echo "# Review before running. Each file below is byte-identical to a copy in Calibre."
    while IFS= read -r f; do printf 'rm -- %q\n' "$f"; done < "$TMP/safe"
    ;;
  *)
    echo "library:   $LIB"
    echo "education: $EDU"
    echo
    printf 'redundant (exact copy is in Calibre): %4s files, %s\n' \
      "$(grep -c . "$TMP/safe")" "$(numfmt --to=iec --suffix=B "$(bytes "$TMP/safe")")"
    printf 'NOT in Calibre (keep or import):      %4s files, %s\n' \
      "$(grep -c . "$TMP/missing")" "$(numfmt --to=iec --suffix=B "$(bytes "$TMP/missing")")"
    echo
    echo "redundant, by folder:"
    sed "s|$EDU/||" "$TMP/safe" | awk -F/ 'NF==1{print "(root)"} NF>1{OFS="/"; NF--; print}' \
      | sort | uniq -c | sort -rn | sed 's/^/  /'
    echo
    echo "--list to see them, --script to emit rm lines, --missing for what is not in Calibre."
    ;;
esac
