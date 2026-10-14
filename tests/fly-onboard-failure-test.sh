#!/bin/bash
# tests/fly-onboard-failure-test.sh — a failed onboarding writes NO routing flag,
# exits non-zero, and pages once (BH-662).
#
# WHY THIS IS THE LOAD-BEARING SUITE. bin/fly-pool-rollout.sh has `set -uo
# pipefail` without `-e` and every failure path is `say …; continue`, so it
# exits 0 on a failed token mint, a failed image build and a failed smoke alike.
# A wrapper that read its rc would report success for every one of them. The
# verdict therefore comes from the flag files on disk, and this suite is what
# proves it: the rollout is driven to a REAL failure (the fake flyctl answers
# SMOKE_FAIL, or hands back no machine id at all) and the assertions are the
# absence of the flags, the exit code, and exactly one ALERTS line.
#
# MUTATION NOTE (D1): add `touch "$H/flags/builder-fly-$P"` anywhere in
# bin/fly-onboard.sh and §1 goes red on three assertions at once; read the
# rollout's rc instead of the flags and §1 goes red on the exit code.
#
# Run from anywhere: tests/fly-onboard-failure-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || SCRATCH_FALLBACK=1
# BRIDGE until BH-459/#609 lands tests/lib/scratch.sh on main.
if [ "${SCRATCH_FALLBACK:-}" = 1 ]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/bh662.XXXXXX"); trap 'rm -rf "$T"' EXIT
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset HARNESS_TICKET HUB_BUILD_OK HUB_NO_BUILD_LANES HUB_BOX_NAME BOX_NAME
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
. "$(dirname "$0")/lib/fly-onboard-fixture.sh" || exit 1

# ══ 1. SMOKE FAILS on a real probe machine ══════════════════════════════════
F1="$T/f1"; fly_onboard_fixture "$F1"
OUT=$(BOX_NAME=box-hub SMOKE_RESULT=SMOKE_FAIL bash "$F1/bin/fly-onboard.sh" alpha 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "a failed onboarding must exit 1, not 0 (got $RC): $OUT"
for F in fly-pool-alpha builder-fly-alpha fly-pool-app-alpha; do
  [ ! -e "$F1/flags/$F" ] \
    && ok || bad "flags/$F must NOT exist after a failed smoke"
done
grep -q 'machine destroy e8aaaaaaaaaaaa' "$F1/logs/flyctl-calls.log" \
  && ok || bad "the probe machine must be destroyed on the failure path"
A=$(grep -c '\[fly-onboard\] alpha onboarding FAILED' "$F1/logs/ALERTS.log")
[ "$A" = 1 ] && ok || bad "exactly one ALERTS line per failed onboarding (got $A)"
grep '\[fly-onboard\] alpha onboarding FAILED' "$F1/logs/ALERTS.log" | grep -q 'smoke' \
  && ok || bad "the ALERTS line must name the step that failed: $(cat "$F1/logs/ALERTS.log")"
grep '\[fly-onboard\] alpha onboarding FAILED' "$F1/logs/ALERTS.log" | grep -q 'bin/fly-onboard.sh alpha' \
  && ok || bad "the ALERTS line must say what to run to fix it"
grep -q '^FLY_ONBOARD alpha FAILED:' <<<"$OUT" \
  && ok || bad "the verdict must say FAILED: $OUT"
grep -q "flags/fly-pool-alpha=absent" <<<"$OUT" \
  && ok || bad "the verdict must report the pool flag as absent: $OUT"
grep -q "flags/builder-fly-alpha=absent" <<<"$OUT" \
  && ok || bad "the verdict must report the builder flag as absent: $OUT"
grep -q 'free-slots="unlimited (BUILD_SLOTS=0' <<<"$OUT" \
  && ok || bad "free-slots must be answered even on the failure path — it is the LOCAL answer now: $OUT"

# ══ 2. THE MACHINE NEVER STARTS: a different step, same discipline ══════════
F2="$T/f2"; fly_onboard_fixture "$F2"
OUT=$(BOX_NAME=box-hub MACHINE_RUN_SILENT=1 bash "$F2/bin/fly-onboard.sh" alpha 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "a smoke that never got a machine id must exit 1 (got $RC)"
[ ! -e "$F2/flags/fly-pool-alpha" ] && [ ! -e "$F2/flags/builder-fly-alpha" ] \
  && ok || bad "no routing flag may be written when no machine ever ran"
[ "$(grep -c '\[fly-onboard\] alpha onboarding FAILED' "$F2/logs/ALERTS.log")" = 1 ] \
  && ok || bad "still exactly one ALERTS line"
grep '\[fly-onboard\] alpha' "$F2/logs/ALERTS.log" | grep -q 'smoke machine run FAILED' \
  && ok || bad "the ALERTS line must name THIS step: $(cat "$F2/logs/ALERTS.log")"

# ══ 3. A FAILED RUN LEAVES THE PROJECT RE-RUNNABLE ══════════════════════════
# Nothing here is sticky: the next run is a full attempt, not an ALREADY.
OUT=$(BOX_NAME=box-hub bash "$F2/bin/fly-onboard.sh" alpha 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "a retry after a failure must be able to succeed (got $RC): $OUT"
[ -f "$F2/flags/fly-pool-alpha" ] && [ -f "$F2/flags/builder-fly-alpha" ] \
  && ok || bad "the retry must write the routing flags"
[ "$(grep -c '\[fly-onboard\] alpha onboarding FAILED' "$F2/logs/ALERTS.log")" = 1 ] \
  && ok || bad "a successful retry must not add another ALERTS line"

echo "fly-onboard-failure: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
