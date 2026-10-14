#!/bin/bash
# tests/lead-gates-doorbell.bh-5876-test.sh — BH-5876 (BH-5870.3): gate 15 of
# the enqueue, the lead-chain doorbell (BH-4057), as the worklist post hook
# lg_post_doorbell in bin/lib/lead-gates.d/97-doorbell.sh. Every case drives
# bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh,
# lead-gates-fixture.bh-5876.sh).
#   D1  a start: one POST /api/wakes/lane, kind lead-review, deduped on this
#       PR head, and the `lead-review doorbell rung` line.
#   D2  a held head (DIRTY): no lead-review ring.
#   D3  the wakes route answers 500: the review still runs, and the line says
#       `doorbell not rung (rc 2)`.
#   D4  flags/lead-chain-wake-off: no ring, `doorbell not rung (rc 1)`.
#   M1  97-doorbell.sh removed: D1 makes no lead-review ring (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-doorbell.bh-5876-test.sh
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
SRC="$LWF_SRC"
[ -r "$SRC/bin/lib/lead-gates.d/97-doorbell.sh" ] && [ -r "$GD/97-doorbell.sh" ] && ok || bad "setup: bin/lib/lead-gates.d/97-doorbell.sh not installed"
H1=$(printf '%040d' 101); H12=${H1:0:12}

# ── D1: a start rings lead-review once ──
lg6_reset; lgf_needs "101:$H1"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "D1 no job: $(cat "$L")"
[ "$(lg6_rings)" = 1 ] && ok || bad "D1 lead-review rings=$(lg6_rings): $(grep wakes "$T/log/worker")"
grep '^POST /api/wakes/lane ' "$T/log/worker" | grep '"kind":"lead-review"' | sed 's#^POST /api/wakes/lane ##' \
  | jq -e --arg d "lead-review:101@$H12" '.repo == "example-org/cromford" and .key == 101 and .dedupe == $d' >/dev/null \
  && ok || bad "D1 ring body: $(grep wakes "$T/log/worker")"
grep -qF "example-org/cromford#101 @$H12: lead-review doorbell rung" "$L" && ok || bad "D1 no rung line: $(cat "$L")"

# ── D2: a held head rings nothing ──
lg6_reset; lgf_needs "101:$H1"; echo dirty > "$FX/ms.101"
lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "D2 a job for a DIRTY head"
[ "$(lg6_rings)" = 0 ] && ok || bad "D2 lead-review rings=$(lg6_rings) for a held head"

# ── D3: the ring fails: the review still runs ──
lg6_reset; lgf_needs "101:$H1"; echo on > "$FX/wakes.fail"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "D3 no job with the wakes route down"
grep -q '^POST /api/lead-reviews/start ' "$T/log/worker" && ok || bad "D3 no /start"
grep -qF "example-org/cromford#101 @$H12: doorbell not rung (rc 2); the */15 cron covers it" "$L" && ok || bad "D3 line: $(cat "$L")"

# ── D4: the kill switch ──
lg6_reset; lgf_needs "101:$H1"; mkdir -p "$H/flags"; echo on > "$H/flags/lead-chain-wake-off"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "D4 no job with the ring off"
[ "$(lg6_rings)" = 0 ] && ok || bad "D4 lead-review rings=$(lg6_rings) with the kill switch on"
grep -qF "example-org/cromford#101 @$H12: doorbell not rung (rc 1); the */15 cron covers it" "$L" && ok || bad "D4 line: $(cat "$L")"

# ── M1: no doorbell gate: no ring ──
mv "$GD/97-doorbell.sh" "$T/97.off"
lg6_reset; lgf_needs "101:$H1"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "M1 no job"
[ "$(lg6_rings)" = 0 ] && ok || bad "M1 lead-review rings=$(lg6_rings) with 97-doorbell.sh gone"
mv "$T/97.off" "$GD/97-doorbell.sh"

echo "lead-gates-doorbell.bh-5876: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
