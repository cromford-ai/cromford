#!/bin/bash
# tests/tier-gate-removed.bh-5035-test.sh — BH-5035: the `human` value of
# tier_gate_mode is removed, and with it every tier hold.
#
# The tier stays a recorded risk class. No hand-off asks it who merges: the
# run-build APPROVE hand-off (`# >>> verdict at review` in bin/lib/rb/pr.sh and
# its settle twin `# >>> verdict artifact` in bin/lib/rb/result.sh) enqueues a
# tier ≠1 APPROVE whatever a tier_gate_mode row says, and bin/review-prs.sh
# merges an external APPROVE (fresh verdict and merge_retry) the same way.
#
# DRIVEN, NOT GREPPED (D2). Each block is cut out of the real pipeline by its
# own markers and run in one bash process. A `tg_holds` that ALWAYS holds is
# defined in that process and logs each call to $T/tg-calls: a block that still
# asks the tier gate is held and the case goes red. setting_get answers from
# $T/rows/<key> ($T/rows/FAIL = an outage), so a stored `human` row is in place
# too.
#   G1 pr.sh block, tier 2, tier_gate_mode.demo-os=human → one enqueue, tier-2 note
#   G2 result.sh block, same → one enqueue
#   G3 global human, tier 3 → one enqueue, no tier_gate_mode line
#   G4 settings unreadable → one enqueue, no ALERTS line, no page stamp
#   G5 no row, tier 1 → no enqueue from the hand-off (tier 1 self-merges; near miss)
#   G6 review-prs fresh merge, APPROVE tier 2, row human → merge_step once
#   G7 review-prs merge_retry, .tier 2, row human → reaches factory_stopped
#   G8 the lib is gone and nothing sources it
#   G9 the tier is still recorded: queue note and the review-prs beat line
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/tier-gate-removed.bh-5035-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR JOB_ID JOB_PHASE_ID

PROJECT=demo-os
SLUG=example-org/demo-os
ROWS="$T/rows"; CALLS="$T/calls"; TGC="$T/tg-calls"
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }

EARLY="$T/rb-early.sh"; SETTLE="$T/rb-settle.sh"
marked '# >>> verdict at review' '# <<< verdict at review' "$RB" > "$EARLY"
marked '# >>> verdict artifact'  '# <<< verdict artifact'  "$RB" > "$SETTLE"
[ -s "$EARLY" ]  && ok || bad "the pipeline carries no '# >>> verdict at review' block"
[ -s "$SETTLE" ] && ok || bad "the pipeline carries no '# >>> verdict artifact' block"

H="$T/h"; mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/state"
rows_reset() { scratch_rm "$ROWS"; mkdir -p "$ROWS"; rm -f "$H/logs/ALERTS.log"; }
row_set() { printf '%s\n' "$2" > "$ROWS/$1"; }

# blk <case> <tier> <block...> — the hand-off blocks in ONE bash process.
blk() {
  local c="$1" tier="$2"; shift 2
  B="$T/b-$c"; scratch_rm "$B"; mkdir -p "$B"; : > "$CALLS"; : > "$TGC"
  printf 'read the diff\nVERDICT: APPROVE\n' > "$B/review.md"
  ( export HARNESS="$H" BUILD="$B" PROJECT="$PROJECT" KEY=BH-5035 SLUG="$SLUG" \
           JOB_ID=job-1 TIER="$tier" PR_URL="https://github.com/$SLUG/pull/42" \
           ROWS="$ROWS" CALLS="$CALLS" TGC="$TGC" SCRIPTS="$*"
    bash -c '
      STAMP() { printf "2026-10-31 04:00:00Z"; }
      job_artifact_put() { return 0; }
      rp_out_is_claude() { return 0; }
      rp_out_prov() { printf claude; }
      to_lane_lead_hold() { return 1; }
      merge_queue_put() { printf "%s\n" "$*" >> "$CALLS"; }
      setting_get() { [ -e "$ROWS/FAIL" ] && return 1; [ -f "$ROWS/$1" ] || return 2; cat "$ROWS/$1"; }
      tg_holds() { printf "%s\n" "$*" >> "$TGC"; return 0; }
      for s in $SCRIPTS; do . "$s"; done' ) 2>"$T/err-$c"
}
ncalls() { grep -c . "$CALLS" 2>/dev/null || true; }
ntg() { grep -c . "$TGC" 2>/dev/null || true; }
plog() { cat "$B/pipeline.log" 2>/dev/null; }

# ── G1: pr.sh block, per-project human, tier 2 → enqueued once ───────────────
rows_reset; row_set "tier_gate_mode.$PROJECT" human
blk g1 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "G1: tier_gate_mode.$PROJECT=human must not hold a tier-2 APPROVE: $(ncalls) enqueues ($(plog))"
[ "$(ntg)" = 0 ] && ok || bad "G1: the pr.sh hand-off still asks tg_holds: $(cat "$TGC")"
grep -qF "tier-2 APPROVE from BH-5035" "$CALLS" && ok || bad "G1/G9: the queue note keeps the tier: $(cat "$CALLS")"
grep -qF 'APPROVE enqueued #42' <<<"$(plog)" && ok || bad "G1: pipeline.log must say enqueued: $(plog)"

# ── G2: result.sh block, same row → enqueued once ────────────────────────────
blk g2 2 "$SETTLE"
[ "$(ncalls)" = 1 ] && ok || bad "G2: the settle hand-off must enqueue under a human row: $(ncalls) ($(plog))"
[ "$(ntg)" = 0 ] && ok || bad "G2: the result.sh hand-off still asks tg_holds: $(cat "$TGC")"

# ── G3: global human, tier 3 → enqueued, no tier_gate_mode line ──────────────
rows_reset; row_set tier_gate_mode ' HUMAN '
blk g3 3 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "G3: a global human must not hold tier 3: $(ncalls)"
grep -qF 'tier-3 APPROVE from BH-5035' "$CALLS" && ok || bad "G3: the note keeps tier 3: $(cat "$CALLS")"
PL=$(plog)
grep -q 'tier_gate_mode\|tier gate' <<<"$PL" && bad "G3: pipeline.log still names the tier gate: $PL" || ok

# ── G4: settings unreadable → enqueued, nothing paged ────────────────────────
rows_reset; touch "$ROWS/FAIL"
blk g4 2 "$EARLY" "$SETTLE"
[ "$(ncalls)" = 1 ] && ok || bad "G4: an unreadable settings worker must not hold the hand-off: $(ncalls)"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "G4: no tier-gate page: $(cat "$H/logs/ALERTS.log")"
[ ! -e "$H/state/tier-gate" ] && ok || bad "G4: no tier-gate page stamp is written"

# ── G5: tier 1 never enqueues from the hand-off (near miss, unchanged) ───────
rows_reset
blk g5 1 "$EARLY" "$SETTLE"
[ "$(ncalls)" = 0 ] && ok || bad "G5: tier 1 must not enqueue from the hand-off: $(ncalls)"

# ── G6 / G7 / G9: bin/review-prs.sh ──────────────────────────────────────────
RP="$DIR/bin/review-prs.sh"
awk '/^  # >>> review-prs fresh merge/{f=1;next} /^  # <<< review-prs fresh merge/{exit} f' "$RP" > "$T/rp-fresh.sh"
awk '/^  # >>> review-prs beat line/{f=1;next} /^  # <<< review-prs beat line/{exit} f' "$RP" > "$T/rp-beat.sh"
awk '/^# >>> review-prs merge-retry/{f=1;next} /^# <<< review-prs merge-retry/{exit} f' "$RP" > "$T/rp-retry.sh"
[ -s "$T/rp-fresh.sh" ] && ok || bad "G6: no '# >>> review-prs fresh merge' block in bin/review-prs.sh"
[ -s "$T/rp-retry.sh" ] && ok || bad "G7: no '# >>> review-prs merge-retry' block in bin/review-prs.sh"
[ -s "$T/rp-beat.sh" ] && ok || bad "G9: no '# >>> review-prs beat line' block in bin/review-prs.sh"

: > "$T/rp.log"; : > "$T/rp-merge.txt"; : > "$TGC"
OUT=$(LOG="$T/rp.log" T="$T" TGC="$TGC" bash -c '
  set -uo pipefail
  STAMP() { printf TS; }
  setting_get() { printf human; }
  tg_holds() { printf "%s\n" "$*" >> "$TGC"; return 0; }
  merge_step() { echo "merge_step $*" >> "$T/rp-merge.txt"; MERGED=yes; }
  PROJECT=project-4 NUM=77 SHA=aaaaaaaa1111 SERVED=claude AUTHOR=collaborator-1 RP_ADVISORY=0 RP_MODEL=- VERDICT=APPROVE TIER=2
  . "$0"
  printf "MERGED=%s\n" "$MERGED"' "$T/rp-fresh.sh" 2>"$T/rp.err")
[ "$(grep -c . "$T/rp-merge.txt")" = 1 ] && grep -q 'MERGED=yes' <<<"$OUT" && ok \
  || bad "G6: a tier-2 APPROVE under a human row must run merge_step once (out '$OUT'; log $(cat "$T/rp.log"); err $(cat "$T/rp.err"))"
[ "$(ntg)" = 0 ] && ok || bad "G6: the fresh merge still asks tg_holds: $(cat "$TGC")"
grep -q 'left unmerged: tier_gate_mode' "$T/rp.log" && bad "G6: the tier hold line is still written: $(cat "$T/rp.log")" || ok

printf '{"77":{"verdict":"APPROVE","tier":"2","served":"claude","merge_retries":0}}\n' > "$T/rp-state.json"
: > "$T/rp-retry.log"; : > "$TGC"
STATE="$T/rp-state.json" T="$T" TGC="$TGC" bash -c '
  set -uo pipefail
  STAMP() { printf TS; }
  setting_get() { printf human; }
  tg_holds() { printf "%s\n" "$*" >> "$TGC"; return 0; }
  rp_prov_is_claude() { return 0; }
  factory_stopped() { echo factory_stopped >> "$T/rp-retry.log"; return 0; }
  PROJECT=project-4 SLUG=example-org/project-4-fx MERGED=
  . "$0"
  merge_retry 77 aaaaaaaa1111' "$T/rp-retry.sh" 2>"$T/rp.err"
grep -qx factory_stopped "$T/rp-retry.log" && ok \
  || bad "G7: merge_retry on a tier-2 APPROVE under a human row must reach the factory_stopped check (err $(cat "$T/rp.err"))"
[ "$(ntg)" = 0 ] && ok || bad "G7: merge_retry still asks tg_holds: $(cat "$TGC")"

LINE=$(MQ=1 MERGED=no VERDICT=APPROVE bash -c '
  set -uo pipefail
  mc_queue_conductor_only() { return 0; }
  NUM=77 AUTHOR=collaborator-1 TIER=2 SLUG=example-org/project-4-fx
  . "$0"; printf "%s\n" "$LINE"' "$T/rp-beat.sh" 2>&1)
grep -q 'APPROVE tier 2' <<<"$LINE" && ok || bad "G9: the review-prs beat still records the tier: '$LINE'"

# ── G8: the lib is gone and nothing sources it ───────────────────────────────
[ ! -e "$DIR/bin/lib/tier-gate.sh" ] && ok || bad "G8: bin/lib/tier-gate.sh must be deleted"
for f in bin/lib/rb/pr.sh bin/lib/rb/result.sh bin/review-prs.sh; do
  SRC=$(grep -v '^[[:space:]]*#' "$DIR/$f")
  grep -q 'tier-gate\.sh\|tg_holds\|tier_gate_mode' <<<"$SRC" && bad "G8: $f still names the tier gate on a code line" || ok
done

# ── G10: the jobs worker refuses a human row at the write ────────────────────
# The route cases are worker/jobs/test/retired-mode-values.bh-5035.test.js;
# this drives the pure refusal the PUT handler calls.
RMV="$DIR/worker/jobs/src/lib/retired-mode-values.js"
if ! command -v node >/dev/null 2>&1; then
  echo "tier-gate-removed: G10 SKIPPED — node is not installed on this box (the worker CI job runs the route cases)"
else
  G10=$(RMV="$RMV" node --input-type=module -e '
    const { retiredModeRefusal } = await import(process.env.RMV);
    for (const [k, v] of [["tier_gate_mode.demo-os", " Human "], ["tier_gate_mode", "off"], ["tier_gate_mode_x", "human"]])
      console.log(`${k}|${retiredModeRefusal(k, v)}`);' 2>&1)
  grep -qxF 'tier_gate_mode.demo-os|tier_gate_mode.demo-os=human was removed by BH-5035: the tier and the lead lane no longer wait on a person. Delete the row, or set tier_gate_mode.demo-os to off.' <<<"$G10" \
    && ok || bad "G10: a tier_gate_mode.<p>=human write is refused with the BH-5035 text: $G10"
  grep -qxF 'tier_gate_mode|null' <<<"$G10" && grep -qxF 'tier_gate_mode_x|null' <<<"$G10" \
    && ok || bad "G10: off, and a key without the dot, are not refused: $G10"
fi

echo "tier-gate-removed.bh-5035: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
