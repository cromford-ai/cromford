#!/bin/bash
# tests/fly-onboard-guard-test.sh — bin/fly-onboard.sh refuses off the hub
# BEFORE it touches Fly, and on the hub it drives the REAL rollout to a verdict
# (BH-662).
#
# WHY THE ORDER MATTERS AND NOT JUST THE ANSWER. This script mints org tokens
# out of the hub's flyctl session and writes hub-side routing flags, so "it
# refused" is only half the property — it must refuse with ZERO flyctl calls,
# which is why every assertion here is about $FLY_CALLS (a file the fake flyctl
# creates on its first invocation) rather than about the message. A refusal that
# happens after a `tokens create org` is not a refusal.
#
# MUTATION NOTE (D1): comment out the `is_hub_box` branch in bin/fly-onboard.sh
# and §1 goes red (rc 0, $FLY_CALLS present). Delete the `--cap` case arm and §4
# goes red. Both were checked by hand before this suite was claimed.
#
# Run from anywhere: tests/fly-onboard-guard-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || SCRATCH_FALLBACK=1
# BRIDGE until BH-459/#609 lands tests/lib/scratch.sh on main: 267 suites source
# it and it is not there yet, so this falls back to its own scratch tree.
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
run_ob() { # run_ob <box-name> <fixture-root> [args...]
  local bn="$1" fx="$2"; shift 2
  OUT=$(BOX_NAME="$bn" bash "$fx/bin/fly-onboard.sh" "$@" 2>"$fx/stderr.txt")
  RC=$?
}

# ══ 1. OFF THE HUB: refused, loudly, with nothing spent ══════════════════════
G1="$T/g1"; fly_onboard_fixture "$G1"
run_ob box-small "$G1" alpha
[ "$RC" = 3 ] && ok || bad "off-hub must exit 3 (got $RC)"
grep -q 'refused on box-small' "$G1/stderr.txt" \
  && ok || bad "the refusal must name the box it happened on: $(cat "$G1/stderr.txt")"
grep -q 'only on the hub' "$G1/stderr.txt" \
  && ok || bad "the refusal must name the reason (the hub): $(cat "$G1/stderr.txt")"
grep -q 'fly/onboard-queue.conf' "$G1/stderr.txt" \
  && ok || bad "the refusal must name the channel that DOES work from here"
[ ! -e "$G1/logs/flyctl-calls.log" ] \
  && ok || bad "a refused run must make ZERO flyctl calls (got: $(cat "$G1/logs/flyctl-calls.log"))"
[ -z "$(ls "$G1/flags" 2>/dev/null)" ] \
  && ok || bad "a refused run must write no flag (got: $(ls "$G1/flags"))"
[ "$(grep -c '\[fly-onboard/alpha\] refused' "$G1/logs/fly-pool-rollout.log")" = 1 ] \
  && ok || bad "the refusal must land exactly once in logs/fly-pool-rollout.log"

# ══ 2. ON THE HUB: the real rollout runs and the verdict comes from disk ═════
G2="$T/g2"; fly_onboard_fixture "$G2"
run_ob box-hub "$G2" alpha
[ "$RC" = 0 ] && ok || bad "an onboarding that reaches SMOKE_OK must exit 0 (got $RC): $OUT"
[ "$(grep -c 'machine run' "$G2/logs/flyctl-calls.log")" = 1 ] \
  && ok || bad "exactly one probe machine per onboarding (got $(grep -c 'machine run' "$G2/logs/flyctl-calls.log"))"
grep -q 'apps create builder-alpha' "$G2/logs/flyctl-calls.log" \
  && ok || bad "the builder app must be ensured"
[ -f "$G2/flags/fly-pool-alpha" ] && [ ! -s "$G2/flags/fly-pool-alpha" ] \
  && ok || bad "with no --cap the pool flag must be written EMPTY (autoscale)"
[ -f "$G2/flags/builder-fly-alpha" ] \
  && ok || bad "the enqueue-shim flag must be written"
[ "$(cat "$G2/flags/fly-pool-app-alpha" 2>/dev/null)" = "pool-alpha" ] \
  && ok || bad "the app flag must name pool-alpha"
V=$(printf '%s\n' "$OUT" | grep -c '^FLY_ONBOARD alpha OK:')
[ "$V" = 1 ] && ok || bad "exactly one OK verdict line on stdout (got $V): $OUT"
grep -q "flags/fly-pool-alpha=present" <<<"$OUT" \
  && ok || bad "the verdict must name the pool flag path and its state: $OUT"
grep -q "flags/builder-fly-alpha=present" <<<"$OUT" \
  && ok || bad "the verdict must name the builder flag path and its state: $OUT"
grep -q 'free-slots="unlimited (fly-routed:' <<<"$OUT" \
  && ok || bad "the verdict must carry bin/free-slots.sh's answer verbatim: $OUT"
grep -q 'FLY_ONBOARD alpha OK:' "$G2/logs/fly-pool-rollout.log" \
  && ok || bad "the verdict must also be in logs/fly-pool-rollout.log"
grep -q 'image: registry.fly.io/builder-alpha' <<<"$OUT" \
  && ok || bad "the rollout's per-step lines must be printed, not just logged: $OUT"
grep -q '10.0.0.13' "$G2/logs/ssh.log" \
  && ok || bad "the owning box's enqueue flag must be set over ssh"

# ══ 3. --cap N is a HARD ceiling, written where pool-cap.sh reads it ═════════
G3="$T/g3"; fly_onboard_fixture "$G3"
run_ob box-hub "$G3" alpha --cap 4
[ "$RC" = 0 ] && ok || bad "--cap 4 must still onboard (got $RC)"
[ "$(cat "$G3/flags/fly-pool-alpha")" = 4 ] \
  && ok || bad "--cap 4 must land as 4 in flags/fly-pool-alpha (got '$(cat "$G3/flags/fly-pool-alpha")')"
grep -q 'present(cap 4)' <<<"$OUT" \
  && ok || bad "the verdict must report the cap that RESOLVES: $OUT"

# ══ 4. A BAD --cap IS REFUSED, NEVER CLAMPED (D11) ══════════════════════════
for BADCAP in 0 abc -1 ""; do
  G4="$T/g4-$(printf %s "$BADCAP" | tr -dc 'A-Za-z0-9')x"; fly_onboard_fixture "$G4"
  run_ob box-hub "$G4" alpha --cap "$BADCAP"
  [ "$RC" = 2 ] && ok || bad "--cap '$BADCAP' must exit 2, never be clamped (got $RC)"
  [ ! -e "$G4/logs/flyctl-calls.log" ] \
    && ok || bad "--cap '$BADCAP' must not reach flyctl"
done
G4M="$T/g4m"; fly_onboard_fixture "$G4M"
run_ob box-hub "$G4M"
[ "$RC" = 2 ] && ok || bad "no project argument must exit 2 (got $RC)"
run_ob box-hub "$G4M" not-a-fleet-project
[ "$RC" = 2 ] && ok || bad "a project that is not in fleet.conf must exit 2 (got $RC)"
[ ! -e "$G4M/logs/flyctl-calls.log" ] \
  && ok || bad "an unknown project must not reach flyctl"

# ══ 5. NO LIB, NO PROOF: this one fails CLOSED ══════════════════════════════
# The build guards fail OPEN on a missing bin/lib/hub-box.sh so a box mid-sync
# keeps building. Here the cost of a wrong "yes" is org credentials, so absence
# of the proof is a refusal.
G5="$T/g5"; fly_onboard_fixture "$G5"
rm -f "$G5/bin/lib/hub-box.sh"
run_ob box-hub "$G5" alpha
[ "$RC" = 3 ] && ok || bad "a missing hub-box.sh must refuse, not assume (got $RC)"
grep -q 'hub-box.sh missing' "$G5/stderr.txt" \
  && ok || bad "the fail-closed refusal must say what is missing: $(cat "$G5/stderr.txt")"
[ ! -e "$G5/logs/flyctl-calls.log" ] \
  && ok || bad "a fail-closed refusal must not reach flyctl"

echo "fly-onboard-guard: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
