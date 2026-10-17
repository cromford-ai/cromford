#!/bin/bash
# tests/fly-onboard-drain-test.sh — the hub drains fly/onboard-queue.conf on its
# own tick, bounded by a ledger (BH-662).
#
# WHY IT DRIVES THE REAL TICK. The drain block lives inside
# bin/fly-pool-tick.sh, which cron/hub.cron already runs every 2 minutes — that
# is the whole reason it is there rather than in a new lane. So this suite runs
# the REAL bin/fly-pool-tick.sh against a scratch $HARNESS with a recording stub
# for bin/fly-onboard.sh, and every assertion is about artifacts: the recorded
# argv, state/fly-onboard/<p>.attempts, logs/fly-pool.log and logs/ALERTS.log.
#
# THE NEGATIVES ARE THE EXPENSIVE ONES. Each launch buys an image build and a
# real performance-4x probe machine, and this loop runs 720 times a day, so
# "does not launch" is the property worth the most assertions: a routed project,
# a project inside its retry window, a project past its attempt cap, a comment
# line, a malformed name, and any box that is not the hub.
#
# NO CLOCK AND NO SLEEP (bin/test-determinism-lint.sh): the retry-window case
# pins .last to a fixed epoch in 2100, and the detached launch is waited for
# with a bounded spin rather than a sleep.
#
# MUTATION NOTE (D1): write the ledger AFTER the launch and §1 still passes but
# §4's cap stops holding; drop the is_hub_box branch and §3 goes red; drop the
# routed check and §2 goes red.
#
# Run from anywhere: tests/fly-onboard-drain-test.sh   (exit 0 = all pass)
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
unset HARNESS HUB_BOX_NAME BOX_NAME FLY_ONBOARD_MAX_ATTEMPTS FLY_ONBOARD_RETRY_MIN

hub() { # hub <dir> — a scratch harness root with the drain's neighbours in it
  HB="$1"
  mkdir -p "$HB/bin/lib" "$HB/logs" "$HB/flags" "$HB/locks" "$HB/env" "$HB/fly" "$HB/state"
  cp "$DIR/bin/pool-cap.sh" "$DIR/bin/box-name.sh" "$HB/bin/"
  cp "$DIR/bin/alert-line.sh" "$HB/bin/"
  cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/env-path.sh" "$HB/bin/lib/"
  printf '#!/bin/bash\nexit 0\n' > "$HB/bin/fly-lock-guard.sh"
  printf '#!/bin/bash\nexit 0\n' > "$HB/bin/fly-pool.sh"
  # The recorder. The launch is detached, so the log path is baked in rather
  # than inherited from an exported variable.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/onboard-argv.log"\nexit 0\n' "$HB" \
    > "$HB/bin/fly-onboard.sh"
  chmod +x "$HB/bin"/*.sh
  : > "$HB/env/global.env"
  # Header only: real project lines in the committed file are routing
  # decisions, not fixture rows, and must not be drained by this test.
  grep -E '^[[:space:]]*(#|$)' "$DIR/fly/onboard-queue.conf" > "$HB/fly/onboard-queue.conf"
  ARGV="$HB/logs/onboard-argv.log"
}
queue() { printf '%s\n' "$@" >> "$HB/fly/onboard-queue.conf"; }
tick()  { ( export HARNESS="$HB" BOX_NAME="${1:-box-hub}"; bash "$DIR/bin/fly-pool-tick.sh" ) ; }
# Bounded spin — no sleep, no clock read. Positives return as soon as the
# detached stub has written; negatives pay the whole budget and then assert
# absence, which is what makes "did not launch" mean something.
settle() { local i=0; until [ -e "$ARGV" ] || [ "$i" -gt 120000 ]; do i=$((i+1)); done; }

# ══ 1. QUEUED AND NOT ROUTED: exactly one launch, ledger written ════════════
hub "$T/d1"; queue "alpha 2026-09-17T18:00:00Z"
tick
settle
[ "$(cat "$ARGV" 2>/dev/null)" = alpha ] \
  && ok || bad "a queued unrouted project must be launched once, with its name as the only argv (got '$(cat "$ARGV" 2>/dev/null)')"
[ "$(cat "$T/d1/state/fly-onboard/alpha.attempts" 2>/dev/null)" = 1 ] \
  && ok || bad "the attempt must be recorded (got '$(cat "$T/d1/state/fly-onboard/alpha.attempts" 2>/dev/null)')"
[ -s "$T/d1/state/fly-onboard/alpha.last" ] \
  && ok || bad "the attempt time must be recorded"
grep -q 'launching bin/fly-onboard.sh alpha (attempt 1 of 3)' "$T/d1/logs/fly-pool.log" \
  && ok || bad "the launch must be visible in logs/fly-pool.log: $(cat "$T/d1/logs/fly-pool.log" 2>/dev/null)"

# ══ 2. ALREADY ROUTED: the line is inert, forever ═══════════════════════════
hub "$T/d2"; queue "alpha 2026-09-17T18:00:00Z"
: > "$T/d2/flags/fly-pool-alpha"; : > "$T/d2/flags/builder-fly-alpha"
tick
settle
[ ! -e "$ARGV" ] \
  && ok || bad "a routed project must never be re-onboarded from the queue (got '$(cat "$ARGV")')"
[ ! -e "$T/d2/state/fly-onboard/alpha.attempts" ] \
  && ok || bad "a routed project must not even open a ledger"

# ══ 3. NOT THE HUB: nothing, anywhere ═══════════════════════════════════════
# This file syncs to every box. A watcher box that drained it would try to mint
# org tokens against a flyctl session it does not have.
hub "$T/d3"; queue "alpha 2026-09-17T18:00:00Z"
tick box-small
settle
[ ! -e "$ARGV" ] && ok || bad "a non-hub box must launch nothing"
[ ! -d "$T/d3/state/fly-onboard" ] && ok || bad "a non-hub box must not even create the ledger dir"

# ══ 4. THE ATTEMPT CAP: stop spending, page ONCE ════════════════════════════
hub "$T/d4"; queue "alpha 2026-09-17T18:00:00Z"
mkdir -p "$T/d4/state/fly-onboard"; echo 3 > "$T/d4/state/fly-onboard/alpha.attempts"
tick; tick
settle
[ ! -e "$ARGV" ] && ok || bad "a project at the attempt cap must not be launched again"
A=$(grep -c '\[fly-onboard\] alpha: 3 onboarding attempts failed' "$T/d4/logs/ALERTS.log")
[ "$A" = 1 ] \
  && ok || bad "the give-up must page exactly once across two ticks (got $A)"
grep -q 'rm state/fly-onboard/alpha.attempts' "$T/d4/logs/ALERTS.log" \
  && ok || bad "the give-up line must say how to retry"

# ══ 5. INSIDE THE RETRY WINDOW: wait, do not spend ══════════════════════════
# .last is pinned to 2100-01-01 so this case can never be decided by the day
# the suite happens to run on.
hub "$T/d5"; queue "alpha 2026-09-17T18:00:00Z"
mkdir -p "$T/d5/state/fly-onboard"
echo 1 > "$T/d5/state/fly-onboard/alpha.attempts"
echo 4102444800 > "$T/d5/state/fly-onboard/alpha.last"
tick
settle
[ ! -e "$ARGV" ] && ok || bad "a project inside its retry window must not be launched"
[ "$(cat "$T/d5/state/fly-onboard/alpha.attempts")" = 1 ] \
  && ok || bad "a skipped retry must not consume an attempt"

# ══ 6. THE FILE AS SHIPPED: header only, nothing to do ══════════════════════
hub "$T/d6"
tick
settle
[ ! -e "$ARGV" ] \
  && ok || bad "comment and blank lines must launch nothing (got '$(cat "$ARGV")')"

# ══ 7. FIELD 1 ONLY, AND A NAME THAT NEEDED CLEANING IS REFUSED ════════════
hub "$T/d7"; queue "example-org/gamma 2026-09-17T18:00:00Z" "alpha beta" "  " "# alpha"
tick
settle
[ "$(cat "$ARGV" 2>/dev/null)" = alpha ] \
  && ok || bad "only 'alpha' may be launched here (got '$(cat "$ARGV" 2>/dev/null)')"
[ "$(wc -l < "$ARGV")" = 1 ] \
  && ok || bad "exactly one launch (got $(wc -l < "$ARGV"))"
[ ! -e "$T/d7/state/fly-onboard/gamma.attempts" ] \
  && ok || bad "a slashed name must be refused, not sanitised into a different project"

echo "fly-onboard-drain: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
