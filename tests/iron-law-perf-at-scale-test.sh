#!/bin/bash
# tests/iron-law-perf-at-scale-test.sh — the PERFORMANCE AT SCALE iron law
# (2026-11-17) reaches its stages through the BH-6557 law-set fragment, the
# fleet rules render and the ALWAYS-BLOCK catalog.
#
#   P1  sil_text: preplan plan execute fix review lead-review carry the title,
#       the PLAN line, the EXECUTE enum line and the BLOCK line. qa, prodqa,
#       triage and "" carry none.
#   P2  rules/topics/18-performance-at-scale.md body == the fragment body. The
#       render carries the title. render-rules --check is clean.
#   P3  rl_line_blocks: a [BLOCK perf-at-scale] line stands. A sub-threshold
#       speed line and a misspelled class do not stand.
#   P4  perf-at-scale is in the catalog and in the five class lists. The
#       performance plan sentence names background jobs, sweeps and agent polls.
#   P5  mutation: with the catalog row cut, the P3 line no longer stands.
#   P6  _dp_droppable accepts perf-at-scale and still protects secret.
#   P7  rl_prompt_note names the class for the two owner-approved cases only.
#       The perf-ticket case keeps its old BLOCK and never names the class.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/iron-law-perf-at-scale-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/bin/lib/stage-iron-laws.sh" || { echo "FAIL: bin/lib/stage-iron-laws.sh missing"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LAWS_DIR="$DIR/prompts/iron-laws.d"
FRAG="$LAWS_DIR/20261117-performance-at-scale.md"
TOPIC="$DIR/rules/topics/18-performance-at-scale.md"
TITLE='PERFORMANCE AT SCALE (iron law, 2026-11-17)'
PLANL='- each table it reads, and its expected row count in 12 months'
EXECL='With Prisma, a partial index never names an enum column in its WHERE'
BLOCKL='REVIEW BLOCK: `[BLOCK perf-at-scale]` for a measured regression on a key screen'
MEMBERS="preplan plan execute fix review lead-review"

# ── P1 ─────────────────────────────────────────────────────────────────────
echo "--- P1"
[ "$(head -1 "$FRAG" 2>/dev/null)" = "stages: $MEMBERS" ] && ok || bad "P1 stages line: '$(head -1 "$FRAG" 2>/dev/null)'"
grep -q $'[\t\r]' "$FRAG" 2>/dev/null && bad "P1 the fragment has a tab or CR" || ok
for st in $MEMBERS; do
  got=$(sil_text "$st" "$LAWS_DIR")
  for c in "$TITLE" "$PLANL" "$EXECL" "$BLOCKL"; do
    grep -qF -- "$c" <<<"$got" && ok || bad "P1 $st lacks '$c'"
  done
done
for st in qa prodqa triage ""; do
  grep -qF -- "$TITLE" <<<"$(sil_text "$st" "$LAWS_DIR")" && bad "P1 non-member '$st' carries the law" || ok
done

# ── P2 ─────────────────────────────────────────────────────────────────────
echo "--- P2"
cmp -s <(tail -n +3 "$TOPIC") <(tail -n +3 "$FRAG") && ok || bad "P2 the topic body is not the fragment body"
grep -qF -- "$TITLE" "$DIR/rules/CLAUDE.md" && ok || bad "P2 rules/CLAUDE.md lacks the title"
"$DIR/bin/render-rules.sh" --root "$DIR" --check >/dev/null 2>&1 && ok || bad "P2 render-rules --check is not clean"

# ── P3 ─────────────────────────────────────────────────────────────────────
echo "--- P3"
S1='[BLOCK perf-at-scale] app/cron/sweep.ts:40: findMany on ClientMessage (plan: 600k rows in 12 months) has no take and no index on (status, createdAt)'
N1='- [BLOCK] a sequential await over two independent reads'
N2='- [BLOCK perf-at-scal] the list query has no index'
p3_stands() {
  HARNESS="$1" bash -c 'unset REVIEW_LEVEL_MODE; . "$0/bin/lib/review-level.sh" || exit 9; rl_line_blocks "$1"' "$1" "$2"
}
p3_stands "$DIR" "$S1"; rc=$?
[ "$rc" = 0 ] && ok || bad "P3 must stand (rc $rc): $S1"
for l in "$N1" "$N2"; do
  p3_stands "$DIR" "$l"; rc=$?
  [ "$rc" = 1 ] && ok || bad "P3 must not stand (rc $rc): $l"
done

# ── P4 ─────────────────────────────────────────────────────────────────────
echo "--- P4"
grep -qx 'perf-at-scale' <(grep -v '^#' "$DIR/catalog/review-always-block.tsv" | awk -F'\t' 'NF{print $1}') && ok \
  || bad "P4 catalog has no perf-at-scale row"
for f in bin/review-prs.sh prompts/stages/review.md prompts/lead-review.md \
         rules/topics/13-review-levels.md prompts/iron-laws.d/20261016-review-levels.md; do
  grep -qE -- '(^|[^a-z-])`?perf-at-scale`?([^a-z-]|$)' "$DIR/$f" && ok || bad "P4 $f does not name class 'perf-at-scale'"
done
SCOPE='a plan for a screen, loader, background job, sweep or agent poll lists its reads'
for f in prompts/stages/plan.md prompts/stages/execute.md bin/run-preplan.sh rules/topics/04-building-software.md; do
  grep -qF -- "$SCOPE" "$DIR/$f" && ok || bad "P4 $f lacks the widened scope sentence"
done

# ── P6 the disprove lane can drop a refuted perf-at-scale BLOCK ────────────
echo "--- P6"
dp() { HARNESS="$DIR" bash -c '. "$0/bin/lib/review-disprove.sh" || exit 9; _dp_droppable "$1"' "$DIR" "$1"; }
dp perf-at-scale; rc=$?
[ "$rc" = 0 ] && ok || bad "P6 _dp_droppable must accept perf-at-scale (rc $rc)"
dp secret; rc=$?
[ "$rc" = 1 ] && ok || bad "P6 _dp_droppable must still protect secret (rc $rc)"

# ── P7 the prompt note: two block cases, the perf ticket outside the class ──
echo "--- P7"
note=$(HARNESS="$DIR" bash -c 'unset REVIEW_LEVEL_MODE; . "$0/bin/lib/review-level.sh" || exit 9; rl_prompt_note p' "$DIR")
grep -qF 'Speed: [BLOCK perf-at-scale] only for a measured regression on a key screen over 300 ms' <<<"$note" && ok || bad "P7 the note lacks the class and the key-screen case: $note"
grep -qF 'an unbounded or unindexed read that this diff adds or changes on a table the plan expects past 100k rows.' <<<"$note" && ok || bad "P7 the note lacks the diff-scoped 100k case: $note"
# The perf-ticket case keeps its old level and never names the class.
for f in "$DIR/prompts/iron-laws.d/20261016-review-levels.md" "$DIR/rules/topics/13-review-levels.md" \
         "$DIR/prompts/iron-laws.d/20261117-performance-at-scale.md" "$DIR/catalog/review-always-block.tsv"; do
  grep -iE 'perf-at-scale[^.]*perf ticket' "$f" >/dev/null && bad "P7 $f attaches perf-at-scale to the perf-ticket case" || ok
done
grep -iE 'perf-at-scale[^.]*perf ticket' <<<"$note" >/dev/null && bad "P7 the note attaches perf-at-scale to the perf-ticket case" || ok
grep -qF 'A BLOCK also on a perf ticket.' <<<"$note" && ok || bad "P7 the perf-ticket BLOCK must keep its old level: $note"

# ── P5 ─────────────────────────────────────────────────────────────────────
echo "--- P5"
M="$T/mut"; mkdir -p "$M"
scratch_install_closure bin/lib/review-level.sh "$M" >/dev/null || bad "P5 closure install of bin/lib/review-level.sh"
cp -R "$DIR/catalog" "$M/"
grep -v '^perf-at-scale' "$DIR/catalog/review-always-block.tsv" > "$M/catalog/review-always-block.tsv"
p3_stands "$M" "$S1"; rc=$?
[ "$rc" = 1 ] && ok || bad "P5 with the row cut, S1 must stop standing (rc $rc)"

echo "iron-law-perf-at-scale: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
