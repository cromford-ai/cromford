#!/bin/bash
# tests/fly-pool-underuse.bh-7382-test.sh — the pool pages when work is queued
# and the pool builds far less than it could (BH-7382, fix 4: "alert when
# queue_depth > 5 and building < 50% of capacity for 15 minutes").
#
#   Section V  the pure verdict, bin/lib/pool-underuse.sh pool_underuse_verdict,
#              as a table (d3-d7 and the plan's decision-rule rows).
#   Section T  the real bin/fly-pool.sh tick: d1 the page, d2 one page per
#              hour, d5 pending before the window, d6 an unusable listing,
#              d8 a clear tick removes the state file, plus the knob off.
#
# Run from anywhere: tests/fly-pool-underuse.bh-7382-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset FLY_API_TOKEN FLY_API_TOKEN_TPROJ FLY_ACCESS_TOKEN POOL_AUTOSCALE POOL_CAP_MAX \
      POOL_STALL_ALERT_S POOL_UNDERUSE_ALERT_S POOL_UNDERUSE_QUEUE_MIN POOL_UNDERUSE_PCT
TAB=$'\t'
NOW0=1791860000   # pinned for the pure table

# ════ Section V: the pure verdict ══════════════════════════════════════════
# shellcheck source=bin/lib/pool-underuse.sh
. "$DIR/bin/lib/pool-underuse.sh" || { echo "FAIL: bin/lib/pool-underuse.sh cannot be sourced"; exit 1; }
v() { pool_underuse_verdict "$@"; }
# args: queued building cap since now thr qmin pct
# d1 (table half) queued 22, building 5, no cap, 1000 s: capacity 27, 5 < 13.5
[ "$(v 22 5 0 $((NOW0-1000)) "$NOW0" 900 5 50)" = "underuse${TAB}1000" ] && ok || bad "V-d1: q22 b5 cap0 1000s must be underuse: $(v 22 5 0 $((NOW0-1000)) "$NOW0" 900 5 50)"
# edge: threshold exact, 20% of a cap of 10
[ "$(v 6 2 10 $((NOW0-900)) "$NOW0" 900 5 50)" = "underuse${TAB}900" ] && ok || bad "V-edge: age == threshold, q6 b2 of cap 10 must be underuse"
[ "$(v 22 0 20 $((NOW0-2000)) "$NOW0" 900 5 50)" = "underuse${TAB}2000" ] && ok || bad "V: q22 b0 of cap 20 must be underuse"
# d3 queued 5 is not > 5
[ "$(v 5 0 0 $((NOW0-9999)) "$NOW0" 900 5 50)" = clear ] && ok || bad "V-d3: queued 5 (not > 5) must be clear"
[ "$(v 6 0 0 $((NOW0-9999)) "$NOW0" 900 5 50)" = "underuse${TAB}9999" ] && ok || bad "V-d3: queued 6 (> 5) is the near side"
# d4 building 3 of cap 6 is 50%, not < 50%
[ "$(v 22 3 6 $((NOW0-9999)) "$NOW0" 900 5 50)" = clear ] && ok || bad "V-d4: building 3 of cap 6 (exactly 50%) must be clear"
[ "$(v 22 2 6 $((NOW0-9999)) "$NOW0" 900 5 50)" = "underuse${TAB}9999" ] && ok || bad "V-d4: building 2 of cap 6 (33%) is the near side"
# d5 600 s is pending; the first tick is pending 0
[ "$(v 22 5 0 $((NOW0-600)) "$NOW0" 900 5 50)" = "pending${TAB}600" ] && ok || bad "V-d5: 600 s must be pending"
[ "$(v 22 5 0 - "$NOW0" 900 5 50)" = "pending${TAB}0" ] && ok || bad "V-d5: the first under-used tick is pending 0"
# d6 building unknown is never under-use
[ "$(v 22 unknown 0 $((NOW0-9999)) "$NOW0" 900 5 50)" = clear ] && ok || bad "V-d6: building unknown must be clear"
# d7 queued 22, building 5 of cap 6 (83%)
[ "$(v 22 5 6 $((NOW0-9999)) "$NOW0" 900 5 50)" = clear ] && ok || bad "V-d7: 5 of cap 6 building must be clear"
# off: threshold 0, pct 0
[ "$(v 22 0 0 $((NOW0-9999)) "$NOW0" 0 5 50)" = clear ] && ok || bad "V: threshold 0 is off"
[ "$(v 22 0 0 $((NOW0-9999)) "$NOW0" 900 5 0)" = clear ] && ok || bad "V: pct 0 never fires"
# a non-number is clear rc 2
OUT=$(v x 0 0 - "$NOW0" 900 5 50); RC=$?
[ "$OUT" = clear ] && [ "$RC" = 2 ] && ok || bad "V: queued 'x' must be clear rc 2 (got '$OUT' rc $RC)"
OUT=$(v 22 '' 0 - "$NOW0" 900 5 50); RC=$?
[ "$OUT" = clear ] && [ "$RC" = 2 ] && ok || bad "V: an empty building count must be clear rc 2 (got '$OUT' rc $RC)"
OUT=$(v 22 5 0 abc "$NOW0" 900 5 50); RC=$?
[ "$OUT" = clear ] && [ "$RC" = 2 ] && ok || bad "V: since 'abc' must be clear rc 2 (got '$OUT' rc $RC)"

# ════ the scratch harness for the real bin/fly-pool.sh ═════════════════════
H="$T/h"
QD="$H/state/build-queue/tproj"; MD="$H/state/fly-pool/tproj"; UF="$H/state/pool-underuse/tproj.json"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$MD" "$QD" "$H/state/pool/tproj" "$H/builds" "$T/fakebin"
: > "$H/env/fly.env"; : > "$H/env/global.env"
printf 'tproj example-org/tproj - - 0 local\n' > "$H/fleet.conf"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
# The hour flag goes through bin/lib/flags.sh: the stub client carries the real
# flag verbs with no worker, so every write lands on the flags/ file path.
scratch_install_closure bin/lib/flags.sh "$H" >/dev/null || { echo "closure install of bin/lib/flags.sh failed"; exit 1; }
cat > "$H/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/qrow.log"; return 0; }
queue_put()  { printf 'put %s\n'  "\$*" >> "$T/qrow.log"; return 0; }
JOBS_HARNESS="$H"; JOBS_BOX=fixture-box
_jobs_req() { return 1; }
_jobs_log() { :; }
. "$H/bin/lib/jobs/flags.sh"
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/pool-cap.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machines list"*) cat "$T/listing.json" 2>/dev/null || echo '[]' ;;
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*) case "\$*" in *heartbeat*) echo 5 ;; esac ;;
esac
exit 0
FLY
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

FRESH=$(date -u -d "@$(( $(date +%s) - 60 ))" +%Y-%m-%dT%H:%M:%SZ)
reset() {
  local p
  for p in "$QD"/* "$MD"/* "$MD"/.sweep.json "$H/state/pool-underuse" "$H/state/pool-stall" \
           "$T/fly-calls" "$T/alert-calls" "$T/qrow.log" "$T/listing.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  for p in "$H/flags"/alerted-*; do [ -e "$p" ] && scratch_rm "$p"; done
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  printf '%s\n' "${1:-0}" > "$H/flags/fly-pool-tproj"
  # A health halt: the tick reaches the budget and the alert, then stops before
  # any spawn, which is the state the alert exists for (work queued, nothing
  # new starting). A pool with no cap would otherwise spawn every queued job.
  : > "$H/flags/pool-halt-tproj"
  return 0
}
# pool <live> <queued> — <live> started, beating machines with jobs and
# <queued> queue files; the listing carries the live machines.
pool() {
  local i rows=""
  for i in $(seq 1 "$1"); do
    jq -nc --arg m "m${i}live" --arg k "LV-$i" '{machine:$m,key:$k,ticket_id:"1",attempt:0,deferrals:0,deaths:0}' > "$MD/m${i}live.json"
    rows="$rows{\"id\":\"m${i}live\",\"state\":\"started\",\"updated_at\":\"$FRESH\"},"
  done
  printf '[%s]\n' "${rows%,}" > "$T/listing.json"
  for i in $(seq 1 "$2"); do
    jq -nc --arg k "QD-$i" '{ticket_id:"2",key:$k,attempt:0,deferrals:0,deaths:0}' > "$QD/QD-$i.json"
  done
}
since_ago() { mkdir -p "$H/state/pool-underuse"; jq -nc --argjson s "$(( $(date +%s) - $1 ))" '{since:$s}' > "$UF"; }
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok-fixture-proj POOL_INFLIGHT_HOLD_READS=0 "$@"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
nlines() { grep -c "$1" "$2" 2>/dev/null || true; }

# ════ Section T: the real tick ═════════════════════════════════════════════
# d1 queued 22, building 5, no cap, under-used for 1000 s: one page with the counts.
reset 0; pool 5 22; since_ago 1000
tick
[ "$(nlines 'under-used' "$T/alert-calls")" = 1 ] && ok || bad "d1: exactly one under-use page: $(cat "$T/alert-calls" 2>/dev/null)"
grep -q '^\[pool/tproj\] under-used for 1[67]m: queued 22, building 5 of capacity 27 (50% floor); orphans 0, spawning 22, cap=unlimited' "$T/alert-calls" 2>/dev/null && ok \
  || bad "d1: the page text: $(grep 'under-used' "$T/alert-calls" 2>/dev/null)"
grep -q 'under-used for 1[67]m: queued 22, building 5' "$H/logs/fly-pool.log" && ok || bad "d1: the tick says it is under-used: $(grep -i under "$H/logs/fly-pool.log")"
[ -f "$H/flags/alerted-pool-underuse-tproj-$(date -u +h%H-%Y%m%d)" ] && ok \
  || bad "d1: the hour flag is flags/alerted-pool-underuse-<p>-h<HH>-<YYYYmmdd>: $(cd "$H/flags" && ls alerted-* 2>/dev/null)"
# d2 the same state again within the hour: still one page, one say line per tick.
tick
[ "$(nlines 'under-used' "$T/alert-calls")" = 1 ] && ok || bad "d2: a second tick in the same hour must not page again: $(cat "$T/alert-calls")"
[ "$(nlines 'under-used for' "$H/logs/fly-pool.log")" = 2 ] && ok || bad "d2: one say line every under-used tick"

# d5 the same counts, under-used for only 600 s: the since stays, no page.
reset 0; pool 5 22; since_ago 600
S0=$(jq -r .since "$UF")
tick
[ -s "$T/alert-calls" ] && grep -q 'under-used' "$T/alert-calls" && bad "d5: 600 s must not page: $(cat "$T/alert-calls")" || ok
[ "$(jq -r .since "$UF" 2>/dev/null)" = "$S0" ] && ok || bad "d5: the since must stay while pending: $(cat "$UF" 2>/dev/null)"
# ...and the first under-used tick writes the since-file.
reset 0; pool 5 22
tick
[ "$(jq -r '.since' "$UF" 2>/dev/null | tr -dc '0-9' | wc -c)" -ge 9 ] && ok || bad "d5: the first under-used tick writes the since-file: $(cat "$UF" 2>/dev/null)"

# d6 an unusable listing (empty beside tracked files) makes building unknown: no page, no state.
reset 0; pool 5 22; since_ago 1000
echo '[]' > "$T/listing.json"
tick
[ -s "$T/alert-calls" ] && grep -q 'under-used' "$T/alert-calls" && bad "d6: an unusable listing must not page: $(cat "$T/alert-calls")" || ok
[ -e "$UF" ] && bad "d6: building unknown is a clear tick" || ok

# d7 (real tick) 5 of a cap of 6 building: clear.
reset 6; pool 5 22; since_ago 1000
tick
[ -s "$T/alert-calls" ] && grep -q 'under-used' "$T/alert-calls" && bad "d7: 5 of cap 6 building must not page: $(cat "$T/alert-calls")" || ok

# d8 a clear tick (queue down to 5) deletes the state file.
reset 0; pool 5 5; since_ago 1000
tick
[ -e "$UF" ] && bad "d8: a clear tick must delete state/pool-underuse/tproj.json" || ok
[ -s "$T/alert-calls" ] && grep -q 'under-used' "$T/alert-calls" && bad "d8: queued 5 must not page" || ok

# off: POOL_UNDERUSE_ALERT_S=0 never pages.
reset 0; pool 5 22; since_ago 5000
tick POOL_UNDERUSE_ALERT_S=0
[ -s "$T/alert-calls" ] && grep -q 'under-used' "$T/alert-calls" && bad "off: POOL_UNDERUSE_ALERT_S=0 must not page: $(cat "$T/alert-calls")" || ok
# a bad knob value falls back to the default, with one line naming it.
reset 0; pool 5 22; since_ago 1000
tick POOL_UNDERUSE_PCT=abc
grep -q 'POOL_UNDERUSE_PCT=abc is not a number of 0-100 — using 50' "$H/logs/fly-pool.log" && ok || bad "knob: a bad value must be named: $(grep -i underuse "$H/logs/fly-pool.log")"
[ "$(nlines 'under-used' "$T/alert-calls")" = 1 ] && ok || bad "knob: the default 50 still pages"

# The new lib names no `rows` state path (bin/state-paths-guard.sh, CI step).
printf '%s\n' bin/lib/pool-underuse.sh > "$T/spg-files"
SPG_OUT=$(cd "$DIR" && SPG_FILES="$T/spg-files" bash bin/state-paths-guard.sh 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "the state-paths guard must pass the new lib (rc=$RC): $SPG_OUT"

echo "fly-pool-underuse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
