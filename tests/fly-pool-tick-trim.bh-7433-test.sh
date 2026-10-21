#!/bin/bash
# tests/fly-pool-tick-trim.bh-7433-test.sh — the tick wrapper without its two
# one-shots (BH-7433).
#
# bin/fly-pool-tick.sh carried two one-shots from 2026-09-14: one emptied the
# number in flags/fly-pool-<p> (BH-660 pool autoscale), one moved a top-level
# machine_id in state/fly/<p>.json under builder_retired and paged. Both had run
# on every project. The first one now did harm: bin/fly-pool-rollout.sh writes a
# number only when an operator sets POOL_CAP, and the one-shot wiped it. Driven
# here against the REAL wrapper in a scratch tree, with recorders in place of
# bin/fly-pool.sh and bin/fly-onboard.sh:
#   1. a number in the flag stays the cap (POOL_AUTOSCALE unset and =0)
#   2. a builder record with a machine_id is left byte-identical, no page
#   3. every pool project still ticks once, the app-name flag never
#   4. the onboard drain still launches an unrouted queued project on the hub
#   5. near miss: a box that is not the hub launches nothing
# Run from anywhere: tests/fly-pool-tick-trim.bh-7433-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset POOL_AUTOSCALE POOL_CAP_MAX HUB_BOX_NAME BOX_NAME JOBS_URL FLY_ONBOARD_MAX_ATTEMPTS FLY_ONBOARD_RETRY_MIN

tree() { # tree <dir> — a scratch harness root for one case
  S="$1"
  mkdir -p "$S/flags" "$S/logs" "$S/locks" "$S/env" "$S/fly" "$S/state/fly" "$S/state/fly-pool"
  scratch_install_closure bin/fly-pool-tick.sh "$S" >/dev/null || { bad "closure install failed"; exit 1; }
  cp "$DIR/bin/pool-cap.sh" "$DIR/bin/alert-line.sh" "$S/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$S/bin/fly-lock-guard.sh"
  printf '#!/bin/bash\nexit 0\n' > "$S/bin/fly-pool-rows-parity.sh"
  printf '#!/bin/bash\nexit 0\n' > "$S/bin/pool-budget.sh"
  printf '#!/bin/bash\necho "$1" >> "%s/ticked.txt"\nexit 0\n' "$S" > "$S/bin/fly-pool.sh"
  # The onboard launch is detached, so the log path is baked in.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/onboard-argv.log"\nexit 0\n' "$S" > "$S/bin/fly-onboard.sh"
  chmod +x "$S/bin"/*.sh
  : > "$S/env/global.env"
}
tick() { # tick <box-name> [VAR=val ...]
  local box="$1"; shift
  ( export HARNESS="$S" BOX_NAME="$box" "$@"
    bash "$DIR/bin/fly-pool-tick.sh" >> "$S/wrapper.out" 2>&1 )
}
count() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
# Bounded spin, no clock read: the onboard stub runs detached.
settle() { local i=0; until [ -e "$S/onboard-argv.log" ] || [ "$i" -gt 120000 ]; do i=$((i+1)); done; }
HUB=box-hub          # HARNESS_HUB_BOX default, bin/lib/deployment.sh
NOT_HUB=box-fixture-2

# ══ 1. A NUMBER IN THE FLAG STAYS THE CAP ════════════════════════════════════
for mode in unset POOL_AUTOSCALE=0; do
  tree "$T/c1-${mode%%=*}"
  echo 7 > "$S/flags/fly-pool-alpha"
  if [ "$mode" = unset ]; then tick "$NOT_HUB"; else tick "$NOT_HUB" "$mode"; fi
  [ "$(cat "$S/flags/fly-pool-alpha")" = 7 ] \
    && ok || bad "[$mode] the flag number must stay (got '$(cat "$S/flags/fly-pool-alpha")')"
  [ ! -e "$S/state/fly-pool/legacy-caps.alpha" ] \
    && ok || bad "[$mode] no legacy-caps.alpha must be written: $(cat "$S/state/fly-pool/legacy-caps.alpha")"
  [ "$(count 'legacy flag cap' "$S/logs/fly-pool.log")" = 0 ] \
    && ok || bad "[$mode] the pool log must not report a retired cap"
  [ "$(HARNESS="$S" "$DIR/bin/pool-cap.sh" alpha)" = 7 ] \
    && ok || bad "[$mode] pool-cap.sh must still resolve the flag cap 7 (got $(HARNESS="$S" "$DIR/bin/pool-cap.sh" alpha))"
done

# ══ 2. A BUILDER RECORD IS LEFT ALONE ════════════════════════════════════════
for mode in unset POOL_AUTOSCALE=0; do
  tree "$T/c2-${mode%%=*}"
  : > "$S/flags/fly-pool-alpha"
  printf '{"app":"builder-alpha","machine_id":"m-fixture-1","region":"iad"}\n' > "$S/state/fly/alpha.json"
  cp "$S/state/fly/alpha.json" "$S/alpha.before"
  if [ "$mode" = unset ]; then tick "$NOT_HUB"; else tick "$NOT_HUB" "$mode"; fi
  cmp -s "$S/state/fly/alpha.json" "$S/alpha.before" \
    && ok || bad "[$mode] state/fly/alpha.json must be byte-identical: $(cat "$S/state/fly/alpha.json")"
  [ "$(count 'm-fixture-1' "$S/logs/ALERTS.log")" = 0 ] \
    && ok || bad "[$mode] no ALERTS line may name the machine: $(cat "$S/logs/ALERTS.log")"
  [ "$(count 'builder record retired' "$S/logs/fly-pool.log")" = 0 ] \
    && ok || bad "[$mode] the pool log must not report a retired record"
done

# ══ 3. EVERY POOL PROJECT STILL TICKS ═══════════════════════════════════════
for mode in unset POOL_AUTOSCALE=0; do
  tree "$T/c3-${mode%%=*}"
  : > "$S/flags/fly-pool-alpha"; : > "$S/flags/fly-pool-beta"
  printf 'pool-alpha\n' > "$S/flags/fly-pool-app-alpha"
  if [ "$mode" = unset ]; then tick "$NOT_HUB"; else tick "$NOT_HUB" "$mode"; fi
  [ "$(count '^alpha$' "$S/ticked.txt")" = 1 ] && [ "$(count '^beta$' "$S/ticked.txt")" = 1 ] \
    && ok || bad "[$mode] alpha and beta must tick once each (got '$(tr '\n' ' ' < "$S/ticked.txt" 2>/dev/null)')"
  [ "$(count 'app-alpha' "$S/ticked.txt")" = 0 ] \
    && ok || bad "[$mode] the app-name flag is not a project (got '$(tr '\n' ' ' < "$S/ticked.txt")')"
  [ "$(wc -l < "$S/ticked.txt")" = 2 ] \
    && ok || bad "[$mode] exactly two ticks (got $(wc -l < "$S/ticked.txt"))"
done

# ══ 4. THE ONBOARD DRAIN STILL RUNS ON THE HUB ══════════════════════════════
tree "$T/c4"
: > "$S/flags/fly-pool-alpha"; : > "$S/flags/builder-fly-alpha"
printf 'gamma 2026-10-19T00:00:00Z\nalpha 2026-10-19T00:00:00Z\n' > "$S/fly/onboard-queue.conf"
tick "$HUB"
settle
[ "$(cat "$S/onboard-argv.log" 2>/dev/null)" = gamma ] \
  && ok || bad "the hub must launch gamma once and never routed alpha (got '$(cat "$S/onboard-argv.log" 2>/dev/null)')"
[ "$(cat "$S/state/fly-onboard/gamma.attempts" 2>/dev/null)" = 1 ] \
  && ok || bad "gamma's attempt must be recorded (got '$(cat "$S/state/fly-onboard/gamma.attempts" 2>/dev/null)')"
[ ! -e "$S/state/fly-onboard/alpha.attempts" ] \
  && ok || bad "routed alpha must have no attempts file"
grep -q 'launching bin/fly-onboard.sh gamma (attempt 1 of 3' "$S/logs/fly-pool.log" \
  && ok || bad "the launch must be logged: $(cat "$S/logs/fly-pool.log" 2>/dev/null)"

# ══ 5. NEAR MISS: A BOX THAT IS NOT THE HUB DRAINS NOTHING ══════════════════
tree "$T/c5"
: > "$S/flags/fly-pool-alpha"; : > "$S/flags/builder-fly-alpha"
printf 'gamma 2026-10-19T00:00:00Z\nalpha 2026-10-19T00:00:00Z\n' > "$S/fly/onboard-queue.conf"
tick "$NOT_HUB"
settle
[ ! -e "$S/onboard-argv.log" ] \
  && ok || bad "a non-hub box must launch no onboarding (got '$(cat "$S/onboard-argv.log")')"
[ ! -e "$S/state/fly-onboard/gamma.attempts" ] \
  && ok || bad "a non-hub box must write no attempts file"
[ "$(count '^alpha$' "$S/ticked.txt")" = 1 ] \
  && ok || bad "the pool tick itself still runs on a non-hub box"

echo "fly-pool-tick-trim: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
