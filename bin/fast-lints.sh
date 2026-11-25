#!/bin/bash
# bin/fast-lints.sh — the fast always-lint set: which cheap always-suites the PR
# lint job and the builder gate run (BH-3860).
#
# Why: four Mergify batches on 2026-10-01/02 were ejected by always-suites that
# take seconds but only ran in the batch (tests/gh-rest-no-subshell-lint.sh
# twice, tests/gh-app-ratchet-test.sh, tests/share-publish-clean.bh-795-test.sh).
# This script is the one source of truth for that set, derived from data, so a
# new fast always-suite joins it with no workflow edit.
#
# Contract (four verbs):
#   --list [--max-s N]
#       `bin/test-impact.sh always`, joined with catalog/ci-suite-durations.tsv
#       (<suite>\t<seconds>\t<run id>; FAST_LINTS_DURATIONS overrides the path;
#       not committed since BH-5518, CI fetches it with bin/ci-durations.sh),
#       keeping seconds <= MAX (MAX = --max-s, else FAST_LINTS_MAX_S) and
#       dropping every suite a kind=suite row of catalog/rules-pack.tsv runs.
#       stdout: the set, LC_ALL=C sort -u. stderr, one line:
#         fast-lints: <n> of <m> always-suites at <=<MAX>s; unmeasured: <list|none>; over: <count>
#       A suite with no durations row is unmeasured and weighs the MEDIAN of
#       the file's numeric rows, the stand-in bin/lib/suite-runner.sh's shard
#       split already uses (BH-5292): in the set when that median is <= MAX.
#       A non-numeric row is unmeasured and left out. Either is named under
#       unmeasured; neither is ever an error. 0.0 counts as fast.
#   --run [--out DIR] [--skip-suites FILE] [--max-s N] [--set DIR]
#       With --set DIR (BH-10014): the suites are the first word of each
#       non-blank, non-# line of DIR/*.txt (sorted, unique), not --list: no
#       durations file is read, so the set cannot be empty for lack of one.
#       A named suite that is not a file is a row with rc 127 and the run ends
#       rc 2 (could-not-run), unless a suite is red: then rc 1. An empty or
#       missing DIR is rc 2.
#       Without --set: runs every suite --list prints (same --max-s) that FILE does not name,
#       each from the repo root as `HARNESS_TEST_SANDBOX=1 bash <suite>`. FILE
#       is bin/rules-pack.sh --out's suites.txt: the first word of each
#       non-blank, non-# line is a suite to skip (its argv is ignored). An
#       unreadable FILE prints one stderr note and skips nothing. Into DIR
#       (default: a fresh mktemp -d, named on stderr) it writes timings.tsv,
#       one `<suite>\t<seconds>\t<rc>` row per suite, suites.txt (what it ran)
#       and log/<suite>.log; both files start empty on every run. stdout:
#         fast-lints: done <suite> rc=<n> <s>s
#       and a red suite's log goes to stderr between `--- <suite> ---` markers.
#       It never judges the budget.
#   --assert-budget TIMINGS [--budget-s N]
#       Sums column 2 of a --run timings.tsv. Over BUDGET (--budget-s, else
#       FAST_LINTS_BUDGET_S) prints `<sum>s over the <BUDGET>s budget` with
#       the three slowest; a row over 2 x FAST_LINTS_MAX_S (the knob, not a
#       --max-s) is named on its own line. Both are NOTES on stderr and rc 0
#       (BH-5292: time is reported, never a red; the RULES_PACK_BUDGET_S rule);
#       within, one `<sum>s within the <BUDGET>s budget (<n> suites)` stdout
#       line, rc 0. A missing, empty or malformed TIMINGS is still rc 2.
#   --share-precheck [--base REF]
#       Should tests/share-publish-clean.bh-795-test.sh run for this branch?
#       Reads the files added, copied or renamed since `git merge-base REF HEAD`
#       (REF default origin/main) and imports TEXT_EXT and FONT_EXT from
#       bin/share/mapping.py the way bin/share/leakcheck.py does, so a new
#       extension there changes this answer with no edit here. stdout: SKIP
#       when every such file's lower-cased extension is in one of the sets,
#       else RUN and one `  <path> (<ext>)` line per file outside them.
#       First runs bin/share/diffcheck.py on the lines added since the merge
#       base (BH-5542): leakcheck.py's rules over each added line as the
#       sanitized mirror sees it. Its report goes to stderr, so stdout stays
#       the SKIP/RUN answer.
#
# rc:
#   0  --list answered (n may be 0 at a tight --max-s; the stderr line says so);
#      --run all green; --assert-budget read the file (within or over: the
#      verdict is the note, never the rc); --share-precheck SKIP or RUN
#   1  --run: a suite was red. (--assert-budget never: over budget and a slow
#      suite are notes, rc 0 — BH-5292)
#      --share-precheck: a share-mirror leak in the lines this branch adds
#      (BH-5542; each hit and its fix on stderr, stdout empty)
#   2  bad or unknown arguments (usage on stderr); the always-suite set
#      unavailable (test-impact.sh missing, failing, or printing nothing), with
#      empty stdout: never an empty green list; --run with an empty set or an
#      unwritable DIR; --assert-budget TIMINGS missing, empty or malformed;
#      --share-precheck with no merge base, a failed diff, an unreadable
#      mapping.py or a share diff check that could not answer (diffcheck.py
#      rc 2). None of these is ever a pass.
#
# Knobs (fly-pool lane, catalog/lanes.d/fly-pool.json): a settings row
# (lane_knob fly-pool), else env, else the registry default. A value that is
# not a whole number >= 1 falls back. An explicit --max-s / --budget-s that is
# not one is rejected with rc 2, never clamped.
#   FAST_LINTS_MAX_S     10  per-suite threshold, seconds
#   FAST_LINTS_BUDGET_S  159 total budget for the PR fast-lints step (a note when over, never a red)
#
# Examples, from the repo root:
#   HARNESS_TEST_SANDBOX=1 bin/fast-lints.sh --list
#   HARNESS_TEST_SANDBOX=1 bin/fast-lints.sh --run --out /tmp/fl
#   bin/fast-lints.sh --assert-budget /tmp/fl/timings.tsv
#   bin/fast-lints.sh --share-precheck --base origin/main
set -uo pipefail
# --share-precheck imports bin/share/mapping.py: no __pycache__ in the checkout.
export PYTHONDONTWRITEBYTECODE=1

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

usage() {
  cat >&2 <<'EOF'
usage: fast-lints.sh --list [--max-s N]
       fast-lints.sh --run [--out DIR] [--skip-suites FILE] [--max-s N] [--set DIR]
       fast-lints.sh --assert-budget TIMINGS [--budget-s N]
       fast-lints.sh --share-precheck [--base REF]
EOF
  exit 2
}
bad() { echo "fast-lints: $*" >&2; usage; }

# ── knobs: a settings row, else env, else the registry default ─────────────
# Same resolution as bin/rules-pack.sh. The entry point owns the root default
# (BH-2613 rule 4).
H="${HARNESS:-${H:-/root/harness}}"
for _lg in "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" "$HERE/lib/lane-gate.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_lg" ] && . "$_lg" 2>/dev/null && break
done
fl_knob() { # fl_knob <ENV> <fallback>
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob fly-pool "$1" "${PROJECT:-}" 2>/dev/null)
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  [ "$((10#$v))" -ge 1 ] || v="$2"
  printf '%s' "$((10#$v))"
}
posint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$((10#$1))" -ge 1 ]; }

VERB="${1:-}"
[ -n "$VERB" ] || bad "no verb"
shift
MAX="" BUDGET_ARG="" TIMINGS="" OUT="" SKIPF="" SETD="" BASE=origin/main
while [ $# -gt 0 ]; do
  opt=$1
  case "$VERB:$opt" in
    --list:--max-s|--run:--max-s|--run:--out|--run:--skip-suites|--run:--set|--assert-budget:--budget-s|--share-precheck:--base)
      [ $# -ge 2 ] || bad "$opt needs a value"
      case "$opt" in
        --max-s) posint "$2" || bad "--max-s must be a whole number >= 1, got '$2'"; MAX=$((10#$2)) ;;
        --budget-s) posint "$2" || bad "--budget-s must be a whole number >= 1, got '$2'"; BUDGET_ARG=$((10#$2)) ;;
        --out) [ -n "$2" ] || bad "--out needs a directory"; OUT=$2 ;;
        --skip-suites) [ -n "$2" ] || bad "--skip-suites needs a file"; SKIPF=$2 ;;
        --set) [ -n "$2" ] || bad "--set needs a directory"; SETD=$2 ;;
        --base) [ -n "$2" ] || bad "--base needs a ref"; BASE=$2 ;;
      esac
      shift 2 ;;
    --assert-budget:-*) bad "unknown option '$opt' for $VERB" ;;
    --assert-budget:*)
      [ -z "$TIMINGS" ] || bad "--assert-budget takes one TIMINGS file"
      TIMINGS=$opt; shift ;;
    *) bad "unknown option '$opt' for $VERB" ;;
  esac
done

case "$VERB" in
  --list|--run|--share-precheck) ;;
  --assert-budget) [ -n "$TIMINGS" ] || bad "--assert-budget needs TIMINGS" ;;
  *) bad "unknown verb '$VERB'" ;;
esac
TAB=$'\t'
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# ── --run ──────────────────────────────────────────────────────────────────
if [ "$VERB" = --run ]; then
  if [ -n "$SETD" ]; then
    case "$SETD" in /*) ;; *) SETD="$ROOT/$SETD" ;; esac
    ( set +f; for f in "$SETD"/*.txt; do [ -f "$f" ] && awk '/^[[:space:]]*(#|$)/ { next } { print $1 }' "$f"; done ) | LC_ALL=C sort -u > "$W/list"
    [ -s "$W/list" ] || { echo "fast-lints: the set $SETD names no suite; nothing to run" >&2; exit 2; }
  else
    "$HERE/fast-lints.sh" --list ${MAX:+--max-s "$MAX"} > "$W/list" || exit 2
  fi
  [ -s "$W/list" ] || { echo "fast-lints: the fast set is empty; nothing to run" >&2; exit 2; }
  if [ -z "$OUT" ]; then
    OUT=$(mktemp -d) || exit 2
    echo "fast-lints: writing to $OUT" >&2
  fi
  mkdir -p "$OUT/log" && OUT=$(cd "$OUT" && pwd) || { echo "fast-lints: cannot create $OUT" >&2; exit 2; }
  { : > "$OUT/timings.tsv" && : > "$OUT/suites.txt"; } || exit 2
  : > "$W/skip"
  if [ -n "$SKIPF" ]; then
    if [ -r "$SKIPF" ]; then
      awk '/^[[:space:]]*(#|$)/ { next } { print $1 }' "$SKIPF" > "$W/skip"
    else
      echo "fast-lints: skip file $SKIPF unreadable; nothing skipped" >&2
    fi
  fi
  cd "$ROOT" || exit 2
  red=0 missing=0
  while IFS= read -r s; do
    grep -qxF -- "$s" "$W/skip" && continue
    if [ ! -f "$s" ]; then
      printf '%s\t0\t127\n' "$s" >> "$OUT/timings.tsv"; missing=1
      echo "fast-lints: done $s rc=127 0s (no such suite)"; continue
    fi
    log="$OUT/log/$(basename "$s").log"
    t0=$(date +%s)
    HARNESS_TEST_SANDBOX=1 bash "$s" > "$log" 2>&1 < /dev/null
    rc=$?
    t1=$(date +%s)
    printf '%s\t%s\t%s\n' "$s" "$((t1 - t0))" "$rc" >> "$OUT/timings.tsv"
    echo "$s" >> "$OUT/suites.txt"
    echo "fast-lints: done $s rc=$rc $((t1 - t0))s"
    if [ "$rc" -ne 0 ]; then
      red=1
      { echo "--- $s ---"; cat "$log"; echo "--- $s ---"; } >&2
    fi
  done < "$W/list"
  [ "$red" = 1 ] && exit 1          # red wins over a missing entry: it must stop the push
  [ "$missing" = 1 ] && exit 2
  exit 0
fi

# ── --assert-budget ────────────────────────────────────────────────────────
if [ "$VERB" = --assert-budget ]; then
  [ -r "$TIMINGS" ] || { echo "fast-lints: timings file $TIMINGS unreadable" >&2; exit 2; }
  BUDGET=${BUDGET_ARG:-$(fl_knob FAST_LINTS_BUDGET_S 159)}
  MAXS=$(fl_knob FAST_LINTS_MAX_S 10)
  # One pass validates every line, sums column 2 and keeps the rows and the
  # slow ones. A malformed line is rc 2, never skipped.
  awk -F'\t' -v lim="$((2 * MAXS))" -v rows="$W/rows" -v slow="$W/slow" '
    $0 == "" { next }
    NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ { bad = NR; exit }
    { n++; sum += $2; print > rows; if ($2 + 0 > lim + 0) print $1 "\t" $2 > slow }
    END {
      if (bad) { printf "fast-lints: %s line %d is malformed (want <suite>, seconds, rc, tab-separated)\n", FILENAME, bad > "/dev/stderr"; exit 2 }
      if (!n) { printf "fast-lints: %s has no timing rows\n", FILENAME > "/dev/stderr"; exit 2 }
      print n, sum
    }
  ' "$TIMINGS" > "$W/sum" || exit 2
  read -r n sum < "$W/sum"
  # REPORTS, NOT GATES (BH-5292, the operator 2026-10-07). Seconds are not harmful in
  # themselves: over the budget and a slow suite are named on stderr for the
  # step log and the rc stays 0. A suite that is RED is --run's rc, not this.
  out=0
  if [ "$sum" -gt "$BUDGET" ]; then
    top=$(LC_ALL=C sort -t"$TAB" -k2,2nr -k1,1 "$W/rows" | head -3 \
      | awk -F'\t' '{ printf "%s%s (%ss)", (NR > 1 ? ", " : ""), $1, $2 }')
    echo "fast-lints: ${sum}s over the ${BUDGET}s budget — slowest: $top (a note, not a failure)" >&2
    out=1
  fi
  if [ -s "$W/slow" ]; then
    while IFS="$TAB" read -r s secs; do
      echo "fast-lints: $s took ${secs}s, over 2 x FAST_LINTS_MAX_S ($((2 * MAXS))s) (a note, not a failure)" >&2
    done < "$W/slow"
    out=1
  fi
  [ "$out" = 0 ] && echo "fast-lints: ${sum}s within the ${BUDGET}s budget ($n suites)"
  exit 0
fi

# ── --share-precheck ───────────────────────────────────────────────────────
if [ "$VERB" = --share-precheck ]; then
  fork=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null) || {
    echo "fast-lints: no merge base between $BASE and HEAD" >&2; exit 2; }
  # BH-5542: leak-check the lines this branch adds, text-only diffs included.
  # Its report goes to stderr: stdout stays the SKIP/RUN answer the step reads.
  python3 "$ROOT/bin/share/diffcheck.py" --base "$BASE" >&2
  case $? in
    0) ;;
    1) echo "fast-lints: share-mirror leak in the lines this branch adds; the hits and fixes are above" >&2; exit 1 ;;
    *) echo "fast-lints: the share diff check could not answer (bin/share/diffcheck.py)" >&2; exit 2 ;;
  esac
  # To a file, not $( ): the list is NUL-separated.
  git -C "$ROOT" diff -z --name-only --diff-filter=ACR "$fork"...HEAD > "$W/paths" || {
    echo "fast-lints: git diff $fork...HEAD failed" >&2; exit 2; }
  python3 - "$ROOT/bin/share" "$W/paths" <<'PY' || { echo "fast-lints: share precheck could not read bin/share/mapping.py" >&2; exit 2; }
import os
import sys

try:
    sys.path.insert(0, sys.argv[1])
    from mapping import (  # noqa: E402
        TEXT_EXT, FONT_EXT,
    )
    with open(sys.argv[2], "rb") as f:
        rels = [p.decode("utf-8", "replace") for p in f.read().split(b"\0") if p]
except Exception as e:  # any failure is "could not answer": rc 2, never SKIP
    print("fast-lints: %s: %s" % (type(e).__name__, e), file=sys.stderr)
    sys.exit(3)
flagged = []
for rel in rels:
    ext = os.path.splitext(rel)[1].lower()
    if ext not in TEXT_EXT and ext not in FONT_EXT:
        flagged.append((rel, ext or "no extension"))
if flagged:
    print("RUN")
    for rel, ext in flagged:
        print("  %s (%s)" % (rel, ext))
else:
    print("SKIP")
PY
  exit 0
fi

# ── --list ─────────────────────────────────────────────────────────────────
[ -n "$MAX" ] || MAX=$(fl_knob FAST_LINTS_MAX_S 10)
DUR="${FAST_LINTS_DURATIONS:-$ROOT/catalog/ci-suite-durations.tsv}"

"$ROOT/bin/test-impact.sh" always > "$W/always" 2> "$W/always.err"
arc=$?
if [ "$arc" -ne 0 ] || [ ! -s "$W/always" ]; then
  echo "fast-lints: the always-suite set is unavailable (test-impact.sh always rc=$arc)" >&2
  exit 2
fi
if [ ! -r "$DUR" ]; then
  echo "fast-lints: durations file $DUR unreadable; every suite is unmeasured" >&2
  : > "$W/dur"
else
  cp "$DUR" "$W/dur"
fi
: > "$W/rp"
[ -r "$ROOT/catalog/rules-pack.tsv" ] && awk -F'\t' '
  /^[[:space:]]*#/ { next }
  $3 == "suite" { split($4, a, " "); if (a[1] ~ /^tests\//) print a[1] }
' "$ROOT/catalog/rules-pack.tsv" > "$W/rp"

# Pass 1 rules-pack ids, pass 2 durations (last row wins), pass 3 the always set.
# The median is over the numeric rows, by insertion sort, the same rule as
# suite_shard_plan; an empty file has no median and its suites stay left out.
awk -F'\t' -v max="$MAX" -v fast="$W/fast" -v rpf="$W/rp" -v durf="$W/dur" '
  FILENAME == rpf  { rp[$1] = 1; next }
  FILENAME == durf { if ($0 !~ /^[[:space:]]*#/ && $1 != "") { d[$1] = $2; if ($2 ~ /^[0-9]+(\.[0-9]+)?$/) v[++k] = $2 + 0 }; next }
  $1 == "" { next }
  {
    if (!sorted) {
      sorted = 1
      for (a = 2; a <= k; a++) { x = v[a]; for (b = a - 1; b >= 1 && v[b] > x; b--) v[b + 1] = v[b]; v[b + 1] = x }
      if (k) med = (k % 2 ? v[(k + 1) / 2] : (v[k / 2] + v[k / 2 + 1]) / 2)
    }
    m++
    if ($1 in rp) next
    if (!($1 in d)) {
      un = un (un == "" ? "" : " ") $1
      if (!k) next
      w = med
    } else if (d[$1] !~ /^[0-9]+(\.[0-9]+)?$/) { un = un (un == "" ? "" : " ") $1; next }
    else w = d[$1]
    if (w + 0 <= max + 0) { n++; print $1 > fast } else over++
  }
  END {
    close(fast)
    printf "fast-lints: %d of %d always-suites at <=%ss; unmeasured: %s; over: %d\n", n, m, max, (un == "" ? "none" : un), over > "/dev/stderr"
  }
' "$W/rp" "$W/dur" "$W/always"
: >> "$W/fast"
LC_ALL=C sort -u "$W/fast"
