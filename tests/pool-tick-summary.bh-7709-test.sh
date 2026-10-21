#!/bin/bash
# tests/pool-tick-summary.bh-7709-test.sh — BH-7709: the hub lane
# bin/pool-tick-summary.sh reads the tail of logs/fly-pool.log once, finds each
# pool project's last tick, classifies that tick's row lines to one decision per
# key, decides what stopped the last tick (or the last start), counts the env
# bundle failures and max-ticks waits of the last hour and today's respawns, and
# POSTs one row per project to /api/pool/tick-summary.
#
# DRIVEN, NOT GREPPED. Every case runs the shipped script in a scratch harness
# (scratch_install_closure: the real jobs client, alert writer and lane gate)
# with a stub curl that records every request. No network.
#   L1  the fixture tick: 26 decisions (13 waits_for, 3 hold, 7 spawned, 3 not_queued)
#   L2  the classifier, one MATCH line per class
#   L3  the near misses: other, or no decision at all
#   L4  a key token with a space or a ';' is dropped
#   L5 L6 L7 L8 window stop: budget, age, code, done
#   L9  the newest tick still runs: the tick before it, plus in_progress_since
#   L10 a stop line after the newest header: the newest tick, even when recent
#   L11 no header in the tail: tick null with the reason, the counts null
#   L12 past 500 decisions: decisions_truncated, the totals still exact
#   L13 a bad knob: exactly 1 ALERTS line, exit 1, 0 POSTs
#   L14 max_ticks_waits_1h and last_max_ticks_at     L15 env_bundle_failures_1h
#   L16 no pool project: exit 0, 0 POSTs; no log: tick null, POST sent
#   L17 a held lock: exit 0, 0 POSTs; a failed POST: exit 0, one log line
#   L18 the defaults with no settings row
#   L19-L21 A1-A3 max-ticks: after the window, before the newest header, another project
#   L22 A4-A7 shed and spawn hold: the per-project lines count, the wrapper and REAP lines do not
#   L23 A8 no attempt line: stop is the window stop; no field ever says "cap"
#   L24 R1-R7 respawns
#   L25 the hub crontab line        L26 flags/lane-off-pool-tick-summary: 0 POSTs
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pool-tick-summary.bh-7709-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LANE="$DIR/bin/pool-tick-summary.sh"
FIXLOG="$DIR/tests/fixtures/pool-tick-summary.bh-7709/fly-pool.log"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "pool-tick-summary.bh-7709-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null || { echo "pool-tick-summary.bh-7709-test: SKIPPED — flock missing"; exit 0; }
[ -f "$LANE" ] || { echo "FAIL: missing $LANE"; exit 1; }
[ -f "$FIXLOG" ] || { echo "FAIL: missing $FIXLOG"; exit 1; }

FB="$T/fakebin"; mkdir -p "$FB"
# The stub curl: records "<METHOD> <URL> <BODY>" to $REQ_SINK and answers
# $CURL_HTTP (default 200).
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
printf '{"written":1,"rejected":0}\n%s\n' "${CURL_HTTP:-200}"
CURL
chmod +x "$FB/curl"

NOW=$(date -u -d '2026-10-21 08:00:00' +%s)   # a fixed clock
ts() { date -u -d "@$((NOW - $1))" '+%Y-%m-%d %H:%M:%SZ'; }   # ts <seconds ago>
iso() { date -u -d "@$((NOW - $1))" '+%Y-%m-%dT%H:%M:%SZ'; }

HN=0
new_harness() { # new_harness [project ...] -> H, a scratch harness with the lane's closure
  HN=$((HN+1)); H="$T/h$HN"
  mkdir -p "$H/logs" "$H/env" "$H/locks" "$H/flags"
  for S in bin/pool-tick-summary.sh bin/jobs-client.sh bin/alert-line.sh; do
    scratch_install_closure "$S" "$H" >/dev/null || { bad "scratch_install_closure $S failed"; return 1; }
  done
  echo "HARNESS_SECRET=sec-fixture-7709" > "$H/env/global.env"
  local p; for p in "$@"; do touch "$H/flags/fly-pool-$p"; done
  : > "$T/req.log"
}
run_lane() { # run_lane [VAR=value ...] -> RC
  env PATH="$FB:$PATH" HARNESS="$H" JOBS_URL="http://jobs.fixture.test" HARNESS_SECRET="sec-fixture-7709" \
    LANE_GATE_DISABLE=1 POOL_TICK_SUMMARY_NOW="$NOW" REQ_SINK="$T/req.log" \
    "$@" bash "$H/bin/pool-tick-summary.sh" </dev/null >/dev/null 2>&1
  RC=$?
}
posts() { grep -c '^POST [^ ]*/api/pool/tick-summary ' "$T/req.log"; }
body() { grep '^POST [^ ]*/api/pool/tick-summary ' "$T/req.log" | tail -1 | cut -d' ' -f3-; }
row() { jq -c --arg p "$1" '.rows[] | select(.project == $p)' <<<"$(body)"; }   # row <project>
alerts() { grep -c . "$H/logs/ALERTS.log" 2>/dev/null || echo 0; }
# one_tick <line text> ... : a log of project p with one header 600 s ago,
# then each line one second apart, then quiet.
one_tick() {
  local i=0 l
  { echo "$(ts 600) [pool/p] pool p: queued=9 running=0 spawning=1 cap=2"
    for l in "$@"; do i=$((i+1)); echo "$(ts $((600 - i))) [pool/p] $l"; done
  } > "$H/logs/fly-pool.log"
}
decs() { row p | jq -r '[.decisions[] | "\(.[0])=\(.[1])"] | join(",")'; }
stopf() { row p | jq -r '.last_tick | "\(.stop) \(.at) \(.cap) \(.knob) \(.window_stop)"'; }
# no field anywhere in the row has the value "cap" (this lane never claims a cap stop)
nocap() { row p | jq -e '[.. | strings | select(. == "cap")] | length == 0' >/dev/null; }

# ---- L1 ----
new_harness fixture-os fixture-q
cp "$FIXLOG" "$H/logs/fly-pool.log"
run_lane
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC"
[ "$(posts)" = 1 ] && ok || bad "L1 posts=$(posts): $(cat "$T/req.log")"
R=$(row fixture-os)
[ "$(jq -r '.decisions | length' <<<"$R")" = 26 ] && ok || bad "L1 decisions: $R"
GOT=$(jq -r '[.decisions[] | .[1]] | group_by(.) | map("\(.[0])=\(length)") | join(",")' <<<"$R")
[ "$GOT" = "hold=3,not_queued=3,spawned=7,waits_for=13" ] && ok || bad "L1 groups: $GOT"
[ "$(jq -r '"\(.tick) \(.queued) \(.running) \(.spawning) \(.cap) \(.hotfix)"' <<<"$R")" = "ok 126 2 2 4 1" ] && ok || bad "L1 header: $R"
[ "$(jq -r '"\(.last_tick.rows_decided) \(.last_tick.rows_spawned) \(.decisions_truncated)"' <<<"$R")" = "26 7 false" ] && ok || bad "L1 totals: $R"
[ "$(jq -r '.last_tick | "\(.started_at) \(.ended_at) \(.window_stop) \(.complete)"' <<<"$R")" = "2026-10-21T07:50:00Z 2026-10-21T07:51:52Z done true" ] && ok || bad "L1 times: $R"
# The 07:55 max-ticks wait is newer than the window: the last start was refused on the cap of 4.
[ "$(jq -r '.last_tick | "\(.stop) \(.at) \(.cap) \(.knob)"' <<<"$R")" = "max-ticks 2026-10-21T07:55:00Z 4 POOL_TICK_MAX_PARALLEL" ] && ok || bad "L1 stop: $R"
[ "$(jq -r '.decisions[0:3] | map(.[0]) | join(",")' <<<"$R")" = "FX-101,FX-102,FX-103" ] && ok || bad "L1 log order: $R"
[ "$(jq -r '.last_tick.in_progress_since' <<<"$R")" = null ] && ok || bad "L1 in_progress: $R"
jq -e '.decisions | map(.[0]) | index("FX-901") == null and index("FX-502") == null' <<<"$R" >/dev/null && ok || bad "L1 other project or older tick leaked: $R"
[ "$(jq -c '.respawns' <<<"$R")" = '[{"key":"FX-301","count":2,"last_result":"PLAN_BLOCKED","last_at":"2026-10-21T07:50:30Z"}]' ] && ok || bad "L1 respawns: $R"
[ "$(jq -r '"\(.respawns_since) \(.respawns_truncated)"' <<<"$R")" = "2026-10-21T06:30:00Z false" ] && ok || bad "L1 respawns_since (the tail starts at 06:30): $R"
Q=$(row fixture-q)
[ "$(jq -r '"\(.cap) \(.last_tick.rows_spawned)"' <<<"$Q")" = "null 1" ] && ok || bad "L1 fixture-q (cap unlimited is null): $Q"
[ "$(jq -r '.decisions | map(.[0]) | join(",")' <<<"$Q")" = "FX-902" ] && ok || bad "L1 fixture-q decisions (its window starts at its header): $Q"
[ "$(jq -r '.last_tick | "\(.stop) \(.at) \(.cap) \(.knob)"' <<<"$Q")" = "done 2026-10-21T07:51:42Z null null" ] && ok || bad "L1 fixture-q stop: $Q"
grep -q 'projects=2 ticks=2 decisions=27 POST rc=0 http=200' "$H/logs/pool-tick-summary.log" && ok || bad "L1 log: $(cat "$H/logs/pool-tick-summary.log" 2>/dev/null)"
[ "$(alerts)" = 0 ] && ok || bad "L1 alerts: $(cat "$H/logs/ALERTS.log")"
grep -q 'ssh rc 255\|still in flight' <<<"$(body)" && bad "L1 the body carries log text" || ok

# ---- L2 ----
new_harness p
one_tick "skipping BH-1: waits for BH-2 (still in flight or its PR is open) — no machine" \
  "SIBLING_SERIAL BH-3 waits for BH-2 on src/a.ts — no machine spawned; re-checked next tick" \
  "SCHED_WAIT BH-4 reason=not in ready set (tick 2026-10-21T07:49:00Z) — no machine spawned; re-checked next tick" \
  "skipping BH-5: HOLD (label)" \
  "skipping BH-6: spawn cap reached (2 of 2 in 86400s) — retried at 09:00, when the oldest counted spawn leaves the window" \
  "env bundle FAILED for BH-7: ssh rc 255 — no machine spawned, job stays queued" \
  "spawned m1 for BH-8 (live=1/2, budget 1 this tick)" \
  "pool p: BH-9 not queued :: review: pending" \
  "account a1 ran out on m2 during BH-15 — cooled down on the hub and unpinned; the next launches skip it" \
  "skipping BH-16: After: BH-2 — no machine spawned; re-checked next tick"
run_lane
[ "$(decs)" = "BH-1=waits_for,BH-3=waits_for,BH-4=waits_for,BH-5=hold,BH-6=spawn_cap,BH-7=env_bundle,BH-8=spawned,BH-9=not_queued,BH-15=quota,BH-16=waits_for" ] && ok || bad "L2 classes: $(decs)"

# ---- L3 ----
new_harness p
one_tick "skipping BH-10: hold check unreadable (gh rc 1) — will retry" \
  "BH-11: setup before launch took 4s" \
  "BH-12 gets account a1 (5h 40%, 7d 12%)" \
  "SCHED_READY BH-13 (tick 2026-10-21T07:49:00Z) — sibling-serial not consulted (scheduler.mode=enforce)" \
  "SIBLING_SERIAL_RELEASED BH-14 after 30 min behind BH-2" \
  "m-fixture-1: tick budget of 600s spent — the reuse search stops" \
  "skipping BH-17: PR check unreadable — will retry" \
  "spawned m3 for BH-17 (live=1/2, budget 1 this tick)" \
  "BH-18: the queue row refused this claim (rc 1) — no machine spawned, re-offered next tick" \
  "BH-19: the project lease is lost — no machine spawned, the job stays queued" \
  "machine run FAILED for BH-20 — job stays queued" \
  "harness sync FAILED to m4 for BH-21 — destroying, job stays queued" \
  "BH-22: no App token for o/r and the bundle carries no PAT — no machine spawned, job stays queued" \
  "BH-23: token swap produced an empty bundle and the bundle carries no PAT — no machine spawned, job stays queued" \
  "skipping BH-24: open PR exists" \
  "skipping BH-10: HOLD (label)"
run_lane
[ "$(decs)" = "BH-10=other,BH-17=spawned,BH-18=other,BH-19=other,BH-20=other,BH-21=other,BH-22=other,BH-23=other,BH-24=other" ] && ok || bad "L3 near misses: $(decs)"
[ "$(row p | jq -r '.last_tick.window_stop')" = done ] && ok || bad "L3 a REAP budget line is not window_stop=budget: $(row p)"
# a line of project q inside p's window is ignored
{ echo "$(ts 600) [pool/p] pool p: queued=1 running=0 spawning=1 cap=2"
  echo "$(ts 599) [pool/q] skipping BH-30: HOLD (label)"
  echo "$(ts 598) [pool/p] skipping BH-31: HOLD (label)"; } > "$H/logs/fly-pool.log"
run_lane
[ "$(decs)" = "BH-31=hold" ] && ok || bad "L3 other project: $(decs)"

# ---- L4 ----
new_harness p
one_tick "skipping BH 25: HOLD (label)" "skipping BH;26: HOLD (label)" "SIBLING_SERIAL BH 27 waits for BH-2 on a" \
  "spawned m1 for BH\$28 (live=1/2, budget 1 this tick)" "skipping BH-29: HOLD (label)"
run_lane
[ "$(decs)" = "BH-29=hold" ] && ok || bad "L4 bad key tokens: $(decs)"
row p | jq -e '.last_tick.rows_decided == 1' >/dev/null && ok || bad "L4 rows_decided: $(row p)"

# ---- L5-L8 ----
for c in "L5 budget POOL_TICK_BUDGET_S|tick budget of 600s spent for p: no more rows are decided this tick, the lock is released at the end" \
         "L6 age POOL_TICK_MAX_AGE_S|tick stopped at a row boundary: it has run 1300s, past POOL_TICK_MAX_AGE_S=1200s; the lock is released and the remaining rows wait for the next tick" \
         "L7 code null|tick stopped at a row boundary: the deployed pool code changed since the tick started (fp a -> b); the lock is released and the next tick runs the new code"; do
  new_harness p
  one_tick "skipping BH-1: HOLD (label)" "${c#*|}"
  run_lane
  read -r ID S KN <<<"${c%%|*}"
  [ "$(row p | jq -r '.last_tick | "\(.window_stop) \(.complete) \(.ended_at)"')" = "$S false $(iso 598)" ] && ok || bad "$ID window stop $S: $(row p)"
  [ "$(stopf)" = "$S $(iso 598) null $KN $S" ] && ok || bad "$ID stop $S: $(stopf)"
done
new_harness p
one_tick "tick budget of 600s spent for q: no more rows are decided this tick, the lock is released at the end"
run_lane
[ "$(row p | jq -r '.last_tick | "\(.window_stop) \(.stop) \(.complete)"')" = "done done true" ] && ok || bad "L8 another project's budget line: $(row p)"

# ---- L9 ----
new_harness p
{ echo "$(ts 300) [pool/p] pool p: queued=5 running=1 spawning=1 cap=2"
  echo "$(ts 299) [pool/p] skipping BH-1: HOLD (label)"
  echo "$(ts 30) [pool/p] pool p: queued=4 running=1 spawning=1 cap=2"
  echo "$(ts 10) [pool/p] skipping BH-2: HOLD (label)"; } > "$H/logs/fly-pool.log"
run_lane
R=$(row p)
[ "$(jq -r '"\(.last_tick.started_at) \(.last_tick.in_progress_since) \(.queued)"' <<<"$R")" = "$(iso 300) $(iso 30) 5" ] && ok || bad "L9 in progress: $R"
[ "$(jq -r '[.decisions[][0]] | join(",")' <<<"$R")" = "BH-1" ] && ok || bad "L9 decisions: $R"
# only one header, still running: no tick, and the reason says so
{ echo "$(ts 30) [pool/p] pool p: queued=4 running=1 spawning=1 cap=2"
  echo "$(ts 10) [pool/p] skipping BH-2: HOLD (label)"; } > "$H/logs/fly-pool.log"
run_lane
R=$(row p)
[ "$(jq -r '"\(.tick) \(.last_tick.in_progress_since) \(.queued) \(.decisions)"' <<<"$R")" = "null $(iso 30) null null" ] && ok || bad "L9 only tick in progress: $R"
jq -e '.reason | test("in progress")' <<<"$R" >/dev/null && ok || bad "L9 reason: $R"

# ---- L10 ----
new_harness p
{ echo "$(ts 300) [pool/p] pool p: queued=5 running=1 spawning=1 cap=2"
  echo "$(ts 30) [pool/p] pool p: queued=4 running=1 spawning=1 cap=2"
  echo "$(ts 20) [pool/p] skipping BH-2: HOLD (label)"
  echo "$(ts 10) [pool/p] tick stopped at a row boundary: it has run 1300s, past POOL_TICK_MAX_AGE_S=1200s; the lock is released and the remaining rows wait for the next tick"; } > "$H/logs/fly-pool.log"
run_lane
R=$(row p)
[ "$(jq -r '.last_tick | "\(.started_at) \(.window_stop) \(.in_progress_since)"' <<<"$R")" = "$(iso 30) age null" ] && ok || bad "L10 stop proves the end: $R"

# ---- L11 ----
new_harness p
echo "$(ts 30) [pool/p] skipping BH-2: HOLD (label)" > "$H/logs/fly-pool.log"
run_lane
R=$(row p)
[ "$(jq -r '"\(.tick) \(.reason)"' <<<"$R")" = "null no tick header in the last 20000 log lines" ] && ok || bad "L11 no header: $R"
# D11: the counts are null, never 0, and the keys are present
jq -e 'has("queued") and .queued == null and .running == null and .last_tick.rows_decided == null and .last_tick.stop == null' <<<"$R" >/dev/null && ok || bad "L11 null counts: $R"

# ---- L12 ----
new_harness p
{ echo "$(ts 900) [pool/p] pool p: queued=600 running=0 spawning=2 cap=2"
  for i in $(seq 1 501); do echo "$(ts 800) [pool/p] skipping K-$i: HOLD (label)"; done
  echo "$(ts 799) [pool/p] spawned m1 for K-501 (live=1/2, budget 2 this tick)"
  echo "$(ts 798) [pool/p] spawned m2 for K-502 (live=2/2, budget 2 this tick)"; } > "$H/logs/fly-pool.log"
run_lane
R=$(row p)
[ "$(jq -r '"\(.decisions | length) \(.decisions_truncated) \(.last_tick.rows_decided) \(.last_tick.rows_spawned)"' <<<"$R")" = "500 true 502 2" ] && ok || bad "L12 truncated: $(jq -c 'del(.decisions)' <<<"$R")"

# ---- L13 ----
for kv in POOL_TICK_SUMMARY_TAIL_LINES=abc POOL_TICK_SUMMARY_TAIL_LINES=999 POOL_TICK_SUMMARY_TAIL_LINES=200001 \
          POOL_TICK_SUMMARY_QUIET_S=0 POOL_TICK_SUMMARY_QUIET_S=1801 POOL_TICK_SUMMARY_QUIET_S=-5; do
  new_harness fixture-os
  cp "$FIXLOG" "$H/logs/fly-pool.log"
  run_lane "$kv"
  [ "$RC" = 1 ] && ok || bad "L13 $kv rc=$RC"
  [ "$(alerts)" = 1 ] && ok || bad "L13 $kv alerts=$(alerts)"
  grep -q "${kv%%=*}" "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "L13 $kv alert text: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
  [ "$(posts)" = 0 ] && ok || bad "L13 $kv posts=$(posts)"
done

# ---- L14, L15 ----
new_harness fixture-os
cp "$FIXLOG" "$H/logs/fly-pool.log"
run_lane
R=$(row fixture-os)
[ "$(jq -r '.last_tick | "\(.max_ticks_waits_1h) \(.last_max_ticks_at)"' <<<"$R")" = "2 2026-10-21T07:55:00Z" ] && ok || bad "L14 max-ticks: $R"
[ "$(jq -r '.env_bundle_failures_1h' <<<"$R")" = 2 ] && ok || bad "L15 env bundle 1h (07:40 x2 in, 06:50 out): $R"
[ "$(jq -r '[.decisions[] | select(.[1] == "env_bundle")] | length' <<<"$R")" = 0 ] && ok || bad "L15 the older tick's failures are not this tick's skips: $R"

# ---- L16 ----
new_harness
cp "$FIXLOG" "$H/logs/fly-pool.log"
touch "$H/flags/fly-pool-app-fixture"
run_lane
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "L16 no project rc=$RC posts=$(posts)"
[ "$(grep -c 'no pool project' "$H/logs/pool-tick-summary.log" 2>/dev/null)" = 1 ] && ok || bad "L16 log: $(cat "$H/logs/pool-tick-summary.log" 2>/dev/null)"
new_harness p
run_lane
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "L16 no log rc=$RC posts=$(posts)"
[ "$(row p | jq -r '"\(.tick) \(.reason) \(.queued) \(.respawns_since)"')" = "null no pool log null null" ] && ok || bad "L16 no log row: $(row p)"

# ---- L17 ----
new_harness p
exec 8>"$H/locks/pool-tick-summary.lock"; flock -n 8
run_lane
exec 8>&-
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "L17 held lock rc=$RC posts=$(posts)"
new_harness p
one_tick "skipping BH-1: HOLD (label)"
run_lane CURL_HTTP=500 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
[ "$RC" = 0 ] && ok || bad "L17 failed POST rc=$RC"
[ "$(grep -c 'POST rc=[1-9][0-9]* http=500' "$H/logs/pool-tick-summary.log" 2>/dev/null)" = 1 ] && ok || bad "L17 log: $(cat "$H/logs/pool-tick-summary.log" 2>/dev/null)"
# The jobs client owns the outage line; this lane adds none of its own.
[ "$(grep -c 'pool-tick-summary\]' "$H/logs/ALERTS.log" 2>/dev/null)" = 0 ] && ok || bad "L17 lane alerts: $(cat "$H/logs/ALERTS.log")"

# ---- L18 ----
new_harness p
{ echo "$(ts 400) [pool/p] pool p: queued=5 running=1 spawning=1 cap=2"
  echo "$(ts 399) [pool/p] skipping BH-1: HOLD (label)"
  echo "$(ts 200) [pool/p] pool p: queued=4 running=1 spawning=1 cap=2"
  echo "$(ts 100) [pool/p] skipping BH-2: HOLD (label)"
  for i in $(seq 1 1500); do echo "$(ts 100) [pool/z] filler $i"; done; } > "$H/logs/fly-pool.log"
run_lane
R=$(row p)
[ "$(jq -r '"\(.tail_lines) \(.last_tick.started_at) \(.last_tick.in_progress_since)"' <<<"$R")" = "20000 $(iso 400) $(iso 200)" ] && ok || bad "L18 defaults (20000 lines, quiet 120 s): $R"
run_lane POOL_TICK_SUMMARY_QUIET_S=60
[ "$(row p | jq -r '.last_tick.started_at')" = "$(iso 200)" ] && ok || bad "L18 quiet knob: $(row p)"
run_lane POOL_TICK_SUMMARY_TAIL_LINES=1000
[ "$(row p | jq -r '"\(.tail_lines) \(.tick)"')" = "1000 null" ] && ok || bad "L18 tail knob: $(row p)"

# ---- L19 (A1) max-ticks after the window end ----
new_harness p
one_tick "skipping BH-1: HOLD (label)"
echo "$(ts 300) [pool/p] max-ticks: 4 of 4 running — p waits for the next start (POOL_TICK_MAX_PARALLEL)" >> "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "max-ticks $(iso 300) 4 POOL_TICK_MAX_PARALLEL done" ] && ok || bad "L19 A1: $(stopf)"
# a max-ticks wait 30 s ago: the start was refused, so the newest tick is over (not in progress)
new_harness p
one_tick "skipping BH-1: HOLD (label)"
echo "$(ts 30) [pool/p] max-ticks: 3 of 3 running — p waits for the next start (POOL_TICK_MAX_PARALLEL)" >> "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "max-ticks $(iso 30) 3 POOL_TICK_MAX_PARALLEL done" ] && ok || bad "L19 A1 recent: $(stopf)"
[ "$(row p | jq -r '"\(.last_tick.in_progress_since) \(.last_tick.started_at)"')" = "null $(iso 600)" ] && ok || bad "L19 A1 recent window: $(row p)"

# ---- L20 (A2) max-ticks before the newest header: a tick ran after it ----
new_harness p
{ echo "$(ts 700) [pool/p] max-ticks: 4 of 4 running — p waits for the next start (POOL_TICK_MAX_PARALLEL)"
  echo "$(ts 600) [pool/p] pool p: queued=9 running=0 spawning=1 cap=2"
  echo "$(ts 599) [pool/p] skipping BH-1: HOLD (label)"; } > "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "done $(iso 599) null null done" ] && ok || bad "L20 A2: $(stopf)"
[ "$(row p | jq -r '.last_tick.max_ticks_waits_1h')" = 1 ] && ok || bad "L20 A2 the wait still counts in the hour: $(row p)"

# the newest tick is in progress and a max-ticks wait sits between the two windows: not the stop
new_harness p
{ echo "$(ts 300) [pool/p] pool p: queued=5 running=1 spawning=1 cap=2"
  echo "$(ts 299) [pool/p] skipping BH-1: HOLD (label)"
  echo "$(ts 100) [pool/p] max-ticks: 4 of 4 running — p waits for the next start (POOL_TICK_MAX_PARALLEL)"
  echo "$(ts 30) [pool/p] pool p: queued=4 running=1 spawning=1 cap=2"
  echo "$(ts 10) [pool/p] skipping BH-2: HOLD (label)"; } > "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "done $(iso 299) null null done" ] && ok || bad "L20 A2 in progress: $(stopf)"
[ "$(row p | jq -r '"\(.last_tick.started_at) \(.last_tick.in_progress_since)"')" = "$(iso 300) $(iso 30)" ] && ok || bad "L20 A2 in progress window: $(row p)"

# ---- L21 (A3) a max-ticks line of project q ----
new_harness p q
one_tick "skipping BH-1: HOLD (label)"
echo "$(ts 300) [pool/q] max-ticks: 4 of 4 running — q waits for the next start (POOL_TICK_MAX_PARALLEL)" >> "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "done $(iso 599) null null done" ] && ok || bad "L21 A3: $(stopf)"
[ "$(row q | jq -r '"\(.tick) \(.last_tick.stop) \(.last_tick.cap)"')" = "null max-ticks 4" ] && ok || bad "L21 A3 q itself: $(row q)"

# ---- L22 (A4-A7) shed and spawn hold ----
new_harness p
one_tick "skipping BH-1: HOLD (label)"
echo "$(ts 300) [pool/p] load-shed p90=9 max=8 — no spawns this tick (reap ran)" >> "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "shed $(iso 300) null null done" ] && ok || bad "L22 A4 shed: $(stopf)"
new_harness p
one_tick "skipping BH-1: HOLD (label)"
echo "$(ts 300) [pool] load-shed p90=9 max=8 — project ticks reap, they spawn nothing" >> "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "done $(iso 599) null null done" ] && ok || bad "L22 A5 wrapper shed: $(stopf)"
new_harness p
one_tick "skipping BH-1: HOLD (label)"
echo "$(ts 300) [pool/p] spawn hold: the runner lane failed (rc 75 at 07:50Z) — no spawns until 09:00Z" >> "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "hold $(iso 300) null null done" ] && ok || bad "L22 A6 spawn hold: $(stopf)"
new_harness p
one_tick "skipping BH-1: HOLD (label)" "m-fixture-1: project spawn hold is on (runner lane failed) — destroying instead of reusing"
run_lane
[ "$(stopf)" = "done $(iso 599) null null done" ] && ok || bad "L22 A7 REAP spawn hold line: $(stopf)"
# the newest attempt wins: a shed after a max-ticks wait
new_harness p
one_tick "skipping BH-1: HOLD (label)"
{ echo "$(ts 300) [pool/p] max-ticks: 4 of 4 running — p waits for the next start (POOL_TICK_MAX_PARALLEL)"
  echo "$(ts 200) [pool/p] load-shed p90=9 max=8 — no spawns this tick (reap ran)"; } >> "$H/logs/fly-pool.log"
run_lane
[ "$(stopf)" = "shed $(iso 200) null null done" ] && ok || bad "L22 newest attempt: $(stopf)"
# no header in the tail, only shed lines: tick null, the stop is still shed
new_harness p
echo "$(ts 200) [pool/p] load-shed p90=9 max=8 — no spawns this tick (reap ran)" > "$H/logs/fly-pool.log"
run_lane
[ "$(row p | jq -r '"\(.tick) \(.last_tick.stop) \(.last_tick.at) \(.queued)"')" = "null shed $(iso 200) null" ] && ok || bad "L22 shed with no header: $(row p)"

# ---- L23 (A8) no attempt line ----
new_harness p
one_tick "skipping BH-1: spawn cap reached (2 of 2 in 86400s) — retried at 09:00" "spawned m1 for BH-2 (live=1/2, budget 1 this tick)"
run_lane
[ "$(stopf)" = "done $(iso 598) null null done" ] && ok || bad "L23 A8: $(stopf)"
nocap && ok || bad "L23 A8 a field says cap: $(row p)"
new_harness fixture-os
cp "$FIXLOG" "$H/logs/fly-pool.log"
run_lane
row fixture-os | jq -e '[.. | strings | select(. == "cap")] | length == 0' >/dev/null && ok || bad "L23 fixture: a field says cap"

# ---- L24 (R1-R7) respawns ----
new_harness p
{ echo "$(ts 32400) [pool/p] spawned m0 for BH-24 (live=1/2, budget 1 this tick)"     # R3 yesterday 23:00
  echo "$(ts 32300) [pool/p] spawned m0 for BH-24 (live=1/2, budget 1 this tick)"
  echo "$(ts 3000) [pool/p] pool p: queued=9 running=0 spawning=1 cap=2"
  echo "$(ts 2999) [pool/p] spawned m1 for BH-20 (live=1/2, budget 1 this tick)"     # R1
  echo "$(ts 2998) [pool/p] spawned m1 for BH-23 (live=1/2, budget 1 this tick)"     # R2
  echo "$(ts 2997) [pool/p] spawned m1 for BH-21 (live=1/2, budget 1 this tick)"
  echo "$(ts 2996) [pool/p] spawned m1 for BH-22 (live=1/2, budget 1 this tick)"
  echo "$(ts 2000) [pool/p] reaped BH-20 from m1: BUILD_FAILED tests red"
  echo "$(ts 1900) [pool/p] reaped rebase BH-21 from m4: PLAN_BLOCKED no plan"        # R4
  echo "$(ts 1890) [pool/p] pool rereview RESULT reaped for BH-22 from m5: PLAN_BLOCKED no plan — job file written"  # R5
  echo "$(ts 1800) [pool/p] pool p: queued=9 running=0 spawning=1 cap=2"
  echo "$(ts 1799) [pool/p] spawned m2 for BH-20 (live=1/2, budget 1 this tick)"
  echo "$(ts 1798) [pool/p] spawned m2 for BH-21 (live=1/2, budget 1 this tick)"
  echo "$(ts 1797) [pool/p] spawned m2 for BH-22 (live=1/2, budget 1 this tick)"
  echo "$(ts 1797) [pool/q] spawned m2 for BH-23 (live=1/2, budget 1 this tick)"     # another project
  echo "$(ts 1000) [pool/p] reaped BH-20 from m2: PLAN_BLOCKED the plan gate refused"
  echo "$(ts 900) [pool/p] pool p: queued=9 running=0 spawning=1 cap=2"
  echo "$(ts 899) [pool/p] spawned m3 for BH-20 (live=1/2, budget 1 this tick)"; } > "$H/logs/fly-pool.log"
run_lane
R=$(row p)
[ "$(jq -c '.respawns' <<<"$R")" = "[{\"key\":\"BH-20\",\"count\":3,\"last_result\":\"PLAN_BLOCKED\",\"last_at\":\"$(iso 899)\"},{\"key\":\"BH-21\",\"count\":2,\"last_result\":null,\"last_at\":\"$(iso 1798)\"},{\"key\":\"BH-22\",\"count\":2,\"last_result\":null,\"last_at\":\"$(iso 1797)\"}]" ] && ok || bad "L24 R1-R5: $(jq -c '.respawns' <<<"$R")"
[ "$(jq -r '"\(.respawns_since) \(.respawns_truncated)"' <<<"$R")" = "2026-10-21T00:00:00Z false" ] && ok || bad "L24 respawns_since midnight: $R"
# R6 a tail that starts at 06:00Z is a partial day
new_harness p
{ echo "2026-10-21 06:00:00Z [pool/z] filler"
  echo "$(ts 600) [pool/p] pool p: queued=9 running=0 spawning=1 cap=2"; } > "$H/logs/fly-pool.log"
run_lane
[ "$(row p | jq -r '"\(.respawns_since) \(.respawns | length)"')" = "2026-10-21T06:00:00Z 0" ] && ok || bad "L24 R6: $(row p)"
# R7 60 respawning keys: 50 kept, the count-3 key first, then by key
new_harness p
{ echo "$(ts 600) [pool/p] pool p: queued=9 running=0 spawning=1 cap=2"
  for i in $(seq 10 69); do
    echo "$(ts 590) [pool/p] spawned m1 for K-$i (live=1/2, budget 1 this tick)"
    echo "$(ts 580) [pool/p] spawned m2 for K-$i (live=1/2, budget 1 this tick)"
  done
  echo "$(ts 570) [pool/p] spawned m3 for K-69 (live=1/2, budget 1 this tick)"; } > "$H/logs/fly-pool.log"
run_lane
R=$(row p)
[ "$(jq -r '"\(.respawns | length) \(.respawns_truncated) \(.respawns[0].key) \(.respawns[0].count) \(.respawns[1].key) \(.respawns[49].key)"' <<<"$R")" = "50 true K-69 3 K-10 K-58" ] && ok || bad "L24 R7: $(jq -c '[.respawns_truncated, (.respawns | length), .respawns[0], .respawns[49]]' <<<"$R")"

# ---- L25 ----
LINE=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" hub 2>/dev/null | grep -v '^[[:space:]]*#' | grep 'pool-tick-summary')
[ "$(grep -c . <<<"$LINE")" = 1 ] && ok || bad "L25 hub lines: $LINE"
grep -q '^\*/2 \* \* \* \* .*hub-lease.sh check && .*/bin/pool-tick-summary.sh' <<<"$LINE" && ok || bad "L25 line: $LINE"

# ---- L26 ----
new_harness fixture-os
cp "$FIXLOG" "$H/logs/fly-pool.log"
touch "$H/flags/lane-off-pool-tick-summary"
run_lane LANE_GATE_DISABLE=0 LANE_START_SPREAD_S=0
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "L26 lane off rc=$RC posts=$(posts)"

echo "pool-tick-summary.bh-7709-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
