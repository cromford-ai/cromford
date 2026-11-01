#!/bin/bash
# tests/tier-retired.bh-4572-test.sh — THE TIER NO LONGER DECIDES WHO MERGES
# (BH-4572, tracer slice BH-4579).
#
# the operator, 2026-10-05: retire the tier-2 human sign-off. The tier stays computed
# and recorded as a risk class. A tier-2 APPROVE goes on the merge queue like
# any other. BH-5035 removed the tier_gate_mode `human` opt-in: a stored
# row of any value, or an unreadable settings worker, changes nothing.
# TEST-CHANGE BH-5035: tier_gate_mode is no longer read; a human, garbage or unreadable row is inert (the APPROVE enqueues, no page, no stamp, no hold line)
#
# DRIVEN, NOT GREPPED (D2/D3). Both hand-off blocks — `# >>> verdict at review`
# (bin/lib/rb/pr.sh) and its settle twin `# >>> verdict artifact`
# (bin/lib/rb/result.sh) — are extracted from the flattened pipeline by their
# own markers and executed against a scratch $HARNESS that carries the real
# bin/alert-line.sh. setting_get is a stub
# over $T/rows/<key> (absent = rc 2 no row, $T/rows/FAIL = rc 1 outage), and
# merge_queue_put appends its arguments to $T/calls. Every assertion reads
# $T/calls, the build's pipeline.log, ALERTS.log or the (absent) page stamp.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/tier-retired.bh-4572-test.sh
# (exit 0 = all pass)
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
DAY=2026-10-05          # pinned through TG_PAGE_DAY: no clock read in this file
ROWS="$T/rows"; CALLS="$T/calls"
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }

EARLY="$T/rb-early.sh"; SETTLE="$T/rb-settle.sh"
marked '# >>> verdict at review' '# <<< verdict at review' "$RB" > "$EARLY"
marked '# >>> verdict artifact'  '# <<< verdict artifact'  "$RB" > "$SETTLE"
[ -s "$EARLY" ]  && ok || bad "the pipeline carries no '# >>> verdict at review' block"
[ -s "$SETTLE" ] && ok || bad "the pipeline carries no '# >>> verdict artifact' block"

# fresh_h <name> — a scratch harness with the pager and its source closure
# (BH-4552). BH-5035: there is no gate lib to install.
fresh_h() {
  local h="$T/h-$1"
  scratch_rm "$h"; mkdir -p "$h/bin/lib" "$h/logs" "$h/flags" "$h/state"
  scratch_install_closure bin/alert-line.sh "$h" >/dev/null || return 1
  printf '%s\n' "$h"
}
rows_reset() { scratch_rm "$ROWS"; mkdir -p "$ROWS"; }
row_set() { printf '%s\n' "$2" > "$ROWS/$1"; }

# blk <harness> <case> <tier> <block...> — run the blocks in ONE bash process.
blk() {
  local h="$1" c="$2" tier="$3"; shift 3
  B="$T/b-$c"; scratch_rm "$B"; mkdir -p "$B"; : > "$CALLS"
  printf 'read the diff\nVERDICT: APPROVE\n' > "$B/review.md"
  ( export HARNESS="$h" BUILD="$B" PROJECT="$PROJECT" KEY=BH-4579 SLUG="$SLUG" \
           JOB_ID=job-1 TIER="$tier" PR_URL="https://github.com/$SLUG/pull/42" \
           ROWS="$ROWS" CALLS="$CALLS" TG_PAGE_DAY="$DAY" ALERT_LINE_STAMP="$DAY 04:00:00Z" \
           SCRIPTS="$*"
    bash -c '
      STAMP() { printf "2026-10-05 04:00:00Z"; }
      job_artifact_put() { return 0; }
      rp_out_is_claude() { return 0; }
      rp_out_prov() { printf claude; }
      to_lane_lead_hold() { return 1; }
      merge_queue_put() { printf "%s\n" "$*" >> "$CALLS"; }
      setting_get() { [ -e "$ROWS/FAIL" ] && return 1; [ -f "$ROWS/$1" ] || return 2; cat "$ROWS/$1"; }
      for s in $SCRIPTS; do . "$s"; done' ) 2>"$T/err-$c"
}
ncalls() { grep -c . "$CALLS" 2>/dev/null || true; }
nalerts() { if [ -f "$1/logs/ALERTS.log" ]; then grep -c . "$1/logs/ALERTS.log"; else echo 0; fi; }
plog() { cat "$B/pipeline.log" 2>/dev/null; }

# ── T1: no row → a tier-2 APPROVE enqueues exactly once, same shape as before ─
rows_reset; H1=$(fresh_h t1)
blk "$H1" t1 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T1: no row must enqueue once, got $(ncalls) ($(cat "$T/err-t1"))"
[ "$(cat "$CALLS")" = "$PROJECT 42 $SLUG tier-2 APPROVE from BH-4579" ] \
  && ok || bad "T1: the enqueue must keep its shape, got: $(cat "$CALLS")"
grep -q 'APPROVE enqueued #42' <<<"$(plog)" && ok || bad "T1: pipeline.log must say enqueued: $(plog)"
[ "$(nalerts "$H1")" = 0 ] && ok || bad "T1: no row is not an alert: $(cat "$H1/logs/ALERTS.log")"

# ── T1b: the settle twin, MQ_ENQUEUED unset, no row → one call ───────────────
rows_reset; blk "$H1" t1b 2 "$SETTLE"
[ "$(ncalls)" = 1 ] && ok || bad "T1b: the settle block with no row must enqueue once, got $(ncalls) ($(cat "$T/err-t1b"))"

# ── T2: per-project human → inert: enqueued, no hold line, no page ─────────
# TEST-CHANGE BH-5035: was "held, named, no page".
rows_reset; row_set tier_gate_mode.$PROJECT human; H2=$(fresh_h t2)
blk "$H2" t2 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T2: tier_gate_mode.$PROJECT=human is inert and must enqueue once, got $(ncalls) calls"
grep -qF 'tier_gate_mode' <<<"$(plog)" && bad "T2: no tier_gate_mode hold line: $(plog)" || ok
[ "$(nalerts "$H2")" = 0 ] && ok || bad "T2: a human row is not an alert: $(cat "$H2/logs/ALERTS.log")"

# ── T2b: the settle twin under the same row → enqueued too ───────────────────
blk "$H2" t2b 2 "$SETTLE"
[ "$(ncalls)" = 1 ] && ok || bad "T2b: the settle twin must enqueue under human, got $(ncalls) calls"
grep -qF 'tier_gate_mode' <<<"$(plog)" && bad "T2b: no settle hold line: $(plog)" || ok
blk "$H2" t2b2 2 "$EARLY" "$SETTLE"
[ "$(ncalls)" = 1 ] && ok || bad "T2b: both blocks in one build write exactly one row under human, got $(ncalls)"

# ── T2c: global human, per-project off → enqueued either way ─────────────────
rows_reset; row_set tier_gate_mode human; row_set tier_gate_mode.$PROJECT off
blk "$H2" t2c 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T2c: a per-project off with a global human must enqueue, got $(ncalls) calls"
rows_reset; row_set tier_gate_mode human
blk "$H2" t2c2 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T2c: a global human with no project row must enqueue, got $(ncalls)"
grep -qF 'tier_gate_mode' <<<"$(plog)" && bad "T2c: no global source is named: $(plog)" || ok

# ── T2d: ' HUMAN ' → inert, tier 3 enqueued with its tier in the note ────────
rows_reset; row_set tier_gate_mode.$PROJECT ' HUMAN '
blk "$H2" t2d 3 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T2d: ' HUMAN ' must be inert and enqueue, got $(ncalls)"
[ "$(cat "$CALLS")" = "$PROJECT 42 $SLUG tier-3 APPROVE from BH-4579" ] \
  && ok || bad "T2d: the enqueue keeps the tier-3 note: $(cat "$CALLS")"
[ "$(nalerts "$H2")" = 0 ] && ok || bad "T2d: no page: $(cat "$H2/logs/ALERTS.log")"

# ── T3: an unreadable settings worker → enqueued, no page, no stamp ──────────
rows_reset; touch "$ROWS/FAIL"; H3=$(fresh_h t3)
blk "$H3" t3 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T3: an unreadable row must not hold, got $(ncalls) calls"
[ "$(nalerts "$H3")" = 0 ] && ok || bad "T3: no page, got $(nalerts "$H3"): $(cat "$H3/logs/ALERTS.log" 2>/dev/null)"
grep -qF '[tier-gate]' "$H3/logs/ALERTS.log" 2>/dev/null \
  && bad "T3: no [tier-gate] page: $(cat "$H3/logs/ALERTS.log")" || ok
[ ! -e "$H3/state/tier-gate" ] && ok || bad "T3: no page stamp is written"
grep -qF 'APPROVE enqueued #42' <<<"$(plog)" && ok || bad "T3: the enqueue line: $(plog)"

# ── T4: again the same day, both blocks → one row, still no page ─────────────
blk "$H3" t4 2 "$EARLY" "$SETTLE"
[ "$(ncalls)" = 1 ] && ok || bad "T4: a second unreadable read must enqueue once, got $(ncalls)"
[ "$(nalerts "$H3")" = 0 ] && ok || bad "T4: still no page, got $(nalerts "$H3")"

# ── T4b: garbage 'maybe' → inert, no page ────────────────────────────────────
rows_reset; row_set tier_gate_mode.$PROJECT maybe; H4=$(fresh_h t4b)
blk "$H4" t4b 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T4b: 'maybe' must be inert and enqueue, got $(ncalls)"
[ "$(nalerts "$H4")" = 0 ] && ok || bad "T4b: 'maybe' pages nobody, got $(nalerts "$H4")"

# ── T4c: no pager and an unreadable row → still enqueued ─────────────────────
rows_reset; touch "$ROWS/FAIL"; H4C=$(fresh_h t4c); rm -f "$H4C/bin/alert-line.sh"
blk "$H4C" t4c 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T4c: no pager must still enqueue, got $(ncalls)"
[ ! -e "$H4C/state/tier-gate" ] && ok || bad "T4c: no page stamp"

# ── T5: TIER 1 never reaches merge_queue_put from either block ───────────────
rows_reset; blk "$H1" t5 1 "$EARLY" "$SETTLE"
[ "$(ncalls)" = 0 ] && ok || bad "T5: tier 1 must never enqueue from the hand-off, got $(ncalls)"
rows_reset; touch "$ROWS/FAIL"; H5=$(fresh_h t5)
blk "$H5" t5b 1 "$EARLY" "$SETTLE"
[ "$(nalerts "$H5")" = 0 ] && ok || bad "T5: a tier-1 build never reads the gate, so never pages"

# ── T6: there is no file flag ────────────────────────────────────────────────
rows_reset; H6=$(fresh_h t6); touch "$H6/flags/tier-gate-mode" "$H6/flags/tier-gate" "$H6/flags/tier_gate_mode"
blk "$H6" t6 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T6: a flags/tier-gate* file must have no effect, got $(ncalls) calls"

# ── T7: the rename ───────────────────────────────────────────────────────────
grep -qE '^[^#]*\. "\$H/bin/lib/autoenqueue\.sh"' "$DIR/bin/merge-conductor.sh" \
  && ok || bad "T7: bin/merge-conductor.sh must source \$H/bin/lib/autoenqueue.sh on a non-comment line"
[ -f "$DIR/bin/lib/autoenqueue.sh" ] && ok || bad "T7: bin/lib/autoenqueue.sh is missing"
[ ! -e "$DIR/bin/lib/tier2-autoenqueue.sh" ] && ok || bad "T7: bin/lib/tier2-autoenqueue.sh must be gone"
# A suite that still copies or sources the old path exits at setup; a merge from main can bring one in.
T7_STALE=$(grep -rlE 'tier2-autoenqueue\.sh' "$DIR/tests" --include='*.sh' 2>/dev/null | grep -vF "$DIR/tests/fixtures/" | grep -vxF "$DIR/tests/tier-retired.bh-4572-test.sh")
[ -z "$T7_STALE" ] && ok || bad "T7: tests still name bin/lib/tier2-autoenqueue.sh: $T7_STALE"
grep -qF 'state/tier2-autoenqueue.txt' "$DIR/bin/lib/autoenqueue.sh" \
  && ok || bad "T7: the ledger path state/tier2-autoenqueue.txt must be kept"

# ── T8: the gate lib is gone; a human row still enqueues ────────────────────
# TEST-CHANGE BH-5035: was "a harness without the lib enqueues and says so".
rows_reset; row_set tier_gate_mode.$PROJECT human; H8=$(fresh_h t8)
blk "$H8" t8 2 "$EARLY"
[ "$(ncalls)" = 1 ] && ok || bad "T8: a human row must enqueue, got $(ncalls)"
grep -qF 'tier gate lib not loaded' <<<"$(plog)" && bad "T8: the hand-off no longer looks for a gate lib: $(plog)" || ok
[ ! -e "$DIR/bin/lib/tier-gate.sh" ] && ok || bad "T8: bin/lib/tier-gate.sh must be deleted (BH-5035)"

# ── T9: the contract from the outside — any tier, any row, one enqueue ───────
# TEST-CHANGE BH-5035: was tg_holds called directly; the function is deleted.
H9=$(fresh_h t9)
for tv in "2 human" "3 human" "2 off" "2 FAIL"; do
  set -- $tv
  rows_reset
  if [ "$2" = FAIL ]; then touch "$ROWS/FAIL"; else row_set tier_gate_mode.$PROJECT "$2"; fi
  blk "$H9" "t9-$1-$2" "$1" "$EARLY"
  [ "$(ncalls)" = 1 ] && ok || bad "T9: tier $1 with row '$2' must enqueue once, got $(ncalls)"
done
rows_reset; row_set tier_gate_mode.$PROJECT human
blk "$H9" t9-1 1 "$EARLY"
[ "$(ncalls)" = 0 ] && ok || bad "T9: tier 1 still never enqueues from the hand-off, got $(ncalls)"

# ── T10: the renamed lib with no root writes nothing (BH-2613 contract) ─────
# The rename makes bin/lib/autoenqueue.sh a new path to the root-literal
# ratchet, so its /root/harness fallback went: with MC_H, HARNESS and H all
# empty, ae_mark and ae_project must write nothing. The tick path is pointed
# into $NR after the source, so a regressed guard writes there, never under /.
NR="$T/noroot"; scratch_rm "$NR"; mkdir -p "$NR"
( cd "$NR" && env -u HARNESS -u H -u MC_H -u MC_TICK_DIR MC_TICK_ID=t1 NR="$NR" \
    AE="$DIR/bin/lib/autoenqueue.sh" bash -c '
    mc_log() { printf "%s\n" "$*" >> "$NR/mc.log"; }
    . "$AE" || exit 9
    [ -z "$(_ae_home)" ] || exit 8
    _ae_tick_file() { printf "%s/leak" "$NR"; }
    ae_mark demo-os ready k1 abc
    ae_project demo-os example-org/demo-os mergify main' ) 2>/dev/null
[ ! -e "$NR/leak" ] && ok || bad "T10: ae_mark with no root must write no tick file"
grep -qF 'no harness root' "$NR/mc.log" 2>/dev/null \
  && ok || bad "T10: ae_project with no root must say so: $(cat "$NR/mc.log" 2>/dev/null)"

# ── T11: _ae_alert with no mc_alert pages through bin/alert-line.sh ────────
# The rename made the lib new to the alert-writers ratchet too, so its raw
# ALERTS.log fallback now goes through the pager.
H11=$(fresh_h t11)
( MC_H="$H11" ALERT_LINE_STAMP="$DAY 04:00:00Z" AE="$DIR/bin/lib/autoenqueue.sh" bash -c '
    . "$AE" || exit 9
    _ae_alert demo-os#42 "fixture line"' ) 2>/dev/null
grep -qxF "$DAY 04:00:00Z [merge-conductor] demo-os#42 AUTOENQUEUE — fixture line" "$H11/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "T11: the fallback page is missing: $(cat "$H11/logs/ALERTS.log" 2>/dev/null)"

# ── M1: THE MUTATION. A hand-off that still asks a tg_holds must fail T2 ────
# TEST-CHANGE BH-5035: was a mutant of the deleted bin/lib/tier-gate.sh. Now a
# tg_holds that always holds is defined in the block's process: the hand-off
# must not call it, so the enqueue still happens.
rows_reset; row_set tier_gate_mode.$PROJECT human; HM=$(fresh_h m1)
MSH="$T/tg-hold-stub.sh"; printf 'tg_holds() { echo tg >> "%s/tg-called"; return 0; }\n' "$T" > "$MSH"
rm -f "$T/tg-called"
blk "$HM" m1a 2 "$MSH" "$EARLY" "$SETTLE"
[ "$(ncalls)" = 1 ] && ok || bad "M1: a hand-off that still asks tg_holds is held (T2 has no teeth otherwise), got $(ncalls)"
[ ! -e "$T/tg-called" ] && ok || bad "M1: neither hand-off block may call tg_holds"

echo "tier-retired.bh-4572: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
