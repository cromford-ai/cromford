#!/bin/bash
# tests/hub-overload-queue.bh-7139-test.sh — BH-7139: the hub stops piling up
# its own processes. Keyed conductor ticks go through a bounded queue (every
# wake still runs), a second fly-pool / stuck-work run for one project exits at
# once, and a cron full tick older than 2 cron periods writes one alert.
#
#   Q1 20 keyed wakes (kw_conductor, 20 PRs), stub conductor, N=3: peak <= 3,
#      peak >= 2, every PR runs exactly once.
#   Q2 fold: the pool full of N held ticks, two wakes for PR 99: one queue
#      entry; after release PR 99 runs exactly once.
#   Q3 N=0 (the kill knob): every wake runs, no entry is left.
#   Q4 the registry seeds MC_KEYED_MAX_PARALLEL=4 and MC_FULL_TICK_PERIOD_S=1800.
#   F1 fly-pool.sh p started twice, the first held inside its tick: the second
#      exits rc 0 while the first still runs, with one `already running` line.
#   S1 stuck-work.sh p while a run of p holds its lock: rc 0, one `busy` line.
#   C1 mc_tick_clock_check: a live full tick older than 2 periods -> one alert
#      over two checks; younger -> none; a dead pid -> stamp removed, no alert.
#   C2 mc_tick_clock_start/end: a full tick stamps and logs FULL_TICK wall_s=,
#      a keyed tick stamps nothing; the conductor and the wake lane call them.
#
# Run: bash tests/hub-overload-queue.bh-7139-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }
# waitfor <cond> — poll, 60 s at most. A bound for a stuck run, not a timing claim.
waitfor() { local i=0; until eval "$1"; do i=$((i + 1)); [ "$i" -ge 300 ] && return 1; sleep 0.2; done; return 0; }
lines() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
KNOBS="$DIR/catalog/lanes.d/merge-conductor.knobs.d"

# ── the keyed pool (Q1-Q3) ──────────────────────────────────────────────────
QH="$T/q"; QX="$T/qx"; export QX
qsetup() {
  [ -e "$QH" ] && scratch_rm "$QH"
  [ -e "$QX" ] && scratch_rm "$QX"
  mkdir -p "$QH/bin/lib" "$QH/state" "$QH/logs" "$QH/locks" "$QX/run"
  # scratch-closure-allow: keyed-wake.sh is sourced alone into the test shell (kw_conductor); the pool script and a stub conductor are the only things it runs
  cp "$DIR/bin/lib/keyed-wake.sh" "$QH/bin/lib/"
  [ -f "$DIR/bin/mc-keyed-pool.sh" ] && cp "$DIR/bin/mc-keyed-pool.sh" "$QH/bin/"
  : > "$QX/ran"; : > "$QX/conc"
  # The stub conductor: counts the ticks alive with it, holds while its PR is
  # in QX_HOLD and $QX/release is absent, records the PR when it ends.
  cat > "$QH/bin/merge-conductor.sh" <<'SH'
#!/bin/bash
k="$MC_ONLY_PR"; n="${k##*#}"
mkdir -p "$QX/run/$$"
ls "$QX/run" | grep -c . >> "$QX/conc"
case " ${QX_HOLD:-} " in
  *" $n "*) i=0; while [ ! -e "$QX/release" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done ;;
esac
sleep 0.3
rmdir "$QX/run/$$"
echo "$k" >> "$QX/ran"
SH
  chmod +x "$QH/bin/merge-conductor.sh" "$QH/bin"/*.sh 2>/dev/null
}
# wake <num>... — one kw_conductor call per PR, as the callers make them.
wake() {
  ( export MC_H="$QH" MC_KEYED_WAKE_MIN_S=0
    . "$QH/bin/lib/keyed-wake.sh"
    for n in "$@"; do kw_conductor o/r "$n" "test wake $n"; done )
}
peak() { sort -n "$QX/conc" | tail -1; }
queue_n() { find "$QH/state/merge-conductor/keyed-queue" -maxdepth 1 -type f -name '*#*' 2>/dev/null | grep -c .; }
idle() { [ "$(queue_n)" = 0 ] && [ -z "$(ls "$QX/run" 2>/dev/null)" ] \
         && ! pgrep -f "$QH/bin/mc-keyed-pool.sh" >/dev/null 2>&1; }

# Q1
qsetup
export MC_KEYED_MAX_PARALLEL=3 QX_HOLD=""
wake $(seq 1 20)
waitfor '[ "$(grep -c . "$QX/ran")" -ge 20 ] && idle' || bad "Q1 the 20 ticks did not finish (ran=$(grep -c . "$QX/ran"), queue=$(queue_n))"
P=$(peak)
check "Q1 at most 3 keyed ticks at once (peak=${P:-none})" '[ -n "$P" ] && [ "$P" -le 3 ]'
check "Q1 the pool runs in parallel (peak=${P:-none} >= 2)" '[ -n "$P" ] && [ "$P" -ge 2 ]'
check "Q1 all 20 PRs ran ($(sort -u "$QX/ran" | grep -c .) distinct)" '[ "$(sort -u "$QX/ran" | grep -c .)" = 20 ]'
check "Q1 each PR ran once ($(grep -c . "$QX/ran") runs)" '[ "$(grep -c . "$QX/ran")" = 20 ]'

# Q2
qsetup
export MC_KEYED_MAX_PARALLEL=2 QX_HOLD="1 2"
wake 1 2
waitfor '[ "$(ls "$QX/run" | grep -c .)" -ge 2 ]' || bad "Q2 setup: the two held ticks did not start"
wake 99 99
check "Q2 two wakes for PR 99 fold into one queue entry (entries=$(queue_n))" '[ "$(queue_n)" = 1 ]'
check "Q2 PR 99 waits while the pool is full" '! grep -qx "o/r#99" "$QX/ran"'
: > "$QX/release"
waitfor 'grep -qx "o/r#99" "$QX/ran" && idle' || bad "Q2 PR 99 never ran after the release"
check "Q2 PR 99 ran exactly once ($(lines 'o/r#99' "$QX/ran"))" '[ "$(lines "o/r#99" "$QX/ran")" = 1 ]'
check "Q2 the held ticks ran once each" '[ "$(grep -c . "$QX/ran")" = 3 ]'

# Q3
qsetup
export MC_KEYED_MAX_PARALLEL=0 QX_HOLD=""
wake 1 2 3 4 5
waitfor '[ "$(grep -c . "$QX/ran")" -ge 5 ]' || bad "Q3 the pool-off wakes did not all run"
check "Q3 pool off: every wake ran, no entry left (ran=$(grep -c . "$QX/ran") queue=$(queue_n))" \
  '[ "$(sort -u "$QX/ran" | grep -c .)" = 5 ] && [ "$(queue_n)" = 0 ]'
unset MC_KEYED_MAX_PARALLEL QX_HOLD

# Q4
check "Q4 MC_KEYED_MAX_PARALLEL seeds 4, settable" \
  '[ "$(jq -r ".default, .settable // true" "$KNOBS/MC_KEYED_MAX_PARALLEL.json" 2>/dev/null | tr "\n" " ")" = "4 true " ]'
check "Q4 MC_FULL_TICK_PERIOD_S seeds 1800 (the */30 cron line), settable" \
  '[ "$(jq -r ".default, .settable // true" "$KNOBS/MC_FULL_TICK_PERIOD_S.json" 2>/dev/null | tr "\n" " ")" = "1800 true " ]'

# ── F1: fly-pool.sh p twice ─────────────────────────────────────────────────
FH="$T/f"
mkdir -p "$FH/bin" "$FH/logs" "$FH/flags" "$FH/locks" "$FH/env" "$FH/state/fly" "$T/ffake"
printf 'HARNESS_SECRET=test-secret\n' > "$FH/env/global.env"; : > "$FH/env/fly.env"
: > "$FH/flags/fly-pool-p"
printf '{"app":"pool-p"}\n' > "$FH/state/fly/p.json"
# The first tick holds inside pool-cap.sh until $T/frelease; a later call returns.
cat > "$FH/bin/pool-cap.sh" <<'SH'
#!/bin/bash
if mkdir "$FX/first" 2>/dev/null; then
  i=0; while [ ! -e "$FX/frelease" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
fi
echo 0
SH
printf '#!/bin/bash\nexit 0\n' > "$T/ffake/fly"
chmod +x "$FH/bin/pool-cap.sh" "$T/ffake/fly"
mkdir -p "$T/fx"
frun() { ( export HARNESS="$FH" FX="$T/fx" FLY_BIN_DIR="$T/ffake" TMPDIR="$T" PATH="$T/ffake:$PATH"
           unset FLY_API_TOKEN FLY_API_TOKEN_P FLY_ACCESS_TOKEN
           bash "$DIR/bin/fly-pool.sh" p >/dev/null 2>&1 ) ; }
frun & F1PID=$!
waitfor '[ -d "$T/fx/first" ]' || bad "F1 setup: the first tick never reached pool-cap.sh"
frun; F2RC=$?
F1LIVE=no; kill -0 "$F1PID" 2>/dev/null && F1LIVE=yes
check "F1 the second start exits rc 0 (rc=$F2RC)" '[ "$F2RC" = 0 ]'
check "F1 it exits while the first tick still runs (first live: $F1LIVE)" '[ "$F1LIVE" = yes ] && [ ! -e "$T/fx/frelease" ]'
check "F1 exactly one 'already running' line ($(lines 'already running' "$FH/logs/fly-pool.log"))" \
  '[ "$(lines "already running" "$FH/logs/fly-pool.log")" = 1 ]'
: > "$T/fx/frelease"
wait "$F1PID"; F1RC=$?
check "F1 the first tick ends rc 0 (rc=$F1RC)" '[ "$F1RC" = 0 ]'

# ── S1: stuck-work.sh p while a run of p holds the lock ─────────────────────
SH_="$T/s"
mkdir -p "$SH_/env" "$SH_/locks" "$SH_/logs" "$T/sfake"
cp -rs "$DIR/bin" "$SH_/bin"; cp -rs "$DIR/catalog" "$SH_/catalog"
rm -f "$SH_/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$SH_/catalog/lanes.json" 2>/dev/null || bad "S1 setup: lanes-build failed"
: > "$SH_/env/global.env"
cat > "$T/sfake/curl" <<'SH'
#!/bin/bash
echo "$*" >> "$SFX/reqs"
wf=0; for a in "$@"; do [ "$a" = -w ] && wf=1; done
case "$*" in *"/api/settings"*) printf '{"settings":[]}'; c=200 ;; *) printf '{"error":"not found"}'; c=404 ;; esac
[ "$wf" = 1 ] && printf '\n%s' "$c"
exit 0
SH
chmod +x "$T/sfake/curl"
printf 'p o/p - -\n' > "$T/sfleet.conf"
( flock "$SH_/locks/stuck-work-p.lock" bash -c 'i=0; while [ ! -e "$1" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done' _ "$T/srelease" ) & SHOLD=$!
waitfor '! flock -n "$SH_/locks/stuck-work-p.lock" true 2>/dev/null' || bad "S1 setup: the holder never took the lock"
( export HARNESS="$SH_" SFX="$T" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
    PATH="$T/sfake:$PATH" HARNESS_TEST_SANDBOX=1 FLEET_CONF="$T/sfleet.conf" STUCK_WORK_PROJECTS=all
  unset PL_LANE PL_PROJECT PL_LOCK_FD PL_SLUG PL_STATE_DIR STUCK_WORK_ENABLED
  bash "$SH_/bin/stuck-work.sh" p >/dev/null 2>&1 ); S1RC=$?
S1LIVE=no; kill -0 "$SHOLD" 2>/dev/null && S1LIVE=yes
check "S1 rc 0 while the holder runs (rc=$S1RC, holder live: $S1LIVE)" '[ "$S1RC" = 0 ] && [ "$S1LIVE" = yes ]'
check "S1 exactly one busy line ($(cat "$SH_/logs/stuck-work-p.log" 2>/dev/null | tr '\n' '|'))" \
  '[ "$(grep -cE "^[0-9T:Z-]+ busy$" "$SH_/logs/stuck-work-p.log" 2>/dev/null)" = 1 ]'
: > "$T/srelease"; wait "$SHOLD" 2>/dev/null

# ── C1/C2: the full-tick clock ──────────────────────────────────────────────
CH="$T/c"; CL="$DIR/bin/lib/mc-tick-clock.sh"
mkdir -p "$CH/bin" "$CH/state/merge-conductor/full-tick"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$T" > "$CH/bin/alert-line.sh"
chmod +x "$CH/bin/alert-line.sh"; : > "$T/alerts"
PER=$(jq -r '.default' "$KNOBS/MC_FULL_TICK_PERIOD_S.json" 2>/dev/null); case "$PER" in ''|*[!0-9]*) PER=1800 ;; esac
NOW=$(date +%s)
bash -c 'exec -a merge-conductor.sh sleep 60' & LIVE=$!
bash -c 'exec -a merge-conductor.sh sleep 60' & YOUNG=$!
waitfor 'grep -q merge-conductor "/proc/$LIVE/cmdline" 2>/dev/null && grep -q merge-conductor "/proc/$YOUNG/cmdline" 2>/dev/null' || true
echo $((NOW - 2 * PER - 60)) > "$CH/state/merge-conductor/full-tick/$LIVE.start"
echo $((NOW - 2 * PER + 300)) > "$CH/state/merge-conductor/full-tick/$YOUNG.start"
echo $((NOW - 2 * PER - 60)) > "$CH/state/merge-conductor/full-tick/999999.start"
# shellcheck source=bin/lib/mc-tick-clock.sh
CHK=$( [ -r "$CL" ] && . "$CL" && mc_tick_clock_check "$CH" "$PER"; [ -r "$CL" ] && . "$CL" && mc_tick_clock_check "$CH" "$PER" )
check "C1 one alert over two checks for the old live tick ($(grep -c . "$T/alerts"); check said: $(echo $CHK))" \
  '[ "$(grep -c . "$T/alerts")" = 1 ] && grep -q -- "--id mc-full-tick-slow" "$T/alerts" && grep -q "pid=$LIVE " "$T/alerts"'
check "C1 the young tick has no alert" '! grep -q "pid=$YOUNG " "$T/alerts"'
check "C1 a dead pid's stamp is removed, no alert" \
  '[ ! -e "$CH/state/merge-conductor/full-tick/999999.start" ] && ! grep -q "pid=999999 " "$T/alerts"'
kill "$LIVE" "$YOUNG" 2>/dev/null; wait "$LIVE" "$YOUNG" 2>/dev/null
C2=$( [ -r "$CL" ] || { echo nolib; exit; }
      # shellcheck source=bin/lib/mc-tick-clock.sh
      . "$CL"; MC_STATE_DIR="$T/c2/state/merge-conductor"; MC_ONLY_KEYS=""
      mc_log() { echo "$*" >> "$T/c2.log"; }
      mc_tick_clock_start; [ -f "$MC_STATE_DIR/full-tick/$$.start" ] && echo stamped
      mc_tick_clock_end;  [ -f "$MC_STATE_DIR/full-tick/$$.start" ] || echo cleared
      # shellcheck disable=SC2034 # read by mc_tick_clock_start
      MC_ONLY_KEYS=" o/r#1 "; mc_tick_clock_start; find "$MC_STATE_DIR/full-tick" -type f | grep -c . )
check "C2 a full tick stamps, then clears ($(echo $C2))" '[ "$(echo $C2)" = "stamped cleared 0" ]'
check "C2 the end logs FULL_TICK wall_s=" 'grep -qE "^FULL_TICK wall_s=[0-9]+ " "$T/c2.log" 2>/dev/null'
check "C2 merge-conductor.sh starts and ends the clock" \
  'grep -q "mc_tick_clock_start" "$DIR/bin/merge-conductor.sh" && grep -q "mc_tick_clock_end" "$DIR/bin/merge-conductor.sh"'
check "C2 the wake lane checks the clock and drains the pool" \
  'grep -q "mc_tick_clock_check" "$DIR/bin/merge-conductor-wake.sh" && grep -q "mc-keyed-pool.sh\" drain" "$DIR/bin/merge-conductor-wake.sh"'

echo "hub-overload-queue: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
