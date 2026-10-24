#!/bin/bash
# guardrails/doc-monolith-edit/check.sh [<base-ref>]
#
# The five contract docs are a contract, not a changelog. They drifted into one
# anyway: in the 100 PRs merged 2026-09-13..15, docs/MERGE-CONDUCTOR.md was
# edited in 18, BUILD-CONCURRENCY in 14, RUN-BUILD-GRAPH, OPERATOR-SETUP and
# EVENTS in 9 each — 5,625 lines of dated "since 2026-09-1x this changed" prose
# — and on 2026-09-16 nine of seventeen builds were deferred on file overlap in
# exactly those files. A change now gets its own dated note under docs/notes/,
# and this check is what keeps that true rather than aspirational.
#
# THREE WAYS THROUGH, in the order they are tested:
#   1. the escape hatch (skip-guardrail label AND a written justification),
#   2. the PR title starts with `docs:` — a documentation pass may rewrite the
#      contract text, that is its job,
#   3. every changed line in a guarded doc sits strictly inside that doc's
#      rendered Changes region, between its <!-- changes:begin --> and
#      <!-- changes:end --> markers.
#
# Anything else fails, and the remediation is always the same: write
# docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md instead. Renaming or deleting a
# guarded doc fails too: those carry no hunk to judge, and moving the whole file
# is the largest change outside the region there is.
#
# Configuration (env, so a repo tunes it without forking the script):
#   DOC_MONOLITHS      space-separated guarded paths (default: the five docs)
#   DOC_MONOLITH_DIFF  a file holding a unified diff. Set it and no git call is
#                      made — that is how the check is testable on fixtures, and
#                      how a CI that already has the diff avoids a second one.
#                      The changed-file list is derived FROM this diff, so a
#                      deletion or a rename is seen the same way an edit is.
#   PR_TITLE           the pull request title.
#
# TWO LIMITATIONS, stated rather than hidden:
#   - The markers are read from the WORKING TREE (in CI, the head commit the
#     diff produced), not from the diff. A PR that deletes a marker therefore
#     fails on the region it LEAVES BEHIND: one marker, or an end above its
#     begin, is an empty region, so every line the PR touched in that doc is
#     outside it. The deleted marker line itself is not what fails — a removed
#     line is judged inclusively up to the end bound, because shortening the
#     region is allowed.
#   - A guarded doc with no markers has an EMPTY region, so every edit to it
#     fails until someone adds the region. That direction is deliberate: the
#     alternative is a doc that silently opts out by losing three lines.
#
# rc 0 = clean / exempt / not adopted / not checked. rc 1 = a guarded doc was
# edited outside its Changes region.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/escape-hatch.sh
. "$SELF/../lib/escape-hatch.sh" 2>/dev/null || true
declare -F guardrail_escape_hatch >/dev/null \
  && guardrail_escape_hatch doc-monolith-edit && exit 0

MONOLITHS="${DOC_MONOLITHS:-docs/MERGE-CONDUCTOR.md docs/BUILD-CONCURRENCY.md docs/RUN-BUILD-GRAPH.md docs/OPERATOR-SETUP.md docs/EVENTS.md}"
BASE="${1:-origin/main}"
BEGIN_MARK='<!-- changes:begin -->'
END_MARK='<!-- changes:end -->'

# Adoption is a fact about the CHECKOUT, never about this diff — the same
# reasoning as verification-map-freshness. A repo that has none of the guarded
# docs is a repo this check has nothing to say about.
ADOPTED=""
for D in $MONOLITHS; do
  [ -f "$D" ] && { ADOPTED=yes; break; }
done
if [ -z "$ADOPTED" ]; then
  echo "GUARDRAIL doc-monolith-edit: none of the guarded docs exist in this checkout — not adopted, nothing to guard."
  exit 0
fi

TMP_DIFF=""
cleanup() { [ -n "$TMP_DIFF" ] && rm -f "$TMP_DIFF"; }
trap cleanup EXIT

if [ -n "${DOC_MONOLITH_DIFF:-}" ]; then
  if [ ! -f "$DOC_MONOLITH_DIFF" ]; then
    echo "GUARDRAIL doc-monolith-edit: DOC_MONOLITH_DIFF=$DOC_MONOLITH_DIFF is not readable — not checked."
    exit 0
  fi
  DIFF="$DOC_MONOLITH_DIFF"
else
  TMP_DIFF=$(mktemp) || {
    echo "GUARDRAIL doc-monolith-edit: no temp file for the diff — not checked."
    exit 0
  }
  if ! git diff "$BASE"...HEAD > "$TMP_DIFF" 2>/dev/null; then
    echo "GUARDRAIL doc-monolith-edit: could not diff against $BASE — not checked."
    exit 0
  fi
  DIFF="$TMP_DIFF"
fi

# Which guarded docs this diff touches, read off the `diff --git a/X b/X` lines
# so a delete (+++ /dev/null) and a rename are both visible.
MONO_PAD=" $(printf '%s' "$MONOLITHS" | tr -s '[:space:]' ' ') "
TOUCHED=$(awk -v mono="$MONO_PAD" '
  /^diff --git / {
    line = substr($0, 12)
    p = index(line, " b/")
    if (p == 0) next
    a = substr(line, 3, p - 3)
    b = substr(line, p + 3)
    if (index(mono, " " a " ") > 0) print a
    if (b != a && index(mono, " " b " ") > 0) print b
  }
' "$DIFF" | sort -u)

if [ -z "$TOUCHED" ]; then
  echo "GUARDRAIL doc-monolith-edit: this diff touches none of the guarded docs. Clean."
  exit 0
fi

# PREFIX only, and only after leading whitespace: a title that merely mentions
# docs ("feat: docs for the new lane", "fix(docs): typo") is not a docs pass.
TITLE="${PR_TITLE:-}"
TITLE="${TITLE#"${TITLE%%[![:space:]]*}"}"
if [ "$(printf '%s' "${TITLE:0:5}" | tr '[:upper:]' '[:lower:]')" = "docs:" ]; then
  echo "GUARDRAIL doc-monolith-edit: PR title starts with 'docs:' — a documentation pass may edit the contract docs. Clean."
  exit 0
fi

REPORT=""
while IFS= read -r D; do
  [ -n "$D" ] || continue
  B=""; E=""
  if [ -f "$D" ]; then
    B=$(grep -nF -m1 -e "$BEGIN_MARK" "$D" | cut -d: -f1)
    E=$(grep -nF -m1 -e "$END_MARK" "$D" | cut -d: -f1)
  fi
  # No file, one marker, or an end above its begin all mean the same thing: an
  # EMPTY region, nothing can be inside it. The two bounds are decided together
  # for exactly that reason — defaulting them independently turned a lost begin
  # marker into "the region is lines 1..E-1", which is most of the doc.
  if [ -z "$B" ] || [ -z "$E" ] || [ "$E" -le "$B" ]; then B=0; E=0; fi

  # Walk the diff's own hunks for this path. Every added line is judged at its
  # new-side number, strictly between the bounds. Every removed line is judged
  # at the new-side number it sat on, and there the upper bound is INCLUSIVE:
  # the line that used to be the region's last one now sits where the end marker
  # does, so `n < e` called shortening the region an edit outside it — the one
  # thing the region is supposed to make easy.
  HITS=$(awk -v target="$D" -v b="$B" -v e="$E" '
    function judge(n)    { if (!(n > b && n < e))  print n }
    function judge_rm(n) { if (!(n > b && n <= e)) print n }
    /^diff --git / {
      cur = ""; inhunk = 0
      line = substr($0, 12)
      p = index(line, " b/")
      if (p > 0) {
        pa = substr(line, 3, p - 3)
        pb = substr(line, p + 3)
        if (pa == target || pb == target) cur = target
      }
      next
    }
    cur == "" { next }
    # File headers only ever appear OUTSIDE a hunk, so only skip them there.
    # Inside one, `--- worker/jobs/schema.sql` is a REMOVED line whose text
    # starts with "-- " (docs/BUILD-CONCURRENCY.md:24 is exactly that today),
    # and `+++ x` an added line starting with "++". Treating either as a file
    # header let that edit through and shifted every later line by one.
    !inhunk && /^\+\+\+/ { next }
    !inhunk && /^--- / { next }
    # A rename or a delete changes the whole file with no hunk to point at: the
    # guarded path stops existing, or appears carrying text nobody reviewed as
    # part of it. Either way it is the largest possible change outside the region.
    !inhunk && /^rename from / { if (substr($0, 13) == target) print "renamed-away"; next }
    !inhunk && /^rename to / { if (substr($0, 11) == target) print "renamed-onto"; next }
    !inhunk && /^deleted file mode/ { print "deleted"; next }
    /^@@/ {
      if (match($0, /\+[0-9]+/)) n = substr($0, RSTART + 1, RLENGTH - 1) + 0
      inhunk = 1
      next
    }
    !inhunk { next }
    /^\\/ { next }
    /^\+/ { judge(n); n++; next }
    /^-/  { judge_rm(n); next }
    /^ /  { n++; next }
    /^$/  { n++; next }
    { inhunk = 0 }
  ' "$DIFF")

  [ -n "$HITS" ] || continue
  if [ "$E" -le "$B" ]; then
    REPORT="$REPORT    $D — no Changes region in this checkout, so every change to it is outside one: $(printf '%s' "$HITS" | tr '\n' ' ')"$'\n'
  else
    REPORT="$REPORT    $D — region is lines $((B + 1))-$((E - 1)); changed outside it: $(printf '%s' "$HITS" | tr '\n' ' ')"$'\n'
  fi
done <<< "$TOUCHED"

if [ -z "$REPORT" ]; then
  echo "GUARDRAIL doc-monolith-edit: every change to a guarded doc is inside its Changes region. Clean."
  exit 0
fi

echo "GUARDRAIL doc-monolith-edit: this diff edits a contract doc outside its rendered Changes region."
printf '%s' "$REPORT"
cat <<'EOF'

Those five docs hold the stable contract — state tables, invariants, commands.
What CHANGED goes in its own file instead:

    docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md

one note per change (what changed, why, which rule or state it touches), with a
`Doc: <NAME>` line naming the docs it belongs to. docs/notes/INDEX.md is a
git-ignored render (BH-8254); a PR never commits it.

Three ways this passes: the note-instead-of-append above, a PR whose title
starts with `docs:` (a real documentation pass, which may rewrite the contract),
or a diff that only touches the region between the <!-- changes:begin --> and
<!-- changes:end --> markers.

If this genuinely needs none of those, take the escape hatch: add the
'skip-guardrail' label AND say why in GUARDRAIL_JUSTIFICATION. The reason stays
in the PR record.
EOF
exit 1
