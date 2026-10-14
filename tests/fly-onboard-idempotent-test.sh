#!/bin/bash
# tests/fly-onboard-idempotent-test.sh — a project that is already Fly-routed
# reports its state and spends NOTHING (BH-662).
#
# WHY THIS IS ITS OWN SUITE. The expensive mistake here is not a crash, it is a
# re-run: bin/fly-pool-rollout.sh is idempotent for apps and images but it
# always launches a REAL probe machine, so a wrapper that re-ran it on a routed
# project would buy a performance-4x every time somebody typed the command (or
# every time the */2 drain read a queue line that was never pruned). The
# assertion is therefore `$FLY_CALLS does not exist` — zero flyctl, not zero
# machine runs.
#
# The negatives carry the weight: HALF-routed must NOT read as routed, and
# `alpha-2`'s flags must never answer a question about `alpha`.
#
# MUTATION NOTE (D1): relax the already-routed test to a single flag (drop the
# builder-fly check) and §3 goes red; make it a prefix match and §4 goes red.
#
# Run from anywhere: tests/fly-onboard-idempotent-test.sh   (exit 0 = all pass)
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

RC=0; OUT=""
run_ob() { local fx="$1"; shift
  OUT=$(BOX_NAME=box-hub bash "$fx/bin/fly-onboard.sh" "$@" 2>"$fx/stderr.txt"); RC=$?
}

# ══ 1. BOTH FLAGS PRESENT: report, exit 0, spend nothing ════════════════════
I1="$T/i1"; fly_onboard_fixture "$I1"
: > "$I1/flags/fly-pool-alpha"
: > "$I1/flags/builder-fly-alpha"
printf 'pool-alpha\n' > "$I1/flags/fly-pool-app-alpha"
run_ob "$I1" alpha
[ "$RC" = 0 ] && ok || bad "an already-routed project must exit 0 (got $RC)"
[ ! -e "$I1/logs/flyctl-calls.log" ] \
  && ok || bad "an already-routed project must make ZERO flyctl calls (got: $(cat "$I1/logs/flyctl-calls.log"))"
grep -q '^FLY_ONBOARD alpha ALREADY:' <<<"$OUT" \
  && ok || bad "the verdict must say ALREADY: $OUT"
grep -q "flags/fly-pool-alpha=present" <<<"$OUT" \
  && ok || bad "ALREADY must still name both flag paths: $OUT"
grep -q "flags/builder-fly-alpha=present" <<<"$OUT" \
  && ok || bad "ALREADY must still name both flag paths: $OUT"
grep -q 'free-slots="unlimited' <<<"$OUT" \
  && ok || bad "ALREADY must still carry the free-slots answer: $OUT"
grep -q 'WARNING' <<<"$(printf '%s\n' "$OUT")" \
  && bad "a fully-flagged project must not warn: $OUT" || ok

# ══ 2. BOTH FLAGS, NO APP FLAG: still routed, but say so ════════════════════
# The pool is reap-only until flags/fly-pool-app-<p> names the app, and a
# silent "already routed" there is a project whose pool never spawns.
I2="$T/i2"; fly_onboard_fixture "$I2"
: > "$I2/flags/fly-pool-alpha"; : > "$I2/flags/builder-fly-alpha"
run_ob "$I2" alpha
[ "$RC" = 0 ] && ok || bad "missing app flag must not change the verdict rc (got $RC)"
[ ! -e "$I2/logs/flyctl-calls.log" ] \
  && ok || bad "missing app flag must not trigger a re-probe"
grep -q 'WARNING: flags/fly-pool-app-alpha missing' <<<"$OUT" \
  && ok || bad "a missing app flag must be reported: $OUT"

# ══ 3. HALF-ROUTED IS NOT ROUTED ════════════════════════════════════════════
I3="$T/i3"; fly_onboard_fixture "$I3"
printf 'pool-alpha\n' > "$I3/flags/fly-pool-app-alpha"   # the app flag alone
run_ob "$I3" alpha
[ "$(grep -c 'machine run' "$I3/logs/flyctl-calls.log" 2>/dev/null)" = 1 ] \
  && ok || bad "the app flag alone is NOT routing — the rollout must run"
I3B="$T/i3b"; fly_onboard_fixture "$I3B"
: > "$I3B/flags/fly-pool-alpha"                          # one of the two only
run_ob "$I3B" alpha
[ "$(grep -c 'machine run' "$I3B/logs/flyctl-calls.log" 2>/dev/null)" = 1 ] \
  && ok || bad "one of the two flags is NOT routed — the rollout must run"
[ "$RC" = 0 ] && ok || bad "a half-routed project that then smokes OK must exit 0 (got $RC)"

# ══ 4. ANOTHER PROJECT'S FLAGS ARE NOT THIS PROJECT'S ═══════════════════════
I4="$T/i4"; fly_onboard_fixture "$I4"
: > "$I4/flags/fly-pool-alpha-2"; : > "$I4/flags/builder-fly-alpha-2"
: > "$I4/flags/fly-pool-alphax";  : > "$I4/flags/builder-fly-alphax"
run_ob "$I4" alpha
grep -q 'ALREADY' <<<"$(printf '%s\n' "$OUT")" \
  && bad "alpha-2/alphax flags must never read as alpha's routing: $OUT" || ok
[ "$(grep -c 'machine run' "$I4/logs/flyctl-calls.log" 2>/dev/null)" = 1 ] \
  && ok || bad "alpha must be onboarded for real despite the lookalike flags"

# ══ 5. RE-RUN AFTER SUCCESS IS THE ALREADY PATH ═════════════════════════════
# The property the drain depends on: a queue line that is never pruned must
# stop costing money the moment the project is routed.
I5="$T/i5"; fly_onboard_fixture "$I5"
run_ob "$I5" alpha
[ "$RC" = 0 ] && ok || bad "first run must succeed (got $RC): $OUT"
N1=$(grep -c 'machine run' "$I5/logs/flyctl-calls.log")
run_ob "$I5" alpha
[ "$RC" = 0 ] && ok || bad "second run must exit 0 (got $RC)"
grep -q 'ALREADY' <<<"$OUT" \
  && ok || bad "the second run must be the ALREADY path: $OUT"
[ "$(grep -c 'machine run' "$I5/logs/flyctl-calls.log")" = "$N1" ] \
  && ok || bad "the second run must spend no further machine"

echo "fly-onboard-idempotent: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
