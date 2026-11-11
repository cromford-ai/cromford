#!/bin/bash
# bin/size-gate.sh <plan.md> <max-lines> <max-files> [planned-files.txt]
#
# How big does this plan say it is, and is that small enough to build whole?
#
# WHY (the operator, 2026-09-12). The pipeline has had a decomposer since 2026-07-28 and
# it fired on exactly one input: a planner voluntarily writing `SIZE: XL` on the
# last line of its own plan. Self-reported, all-or-nothing, unmeasured — and an
# `L` plan that turns into 1,400 lines was indistinguishable from an `L` plan
# that turns into 200. Median diff across 381 merged harness PRs: 1,268 lines.
# So the plan now DECLARES its size in numbers, and over a threshold the ticket
# is split instead of built.
#
# THE UNIT IS PRODUCT LINES. bin/size-scope.sh owns what that means (tests,
# docs, specs, lockfiles and generated files do not count) and is the only place
# that list exists — the post-hoc guard in run-build.sh calls the same helper on
# the diff that actually shipped, so the two sides cannot disagree about what
# they measured.
#
# WHAT IT READS. A '## Size' section (or '## Size estimate') containing:
#     FILES: 6
#     LINES: 240
# Forgiving, because a model writes it: bullets, bold, `~`, thousands
# separators and lower case all parse. Fenced code blocks are skipped whole —
# a sample that says `LINES: 10` is not a declaration, the same rule
# bin/plan-gate.sh applies to VALIDATE:.
#
# An optional third key, `DIFF_KB: 45`, is the plan's estimate of its WHOLE
# diff (tests, docs, fixtures and generated files included). The lead review
# reads at most LEAD_REVIEW_DIFF_MAX_BYTES of a diff (400000 by default; the
# limit here is that / 1000, in KB), so a plan over it is split like a plan over
# the line limit, with the same tolerance band. A plan without the key is sized
# exactly as before: it prints no DIFF line and is never `undeclared` for it.
#
# THE FILE AXIS IS THE DECLARATION, NOT THE MENTION LIST (BH-612, 2026-09-16).
# This gate used to "verify" the declared FILE count against planned-files.txt,
# on the reasoning that a line estimate cannot be checked at plan time but a
# file count can. It cannot. planned-files.txt is built by bin/planned-files.sh,
# whose own header calls itself a deliberate over-listing — it scrapes every
# repo-relative path token the plan MENTIONS, which on a real plan includes the
# callers it read, the "## Out of scope" list and the "do NOT edit src/x.ts"
# line. That superset is the right input for bin/conflict-check.sh and the
# claims ledger (over-listing costs a serialization, under-listing costs a
# conflict) and the wrong input for size: project-5 #1906 declared files=2
# lines=45 and was decomposed into two children on 18 mentions, #1907 the same
# on 16, both in one night.
#
# So the DECLARED FILES is what gates. The superset is still counted and printed
# for the ledger (SIZE_FILES_PLANNED) and, when it is over the TOLERATED file
# limit, named as `SIZE_FILES_MENTIONED: n (not gating)` — visible to a reviewer,
# authoritative over nothing. A declaration that UNDER-counts is caught after
# execute, against the diff that actually shipped, by bin/evidence-summary.sh's
# `SIZE_DECLARATION_EXCEEDED` row (a warning on the PR, never a block: by then
# the code is written). Test files in either list still do not count — size-scope
# owns that, so a plan is never pushed over by the tests it promises to write.
#
# NO DECLARATION IS A WARNING, NOT A MALFORMED PLAN (BH-5292, the operator 2026-10-07).
# A missing `## Size` is a missing number, not harm, so the build proceeds with
# its size ESTIMATED from the plan's file list: files = the product files in
# planned-files.txt (the mention superset, so it errs large), lines = files x
# (MAXL / MAXF), the threshold's own lines-per-file ratio. Because that
# superset over-lists (the BH-612 lesson above), an estimate splits only past
# 2x the nominal limits; between 1x and 2x it builds whole and says so. The
# estimate never prints a SIZE_DECLARED line: nothing was declared, and
# bin/evidence-summary.sh compares the shipped diff only with a declaration.
#
# prints: SIZE_DECLARED / SIZE_FILES / SIZE_FILES_PLANNED / SIZE_LINES /
#         SIZE_LIMITS / SIZE_DIFF_KB + SIZE_DIFF_LIMIT_KB (when DIFF_KB is
#         declared) / SIZE_FILES_MENTIONED (when the superset is over the
#         tolerated file limit; informational) / SIZE_OVER (when over) /
#         SIZE_VERDICT. With no declaration: SIZE_GATE_WARNING /
#         SIZE_ESTIMATED / SIZE_LIMITS / SIZE_OVER (past 2x) / SIZE_VERDICT
#         (estimated, or over). SIZE_SLICES_EXPECTED on both of those paths
#         (BH-8739): max(1, ceil(lines/max-lines), ceil(files/max-files)), the
#         number of one-build slices the size implies. bin/lib/slice-gate.sh
#         reads it; above SLICE_CONFIRM_OVER the decomposer asks a person
#         before it files children. `undeclared` prints none.
#
# exit 0  within both limits, or no declaration and an estimate within 2x
# exit 2  over at least one limit, or an estimate past 2x  (the decomposable case)
# exit 3  no readable plan at all  (never a pass)
set -uo pipefail
PLAN="${1:-}"
MAXL="${2:-700}"; MAXF="${3:-20}"
LIST="${4:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$MAXL" in ''|*[!0-9]*) MAXL=700 ;; esac
case "$MAXF" in ''|*[!0-9]*) MAXF=20 ;; esac
# WHERE THE LIMITS CAME FROM (BH-4985): the caller passes bin/size-threshold.sh's
# `src` in SIZE_LIMITS_SRC and it rides the SIZE_LIMITS line as ` src=<src>`.
# Only the shapes that script prints are accepted; anything else, or nothing,
# leaves the line exactly as it was before the field existed.
LSRC="${SIZE_LIMITS_SRC:-}"
case "$LSRC" in *[!a-z:,]*) LSRC="" ;; esac
# TOLERANCE (the operator, 2026-09-16): a plan that lands a hair over the line is not
# what the gate exists for. BH-594 sized itself 310 product lines against a
# 300-line threshold and was decomposed into serial children, which doubled the
# latency of a hub-blocking fix for ten lines of slack. The threshold is an
# ESTIMATE judged against an ESTIMATE; splitting on a 3% overshoot treats both
# as exact. So the gate tolerates an overshoot of SIZE_GATE_TOLERANCE_PCT
# (default 15) on each axis: 700 lines trips at 805, 20 files at 23. A plan in
# the band is reported as `within` with a SIZE_TOLERATED line naming the
# overshoot, so the ledger still says it was over the nominal number. The
# NOMINAL limits stay what the children are budgeted against, so tolerance
# never compounds: a split child gets 700, not 805. 0 turns the band off.
TOL="${SIZE_GATE_TOLERANCE_PCT:-15}"
case "$TOL" in ''|*[!0-9]*) TOL=15 ;; esac
[ "$TOL" -le 100 ] || TOL=100
MAXL_TOL=$(( (MAXL * (100 + TOL)) / 100 ))
MAXF_TOL=$(( (MAXF * (100 + TOL)) / 100 ))

# slices <lines> <files> — the expected slice count (BH-8739), at least 1.
slices() {
  local l="$1" f="$2" n=1 a=1 b=1
  [ "$MAXL" -gt 0 ] && a=$(( (l + MAXL - 1) / MAXL ))
  [ "$MAXF" -gt 0 ] && b=$(( (f + MAXF - 1) / MAXF ))
  [ "$a" -gt "$n" ] && n="$a"
  [ "$b" -gt "$n" ] && n="$b"
  echo "SIZE_SLICES_EXPECTED: $n"
}

undeclared() { # undeclared <why>
  echo "SIZE_GATE_UNAVAILABLE $1"
  echo "SIZE_LIMITS: lines=$MAXL files=$MAXF${LSRC:+ src=$LSRC}"
  echo "SIZE_VERDICT: undeclared"
  exit 3
}
[ -n "$PLAN" ] && [ -s "$PLAN" ] || undeclared "no readable plan at ${PLAN:-<none>}"

# The section, then the two numbers inside it. awk rather than grep because the
# scope matters: FILES:/LINES: anywhere else in a plan (a file list, a prose
# sentence) is not the declaration, and a fenced sample never is.
DECL=$(awk '
  function num(s,   t) {
    t = s
    sub(/^[^:]*:[ \t]*/, "", t)
    gsub(/[~,`*_ \t]/, "", t)
    if (match(t, /^[0-9]+/)) return substr(t, RSTART, RLENGTH)
    return ""
  }
  { line = $0 }
  line ~ /^[ \t]*(```|~~~)/ { fence = 1 - fence; next }
  fence { next }
  /^#+[ \t]/ {
    h = tolower($0); sub(/^#+[ \t]*/, "", h); gsub(/[ \t]+$/, "", h)
    insize = (h ~ /^size([ \t]|$)/ || h ~ /^size (estimate|declaration)/)
    next
  }
  insize {
    l = tolower(line)
    gsub(/[-*+\t ]+/, " ", l); sub(/^ /, "", l)
    gsub(/\*\*/, "", l)
    if (l ~ /^files[ ]*:/ && f == "") { f = num(l) }
    if (l ~ /^lines[ ]*:/ && n == "") { n = num(l) }
    if (l ~ /^diff_kb[ ]*:/ && k == "") { k = num(l) }
  }
  END { printf "%s\t%s\t%s\n", f, n, k }
' "$PLAN" 2>/dev/null)
FILES=$(printf '%s' "$DECL" | cut -f1)
LINES=$(printf '%s' "$DECL" | cut -f2)
DIFFKB=$(printf '%s' "$DECL" | cut -f3)
case "$DIFFKB" in ''|*[!0-9]*) DIFFKB="" ;; esac
DLIM_B="${LEAD_REVIEW_DIFF_MAX_BYTES:-400000}"
case "$DLIM_B" in ''|*[!0-9]*|0*) DLIM_B=400000 ;; esac
DLIM=$((DLIM_B / 1000)); [ "$DLIM" -gt 0 ] || DLIM=400
DLIM_TOL=$(( (DLIM * (100 + TOL)) / 100 ))
case "$FILES" in ''|*[!0-9]*) FILES="" ;; esac
case "$LINES" in ''|*[!0-9]*) LINES="" ;; esac
# HALF A DECLARATION IS NOT A DECLARATION. A plan that says LINES and not FILES
# has not been sized; treating the missing half as 0 would let any plan pass the
# file limit by omission.
# The mention superset: product files anywhere in the plan's prose. Counted for
# the record and for the conflict scheduler, never for a declared verdict (see
# the header, and BH-612); with no declaration it is the estimate's input.
PLANNED=""
if [ -n "$LIST" ] && [ -s "$LIST" ] && [ -x "$HERE/size-scope.sh" ]; then
  PLANNED=$("$HERE/size-scope.sh" --filter < "$LIST" 2>/dev/null | sort -u | grep -c . || true)
  case "$PLANNED" in ''|*[!0-9]*) PLANNED="" ;; esac
fi

# >>> size estimate
if [ -z "$FILES" ] || [ -z "$LINES" ]; then
  EF=${PLANNED:-0}
  EL=0; [ "$MAXF" -gt 0 ] && EL=$(( EF * MAXL / MAXF ))
  echo "SIZE_GATE_WARNING: the plan carries no '## Size' section with both FILES: and LINES: — size estimated from its file list, building on"
  if [ -n "$PLANNED" ]; then ESRC="$PLANNED product file(s)"; else ESRC="none readable"; fi
  echo "SIZE_ESTIMATED: files=$EF lines=$EL (from the plan's file list, $ESRC; lines = files x $MAXL/$MAXF)"
  echo "SIZE_LIMITS: lines=$MAXL files=$MAXF${LSRC:+ src=$LSRC}"
  slices "$EL" "$EF"
  EOVER=""
  [ "$EF" -gt $(( 2 * MAXF )) ] && EOVER="files=$EF>2x$MAXF (estimated)"
  [ "$EL" -gt $(( 2 * MAXL )) ] && EOVER="${EOVER:+$EOVER; }lines=$EL>2x$MAXL (estimated)"
  if [ -n "$EOVER" ]; then
    echo "SIZE_OVER: $EOVER"
    echo "SIZE_VERDICT: over"
    exit 2
  fi
  echo "SIZE_VERDICT: estimated"
  exit 0
fi
# <<< size estimate

echo "SIZE_DECLARED: files=$FILES lines=$LINES"
echo "SIZE_FILES: $FILES"
[ -n "$PLANNED" ] && echo "SIZE_FILES_PLANNED: $PLANNED"
echo "SIZE_LINES: $LINES"
echo "SIZE_LIMITS: lines=$MAXL files=$MAXF${LSRC:+ src=$LSRC}"
slices "$LINES" "$FILES"
[ -n "$DIFFKB" ] && { echo "SIZE_DIFF_KB: $DIFFKB"; echo "SIZE_DIFF_LIMIT_KB: $DLIM"; }

[ "$TOL" -gt 0 ] && echo "SIZE_TOLERANCE: ${TOL}% (lines<=$MAXL_TOL files<=$MAXF_TOL build whole)"
# A wide mention list is worth SAYING and worth nothing as a verdict. Printed
# only above the TOLERATED limit, so plans inside the band add no noise, and
# always with "(not gating)" so nobody reads it as the number that fired.
if [ -n "$PLANNED" ] && [ "$PLANNED" -gt "$MAXF_TOL" ]; then
  echo "SIZE_FILES_MENTIONED: $PLANNED (not gating)"
fi
# Past the band is over; inside the band is tolerated and named. SIZE_OVER still
# quotes the NOMINAL limit so the ledger reads exactly as it did before the band.
OVER=""; TOLERATED=""
if [ "$LINES" -gt "$MAXL_TOL" ]; then
  OVER="lines=$LINES>$MAXL"
elif [ "$LINES" -gt "$MAXL" ]; then
  TOLERATED="lines=$LINES>$MAXL"
fi
if [ "$FILES" -gt "$MAXF_TOL" ]; then
  OVER="${OVER:+$OVER; }files=$FILES>$MAXF"
elif [ "$FILES" -gt "$MAXF" ]; then
  TOLERATED="${TOLERATED:+$TOLERATED; }files=$FILES>$MAXF"
fi
if [ -n "$DIFFKB" ] && [ "$DIFFKB" -gt "$DLIM_TOL" ]; then OVER="${OVER:+$OVER; }diff_kb=$DIFFKB>$DLIM"
elif [ -n "$DIFFKB" ] && [ "$DIFFKB" -gt "$DLIM" ]; then TOLERATED="${TOLERATED:+$TOLERATED; }diff_kb=$DIFFKB>$DLIM"; fi
if [ -n "$OVER" ]; then
  echo "SIZE_OVER: $OVER"
  echo "SIZE_VERDICT: over"
  exit 2
fi
[ -n "$TOLERATED" ] && echo "SIZE_TOLERATED: $TOLERATED (within the ${TOL}% band, building whole)"
echo "SIZE_VERDICT: within"
exit 0
