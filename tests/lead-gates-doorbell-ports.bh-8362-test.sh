#!/bin/bash
# tests/lead-gates-doorbell-ports.bh-8362-test.sh — the lead-chain doorbell
# (bin/lib/lead-chain-wake.sh lcw_ring) as the worklist's post hook rings it
# (lg_post_doorbell, bin/lib/lead-gates.d/97-doorbell.sh), for the outcomes the
# gate suite (tests/lead-gates-doorbell.bh-5876-test.sh) does not pin. Every
# case drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh,
# lead-gates-fixture.bh-5876.sh).
#   DP1  PR 41 on head A rings once, dedupe `lead-review:41@<A12>`; the same PR
#        on a new head B rings once more, dedupe `lead-review:41@<B12>`.
#   DP2  a second tick on head A, whose review is done (paid already): no new ring.
#   DP3  bin/lib/lead-chain-wake.sh absent from the harness: the job still
#        opens, and the log says `doorbell not rung (no lcw_ring)`.
#   M1   97-doorbell.sh removed: DP1's head A rings 0 times (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-doorbell-ports.bh-8362-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
lg6_setup
GD="$H/bin/lib/lead-gates.d"
LCW="$H/bin/lib/lead-chain-wake.sh"
for f in bin/lib/lead-gates.d/97-doorbell.sh bin/lib/lead-chain-wake.sh; do
  [ -r "$LWF_SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
# Real heads in the clone, so each review finishes and its row is done.
HA=$(lg6_head 41 d/a.txt "head a") || bad "setup: head A"; A12=${HA:0:12}
HB=$(lg6_head 41 d/b.txt "head b") || bad "setup: head B"; B12=${HB:0:12}
[ "$A12" != "$B12" ] && ok || bad "setup: heads A and B share a sha12"
# dedupes — the dedupe key of every lead-review ring, one a line
dedupes() {
  grep '^POST /api/wakes/lane ' "$T/log/worker" 2>/dev/null | grep '"kind":"lead-review"' | sed 's#^POST /api/wakes/lane ##' \
    | jq -r '.dedupe' 2>/dev/null
}

# ── DP1: head A rings once; a new head B rings once more ──
lg6_reset; lgf_needs "41:$HA"
lwf_tick
[ "$(lgf_jobs 41)" = 1 ] && ok || bad "DP1 no job on head A: $(cat "$L")"
[ "$(lg6_rings)" = 1 ] && ok || bad "DP1 rings on head A=$(lg6_rings): $(grep wakes "$T/log/worker")"
[ "$(dedupes)" = "lead-review:41@$A12" ] && ok || bad "DP1 head A dedupe: $(dedupes)"

# ── DP2: head A again, its row finished: no new ring ──
lwf_tick
[ "$(lg6_rings)" = 1 ] && ok || bad "DP2 rings after a second tick on head A=$(lg6_rings): $(dedupes)"
grep -qF "paid already lr-41-$A12: its request is done; no agent call" "$L" && ok || bad "DP2 head A not seen as paid: $(cat "$L")"

lgf_needs "41:$HB"
lwf_tick
[ "$(lg6_rings)" = 2 ] && ok || bad "DP1 rings after head B=$(lg6_rings): $(dedupes)"
[ "$(dedupes | sed -n 2p)" = "lead-review:41@$B12" ] && ok || bad "DP1 head B dedupe: $(dedupes)"
grep -qF "example-org/cromford#41 @$B12: lead-review doorbell rung" "$L" && ok || bad "DP1 no rung line for head B: $(cat "$L")"

# ── DP3: no lead-chain-wake lib: the job opens, one no-lib line ──
mv "$LCW" "$T/lcw.off"
lg6_reset; lgf_needs "41:$HA"
lwf_tick
[ "$(lgf_jobs 41)" = 1 ] && ok || bad "DP3 no job with the lib absent: $(cat "$L") $(tail -5 "$T/out")"
[ "$(lg6_rings)" = 0 ] && ok || bad "DP3 rings=$(lg6_rings) with the lib absent"
grep -qF "example-org/cromford#41 @$A12: doorbell not rung (no lcw_ring); the */15 cron covers it" "$L" && ok \
  || bad "DP3 no no-lib line: $(cat "$L")"
mv "$T/lcw.off" "$LCW"

# ── M1: no doorbell gate: head A rings nothing ──
mv "$GD/97-doorbell.sh" "$T/97.off"
lg6_reset; lgf_needs "41:$HA"
lwf_tick
[ "$(lgf_jobs 41)" = 1 ] && ok || bad "M1 no job: $(cat "$L")"
[ "$(lg6_rings)" = 0 ] && ok || bad "M1 rings=$(lg6_rings) with 97-doorbell.sh gone"
mv "$T/97.off" "$GD/97-doorbell.sh"

echo "lead-gates-doorbell-ports.bh-8362: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
