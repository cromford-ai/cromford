#!/bin/bash
# tests/fly-pool-tick-slow-project.bh-7491-test.sh — a slow or stuck project tick
# must never delay the next tick of another project (BH-7491).
#
# bin/fly-pool-tick.sh used to `wait` for every project tick. One slow project
# (project-6-os, 156 queued rows) held the wrapper, the single-run gate (BH-7422)
# turned every later cron start away, and each project ticked once per round of
# the slowest project. Driven here against a scratch tree with a stub
# bin/fly-pool.sh that takes the REAL per-project lock the way the real one does:
#   1. the wrapper returns after its bound while the slow tick still runs
#   2. a second wrapper run ticks the fast project again, the slow one is refused
#      by its own lock
#   3. the BH-2522 preflight still runs, after the fast tick, in every run
#   4. a tick past the hard limit writes ONE log line and ONE alert per episode
#   5. when the slow tick ends the episode ends: the next hang alerts again
# Barriers are files: the slow stub holds until $S/release exists.
# Run from anywhere: tests/fly-pool-tick-slow-project.bh-7491-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

S="$T/h"
mkdir -p "$S/bin" "$S/flags" "$S/logs" "$S/locks" "$S/env" "$S/state/fly-pool"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/alert-line.sh" "$S/bin/"
printf '#!/bin/bash\nexit 0\n' > "$S/bin/fly-lock-guard.sh"
printf '#!/bin/bash\nexit 0\n' > "$S/bin/beat.sh"
: > "$S/env/global.env"
# The stub: the real lock, the real "already running" line, then the work.
cat > "$S/bin/fly-pool.sh" <<STUB
#!/bin/bash
P="\$1"; H="$S"
exec 8>"\$H/locks/fly-pool-\$P.lock"
if ! flock -n 8; then
  echo "[pool/\$P] already running" >> "\$H/logs/fly-pool.log"; exit 0
fi
echo "\$P" >> "\$H/ticked.txt"
if [ "\$P" = slow ]; then
  i=0; until [ -e "\$H/release" ] || [ "\$i" -ge 250 ]; do sleep 0.2; i=\$((i+1)); done
fi
: > "\$H/done.\$P"
exit 0
STUB
# The preflight stub records whether the fast tick had finished when it ran.
cat > "$S/bin/fly-pool-rows-parity.sh" <<STUB
#!/bin/bash
if [ -e "$S/done.fast" ]; then echo after-fast >> "$S/parity.log"; else echo before-fast >> "$S/parity.log"; fi
exit 0
STUB
chmod +x "$S/bin"/*.sh
for p in slow fast; do : > "$S/flags/fly-pool-$p"; done

wrapper() { # wrapper [VAR=val ...] — one cron start; output to files, never a pipe
  ( export HARNESS="$S" POOL_TICK_WAIT_S=2 POOL_TICK_HARD_LIMIT_S=1 "$@"
    timeout 20 bash "$DIR/bin/fly-pool-tick.sh" >> "$S/wrapper.out" 2>&1 )
}
count() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
cleanup_slow() { : > "$S/release"; local i=0; until [ -e "$S/done.slow" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i+1)); done; }

# ══ 1. FIRST START: slow holds, wrapper returns at its bound ═════════════════
START=$(date +%s); wrapper; RC=$?; EL=$(( $(date +%s) - START ))
[ "$RC" = 0 ] && [ "$EL" -lt 15 ] \
  && ok || bad "the wrapper must return at its bound while the slow tick runs (rc=$RC, took ${EL}s)"
[ "$(count '^fast$' "$S/ticked.txt")" = 1 ] && [ "$(count '^slow$' "$S/ticked.txt")" = 1 ] \
  && ok || bad "run 1 must start both projects (got '$(tr '\n' ' ' < "$S/ticked.txt")')"
[ ! -e "$S/done.slow" ] \
  && ok || bad "the slow tick must still be running after run 1"
[ "$(cat "$S/parity.log" 2>/dev/null)" = after-fast ] \
  && ok || bad "the BH-2522 preflight must run after the fast tick (got '$(cat "$S/parity.log" 2>/dev/null)')"

# ══ 2. SECOND START while slow still runs ════════════════════════════════════
wrapper
[ "$(count '^fast$' "$S/ticked.txt")" = 2 ] \
  && ok || bad "a second wrapper run must tick the fast project again while slow runs (fast ticks: $(count '^fast$' "$S/ticked.txt"))"
[ "$(count '^slow$' "$S/ticked.txt")" = 1 ] \
  && ok || bad "the slow project's own lock must refuse a second tick (slow ticks: $(count '^slow$' "$S/ticked.txt"))"
[ "$(count 'pool/slow\] already running' "$S/logs/fly-pool.log")" = 1 ] \
  && ok || bad "the refused slow start must log 'already running' once"
[ "$(wc -l < "$S/parity.log")" = 2 ] \
  && ok || bad "the preflight must run in every wrapper run"

# ══ 3. HARD LIMIT: one log line and one alert for the episode ════════════════
# Run 1 waited 2 s for slow, the limit is 1 s: run 2 already saw it past the limit.
wrapper
[ "$(count 'pool/slow\].*past the hard limit' "$S/logs/fly-pool.log")" = 1 ] \
  && ok || bad "exactly one hard-limit log line expected over 3 runs (got $(count 'past the hard limit' "$S/logs/fly-pool.log"))"
[ "$(count 'pool/slow\].*past the hard limit' "$S/logs/ALERTS.log")" = 1 ] \
  && ok || bad "exactly one hard-limit alert expected over 3 runs (got $(count 'past the hard limit' "$S/logs/ALERTS.log"))"
[ "$(count 'pool/fast\].*past the hard limit' "$S/logs/ALERTS.log")" = 0 ] \
  && ok || bad "the fast project must not alert"
[ ! -e "$S/done.slow" ] \
  && ok || bad "the tick must not be killed: an alert is enough"

# ══ 4. EPISODE ENDS: slow finishes, next hang alerts again ═══════════════════
cleanup_slow
[ -e "$S/done.slow" ] && ok || bad "slow stub did not finish after release"
rm -f "$S/release" "$S/done.slow"
wrapper    # lock free: slow ticks and holds again, episode state is cleared
[ "$(count '^slow$' "$S/ticked.txt")" = 2 ] \
  && ok || bad "after the slow tick ends the next run must tick it again (slow ticks: $(count '^slow$' "$S/ticked.txt"))"
wrapper    # held for >1 s again: a NEW episode, a second alert
[ "$(count 'pool/slow\].*past the hard limit' "$S/logs/ALERTS.log")" = 2 ] \
  && ok || bad "a new hang after the first ended must alert again (got $(count 'past the hard limit' "$S/logs/ALERTS.log"))"
cleanup_slow

# ══ 5. BOUND OFF (0) keeps the old contract: wait for every tick ═════════════
rm -f "$S/release" "$S/done.slow" "$S/done.fast"
( sleep 3; : > "$S/release" ) &
REL=$!
START=$(date +%s); wrapper POOL_TICK_WAIT_S=0; EL=$(( $(date +%s) - START ))
wait "$REL" 2>/dev/null
[ "$EL" -ge 3 ] \
  && ok || bad "POOL_TICK_WAIT_S=0 must wait for the slow tick (took ${EL}s)"

echo "fly-pool-tick-slow-project: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
