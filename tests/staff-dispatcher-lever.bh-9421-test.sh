#!/bin/bash
# tests/staff-dispatcher-lever.bh-9421-test.sh — BH-9421 (BH-9187 C3): the
# dispatcher pilot, driven through the SHIPPED bin/staff-dispatcher-lever.sh.
#
#   A1   level observe, file and no level row: ONE metric post (value 2), 0
#        action posts, 0 queue writes
#   A2   level act, dry run by default: 2 action posts, dryRun:true, release
#        first then enqueue, every field the C0 route validates; 0 queue writes
#   A3   level act, STAFF_DSP_LEVER_DRY_RUN=0: each action post comes BEFORE
#        its queue write (PATCH count_attempt:true, POST with no status)
#   A4   a replay (existing:true) and a 409 key_mismatch are `seen`, never a
#        second queue write; STAFF_DSP_LEVER_MAX caps new rows, claims first,
#        the rest deferred
#   A5   the metric decision table (ready rows and orphan claims)
#   A6   the enqueue guard: BLOCKED, `OK trailing`, empty, a timeout, no gate
#        script, a running build job -> declined, no action row; OK -> 1 row
#   A7   the four kill flags, STAFF_DSP_LEVER_ENABLED=0 and a paused roster row
#   A8   a 500-row answer (any of the 3 reads) or a failed read: no sample,
#        no action
#   A9   a failed metric post: the lever still runs
#   A10  a failed action post: no queue write, failed=1
#   A11  a capped release: one release-cap line, released=0
#   A12  0 vendor calls: curl and gh on PATH are never run
#   A13  the release guard (BH-9421 lead BLOCK): a build job for the key
#        opened after claimed_at, whatever its status, or any build job that
#        finished inside STAFF_DSP_FINISH_GRACE_MIN (fly-pool has not
#        collected it yet), or a failed per-key jobs read = declined, no
#        action row, no queue write. A job that finished before the claim and
#        outside the grace does not stop the release.
#
# MUTATIONS (D1), each tried once by hand against the lane: drop the
# running-job filter -> A5 red; `>=` to `>` on the age -> A5 edge red; post the
# action after the queue write -> A3 red; drop the level check -> A1 red; drop
# the 500-row check -> A8 red.
#
# The worker is a stub in the STAFF_DSP_FIXTURE file (sourced by the lane
# after its libs, sandbox only). flag_active, staff_level, queue_put and
# queue_release_counted are the real ones over that stub. curl and gh on PATH
# log and fail.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-dispatcher-lever.bh-9421-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-dispatcher-lever: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
count() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

for SRC in "$DIR/bin/staff-dispatcher-lever.sh" "$DIR/catalog/lanes.d/staff-dispatcher-lever.json" \
           "$DIR/cron/lanes/729-staff-dispatcher-lever.cron" "$DIR/bin/lib/staff-contract.sh"; do
  [ -r "$SRC" ] || bad "missing $SRC"
done
[ -r "$DIR/bin/staff-dispatcher-lever.sh" ] || { echo "staff-dispatcher-lever: $PASS passed, $FAIL failed"; exit 1; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/env" "$T/fakebin"
for L in bin/staff-dispatcher-lever.sh bin/jobs-client.sh bin/lib/staff-contract.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
mkdir -p "$H/catalog"; cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
: > "$H/env/global.env"
for b in curl gh agent-call agent-call.sh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 99\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done

# The fixture. $FXT/req.log is every request in order. Answers:
#   agent.json the roster row; set.<key> a settings value (absent = no row)
#   ready.json claimed.json jobs.json the three list answers; <name>.down = rc 1
#   metric.fail, action.fail = rc 1; action.ans + action.rc = a fixed answer
#   patch.ans the PATCH /api/queue answer
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name=dispatcher") cat "$FXT/agent.json"; return 0 ;;
    "GET /api/settings/"*)
      local k=${2#/api/settings/}
      [ -f "$FXT/set.$k" ] || return 2
      jq -cn --arg v "$(cat "$FXT/set.$k")" '{setting: {value: $v}}'; return 0 ;;
    "GET /api/queue?status=ready"*) [ -f "$FXT/ready.down" ] && return 1; cat "$FXT/ready.json"; return 0 ;;
    "GET /api/queue?status=claimed"*) [ -f "$FXT/claimed.down" ] && return 1; cat "$FXT/claimed.json"; return 0 ;;
    "GET /api/jobs?project="*)
      printf '%s\n' "$2" >> "$FXT/keyjobs.log"
      [ -f "$FXT/keyjobs.down" ] && return 1
      if [ -f "$FXT/keyjobs.json" ]; then cat "$FXT/keyjobs.json"; else echo '{"jobs":[],"as_of":"2026-11-10T12:00:00.123Z"}'; fi
      return 0 ;;
    "GET /api/jobs?"*) [ -f "$FXT/jobs.down" ] && return 1; cat "$FXT/jobs.json"; return 0 ;;
    "PATCH /api/queue") cat "$FXT/patch.ans"; return 0 ;;
    "POST /api/queue") printf '{"queued":{"status":"queued"},"duplicate":false}'; return 0 ;;
  esac
  return 2
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/req.log"
  case "$2" in
    /api/staff/levers/metric)
      jq -c . "$3" >> "$FXT/metric.jsonl"
      [ -f "$FXT/metric.fail" ] && return 1
      echo '{"ok":true,"sample_id":1,"settled":0}'; return 0 ;;
    /api/staff/levers/actions)
      jq -c . "$3" >> "$FXT/actions.jsonl"
      [ -f "$FXT/action.fail" ] && return 1
      if [ -f "$FXT/action.ans" ]; then cat "$FXT/action.ans"; return "$(cat "$FXT/action.rc" 2>/dev/null || echo 0)"; fi
      echo '{"ok":true,"action":{"id":1}}'; return 0 ;;
  esac
  return 1
}
SH

NOW_E=$(date -u -d 2026-11-10T12:00:00Z +%s)
ago() { date -u -d "@$((NOW_E - $1 * 60))" +%Y-%m-%dT%H:%M:%SZ; }
SEQ=0
# qrow <status> <age-min> [project]: one build_queue row with a unique key.
qrow() {
  SEQ=$((SEQ + 1)); local k="DSP-$$${SEQ}" p="${3:-proj-a}" st=$1 a; a=$(ago "$2")
  jq -cn --arg p "$p" --arg k "$k" --arg s "$st" --arg a "$a" \
    '{project: $p, ticket_key: $k, ticket_id: ("id-" + $k), status: $s, target: "fly", attempt: 0,
      claimed_by: (if $s == "claimed" then "fly-x" else null end),
      claimed_at: (if $s == "claimed" then $a else null end),
      enqueued_at: (if $s == "claimed" then "2026-11-01T00:00:00Z" else $a end)}'
}
# jrow <project> <ticket_id> <kind>: one running job.
jrow() { jq -cn --arg p "$1" --arg t "$2" --arg k "$3" '{id: ("j-" + $t), project: $p, ticket_id: $t, kind: $k, status: "running"}'; }
keyof() { jq -r .ticket_key <<<"$1"; }
# put <file> <field> <rows...>
put() { local f=$1 fld=$2; shift 2; printf '%s\n' "$@" | jq -s --arg f "$fld" '{($f): [.[] | select(. != null)], as_of: "2026-11-10T12:00:00.123Z"}' > "$FXT/$f.json"; }
manyrows() { local i; for i in $(seq 1 500); do printf '{"project":"proj-a","ticket_key":"M-%s","status":"%s","enqueued_at":"2026-11-10T11:59:00Z","claimed_at":"2026-11-10T11:59:00Z","kind":"build"}\n' "$i" "$1"; done; }
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT" "$T/net.log"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT" "$H/flags"
  echo '{"agent":{"name":"dispatcher","status":"active"}}' > "$FXT/agent.json"
  echo '{"queued":{"status":"queued","attempt":1}}' > "$FXT/patch.ans"
  put ready queue; put claimed queue; put jobs jobs
  gate OK
}
# gate <mode>: the stub bin/triage-gate.sh. OK | BLOCKED | TRAIL | EMPTY | SLEEP | MISSING
gate() {
  rm -f "$H/bin/triage-gate.sh"
  case "$1" in
    MISSING) return 0 ;;
    OK) printf '#!/bin/bash\necho "$*" >> "%s/gate.log"\necho OK\n' "$FXT" ;;
    BLOCKED) printf '#!/bin/bash\necho "BLOCKED deps"\n' ;;
    TRAIL) printf '#!/bin/bash\necho "OK trailing"\n' ;;
    EMPTY) printf '#!/bin/bash\nexit 0\n' ;;
    SLEEP) printf '#!/bin/bash\nsleep 30\necho OK\n' ;;
  esac > "$H/bin/triage-gate.sh"
  chmod +x "$H/bin/triage-gate.sh"
}
level() { printf '%s' "$1" > "$FXT/set.staff.dispatcher.level"; }
run() { # the shipped entry point, sandboxed
  env HARNESS="$H" FXT="$FXT" STAFF_DSP_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 STAFF_DSP_TIMED=1 JOBS_URL= JOBS_SETTINGS_CACHE_S=0 PATH="$T/fakebin:$PATH" "$@" \
    bash "$H/bin/staff-dispatcher-lever.sh" >"$T/out.txt" 2>&1
}
LOGF="$H/logs/staff-dispatcher-lever.log"
REQ="$FXT/req.log"
# Every request but the flag reads the kill check itself makes (flag_active
# reads the worker's flags; the staff-* flags are ported).
nonflag() { grep -vc ' /api/flags' "$REQ" 2>/dev/null || true; }
metric_posts() { count "POST /api/staff/levers/metric" "$REQ"; }
action_posts() { count "POST /api/staff/levers/actions" "$REQ"; }
queue_writes() { grep -cE '^(PATCH|POST) /api/queue ' "$REQ" 2>/dev/null || true; }
mvalue() { jq -s -r 'last | .value // "none"' "$FXT/metric.jsonl" 2>/dev/null || echo none; }
summ() { grep -o "$1=[^ ]*" "$LOGF" 2>/dev/null | tail -1 | cut -d= -f2; }
netcheck() { [ -s "$T/net.log" ] && bad "$1: vendor call: $(head -1 "$T/net.log")" || ok; }
# bad_state: 1 ready row 3h old + 1 claimed row 45m old with no job.
bad_state() { RR=$(qrow ready 180); CR=$(qrow claimed 45); put ready queue "$RR"; put claimed queue "$CR"; }

# ═════ A1: observe, file, no row -> sample only ══════════════════════════════
for L in observe file none; do
  reset; bad_state
  [ "$L" = none ] || level "$L"
  run; rc=$?
  eq "A1[$L] exit" "$rc" 0
  eq "A1[$L] metric posts" "$(metric_posts)" 1
  eq "A1[$L] metric value" "$(mvalue)" 2
  eq "A1[$L] action posts" "$(action_posts)" 0
  eq "A1[$L] queue writes" "$(queue_writes)" 0
  WANT=observe; [ "$L" = file ] && WANT=file
  eq "A1[$L] summary level" "$(summ level)" "$WANT"
  [ "$L" = file ] && eq "A1[file] summary level is file" "$(grep -c 'level=file ' "$LOGF")" 1
  [ "$L" = none ] && eq "A1[none] level_fallback" "$(grep -c 'level_fallback=1' "$LOGF")" 1
  netcheck "A1[$L]"
done

# ═════ A2: act, dry run by default ═══════════════════════════════════════════
reset; bad_state; level act
run
eq "A2 action posts" "$(action_posts)" 2
eq "A2 levers in order" "$(jq -r .lever "$FXT/actions.jsonl" | paste -sd, -)" "release,enqueue"
eq "A2 dryRun" "$(jq -r .dryRun "$FXT/actions.jsonl" | paste -sd, -)" "true,true"
eq "A2 metricBefore" "$(jq -r .metricBefore "$FXT/actions.jsonl" | paste -sd, -)" "2,2"
eq "A2 agent" "$(jq -r .agent "$FXT/actions.jsonl" | sort -u)" dispatcher
eq "A2 metric" "$(jq -r .metric "$FXT/actions.jsonl" | sort -u)" ready_unqueued_2h
eq "A2 targets" "$(jq -r .target "$FXT/actions.jsonl" | paste -sd, -)" "proj-a/$(keyof "$CR"),proj-a/$(keyof "$RR")"
eq "A2 key format" "$(jq -r .key "$FXT/actions.jsonl" | head -1)" "release|dry|proj-a/$(keyof "$CR")|$(jq -r .claimed_at <<<"$CR")"
# The C0 route's validation (worker/jobs/src/routes/staff-levers.js): strings
# 1..200, dryRun boolean, metricBefore a finite number, detail a string <= 2000.
eq "A2 bodies valid" "$(jq -s '[.[] | (.agent|type=="string") and (.lever|type=="string" and length<=200)
  and (.target|type=="string" and length<=200) and (.dryRun|type=="boolean") and (.metric|test("^[a-z][a-z0-9_]{0,63}$"))
  and (.metricBefore|type=="number") and (.key|type=="string" and length>0 and length<=200)
  and ((.detail // "")|type=="string" and length<=2000)] | all' "$FXT/actions.jsonl")" true
eq "A2 metric body detail is a string" "$(jq -r '.detail | type' "$FXT/metric.jsonl")" string
eq "A2 queue writes" "$(queue_writes)" 0
eq "A2 summary" "$(summ actions_new) $(summ dry_run)" "2 1"
eq "A2 gate asked with the ticket id" "$(cat "$FXT/gate.log" 2>/dev/null)" "proj-a --buildable-strict $(jq -r .ticket_id <<<"$RR")"
netcheck A2

# ═════ A3: act, live: the action row comes first ═════════════════════════════
reset; bad_state; level act
run STAFF_DSP_LEVER_DRY_RUN=0
L_AR=$(grep -n 'POST /api/staff/levers/actions .*"lever":"release"' "$REQ" | cut -d: -f1)
L_P=$(grep -n '^PATCH /api/queue ' "$REQ" | cut -d: -f1)
L_AE=$(grep -n 'POST /api/staff/levers/actions .*"lever":"enqueue"' "$REQ" | cut -d: -f1)
L_Q=$(grep -n '^POST /api/queue ' "$REQ" | cut -d: -f1)
[ -n "$L_AR" ] && [ -n "$L_P" ] && [ "$L_AR" -lt "$L_P" ] && ok || bad "A3 release action ($L_AR) before PATCH ($L_P)"
[ -n "$L_AE" ] && [ -n "$L_Q" ] && [ "$L_AE" -lt "$L_Q" ] && ok || bad "A3 enqueue action ($L_AE) before POST ($L_Q)"
eq "A3 PATCH counts the attempt" "$(grep '^PATCH /api/queue ' "$REQ" | sed 's/^PATCH \/api\/queue //' | jq -r '.count_attempt, .status, .key' | paste -sd, -)" "true,queued,$(keyof "$CR")"
eq "A3 POST has no status" "$(grep '^POST /api/queue ' "$REQ" | sed 's/^POST \/api\/queue //' | jq -r '(.status // "none"), .key, .ticket_id' | paste -sd, -)" "none,$(keyof "$RR"),$(jq -r .ticket_id <<<"$RR")"
eq "A3 dryRun false" "$(jq -r .dryRun "$FXT/actions.jsonl" | paste -sd, -)" "false,false"
eq "A3 live key" "$(jq -r .key "$FXT/actions.jsonl" | cut -d'|' -f1,2 | paste -sd, -)" "release|live,enqueue|live"
eq "A3 summary" "$(summ released) $(summ enqueued) $(summ actions_new)" "1 1 2"
netcheck A3

# ═════ A4: replay is seen; the cap ═══════════════════════════════════════════
echo '{"ok":true,"existing":true,"action":{"id":1}}' > "$FXT/action.ans"
: > "$REQ"
run STAFF_DSP_LEVER_DRY_RUN=0
eq "A4 replay queue writes" "$(queue_writes)" 0
eq "A4 replay seen" "$(summ seen) $(summ actions_new)" "2 0"
echo '{"error":"key_mismatch","action":{"id":1}}' > "$FXT/action.ans"; echo 9 > "$FXT/action.rc"
: > "$REQ"
run STAFF_DSP_LEVER_DRY_RUN=0
eq "A4 key_mismatch queue writes" "$(queue_writes)" 0
eq "A4 key_mismatch seen" "$(summ seen) $(summ failed)" "2 0"
reset; level act
C1=$(qrow claimed 50); C2=$(qrow claimed 40); C3=$(qrow claimed 60); R1=$(qrow ready 200); R2=$(qrow ready 300)
put claimed queue "$C1" "$C2" "$C3"; put ready queue "$R1" "$R2"
run STAFF_DSP_LEVER_MAX=3
eq "A4 cap new posts" "$(action_posts)" 3
eq "A4 cap claims first, oldest first" "$(jq -r .target "$FXT/actions.jsonl" | paste -sd, -)" \
  "proj-a/$(keyof "$C3"),proj-a/$(keyof "$C1"),proj-a/$(keyof "$C2")"
eq "A4 deferred" "$(summ deferred)" 2
netcheck A4

# ═════ A5: the metric decision table ═════════════════════════════════════════
# m5 <want> <label> : runs with the lists already put, observe level
m5() { run; eq "A5 $2" "$(mvalue)" "$1"; }
reset; put ready queue "$(qrow ready 120)"; m5 1 "ready 120m (edge)"
reset; put ready queue "$(qrow ready 180)"; m5 1 "ready 3h"
reset; put ready queue "$(qrow ready 119)"; m5 0 "ready 119m"
reset; put ready queue "$(qrow queued 300)" "$(qrow dropped 300)" "$(qrow claimed 300)"; m5 0 "queued/dropped/claimed in the ready answer"
reset; put claimed queue "$(qrow claimed 30)"; m5 1 "claimed 30m (edge), no job"
reset; X=$(qrow claimed 45); put claimed queue "$X"; put jobs jobs "$(jrow proj-a "$(keyof "$X")" triage)"; m5 1 "claimed 45m, running triage job"
reset; X=$(qrow claimed 45); put claimed queue "$X"; put jobs jobs "$(jrow proj-b "$(keyof "$X")" build)"; m5 1 "claimed 45m, running build in another project"
reset; put claimed queue "$(qrow claimed 29)"; m5 0 "claimed 29m"
reset; X=$(qrow claimed 45); put claimed queue "$X"; put jobs jobs "$(jrow proj-a "$(keyof "$X")" build)"; m5 0 "claimed 45m, running build same key"
reset; X=$(qrow claimed 45); put claimed queue "$X"; put jobs jobs "$(jrow proj-a "$(jq -r .ticket_id <<<"$X")" build)"; m5 0 "claimed 45m, running build by ticket_id"
reset; put claimed queue "$(qrow claimed 45)"; touch "$FXT/jobs.down"; run
eq "A5 claimed 45m, jobs read failed: no sample" "$(metric_posts)" 0
reset; put ready queue "$(qrow ready 180)" "$(qrow ready 10)"; put claimed queue "$(qrow claimed 45)" "$(qrow claimed 5)"; m5 2 "mixed"
eq "A5 mixed detail" "$(jq -r '.detail | fromjson | "\(.ready) \(.claimed_orphan) \(.ready_age_min) \(.claim_age_min)"' "$FXT/metric.jsonl")" "1 1 120 30"
reset; put ready queue "$(qrow ready 100)"; run STAFF_DSP_READY_AGE_MIN=90; eq "A5 ready knob 90" "$(mvalue)" 1
reset; put claimed queue "$(qrow claimed 20)"; run STAFF_DSP_CLAIM_AGE_MIN=15; eq "A5 claim knob 15" "$(mvalue)" 1
reset; put ready queue "$(qrow ready 180)"; run STAFF_DSP_READY_AGE_MIN=0
eq "A5 out-of-range knob: default + warn" "$(mvalue) $(count 'warn: STAFF_DSP_READY_AGE_MIN=0' "$LOGF")" "1 1"

# ═════ A6: the enqueue guard ═════════════════════════════════════════════════
for G in BLOCKED TRAIL EMPTY SLEEP MISSING RUNNING; do
  reset; level act; RR=$(qrow ready 180); put ready queue "$RR"
  if [ "$G" = RUNNING ]; then put jobs jobs "$(jrow proj-a "$(keyof "$RR")" build)"; else gate "$G"; fi
  run STAFF_DSP_GATE_TIMEOUT_S=5 STAFF_DSP_LEVER_DRY_RUN=0
  eq "A6[$G] action posts" "$(action_posts)" 0
  eq "A6[$G] queue writes" "$(queue_writes)" 0
  eq "A6[$G] declined lines" "$(count 'declined enqueue' "$LOGF")" 1
  eq "A6[$G] summary declined" "$(summ declined)" 1
done
reset; level act; put ready queue "$(qrow ready 180)"; gate OK
run
eq "A6[OK] enqueue action posts" "$(action_posts)" 1
eq "A6[OK] declined" "$(summ declined)" 0

# ═════ A7: kill flags, the enabled knob, the roster ══════════════════════════
for F in staff-off-all staff-kill-all staff-off-dispatcher staff-kill-dispatcher; do
  reset; bad_state; level act; touch "$H/flags/$F"
  run
  eq "A7[$F] non-flag requests" "$(nonflag)" 0
  eq "A7[$F] killed line" "$(count "killed by $F" "$LOGF")" 1
done
reset; bad_state; level act; run STAFF_DSP_LEVER_ENABLED=0
eq "A7 disabled non-flag requests" "$(nonflag)" 0
reset; bad_state; level act; echo '{"agent":{"name":"dispatcher","status":"paused"}}' > "$FXT/agent.json"; run
eq "A7 paused metric posts" "$(metric_posts)" 0
eq "A7 paused action posts" "$(action_posts)" 0
eq "A7 paused log line" "$(count "not active" "$LOGF")" 1

# ═════ A8: incomplete or failed reads ════════════════════════════════════════
for W in ready claimed jobs; do
  reset; bad_state; level act
  case "$W" in
    ready) manyrows ready | jq -s '{queue: ., as_of: "2026-11-10T12:00:00Z"}' > "$FXT/ready.json" ;;
    claimed) manyrows claimed | jq -s '{queue: ., as_of: "2026-11-10T12:00:00Z"}' > "$FXT/claimed.json" ;;
    jobs) manyrows running | jq -s '{jobs: ., as_of: "2026-11-10T12:00:00Z"}' > "$FXT/jobs.json" ;;
  esac
  run
  eq "A8[$W 500] metric posts" "$(metric_posts)" 0
  eq "A8[$W 500] action posts" "$(action_posts)" 0
  eq "A8[$W 500] incomplete line" "$(count "incomplete: $W" "$LOGF")" 1
  reset; bad_state; level act; touch "$FXT/$W.down"
  run
  eq "A8[$W down] metric posts" "$(metric_posts)" 0
  eq "A8[$W down] action posts" "$(action_posts)" 0
  eq "A8[$W down] unreadable line" "$(count "unreadable: $W" "$LOGF")" 1
done
reset; bad_state; level act; echo '{"queue": "x", "as_of": "2026-11-10T12:00:00Z"}' > "$FXT/ready.json"; run
eq "A8 non-array answer: no sample" "$(metric_posts) $(count 'unreadable: ready' "$LOGF")" "0 1"

# ═════ A9: a failed metric post does not stop the lever ═════════════════════
reset; bad_state; level act; touch "$FXT/metric.fail"; run
eq "A9 action posts" "$(action_posts)" 2
eq "A9 metric failed line" "$(count 'metric post failed' "$LOGF")" 1

# ═════ A10: a failed action post writes nothing ══════════════════════════════
reset; level act; put claimed queue "$(qrow claimed 45)"; touch "$FXT/action.fail"
run STAFF_DSP_LEVER_DRY_RUN=0
eq "A10 queue writes" "$(queue_writes)" 0
eq "A10 summary" "$(summ failed) $(summ actions_new) $(summ released)" "1 0 0"

# ═════ A11: a capped release ═════════════════════════════════════════════════
reset; level act; put claimed queue "$(qrow claimed 45)"
echo '{"queued":{"status":"failed","attempt":4},"attempt_max":3}' > "$FXT/patch.ans"
run STAFF_DSP_LEVER_DRY_RUN=0
eq "A11 release-cap line" "$(count 'release-cap' "$LOGF")" 1
eq "A11 released" "$(summ released) $(summ actions_new)" "0 1"

# ═════ A13: the release guard: a finished build is not an orphan ═══════════
# kjob <ticket_id> <status> <created-ago-min> <updated-ago-min>: one build job.
kjob() { jq -cn --arg t "$1" --arg s "$2" --arg c "$(ago "$3")" --arg u "$(ago "$4")" \
  '{id: ("j-" + $t + "-" + $s), project: "proj-a", ticket_id: $t, kind: "build", status: $s, created_at: $c, updated_at: $u}'; }
# a13 <label> <want-actions> <dry> <job-rows...>: one claimed row 90 min old, no running job.
a13() {
  local label=$1 want=$2 dry=$3; shift 3
  reset; level act; CR=$(qrow claimed 90); put claimed queue "$CR"
  K=$(keyof "$CR"); I=$(jq -r .ticket_id <<<"$CR")
  local rows=() r; for r in "$@"; do rows+=("$(eval "$r")"); done
  [ "${#rows[@]}" -gt 0 ] && put keyjobs jobs "${rows[@]}"
  run STAFF_DSP_LEVER_DRY_RUN="$dry"
  eq "A13[$label] action posts" "$(action_posts)" "$want"
  if [ "$want" = 0 ]; then
    eq "A13[$label] queue writes" "$(queue_writes)" 0
    eq "A13[$label] declined release line" "$(count 'declined release' "$LOGF")" 1
    eq "A13[$label] summary declined" "$(summ declined) $(summ released)" "1 0"
  else
    eq "A13[$label] released" "$(summ released) $(summ declined)" "1 0"
  fi
}
a13 "done after claim, live"        0 0 'kjob "$K" done 80 2'
a13 "done after claim, dry run"     0 1 'kjob "$K" done 80 2'
a13 "failed after claim, long ago"  0 0 'kjob "$K" failed 85 70'
a13 "done by ticket_id"             0 0 'kjob "$I" done 80 2'
a13 "resumed job, done in grace"    0 0 'kjob "$K" done 300 5'
a13 "old job, done past grace"      1 0 'kjob "$K" done 300 200'
a13 "no build job at all"           1 0
eq "A13 per-key read names project, key and kind" "$(head -1 "$FXT/keyjobs.log")" "/api/jobs?project=proj-a&ticket_id=$K&kind=build&limit=50"
reset; level act; put claimed queue "$(qrow claimed 90)"; touch "$FXT/keyjobs.down"
run STAFF_DSP_LEVER_DRY_RUN=0
eq "A13[read down] action posts" "$(action_posts)" 0
eq "A13[read down] queue writes" "$(queue_writes)" 0
eq "A13[read down] declined" "$(summ declined)" 1
reset; level act; put claimed queue "$(qrow claimed 90)"; printf 'oops' > "$FXT/keyjobs.json"
run STAFF_DSP_LEVER_DRY_RUN=0
eq "A13[non-JSON] action posts" "$(action_posts)" 0
reset; level act; CR=$(qrow claimed 90); put claimed queue "$CR"; put keyjobs jobs "$(kjob "$(keyof "$CR")" done 300 15)"
run STAFF_DSP_LEVER_DRY_RUN=0 STAFF_DSP_FINISH_GRACE_MIN=10
eq "A13 grace knob 10: a 15m-old finish releases" "$(summ released)" 1
netcheck A13

# ═════ A12: 0 vendor calls over the whole suite ═════════════════════════════
netcheck A12

echo "staff-dispatcher-lever: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
