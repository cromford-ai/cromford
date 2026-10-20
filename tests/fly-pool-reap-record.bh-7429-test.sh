#!/bin/bash
# tests/fly-pool-reap-record.bh-7429-test.sh — BH-7429 (BH-6896 S2): the reap
# of a finished pool machine read every build-dir file over `ssh console`, one
# Fly call each (30 per machine), and a stopped machine answered none of them.
# The runner now posts its build record to the jobs API (bin/lib/pool-record.sh)
# and the reap reads that first, behind the lane knob POOL_RECORD_READ.
#
# This suite runs the REAL bin/fly-pool.sh on a scratch copy. The fly stub logs
# every call and serves `ssh console` from a fake machine disk under
# $T/mfs/<mid>/; the record comes from a fixture _jobs_req (export -f) that
# answers GET /api/pool/records in the worker's shape, built from those same
# files.
#   A1 2 machines with records: <= 4 Fly calls, 0 ssh, the same build dirs as
#      the ssh path        A2 record + machine stopped    A3 404 -> ssh
#   A4 another machine's record -> ssh   A5 a record older than the spawn -> ssh
#   A6 worker down -> ssh + one line     A7 skipped files, started / stopped
#   A8 a miss on a stopped machine: the BH-2643 row path is unchanged
#   A9 knob 0: no record read at all     A10 an RB- key: no record read
# BH7429_MEASURE=1 prints the before/after METRIC lines (5 ticks each).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/pool-record.sh" ] || { echo "FAIL: bin/lib/pool-record.sh does not exist (the reap has no record reader)"; FAIL=1; }
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin" "$T/ledger" "$T/rec" "$T/tmp"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "FAIL: cannot install the fly-pool closure"; exit 1; }
printf 'FLY_API_TOKEN_project-5=tok-fixture\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

# Fly: every call is one line in $T/fly.calls. The listing is $T/listing.
# `ssh console` runs the command against $T/mfs/<mid> (the machine's disk) when
# that machine is listed `started`, and reaches nothing otherwise.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly.calls"
case "\$*" in
  *"machines list"*) cat "$T/listing" ;;
  *"machine status"*) echo "State: stopped" ;;
  *"machine destroy"*) echo "\$*" >> "$T/destroyed" ;;
  *"ssh console"*)
    mid=""; cmd=""
    while [ \$# -gt 0 ]; do case "\$1" in --machine) mid="\$2"; shift ;; -C) cmd="\$2"; shift ;; esac; shift; done
    jq -e --arg m "\$mid" '.[] | select(.id==\$m and .state=="started")' "$T/listing" >/dev/null 2>&1 || exit 1
    root="$T/mfs/\$mid"
    cmd=\${cmd//\/run\/harness/\$root/run/harness}; cmd=\${cmd//\/data\/harness/\$root/data/harness}
    bash -c "\$cmd" | sed "s#\$root##g" ;;
esac
exit 0
FLY
chmod +x "$T/fakebin/fly"

# The jobs API, as a fixture. GET /api/pool/records answers $T/rec/<mid>.json
# (rc 0) or 404 (rc 2); $T/rec/_down makes every call rc 1; $T/rec/_stamp-rc
# is the reaped stamp's rc. Every call is one line in $T/jobs.calls.
_jobs_req() {
  echo "$1 $2${3:+ $3}" >> "$REC_FIX/../jobs.calls"
  [ -e "$REC_FIX/_down" ] && return 1
  case "$1 $2" in
    "GET /api/pool/records?"*)
      local m; m=$(printf '%s' "$2" | sed -n 's/.*[?&]machine=\([^&]*\).*/\1/p')
      [ -f "$REC_FIX/$m.json" ] || return 2
      cat "$REC_FIX/$m.json"; return 0 ;;
    "POST /api/pool/records/reaped")
      # What was true when the stamp arrived: is the machine file still there,
      # and had the machine been destroyed yet (BH-7429 A11).
      echo "mf=$([ -e "$REC_FIX/../h/state/fly-pool/project-5/m1.json" ] && echo present || echo gone) destroyed=$(grep -c 'machine destroy' "$REC_FIX/../fly.calls")" >> "$REC_FIX/../stamp.state"
      return "$(cat "$REC_FIX/_stamp-rc" 2>/dev/null || echo 0)" ;;
  esac
  return 1
}
# The BH-2643 pool-result row, as in its own suite.
job_ledger_row() {
  local rc; rc=$(cat "$LEDGER_FIX/rc" 2>/dev/null || echo 2)
  [ "$rc" = 0 ] && cat "$LEDGER_FIX/row"
  return "$rc"
}
export -f _jobs_req job_ledger_row

SPAWN_EPOCH=$((NOW-900))
SPAWNED_AT=$(date -u -d "@$SPAWN_EPOCH" '+%Y-%m-%d %H:%M:%SZ')
POSTED_AT=$(date -u -d "@$((SPAWN_EPOCH+600))" '+%Y-%m-%dT%H:%M:%SZ')

run_pool() { # run_pool [env assignments...]
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/destroyed"; : > "$T/fly.calls"; : > "$T/jobs.calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" \
           FLY_API_TOKEN_project-5=tok-fixture FLY_BIN_DIR="$T/fakebin" LEDGER_FIX="$T/ledger" REC_FIX="$T/rec" \
           POOL_SPAWN=0 POOL_RECORD_READ="${KNOB:-1}" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/* "$H/state/fly-pool/project-5"/* \
           "$H/state/pool/project-5"/* "$H/builds"/* "$T/ledger"/* "$T/rec"/* "$T/mfs" "$H/state/fly-cost"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}

machine() { # machine <mid> <key>: the pool json and the machine's disk
  local mid="$1" key="$2" bd="project-5-$2-202610191500"
  jq -nc --arg m "$mid" --arg k "$key" --arg ts "$SPAWNED_AT" \
    '{machine:$m,key:$k,ticket_id:"77",attempt:0,deferrals:0,deaths:0,spawned_at:$ts}' \
    > "$H/state/fly-pool/project-5/$mid.json"
  local r="$T/mfs/$mid"
  mkdir -p "$r/run/harness" "$r/data/harness/builds/$bd" "$r/data/harness/logs"
  printf 'PLAN_BLOCKED %s needs a product decision\nBUILD_DIR: /data/harness/builds/%s\n' "$key" "$bd" > "$r/run/harness/RESULT"
  printf '# plan for %s\n\n| a | b |\n' "$key" > "$r/data/harness/builds/$bd/plan.md"
  printf 'VERDICT: APPROVE\r\nwindows line\r\n' > "$r/data/harness/builds/$bd/review.md"
  printf 'E2E: PASS — ünïcode ✓\n' > "$r/data/harness/builds/$bd/e2e.md"
  printf 'abc123def\n' > "$r/data/harness/builds/$bd/reviewed-sha"
  printf 'stage one\nstage two\n' > "$r/data/harness/builds/$bd/pipeline.log"
  printf 'src/a.ts\n' > "$r/data/harness/builds/$bd/changed-files.txt"
  printf '{"ticket":"%s"}\n' "$key" > "$r/data/harness/builds/$bd/ticket-meta.json"
  printf 'class=timeout runner=claude\n' > "$r/data/harness/logs/failovers.log"
}

# The GET answer the worker gives for this machine's record, built from its
# disk: RESULT, every listed file present, the failovers.log tail.
record() { # record <mid> [posted_at] [as-machine]
  local mid="$1" at="${2:-$POSTED_AT}" as="${3:-$1}" r="$T/mfs/$1" bd f files="[]"
  bd=$(sed -n 's#^BUILD_DIR: /data/harness/builds/##p' "$r/run/harness/RESULT" | head -1)
  add() { files=$(jq -c --arg n "$1" --arg b "$(base64 -w0 "$2")" --argjson y "$(wc -c < "$2")" '. + [{name:$n,body:$b,bytes:$y,skipped:0}]' <<<"$files"); }
  add RESULT "$r/run/harness/RESULT"
  for f in "$r/data/harness/builds/$bd"/*; do add "$(basename "$f")" "$f"; done
  add failovers.log "$r/data/harness/logs/failovers.log"
  jq -nc --arg d "$bd" --arg m "$as" --arg at "$at" --argjson f "$files" \
    '{record:{build_dir:$d,machine:$m,posted_at:$at,files:$f}}' > "$T/rec/$mid.json"
}

listing() { jq -nc --arg a "$1" --arg b "${2:-}" '[{id:"m1",state:$a}] + (if $b == "" then [] else [{id:"m2",state:$b}] end)' > "$T/listing"; }
ssh_calls() { grep -c 'ssh console' "$T/fly.calls"; }
bdir() { ls -d "$H/builds/pool-project-5-$1-"* 2>/dev/null | head -1; }
LOG="$H/logs/fly-pool.log"

# ── the ssh path first (knob 0): the build dirs the record path must equal ──
reset_state
machine m1 BH-1; machine m2 BH-2; listing started started
KNOB=0 run_pool
SSH_CALLS=$(ssh_calls); SSH_TOTAL=$(wc -l < "$T/fly.calls")
mkdir -p "$T/ssh-dirs"
for k in BH-1 BH-2; do
  d=$(bdir "$k"); [ -n "$d" ] && cp -a "$d" "$T/ssh-dirs/$k" || bad "ssh path: no build dir for $k: $(cat "$LOG")"
done
[ "$SSH_CALLS" -ge 58 ] && ok || bad "ssh path: $SSH_CALLS ssh calls for 2 machines (the baseline the record path removes)"
# ── A9 knob 0: no record read at all ─────────────────────────────────────
grep -q 'GET /api/pool/records' "$T/jobs.calls" && bad "A9 knob 0 read a record: $(cat "$T/jobs.calls")" || ok

# ── A1 2 machines with records: <= 4 Fly calls, 0 ssh, the same build dirs ─
reset_state
machine m1 BH-1; machine m2 BH-2; listing started started; record m1; record m2
run_pool
N=$(wc -l < "$T/fly.calls")
[ "$N" -le 4 ] && ok || bad "A1 $N Fly calls for 2 machines with records (want <= 4): $(tr '\n' ';' < "$T/fly.calls")"
[ "$(ssh_calls)" = 0 ] && ok || bad "A1 $(ssh_calls) ssh console calls (want 0)"
[ "$(grep -c 'machine destroy' "$T/fly.calls")" = 2 ] && ok || bad "A1 destroys: $(cat "$T/destroyed")"
for k in BH-1 BH-2; do
  d=$(bdir "$k")
  if [ -n "$d" ] && [ -d "$T/ssh-dirs/$k" ]; then
    # cost.csv and its cursor carry this tick's own Fly seconds (BH-4019): they
    # differ between any two ticks, on either path. result-source (A12) names
    # where the result came from: the one file only the record path writes.
    diff -r -x cost.csv -x .cost-rows.cursor -x result-source "$T/ssh-dirs/$k" "$d" >"$T/diff.$k" 2>&1 \
      && ok || bad "A1 $k: the record path's build dir differs from the ssh path's: $(head -20 "$T/diff.$k")"
    [ -s "$d/plan.md" ] && [ -s "$d/failovers.log" ] && [ -s "$d/RESULT" ] && ok || bad "A1 $k: files missing: $(ls "$d")"
  else
    bad "A1 $k: no build dir (record=$d ssh=$T/ssh-dirs/$k)"
  fi
  grep -q "record for $k taken from the jobs API (9 files, 0 skipped)" "$LOG" \
    && ok || bad "A1 $k: no 'taken from the jobs API' line: $(grep -i record "$LOG")"
done
[ "$(grep -c '^POST /api/pool/records/reaped' "$T/jobs.calls")" = 2 ] && ok || bad "A1 reaped stamps: $(cat "$T/jobs.calls")"
grep -q "since=$(date -u -d "@$((SPAWN_EPOCH-60))" '+%Y-%m-%dT%H:%M:%SZ')" "$T/jobs.calls" \
  && ok || bad "A1 the GET is bounded by spawned_at less 60 s: $(grep GET "$T/jobs.calls")"
ls -d "$T/tmp"/pool-record.* >/dev/null 2>&1 && bad "A1 stage dirs left in TMPDIR: $(ls "$T/tmp")" || ok

# ── A2 a record and a STOPPED machine: files written, no ssh, not a death ──
reset_state
machine m1 BH-1; listing stopped; record m1
run_pool
d=$(bdir BH-1)
[ -n "$d" ] && cmp -s "$d/plan.md" "$T/mfs/m1/data/harness/builds/project-5-BH-1-202610191500/plan.md" \
  && ok || bad "A2 no plan.md from the record: $(cat "$LOG")"
[ "$(ssh_calls)" = 0 ] && ok || bad "A2 ssh calls on a stopped machine: $(ssh_calls)"
grep -q 'dead (state=' "$LOG" && bad "A2 a recorded result was counted as a death" || ok
[ -e "$H/state/build-queue/project-5/BH-1.json" ] && bad "A2 requeued: $(cat "$H/state/build-queue/project-5/BH-1.json")" || ok
grep -q 'machine destroy m1' "$T/destroyed" && ok || bad "A2 m1 not destroyed"

# ── A3 no record (404): the ssh pull, exactly as with the knob off ─────────
reset_state
machine m1 BH-1; listing started
run_pool
[ "$(ssh_calls)" = "$((SSH_CALLS/2))" ] && ok || bad "A3 404: $(ssh_calls) ssh calls, want $((SSH_CALLS/2)) (the knob-0 count for one machine)"
diff -r -x cost.csv -x .cost-rows.cursor "$T/ssh-dirs/BH-1" "$(bdir BH-1)" >/dev/null 2>&1 && ok || bad "A3 the ssh dir differs"
grep -q 'no build record for BH-1 .*pulled over ssh' "$LOG" && ok || bad "A3 no fallback line: $(cat "$LOG")"
grep -q '^POST /api/pool/records/reaped' "$T/jobs.calls" && bad "A3 a miss was stamped reaped" || ok

# ── A4 a record of ANOTHER machine for the same key: the ssh path ─────────
reset_state
machine m1 BH-1; listing started; record m1 "$POSTED_AT" m9
run_pool
[ "$(ssh_calls)" = "$((SSH_CALLS/2))" ] && ok || bad "A4 another machine's record was used: $(ssh_calls) ssh calls"
grep -q 'taken from the jobs API' "$LOG" && bad "A4 another machine's record was taken" || ok

# ── A5 a record older than the spawn (an earlier run of the key): ssh ──────
# The worker filters on since=spawned_at-60s, so the fixture answers 404 for
# it exactly as the route does (worker/jobs/test/pool-records.bh-7429.test.js G2).
reset_state
machine m1 BH-1; listing started; record m1 "$(date -u -d "@$((SPAWN_EPOCH-600))" '+%Y-%m-%dT%H:%M:%SZ')"
_since=$(date -u -d "@$((SPAWN_EPOCH-60))" '+%Y-%m-%dT%H:%M:%SZ')
[ "$(jq -r .record.posted_at "$T/rec/m1.json")" \< "$_since" ] && mv "$T/rec/m1.json" "$T/rec/m1.old"
run_pool
[ "$(ssh_calls)" = "$((SSH_CALLS/2))" ] && ok || bad "A5 an old record was used: $(ssh_calls) ssh calls"

# ── A6 the worker is down: the ssh path and one line ───────────────────────
reset_state
machine m1 BH-1; listing started; record m1; : > "$T/rec/_down"
run_pool
[ "$(ssh_calls)" = "$((SSH_CALLS/2))" ] && ok || bad "A6 worker down: $(ssh_calls) ssh calls"
[ "$(grep -c 'build record for BH-1 unreadable' "$LOG")" = 1 ] && ok || bad "A6 want one unreadable line: $(cat "$LOG")"
grep -q 'dead (state=' "$LOG" && bad "A6 an outage was counted as a death" || ok

# ── A7 skipped files: started -> one ssh pull each; stopped -> absent + line ─
reset_state
machine m1 BH-1; listing started; record m1
jq -c '(.record.files[] | select(.name=="pipeline.log")) |= (.body=null | .skipped=1)' "$T/rec/m1.json" > "$T/rec/x" && mv "$T/rec/x" "$T/rec/m1.json"
run_pool
[ "$(ssh_calls)" = 1 ] && grep -q 'pipeline.log' "$T/fly.calls" && ok || bad "A7 started: $(ssh_calls) ssh calls: $(grep ssh "$T/fly.calls")"
cmp -s "$(bdir BH-1)/pipeline.log" "$T/mfs/m1/data/harness/builds/project-5-BH-1-202610191500/pipeline.log" \
  && ok || bad "A7 started: the skipped file was not pulled"
grep -q 'record for BH-1 taken from the jobs API (9 files, 1 skipped)' "$LOG" && ok || bad "A7 started: $(grep record "$LOG")"
reset_state
machine m1 BH-1; listing stopped; record m1
jq -c '(.record.files[] | select(.name=="pipeline.log")) |= (.body=null | .skipped=1)' "$T/rec/m1.json" > "$T/rec/x" && mv "$T/rec/x" "$T/rec/m1.json"
run_pool
[ "$(ssh_calls)" = 0 ] && ok || bad "A7 stopped: $(ssh_calls) ssh calls"
[ ! -e "$(bdir BH-1)/pipeline.log" ] && ok || bad "A7 stopped: pipeline.log exists"
grep -q 'record for BH-1 taken from the jobs API (8 files, 1 skipped; not on the hub: pipeline.log' "$LOG" \
  && ok || bad "A7 stopped: the line must name the absent file: $(grep record "$LOG")"
# The stamp fails: one line, the build dir stays.
reset_state
machine m1 BH-1; listing started; record m1; echo 1 > "$T/rec/_stamp-rc"
run_pool
grep -q 'build record for BH-1 not stamped reaped' "$LOG" && [ -s "$(bdir BH-1)/plan.md" ] && ok || bad "A7 stamp failure: $(grep record "$LOG")"

# ── A11 the stamp is the LAST step (BH-7429 review): it lands after the ────
# terminal work — the machine destroyed and its file gone — so a tick that dies
# before the end leaves the record unstamped and the next tick reads it again.
reset_state; : > "$T/stamp.state"
machine m1 BH-1; listing started; record m1
run_pool
[ "$(cat "$T/stamp.state")" = "mf=gone destroyed=1" ] && ok || bad "A11 the stamp arrived early: '$(cat "$T/stamp.state")' (want 'mf=gone destroyed=1')"
# ── A12 the record arm names its source, as the row arm does ───────────────
grep -q 'build record' "$(bdir BH-1)/result-source" 2>/dev/null && ok || bad "A12 result-source missing or wrong: $(cat "$(bdir BH-1)/result-source" 2>&1)"

# ── A8 a miss on a stopped machine: the BH-2643 row path runs unchanged ───
reset_state
machine m1 BH-1; listing stopped
DEFLINE="BUILD_DEFERRED REFUSED pause :: paused: pause_flags row paused-project-5 is active"
jq -nc --arg r "$DEFLINE" --argjson a "$((SPAWN_EPOCH+31))" \
  '{status:"result",detail:({rline:$r,machine:"m1",at:$a}|tojson)}' > "$T/ledger/row"; echo 0 > "$T/ledger/rc"
run_pool
grep -q 'result for BH-1 taken from the pool-result row' "$LOG" && ok || bad "A8 the row path did not run: $(cat "$LOG")"
grep -q 'pool-result row' "$(bdir BH-1)/result-source" 2>/dev/null && ok || bad "A8 result-source missing"
[ "$(jq -r '.deferrals' "$H/state/build-queue/project-5/BH-1.json" 2>/dev/null)" = 1 ] && ok || bad "A8 not requeued as a deferral"

# ── A10 a rebase key never reads a record (its reap is its own, BH-542) ───
reset_state
machine m1 RB-21-abc; listing started; record m1
run_pool
grep -q 'GET /api/pool/records' "$T/jobs.calls" && bad "A10 an RB- key read a record: $(cat "$T/jobs.calls")" || ok
[ "$(ssh_calls)" -ge 1 ] && ok || bad "A10 the RB- key was not reaped over ssh"

# ── measure mode: 5 two-machine ticks per path ─────────────────────────────
if [ "${BH7429_MEASURE:-}" = 1 ]; then
  median() { sort -g | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
  # The fixed cost of a tick with nothing to reap, so the margin per machine
  # can be read apart from it.
  : > "$T/cpu.empty"
  for i in 1 2 3 4 5; do
    reset_state; listing started started
    TIMEFORMAT='%U %S'
    { time KNOB=1 run_pool; } 2> "$T/time.out"
    awk '{printf "%.3f\n", $1+$2}' "$T/time.out" >> "$T/cpu.empty"
  done
  EMPTY=$(median < "$T/cpu.empty")
  for path in ssh record; do
    : > "$T/cpu.$path"; : > "$T/fly.$path"
    for i in 1 2 3 4 5; do
      reset_state
      machine m1 BH-1; machine m2 BH-2; listing started started
      [ "$path" = record ] && { record m1; record m2; }
      kb=0; [ "$path" = record ] && kb=1
      TIMEFORMAT='%U %S'
      { time KNOB=$kb run_pool; } 2> "$T/time.out"
      awk '{printf "%.3f\n", ($1+$2)/2}' "$T/time.out" >> "$T/cpu.$path"
      # Per reaped machine: every Fly call but the tick's one agent start and
      # one listing, over the 2 machines.
      awk -v n="$(wc -l < "$T/fly.calls")" 'BEGIN{printf "%.1f\n", (n-2)/2}' >> "$T/fly.$path"
    done
    CPM=$(median < "$T/cpu.$path")
    echo "METRIC $path fly_per_machine=$(median < "$T/fly.$path") cpu_per_machine=$CPM cpu_margin_per_machine=$(awk -v c="$CPM" -v e="$EMPTY" 'BEGIN{printf "%.3f", c-e/2}') empty_tick_cpu=$EMPTY"
  done
  # The record arm alone (pool_record_get + pool_record_install) on m1's
  # record, 10 times: the part of the reap this ticket replaced.
  reset_state; machine m1 BH-1; listing started; record m1
  TIMEFORMAT='%U %S'
  { time ( export HARNESS="$H" TMPDIR="$T/tmp" REC_FIX="$T/rec"
      . "$DIR/bin/lib/pool-record.sh"
      for i in 1 2 3 4 5 6 7 8 9 10; do
        rm -rf "$T/arm"; mkdir -p "$T/arm/local"
        I=$(pool_record_get project-5 BH-1 m1 "$SPAWNED_AT" "$T/arm/stage") || exit 1
        pool_record_install "$T/arm/stage" "$T/arm/local" m1 started "$I" >/dev/null || exit 1
      done ) ; } 2> "$T/time.out" || bad "measure: the record arm failed"
  echo "METRIC record_arm cpu_per_machine=$(awk '{printf "%.3f", ($1+$2)/10}' "$T/time.out")"
fi

echo "fly-pool-reap-record: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
