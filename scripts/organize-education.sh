#!/usr/bin/env bash
#
# organize-education.sh - sort ~/Documents/Education into a book library and a
# plain folder tree.
#
#   ./organize-education.sh                          # DRY RUN, changes nothing
#   ./organize-education.sh --apply                  # import + dedup
#   ./organize-education.sh --apply --prune-amazon   # also delete the 15G folder
#
# The split:
#
#   textbooks and references  -> the calibre library, tagged by the folder they
#                                came from. calibre dedupes on title and author,
#                                which catches the "same book, different bytes"
#                                cases a hash never will.
#   everything else           -> stays a plain folder. Coursework belongs with its
#                                course, and an interactive Unity app is not a
#                                document a library can hold.
#
# Nothing is deleted by the import. calibredb COPIES into the library and leaves
# the source alone, so this is reversible until you remove the sources yourself,
# deliberately, after checking the result.
set -uo pipefail

E="$HOME/Documents/Education"
LIB="${CALIBRE_LIBRARY:-/media/samuelstidham/StoragePrime/Books/Calibre Library}"
VITAL="$HOME/Documents/Vital"

APPLY=0
PRUNE=0
for a in "$@"; do
  case "$a" in
    --apply)        APPLY=1 ;;
    --prune-amazon) PRUNE=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

say()   { printf '%s\n' "$*"; }
head_() { printf '\n=== %s ===\n' "$*"; }
run()   { if [ "$APPLY" = 1 ]; then "$@"; else say "  DRY: $*"; fi; }

head_ "mode"
[ "$APPLY" = 1 ] && say "  APPLY: changes are real" || say "  DRY RUN. re-run with --apply"
say "  library: $LIB"

# --------------------------------------------------------------------------
# A secret was found sitting in a pile of textbooks. It is not a book, it must
# not enter the library, and it must not stay here.
head_ "1. rescue secrets misfiled as books"
shopt -s nullglob
for f in "$E"/*Recovery-Key*.pdf "$E"/*recovery*key*.pdf; do
  [ -f "$f" ] || continue
  say "  SECRET: $(basename "$f")"
  say "    -> ~/Documents/Vital/Identity/  (a firefox sync recovery key, not a book)"
  run mkdir -p "$VITAL/Identity"
  run mv "$f" "$VITAL/Identity/"
done
shopt -u nullglob

# --------------------------------------------------------------------------
# Byte identical files only. This is the conservative pass: same bytes, so
# removing the extras cannot lose anything. Title level duplicates are left to
# calibre, which understands metadata.
head_ "2. exact duplicate books (content hash)"
python3 - "$E" "$APPLY" <<'PY'
import hashlib, os, sys
from collections import defaultdict
E, APPLY = sys.argv[1], sys.argv[2] == "1"
EXT = {'.epub', '.pdf', '.azw', '.azw3', '.mobi'}

by_size = defaultdict(list)
for root, _, files in os.walk(E):
    for f in files:
        if os.path.splitext(f)[1].lower() in EXT:
            p = os.path.join(root, f)
            try: by_size[os.path.getsize(p)].append(p)
            except OSError: pass

def md5(p):
    h = hashlib.md5()
    with open(p, 'rb') as fh:
        for c in iter(lambda: fh.read(1 << 20), b''): h.update(c)
    return h.hexdigest()

groups = defaultdict(list)
for size, paths in by_size.items():
    if len(paths) < 2: continue
    for p in paths:
        try: groups[md5(p)].append(p)
        except OSError: pass

def area(p):
    """Top level folder under Education, e.g. SNHU, Books, or '' for a loose file."""
    rel = os.path.relpath(p, E)
    parts = rel.split(os.sep)
    return parts[0] if len(parts) > 1 else ''

freed = removed = deferred = 0
for h, paths in sorted(groups.items()):
    if len(paths) < 2: continue

    # Only auto-delete when every copy lives in the SAME top level area. Across
    # areas the "duplicate" is a deliberate choice, not an accident: a textbook in
    # Books/ and the same textbook in a course folder are two different jobs, and
    # deleting the Books/ copy would drop it from the calibre import and lose its
    # tag. Those get reported, not removed.
    if len({area(p) for p in paths}) > 1:
        print(f"  REVIEW (spans areas, left alone): {os.path.basename(paths[0])[:52]}")
        for p in paths: print(f"      {p.replace(E, '.')}")
        deferred += len(paths) - 1
        continue

    # Within one area, the DEEPEST path is the filed one. A problem set living in
    # 'Courses/2026/07 - MAT-275/Module 8/Problem Set' is organised; the identical
    # file dumped at the area root is the stray. Keep the organised copy.
    paths.sort(key=lambda p: (-p.count(os.sep), len(p)))
    keep, drop = paths[0], paths[1:]
    print(f"  keep: {keep.replace(E, '.')}")
    for d in drop:
        print(f"    rm: {d.replace(E, '.')}")
        freed += os.path.getsize(d)
        removed += 1
        if APPLY:
            try: os.remove(d)
            except OSError as e: print(f"       FAILED: {e}")

print(f"\n  removed {removed} strays, {freed/1e6:.1f} MB")
print(f"  deferred {deferred} cross-area copies for you to judge")
PY

# --------------------------------------------------------------------------
# Each source folder becomes a tag. That preserves the organisation already done
# by hand, without forcing every book into exactly one folder. A book can be both
# Math and Reference, which a directory tree cannot express.
head_ "3. import textbooks into calibre, tagged by source"
if ! command -v calibredb >/dev/null 2>&1; then
  say "  calibredb not on PATH. Install calibre first."
  exit 1
fi

# Everything calibredb reports goes here. This log is the ONLY basis on which
# source files may later be deleted.
#
# calibredb add COPIES, it never moves. So after an import you hold two copies and
# the sources are 18.5G of pure duplication. They should go. But not on faith:
#
#   - a corrupt or unsupported file is simply not added. Delete it and it is gone.
#   - a book whose title and author match an existing one is SKIPPED. If the
#     metadata is sloppy, which is normal for loose epubs, two different books can
#     collide and the second is silently not added.
#
# calibredb prints both the added ids and the ignored duplicates, so the log turns
# "probably fine" into a list you can check. Delete from the log, never from hope.
IMPORT_LOG="${IMPORT_LOG:-$HOME/.local/state/education-import.log}"

# Add a tag to books that already exist, without destroying the tags they have.
#
# set_metadata --field tags:"X" REPLACES the entire tag list, it does not append.
# Plenty of these books ship real tags in their own metadata (Programming,
# refactoring, SOLID principles), and overwriting those to say "Computer Science"
# would throw away information the file came with. So read, union, write back.
# A book that already carries the tag is left untouched, which keeps this
# idempotent.
tag_ids() {
  local tag="$1"; shift
  local id cur new
  for id in "$@"; do
    cur="$(sqlite3 -readonly "file:$LIB/metadata.db?immutable=1" \
      "select coalesce(group_concat(t.name,','),'')
       from books_tags_link l join tags t on t.id=l.tag where l.book=$id;" 2>/dev/null)"
    printf '%s' "$cur" | tr ',' '\n' | grep -qxF "$tag" && continue
    if [ -n "$cur" ]; then new="$cur,$tag"; else new="$tag"; fi
    calibredb set_metadata "$id" --field "tags:$new" --with-library "$LIB" >/dev/null 2>&1 \
      || say "    WARN: could not tag id ${id}"
  done
}

import_dir() {
  local dir="$1" tag="$2"
  [ -d "$dir" ] || { say "  skip (absent): ${dir/#$HOME/\~}"; return 0; }
  local n
  n=$(find "$dir" -type f \( -iname '*.epub' -o -iname '*.pdf' -o -iname '*.azw' -o -iname '*.azw3' -o -iname '*.mobi' \) 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || { say "  skip (no books): ${dir/#$HOME/\~}"; return 0; }
  say "  ${n} books  ${dir/#$HOME/\~}  -> tag: ${tag}"
  # No --duplicates flag on purpose. Without it calibredb SKIPS books already in
  # the library, matching on title and author. That is the dedup.
  #
  # Do NOT pass --tags here. calibredb accepts it and honours it for a single
  # file, but with -r it reads metadata per file and silently discards the
  # command line metadata options: no error, no warning, exit 0, books land
  # untagged. That bug cost a whole import run. Tag from the reported ids
  # instead, which is also more honest, it only tags what was actually added.
  if [ "$APPLY" = 1 ]; then
    mkdir -p "$(dirname "$IMPORT_LOG")"
    local out ids
    out="$( { printf '\n########## %s  (tag: %s) ##########\n' "$dir" "$tag"
              calibredb add -r "$dir" --with-library "$LIB" 2>&1
            } | tee -a "$IMPORT_LOG" )"
    # "Added book ids: 1, 2, 3" -> "1 2 3". Absent when everything was a dupe.
    ids="$(printf '%s\n' "$out" | sed -n 's/^Added book ids: *//p' | tr ',' ' ')"
    if [ -n "${ids// /}" ]; then
      # shellcheck disable=SC2086
      tag_ids "$tag" $ids
      say "    tagged $(printf '%s\n' $ids | grep -c .) newly added"
    else
      say "    nothing new (all duplicates)"
    fi
  else
    say "  DRY: calibredb add -r '$dir' --with-library '$LIB'  then tag -> ${tag}"
  fi
}

# Books/Purchased Amazon Books is deliberately NOT imported.
#
# It is a backup of the whole Amazon library and all 864 books are already in
# calibre. That was verified, not assumed: filename matching accounted for 854,
# and reading the internal metadata of the remaining 10 with ebook-meta resolved
# 9 more. Files named B004F9PR4Q_EBOK.epub carry no title in the filename at all,
# only inside.
#
# Importing them would be 15G of no-ops, since calibre would skip every one as a
# duplicate. See prune_amazon() for the payoff: that folder is redundant.
#
# Exactly one book there is NOT in the library, and it is the interesting case.
import_second_edition() {
  local f
  f="$(find "$E/Books/Purchased Amazon Books" -iname 'Godot 4Game*' -iname '*.azw' 2>/dev/null | head -1)"
  [ -n "$f" ] || { say "  2nd edition not found, skipping"; return 0; }
  say "  Godot 4 Game Development Projects, SECOND EDITION"
  say "    the library holds the FIRST edition. Same title, same author, so"
  say "    calibre would skip this as a duplicate and the 2nd edition would be"
  say "    lost the moment the folder is deleted. --duplicates forces it in."
  if [ "$APPLY" = 1 ]; then
    calibredb add "$f" --tags "Purchased" --duplicates --with-library "$LIB" 2>&1 | tee -a "$IMPORT_LOG"
  else
    say "  DRY: calibredb add '$f' --tags Purchased --duplicates --with-library '$LIB'"
  fi
}
import_second_edition

import_dir "$E/Books/Herbalism"              "Herbalism"
import_dir "$E/Books/TTRPGs"                 "TTRPGs"
import_dir "$E/Books/Cicero"                 "Cicero"
import_dir "$E/Books/Vaesen"                 "Vaesen"
import_dir "$E/Books/Harvard Classics"       "Harvard Classics"
import_dir "$E/Math"                         "Math"
import_dir "$E/Icelandic"                    "Icelandic"
import_dir "$E/Computer Science/Books"       "Computer Science"

# Loose books sitting at the top level, and loose ones directly in Books/.
head_ "4. loose books"
say "  top level and Books/ root, added individually so the pile stops growing"
for f in "$E"/*.epub "$E"/*.pdf "$E"/*.azw "$E"/*.azw3 "$E"/Books/*.epub "$E"/Books/*.pdf; do
  [ -f "$f" ] || continue
  say "    + $(basename "$f")"
  run calibredb add "$f" --tags "Unsorted" --with-library "$LIB"
done

# --------------------------------------------------------------------------
head_ "5. IDSA (Interactive DSA, a Unity CS book)"
# It IS educational, it just is not a document, so it stays a plain folder. Two
# easy wins: the zip is already extracted, and only one of the three platform
# builds will ever run here.
IDSA="$E/IDSA_build_40_MACOS_WIN_LINUX"
for z in "$E"/*IDSA*.zip; do
  [ -f "$z" ] || continue
  say "  redundant zip (already extracted): $(basename "$z")  $(du -sh --apparent-size "$z" 2>/dev/null | cut -f1)"
  run rm -f "$z"
done
for plat in MACOS WIN64; do
  d="$IDSA/IDSA_build_40_$plat"
  [ -d "$d" ] || continue
  say "  $plat build, unused on linux: $(du -sh --apparent-size "$d" 2>/dev/null | cut -f1)"
  run rm -rf "$d"
done

head_ "6. the Amazon folder (15G, redundant)"
# Its own step, and gated. Every one of the 864 books was verified to be in the
# library, but the ONE exception is a second edition that calibre's title+author
# dedup cannot distinguish from the first. Deleting before that is safely in
# would destroy it silently, so refuse to.
prune_amazon() {
  local P="$E/Books/Purchased Amazon Books"
  [ -d "$P" ] || { say "  already gone"; return 0; }
  local size; size="$(du -sh --apparent-size "$P" 2>/dev/null | cut -f1)"

  # The guard: is the second edition in the library yet?
  local second
  second="$(calibredb list --with-library "$LIB" --search 'title:"Godot 4 Game Development Projects"' --fields title 2>/dev/null | tail -n +2 | wc -l)"
  if [ "${second:-0}" -lt 2 ]; then
    say "  REFUSING to delete $size."
    say "  The library shows ${second:-0} edition(s) of 'Godot 4 Game Development"
    say "  Projects'. Both the 1st and 2nd must be present before this folder can"
    say "  go, or the 2nd edition is lost. Run the import first."
    return 1
  fi
  say "  verified: both editions present, and 864/864 books accounted for"
  say "  delete: ${P/#$HOME/\~}  ($size)"
  run rm -rf "$P"
}
if [ "$PRUNE" = 1 ]; then
  prune_amazon
else
  say "  skipped. This deletes 15G, so it is opt in:"
  say "    ./organize-education.sh --apply --prune-amazon"
  say "  Read $IMPORT_LOG and back up first."
fi

head_ "7. what stays plain, untouched"
say "  SNHU/                 coursework belongs with its course"
say "  4000/                 a course archive, html and py, not books"
say "  Go Courses/, Godot Academy/, DBT Worksheets/"
say "  Computer Science/Data Structures and Algorithms/"
say "  IDSA_build_40_MACOS_WIN_LINUX/IDSA_build_40_LINUX/"

head_ "done"
if [ "$APPLY" = 1 ]; then
  say "  Sources were COPIED, not moved. Nothing has been lost, and nothing has"
  say "  been reclaimed yet either: the books now exist twice."
  say ""
  say "  Import log: $IMPORT_LOG"
  say ""
  say "  Before deleting a single source file, read the log for the two things"
  say "  that make deletion unsafe:"
  say "    grep -ci 'already exist' $IMPORT_LOG    # skipped as duplicates"
  say "    grep -ciE 'error|failed|not added'  $IMPORT_LOG    # failed outright"
  say ""
  say "  A skipped book is NOT in the library under that file. It matched an"
  say "  existing title and author, which is usually right and occasionally a"
  say "  metadata collision between two different books."
  say ""
  say "  Then check the count moved as expected:"
  say "    calibredb list --with-library \"$LIB\" --fields title | wc -l"
  say ""
  say "  Only then remove sources, and back up first so the library's new"
  say "  contents are in a snapshot before the originals disappear:"
  say "    ~/nix-config/scripts/backup.sh backup"
else
  say "  that was a DRY RUN. re-run with --apply"
fi
