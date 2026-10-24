#!/bin/bash
# bin/render-doc-index.sh [--check|--check-committed] [notes-dir] [out-file]
#
# Render docs/notes/INDEX.md from the dated notes in docs/notes/.
#
# The five contract docs became changelogs: 5,625 lines of "since 2026-09-1x
# this changed" prose, and on 2026-09-16 nine of seventeen builds were deferred
# on file overlap in exactly those files. The new shape is one note per change,
# named docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md, plus this index over them.
#
# A note is tagged by one line naming the docs it belongs to:
#
#     Doc: EVENTS, BUILD-CONCURRENCY
#
# First such line outside a code fence (``` or ~~~) wins, names are matched case-insensitively
# against DOC_NOTES_TAGS, and a note with no usable tag lands under `untagged`
# rather than being dropped. The title is the note's first `# ` heading (falling
# back to the filename stem); the date is the filename's YYYY-MM-DD prefix
# (falling back to `unknown`, sorted last in its group).
#
# DETERMINISM IS THE POINT. This reads no clock, no hostname, and prints no
# counts: two runs over the same directory are byte-identical.
#
# INDEX.md IS NOT IN GIT (BH-8254, the BH-1175 shape). Every PR that added a
# note made a committed copy stale, so the byte --check of #7181 could not land:
# Mergify draft #8239 dequeued it when #8060 merged first with one note. The
# file is in .gitignore, and every reader renders its own copy: bin/docs-sync.sh
# on every box, bin/publish-share.sh for the mirror, CI through --check.
#
#   bin/render-doc-index.sh                      # docs/notes/ -> docs/notes/INDEX.md
#   bin/render-doc-index.sh path/to/notes out.md # explicit
#   DOC_NOTES_DIR=… DOC_NOTES_INDEX=… bin/render-doc-index.sh
#   DOC_NOTES_TAGS="EVENTS FOO" bin/render-doc-index.sh   # heading order
#   bin/render-doc-index.sh --check              # are the notes valid?
#   bin/render-doc-index.sh --check path/to/notes out.md
#   bin/render-doc-index.sh --check-committed    # is INDEX.md what a render writes?
#
# rc 0 = rendered (or nothing to render). rc 1 = the write failed, and the
# previous INDEX.md is left exactly as it was.
#
# --check (BH-8254) validates the SOURCES. It never compares bytes with an
# index on disk and never writes the index. It prints every failure, not only
# the first:
#   - a note whose first Doc: line outside a fence yields no tag (`Doc:`,
#     `Doc: , ,`); a note with no Doc: line at all is valid and lands under
#     `untagged`
#   - two notes that render the same row (same tag, date and title)
#   - two renders into $TMPDIR that differ (the render is not deterministic)
#   - the index TRACKED in git, plus a hint when .gitignore no longer covers it
# rc 0 = valid. rc 1 = a failure above. rc 2 = the check could not run (no notes
# dir, a note awk cannot read, no writable $TMPDIR).
#
# --check-committed (BH-1162) is the old byte comparison, for a repo that
# commits its index: render into $TMPDIR and compare with the index. rc 0 = in
# sync. rc 1 = stale or missing, with a short diff. rc 2 = could not run.
set -uo pipefail
# Byte-identical means byte-identical on every box: the two sorts below collate
# in the caller's locale otherwise, and `…-a-b.md` / `…-ab.md` swap places
# between C and en_US.UTF-8.
export LC_ALL=C
# MODE: render (default), check (BH-8254, validate the sources) or committed
# (BH-1162, the byte compare). CHECK=1 for both check modes: they render into
# $TMPDIR, never write the index, and map "could not run" to rc 2.
MODE=render
case "${1:-}" in
  --check) MODE=check; shift ;;
  --check-committed) MODE=committed; shift ;;
esac
CHECK=0; [ "$MODE" = render ] || CHECK=1
STRICT=0; [ "$MODE" = check ] && STRICT=1
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

NOTES_DIR="${1:-${DOC_NOTES_DIR:-$ROOT/docs/notes}}"
OUT="${2:-${DOC_NOTES_INDEX:-$NOTES_DIR/INDEX.md}}"
TAGS="${DOC_NOTES_TAGS:-MERGE-CONDUCTOR BUILD-CONCURRENCY RUN-BUILD-GRAPH OPERATOR-SETUP EVENTS}"

if [ ! -d "$NOTES_DIR" ]; then
  if [ "$CHECK" = 1 ]; then
    echo "render-doc-index: no $NOTES_DIR — nothing to check." >&2
    exit 2
  fi
  echo "render-doc-index: no $NOTES_DIR — nothing to render."
  exit 0
fi

# Every temp file this run makes, removed on every exit path. A plain render's
# temp file is moved onto OUT first, so removing its old name is a no-op.
TMPS=()
trap 'rm -f "${TMPS[@]}"' EXIT

# collect — set RECORDS (and, under --check, ERRS) from the notes.
# One record per (tag, note): ORDER<TAB>TAG<TAB>DKEY<TAB>FILE<TAB>DATE<TAB>TITLE.
# ORDER is zero-padded so a plain string sort puts the configured docs first in
# their configured order, then unknown tags alphabetically, then untagged.
# DKEY exists because entries sort DESCENDING inside a heading and letters
# collate after digits: sorting the filename alone put `undated-note.md` above
# every dated entry, the opposite of what this file documents. `1<date>` for a
# dated note, `0` for an undated one, so reversed it lands last in its group.
# Under --check (STRICT=1) awk also prints `ERR<TAB>empty-doc<TAB><file>` for a
# note that has a Doc: line outside a fence and still yields no tag. A plain
# render never sees that record, so its bytes do not change.
collect() {
  local F BASE DATE DKEY REC
  RECORDS=""; ERRS=""
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    BASE="${F##*/}"
    case "$BASE" in INDEX.md|README.md) continue ;; esac
    case "$BASE" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*) DATE="${BASE:0:10}" ;;
      *) DATE="unknown" ;;
    esac
    case "$DATE" in unknown) DKEY="0" ;; *) DKEY="1$DATE" ;; esac
    REC=$(awk -v base="$BASE" -v date="$DATE" -v dkey="$DKEY" -v tags="$TAGS" -v strict="$STRICT" '
      BEGIN {
        n = split(tags, TL, /[ ,]+/)
        for (i = 1; i <= n; i++) if (TL[i] != "") { CANON[toupper(TL[i])] = TL[i]; ORD[TL[i]] = i }
        fence = 0; title = ""; doc = ""; docseen = 0
      }
      /^[[:space:]]*(```|~~~)/ { fence = 1 - fence; next }
      fence { next }
      title == "" && /^#[[:space:]]/ {
        title = $0; sub(/^#[[:space:]]+/, "", title); sub(/[[:space:]]+$/, "", title)
      }
      tolower($0) ~ /^[[:space:]]*doc:/ { docseen = 1 }
      doc == "" && tolower($0) ~ /^[[:space:]]*doc:/ { doc = substr($0, index($0, ":") + 1) }
      END {
        if (title == "") { title = base; sub(/\.md$/, "", title) }
        emitted = 0
        n = split(doc, P, ",")
        for (i = 1; i <= n; i++) {
          t = P[i]
          gsub(/^[[:space:]]+/, "", t); gsub(/[[:space:]]+$/, "", t)
          if (t == "") continue
          if (toupper(t) in CANON) t = CANON[toupper(t)]
          if (t in seen) continue
          seen[t] = 1
          order = (t in ORD) ? sprintf("%03d", ORD[t]) : "500"
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", order, t, dkey, base, date, title
          emitted++
        }
        if (emitted == 0) {
          if (strict && docseen) printf "ERR\tempty-doc\t%s\n", base
          printf "999\tuntagged\t%s\t%s\t%s\t%s\n", dkey, base, date, title
        }
      }
    ' "$F") || { echo "render-doc-index: could not read $F" >&2; exit $((1 + CHECK)); }
    RECORDS="$RECORDS$REC"$'\n'
  done <<< "$(find "$NOTES_DIR" -maxdepth 1 -type f -name '*.md' | sort)"
  if [ "$STRICT" = 1 ]; then
    ERRS=$(printf '%s' "$RECORDS" | grep $'^ERR\t')
    RECORDS=$(printf '%s' "$RECORDS" | grep -v $'^ERR\t')$'\n'
  fi
}

# write_index <file> — the index for RECORDS, into <file>.
write_index() {
  {
    echo "# Notes index"
    echo
    echo "Rendered by \`bin/render-doc-index.sh\` from the notes in this directory."
    echo "Do not hand-edit: the next docs pass overwrites it. To record a change, add"
    echo "\`docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md\` with a \`Doc:\` line naming the docs"
    echo "it belongs to, and re-render."
    if [ -z "${RECORDS//[$'\n']/}" ]; then
      echo
      echo "No notes yet."
    else
      local PREV="" TAG FILE DATE TITLE
      while IFS=$'\t' read -r _ TAG _ FILE DATE TITLE; do
        [ -n "$TAG" ] || continue
        if [ "$TAG" != "$PREV" ]; then
          echo
          echo "## $TAG"
          echo
          PREV="$TAG"
        fi
        echo "- $DATE — [$TITLE]($FILE)"
      done <<< "$(printf '%s' "$RECORDS" | sort -t$'\t' -k1,1 -k2,2 -k3,3r -k4,4r)"
    fi
  } > "$1"
}

# render_tmp — collect, then write a temp file; its path in TMP. A plain render
# writes in the destination directory, so a failed render leaves the old index
# standing rather than half-written. Both check modes write in $TMPDIR instead
# and never touch the destination.
render_tmp() {
  local DIR_
  collect
  DIR_="$(dirname "$OUT")"
  [ "$CHECK" = 1 ] && DIR_="${TMPDIR:-/tmp}"
  TMP=$(mktemp "$DIR_/.render-doc-index.XXXXXX" 2>/dev/null) || {
    echo "render-doc-index: cannot write in $DIR_ — $OUT left unchanged." >&2
    exit $((1 + CHECK))
  }
  TMPS+=("$TMP")
  write_index "$TMP" || {
    echo "render-doc-index: write to $DIR_ failed — $OUT left unchanged." >&2
    exit $((1 + CHECK))
  }
}

if [ "$MODE" = check ]; then
  BAD=0
  render_tmp; FIRST="$TMP"; FIRST_ERRS="$ERRS"; FIRST_RECORDS="$RECORDS"
  render_tmp; SECOND="$TMP"

  # 1. a Doc: line that yields no tag.
  while IFS=$'\t' read -r _ _ FILE; do
    [ -n "$FILE" ] || continue
    echo "render-doc-index: $FILE has a Doc: line that names no doc. Write \`Doc: <NAME>[, <NAME>]\`, or remove the line (the note then lands under untagged)." >&2
    BAD=1
  done <<< "$FIRST_ERRS"

  # 2. two notes that render the same row: the same tag, date and title. The
  #    link differs (file names are unique), the visible text does not.
  DUPES=$(printf '%s' "$FIRST_RECORDS" | awk -F'\t' 'NF >= 6 {
      k = $2 FS $5 FS $6
      if (k in seen) print $2 "\t" seen[k] "\t" $4 "\t" $5 "\t" $6; else seen[k] = $4
    }')
  while IFS=$'\t' read -r TAG A B DATE TITLE; do
    [ -n "$TAG" ] || continue
    echo "render-doc-index: $A and $B render the same row under $TAG ($DATE — $TITLE). Give one of them a distinct title." >&2
    BAD=1
  done <<< "$DUPES"

  # 3. the render is deterministic: two renders of the same notes are equal.
  if ! cmp -s "$FIRST" "$SECOND"; then
    echo "render-doc-index: two renders of $NOTES_DIR differ — the render is not deterministic:" >&2
    diff -u "$FIRST" "$SECOND" | head -n 40 >&2
    BAD=1
  fi

  # 4. the index is not tracked. As in bin/verification-map-build.sh, the
  #    ignore line is not REQUIRED for a pass, only hinted: a PR that deletes
  #    the .gitignore line and force-adds the index must still go red.
  OUT_DIR="$(dirname "$OUT")"
  if [ -d "$OUT_DIR" ] && command -v git >/dev/null 2>&1 \
     && git -C "$OUT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    TRACKED=$(git -C "$OUT_DIR" ls-files --full-name -- "${OUT##*/}" 2>/dev/null || true)
    REL="${TRACKED%%$'\n'*}"
    if [ -n "$REL" ]; then
      echo "render-doc-index: $REL is TRACKED in git. It is GENERATED and must not be committed (BH-8254):" >&2
      echo "render-doc-index:   git rm --cached $REL   — the sources are the notes beside it" >&2
      if ! git -C "$OUT_DIR" check-ignore -q --no-index -- "${OUT##*/}" 2>/dev/null; then
        echo "render-doc-index:   and .gitignore no longer covers it — restore that line too, or the next build commits it again" >&2
      fi
      BAD=1
    fi
  fi
  exit "$BAD"
fi

render_tmp

if [ "$MODE" = committed ]; then
  if cmp -s "$TMP" "$OUT"; then
    exit 0
  fi
  echo "render-doc-index: $OUT is stale — run bin/render-doc-index.sh"
  if [ -e "$OUT" ]; then
    diff -u "$OUT" "$TMP" | head -n 40
  else
    echo "render-doc-index: $OUT does not exist"
  fi
  exit 1
fi

chmod 644 "$TMP"
mv "$TMP" "$OUT" || {
  echo "render-doc-index: could not move the rendered index onto $OUT." >&2
  exit 1
}
echo "render-doc-index: wrote $OUT"
exit 0
