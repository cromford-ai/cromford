#!/bin/bash
# tests/mc-wake-consumer.bh-6975-test.sh — BH-6975 (BH-6545.2): the merge
# conductor acts on PR and check wakes within a minute.
#
# Driven through the REAL bin/merge-conductor-wake.sh over real curl against
# the REAL jobs worker (tests/lib/mc-wake-worker.bh-6975.mjs). K1/K2 write their
# wake rows through the real signed POST /webhooks/github (wakeOf), the other
# cases insert a row with a chosen `at`. The launcher is the REAL kw_conductor
# (bin/lib/keyed-wake.sh); stubbed: bin/merge-conductor.sh (appends
# $MC_ONLY_PR to a calls file) and gh on PATH (fixtures, `gh api -i` shape).
#
#   K1  check_run.completed on an open WAIT_CI head -> one keyed tick, WAKE line, cursor = max
#   K2  pull_request.synchronize, not-harness line -> 0 calls, skip not-harness, consumed
#   K2b a wake for a repo no fleet project owns -> skip unowned-repo
#   K3  budget row 2, four PRs -> 2 calls, hold budget, cursor at the 2nd; rerun -> 2 more
#   K3b budget 0 -> 0 calls, cursor unchanged
#   K4  a wake 42 s old -> latency_s=42 (clock pinned by MC_WAKE_NOW)
#   C1  no row, no env -> registry default 10 (11 PRs: 10 calls, 1 hold)
#   C2  a fresh keyed-wake stamp -> carry deduped; stamp aged -> paid from the carry
#   C3a sha not in pr-state.tsv, GitHub names open PR 13 -> 1 call
#   C3b GitHub answers [] -> skip no-open-pr; C3c lookups 0 -> skip sha-unplaced, no gh call
#   C4  901 s old -> stale, 899 s -> tick; a 901 s carry line -> dropped stale
#   C5  no cursor row -> planted at max, 0 calls, no ALERTS.log
#   C6  a-e: lane flag, automerge-disabled, lane-off-merge-conductor,
#       switch.factory-stop, mc_keyed_wake=0 -> 0 calls, cursor unchanged
#   C7  worker down -> 0 calls, exit 0, one `worker unreachable` line
#   C8  only push and issue wakes -> 0 calls, no WAKE line, cursor = max
#   C9  five checks wakes on one head -> 1 call, 4 done-this-tick
#   C10 a pr wake with key `-` -> skip no-key
#   C11 a not-harness-unread line only -> still a tick
#   C12 the lane lock held -> 0 calls, cursor unchanged
#   C13 one sha heads two PRs, budget 1 -> 1 call, the other carried reason=budget
#
# Run from anywhere: tests/mc-wake-consumer.bh-6975-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/mc-wake-worker.bh-6975.mjs"
SCRIPT_REL=bin/merge-conductor-wake.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 && command -v setsid >/dev/null 2>&1 \
  || { echo "SKIP: node, jq, curl, flock or setsid missing"; exit 0; }

SLUG=Example-Org/example-repo
LSLUG=example-org/example-repo
A=$(printf 'a%.0s' $(seq 1 40))
B=$(printf 'b%.0s' $(seq 1 40))
C=$(printf 'c%.0s' $(seq 1 40))
T0=1792000000
export LANE_REGISTRY
LANE_REGISTRY=$(cd "$DIR" && . bin/lib/lanes-registry.sh && lanes_json_path "$DIR") \
  || { echo "setup: the lane registry did not compose"; exit 1; }

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT

# The gh stub: `gh api -i -X <m> <path>` answers `HTTP/2 200` + the fixture
# $GHFIX/<path with / as _>.json, a missing fixture is GitHub's 404. Every call
# is one line in $GHFIX/calls.
mkdir -p "$T/ghbin"
cat > "$T/ghbin/gh" <<'STUB'
#!/bin/bash
[ "${1:-}" = api ] || exit 0
shift; P=""
while [ $# -gt 0 ]; do
  case "$1" in -i) ;; -X|-H|--jq) shift ;; *) P="$1" ;; esac; shift
done
echo "$P" >> "$GHFIX/calls"
F="$GHFIX/$(printf '%s' "$P" | tr '/' '_').json"
if [ -e "$F" ]; then printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; cat "$F"; exit 0; fi
printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n{"message":"Not Found"}'; exit 1
STUB
chmod +x "$T/ghbin/gh"

# fresh — a new scratch harness H and a new worker; exports JOBS_URL.
N=0
fresh() {
  N=$((N+1))
  H="$T/h$N"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/env" "$H/flags" "$T/gh$N"
  # The stub goes in first: scratch_install_closure never overwrites a file.
  cat > "$H/bin/merge-conductor.sh" <<'STUB'
#!/bin/bash
# stub: the keyed conductor tick records which PR it was started for
printf '%s\n' "${MC_ONLY_PR:-ALL}" >> "$STUB_CALLS"
STUB
  ( cd "$DIR" && scratch_install_closure "$SCRIPT_REL" "$H" && scratch_install_closure bin/jobs-client.sh "$H" \
    && scratch_install_closure bin/fleet-conf.sh "$H" ) >/dev/null 2>&1 || bad "setup: closure install"
  chmod +x "$H/bin/"*.sh 2>/dev/null
  printf 'proj %s https://proj.example /api/board 0 local -\n' "$SLUG" > "$H/fleet.conf"
  : > "$T/calls$N"; : > "$T/w$N.log"; : > "$T/w$N.port"; : > "$T/gh$N/calls"
  export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUB_CALLS="$T/calls$N" GHFIX="$T/gh$N"
  export HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
  export LANE_GATE_CACHE_S=0 BOX_NAME=hub GH_ETAG=0 PATH="$T/ghbin:$PATH"
  # The lane's clock is pinned (MC_WAKE_NOW) and every inserted wake's `at` is
  # relative to it. K1/K2 unset it: their rows carry the worker's real clock.
  export MC_WAKE_NOW="$T0"
  unset MC_WAKE_BUDGET MC_WAKE_WAKES MC_WAKE_MIN_S MC_WAKE_MAX_AGE_S MC_WAKE_SHA_LOOKUPS MC_KEYED_WAKE MC_KEYED_WAKE_MIN_S MC_H
  node "$SRV" "$T/w$N.log" > "$T/w$N.port" 2> "$T/w$N.err" &
  WPID=$!; PIDS+=("$WPID")
  for _ in $(seq 1 200); do [ -s "$T/w$N.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$N.port")
  if [ -z "$PORT" ]; then wait "$WPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
    echo "setup: worker did not start: $(cat "$T/w$N.err")"; exit 1; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
}

LOGF() { printf '%s' "$H/logs/merge-conductor-wake-cron.log"; }
has() { grep -qF -- "$1" "$(LOGF)" 2>/dev/null; }
cnt() { grep -cF -- "$1" "$(LOGF)" 2>/dev/null; }
calls() { grep -c . "$STUB_CALLS"; }
# run — the lane once, then a bounded wait (<= 5 s) until every detached stub
# conductor the lane reported started (`action=tick`) has written its line.
run() {
  "$H/$SCRIPT_REL" > "$T/run.out" 2>&1; RC=$?
  local want; want=$(cnt "action=tick")
  for _ in $(seq 1 50); do [ "$(calls)" -ge "${want:-0}" ] && break; sleep 0.1; done
  sleep 0.2
}
cursor() { curl -sS "$JOBS_URL/__cursor" | jq -r '.cursor // "null"'; }
maxid() { curl -sS "$JOBS_URL/__cursor" | jq -r '.max_id'; }
ago() { date -u -d "@$(( ${MC_WAKE_NOW:-$(date -u +%s)} - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k, value:$v}')" >/dev/null; }
# wake <kind> <key> [event] [age_s] [repo] — one row; prints its id
wake() {
  curl -sS -X PUT "$JOBS_URL/__wake" -d "$(jq -nc --arg r "${5:-$SLUG}" --arg k "$1" --arg key "$2" \
    --arg e "${3:-pull_request.synchronize}" --arg at "$(ago "${4:-0}")" '{repo:$r, kind:$k, key:$key, event:$e, at:$at}')" \
    | jq -r .id
}
hook() { # hook <event> <payload json> <delivery> — through the real webhook route
  curl -sS -X POST "$JOBS_URL/__hook" -d "$(jq -nc --arg e "$1" --argjson p "$2" --arg d "$3" \
    '{event:$e, payload:$p, delivery:$d}')" > "$T/hook.out"
}
prstate() { # prstate <n> <state> <head> — one pr-state.tsv row (key state since head ...)
  printf '%s#%s\t%s\t2026-10-16T00:00:00Z\t%s\t-\t-\t-\thttps://github.com/%s/pull/%s\n' \
    "$SLUG" "$1" "$2" "$3" "$SLUG" "$1" >> "$H/state/merge-conductor/pr-state.tsv"
}
fx() { printf '%s' "$2" > "$GHFIX/$(printf '%s' "$1" | tr '/' '_').json"; }
plant() { run; [ "$(cursor)" != null ] || bad "setup: the first tick planted no cursor"; : > "$(LOGF)"; }
wakeline() { grep -F "WAKE pr=$1 " "$(LOGF)" | head -1; }
latency_of() { wakeline "$1" | sed -n 's/.* latency_s=\([^ ]*\) .*/\1/p'; }

for f in "$DIR/$SCRIPT_REL" "$DIR/tests/lib/mc-wake-worker.bh-6975.mjs" \
         "$DIR/catalog/lanes.d/merge-conductor-wake.json" "$DIR/cron/lanes/413-merge-conductor-wake.cron"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done

# --- K1: a checks wake for an open harness PR head ------------------------------
fresh; unset MC_WAKE_NOW; plant
prstate 11 WAIT_CI "$A"
hook check_run "$(jq -nc --arg s "$A" --arg r "$SLUG" '{action:"completed", check_run:{head_sha:$s}, repository:{full_name:$r}}')" d-k1
run
[ "$RC" = 0 ] && ok "K1 exit 0" || bad "K1 rc $RC: $(cat "$T/run.out")"
[ "$(calls)" = 1 ] && grep -qx "$SLUG#11" "$STUB_CALLS" \
  && ok "K1 exactly one keyed tick, MC_ONLY_PR=$SLUG#11" || bad "K1 calls: $(cat "$STUB_CALLS")"
L=$(wakeline 11)
[[ "$L" =~ WAKE\ pr=11\ event=check_run\.completed\ latency_s=[0-9]+\ repo=$SLUG\ wake=[0-9]+\ action=tick ]] \
  && ok "K1 WAKE pr=11 event=check_run.completed latency_s=<int> action=tick" || bad "K1 line: $(cat "$(LOGF)")"
[ "$(cursor)" = "$(maxid)" ] && ok "K1 cursor = max ($(cursor))" || bad "K1 cursor $(cursor) max $(maxid)"
has "tick wakes=1 pc=1 ticks=1 carried=0 budget=10" && ok "K1 summary line" || bad "K1 summary: $(tail -1 "$(LOGF)")"

# --- K2 / K2b: not a harness PR -------------------------------------------------
fresh; unset MC_WAKE_NOW; plant
echo "not-harness $LSLUG#12" >> "$H/state/merge-conductor/attempts.txt"
hook pull_request "$(jq -nc --arg r "$SLUG" '{action:"synchronize", number:12, pull_request:{number:12}, repository:{full_name:$r}}')" d-k2
hook pull_request "$(jq -nc '{action:"synchronize", number:14, pull_request:{number:14}, repository:{full_name:"Other-Org/unknown"}}')" d-k2b
run
[ "$(calls)" = 0 ] && ok "K2 no keyed tick for a non-harness PR" || bad "K2 calls: $(cat "$STUB_CALLS")"
[[ "$(wakeline 12)" =~ event=pull_request\.synchronize\ latency_s=[0-9]+\ .*action=skip\ reason=not-harness ]] \
  && ok "K2 WAKE pr=12 action=skip reason=not-harness (attempts line in another case)" || bad "K2 line: $(cat "$(LOGF)")"
[[ "$(wakeline 14)" =~ repo=Other-Org/unknown\ .*action=skip\ reason=unowned-repo ]] \
  && ok "K2b WAKE pr=14 action=skip reason=unowned-repo" || bad "K2b line: $(cat "$(LOGF)")"
[ "$(cursor)" = "$(maxid)" ] && ok "K2 both wakes consumed: cursor = max" || bad "K2 cursor $(cursor) max $(maxid)"

# --- K3 / K3b: the budget ---------------------------------------------------------
fresh; plant
setting lane.merge-conductor-wake.mc_wake_budget 2
for n in 21 22 23 24; do eval "W$n=\$(wake pr $n)"; done
run
[ "$(calls)" = 2 ] && grep -qx "$SLUG#21" "$STUB_CALLS" && grep -qx "$SLUG#22" "$STUB_CALLS" \
  && ok "K3 budget 2: keyed ticks for 21 and 22 only" || bad "K3 calls: $(cat "$STUB_CALLS")"
[[ "$(wakeline 23)" =~ action=hold\ reason=budget ]] && ok "K3 WAKE pr=23 action=hold reason=budget" || bad "K3 hold: $(cat "$(LOGF)")"
[ -n "$(wakeline 24)" ] && bad "K3 PR 24 was decided after the hold" || ok "K3 the loop stops at the hold"
[ "$(cursor)" = "$W22" ] && ok "K3 cursor = the PR 22 wake ($W22)" || bad "K3 cursor $(cursor), want $W22"
: > "$(LOGF)"; run
[ "$(calls)" = 4 ] && grep -qx "$SLUG#23" "$STUB_CALLS" && grep -qx "$SLUG#24" "$STUB_CALLS" \
  && ok "K3 next tick: 23 and 24 tick" || bad "K3 rerun calls: $(cat "$STUB_CALLS")"
[ "$(cursor)" = "$(maxid)" ] && ok "K3 next tick: cursor = max" || bad "K3 rerun cursor $(cursor)"
fresh; plant
setting lane.merge-conductor-wake.mc_wake_budget 0
C0=$(cursor); wake pr 25 >/dev/null
run
[ "$(calls)" = 0 ] && [ "$(cursor)" = "$C0" ] && ok "K3b budget 0: 0 calls, cursor unchanged" \
  || bad "K3b calls=$(calls) cursor $(cursor) (was $C0)"

# --- K4: the latency line -----------------------------------------------------------
fresh; plant
wake pr 31 pull_request.opened 42 >/dev/null
run
LAT=$(latency_of 31)
[ "$LAT" = 42 ] && ok "K4 latency_s=42 (the clock is pinned)" || bad "K4 latency '$LAT': $(cat "$(LOGF)")"
[[ "$(wakeline 31)" =~ ^.*WAKE\ pr=31\ event=pull_request\.opened\ latency_s= ]] \
  && ok "K4 the line starts WAKE pr=31 event=pull_request.opened latency_s=" || bad "K4 line: $(wakeline 31)"

# --- C1: the registry default -------------------------------------------------------
fresh; plant
for n in $(seq 101 111); do wake pr "$n" >/dev/null; done
run
[ "$(calls)" = 10 ] && ok "C1 no row and no env: budget 10 (10 calls)" || bad "C1 calls=$(calls)"
[ "$(cnt "action=hold reason=budget")" = 1 ] && [[ "$(wakeline 111)" =~ action=hold ]] \
  && ok "C1 the eleventh PR (111) is held" || bad "C1 hold: $(cat "$(LOGF)")"

# --- C2: a deduped launch is carried, then paid ---------------------------------------
fresh; plant
mkdir -p "$H/state/merge-conductor/keyed-wake"
STAMP="$H/state/merge-conductor/keyed-wake/Example-Org_example-repo#41"
date +%s > "$STAMP"
wake pr 41 pull_request.synchronize 5 >/dev/null
run
[ "$(calls)" = 0 ] && ok "C2 tick 1: a fresh stamp starts nothing" || bad "C2 tick 1 calls: $(cat "$STUB_CALLS")"
[[ "$(wakeline 41)" =~ action=carry\ reason=deduped ]] && ok "C2 tick 1: action=carry reason=deduped" || bad "C2 line: $(cat "$(LOGF)")"
CARRY="$H/state/merge-conductor-wake/carry.tsv"
[ "$(grep -c . "$CARRY" 2>/dev/null)" = 1 ] && grep -qx "$SLUG#41" <<<"$(cut -f1 "$CARRY")" \
  && ok "C2 tick 1: one carry line for $SLUG#41" || bad "C2 carry: $(cat "$CARRY" 2>/dev/null)"
[ "$(cursor)" = "$(maxid)" ] && ok "C2 tick 1: the wake is complete (cursor = max)" || bad "C2 cursor $(cursor)"
LAT1=$(latency_of 41)
echo $(( $(date +%s) - 60 )) > "$STAMP"
export MC_WAKE_NOW=$((T0 + 20))
: > "$(LOGF)"; run
[ "$(calls)" = 1 ] && grep -qx "$SLUG#41" "$STUB_CALLS" && ok "C2 tick 2: the carry is paid (one call #41)" \
  || bad "C2 tick 2 calls: $(cat "$STUB_CALLS")"
[[ "$(wakeline 41)" =~ wake=carry\ action=tick ]] && ok "C2 tick 2: wake=carry action=tick" || bad "C2 tick 2 line: $(cat "$(LOGF)")"
[ ! -s "$CARRY" ] && ok "C2 tick 2: the carry file is empty" || bad "C2 carry left: $(cat "$CARRY")"
LAT2=$(latency_of 41)
[ "$LAT1" = 5 ] && [ "$LAT2" = 25 ] \
  && ok "C2 the carry keeps the first at (latency 5 -> 25, 20 s later)" || bad "C2 latency $LAT1 -> $LAT2"

# --- C3: a sha pr-state.tsv does not know --------------------------------------------
fresh; plant
fx "repos/$LSLUG/commits/$B/pulls" "$(jq -nc --arg s "$B" '[{number:13, state:"open", head:{sha:$s}}]')"
wake checks "$B" check_suite.completed >/dev/null
run
[ "$(calls)" = 1 ] && grep -qx "$SLUG#13" "$STUB_CALLS" && ok "C3a GitHub names open PR 13: one call, fleet.conf spelling" \
  || bad "C3a calls: $(cat "$STUB_CALLS") log: $(cat "$(LOGF)")"
grep -qx "repos/$LSLUG/commits/$B/pulls" "$GHFIX/calls" && ok "C3a one commits/<sha>/pulls read" || bad "C3a gh: $(cat "$GHFIX/calls")"
fresh; plant
prstate 15 MERGED "$C"
fx "repos/$LSLUG/commits/$C/pulls" '[]'
wake checks "$C" check_run.completed >/dev/null
run
[ "$(calls)" = 0 ] && [[ "$(wakeline -)" =~ action=skip\ reason=no-open-pr ]] \
  && ok "C3b a MERGED row does not map; GitHub answers []: skip no-open-pr" || bad "C3b calls=$(calls): $(cat "$(LOGF)")"
fresh; plant
setting lane.merge-conductor-wake.mc_wake_sha_lookups 0
wake checks "$B" check_run.completed >/dev/null
run
[ "$(calls)" = 0 ] && [[ "$(wakeline -)" =~ action=skip\ reason=sha-unplaced ]] \
  && ok "C3c no lookups left: skip sha-unplaced" || bad "C3c calls=$(calls): $(cat "$(LOGF)")"
[ ! -s "$GHFIX/calls" ] && ok "C3c no GitHub read" || bad "C3c gh: $(cat "$GHFIX/calls")"

# --- C4: stale -------------------------------------------------------------------------
fresh; plant
wake pr 70 pull_request.synchronize 901 >/dev/null
wake pr 71 pull_request.synchronize 899 >/dev/null
mkdir -p "$H/state/merge-conductor-wake"
printf '%s#72\tpull_request.opened\t%s\t5\n' "$SLUG" "$(ago 901)" > "$H/state/merge-conductor-wake/carry.tsv"
run
[ "$(calls)" = 1 ] && grep -qx "$SLUG#71" "$STUB_CALLS" && ok "C4 899 s old ticks, 901 s old does not (max age 900)" \
  || bad "C4 calls: $(cat "$STUB_CALLS")"
[[ "$(wakeline 70)" =~ action=skip\ reason=stale ]] && ok "C4 WAKE pr=70 skip stale" || bad "C4 70: $(cat "$(LOGF)")"
[[ "$(wakeline 72)" =~ wake=carry\ action=skip\ reason=stale ]] && ok "C4 a 901 s carry line: skip stale" || bad "C4 72: $(cat "$(LOGF)")"
[ ! -s "$H/state/merge-conductor-wake/carry.tsv" ] && ok "C4 the stale carry line is dropped" || bad "C4 carry: $(cat "$H/state/merge-conductor-wake/carry.tsv")"

# --- C5: the first tick ------------------------------------------------------------------
fresh
for n in 1 2 3; do wake pr "8$n" >/dev/null; done
run
[ "$(cursor)" = "$(maxid)" ] && [ "$(cursor)" = 3 ] && ok "C5 no cursor row: planted at max 3" || bad "C5 cursor $(cursor) max $(maxid)"
[ "$(calls)" = 0 ] && ok "C5 the first tick starts nothing" || bad "C5 calls=$(calls)"
has "first tick — cursor planted at 3" && ok "C5 the plant is logged" || bad "C5 log: $(cat "$(LOGF)")"
[ ! -e "$H/logs/ALERTS.log" ] && ok "C5 no ALERTS.log" || bad "C5 alert: $(cat "$H/logs/ALERTS.log")"

# --- C6: off switches ----------------------------------------------------------------------
off_case() { # off_case <label> <setup command...>
  local label="$1"; shift
  fresh; plant
  wake pr 90 >/dev/null; local c0; c0=$(cursor)
  "$@"
  run
  [ "$RC" = 0 ] && [ "$(calls)" = 0 ] && [ "$(cursor)" = "$c0" ] \
    && ok "$label: exit 0, 0 calls, cursor unchanged" || bad "$label: rc $RC calls=$(calls) cursor $(cursor) (was $c0): $(cat "$(LOGF)")"
}
flag() { touch "$H/flags/$1"; }
off_case "C6a flags/lane-off-merge-conductor-wake" flag lane-off-merge-conductor-wake
off_case "C6b flags/automerge-disabled" flag automerge-disabled
off_case "C6c flags/lane-off-merge-conductor" flag lane-off-merge-conductor
fx_stop() { setting switch.factory-stop 1; }
off_case "C6d switch.factory-stop=1" fx_stop
fx_kw() { setting lane.merge-conductor.mc_keyed_wake 0; }
off_case "C6e lane.merge-conductor.mc_keyed_wake=0" fx_kw
has "keyed wakes off" && ok "C6e the off line is logged" || bad "C6e log: $(cat "$(LOGF)")"

# --- C7: worker down -------------------------------------------------------------------------
fresh; plant
wake pr 91 >/dev/null
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
run
[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && ok "C7 worker down: exit 0, 0 calls" || bad "C7 rc $RC calls=$(calls)"
[ "$(cnt "worker unreachable")" = 1 ] && ok "C7 one worker unreachable line" || bad "C7 log: $(cat "$(LOGF)")"

# --- C8: other kinds ---------------------------------------------------------------------------
fresh; plant
wake push "$A" "push.$B..$A" >/dev/null
wake issue 5 issues.opened >/dev/null
run
[ "$(calls)" = 0 ] && ! has "WAKE " && ok "C8 push and issue wakes: 0 calls, no WAKE line" || bad "C8 calls=$(calls): $(cat "$(LOGF)")"
[ "$(cursor)" = "$(maxid)" ] && ok "C8 cursor = max" || bad "C8 cursor $(cursor)"

# --- C9: many wakes, one PR ----------------------------------------------------------------------
fresh; plant
prstate 51 WAIT_CI "$A"
for _ in 1 2 3 4 5; do wake checks "$A" check_run.completed >/dev/null; done
run
[ "$(calls)" = 1 ] && grep -qx "$SLUG#51" "$STUB_CALLS" && ok "C9 five wakes on one head: one call" || bad "C9 calls: $(cat "$STUB_CALLS")"
[ "$(cnt "action=skip reason=done-this-tick")" = 4 ] && ok "C9 four skip done-this-tick" || bad "C9 log: $(cat "$(LOGF)")"

# --- C10: no key ---------------------------------------------------------------------------------
fresh; plant
wake pr - >/dev/null
run
[ "$(calls)" = 0 ] && [[ "$(wakeline -)" =~ action=skip\ reason=no-key ]] && ok "C10 key -: skip no-key" || bad "C10: $(cat "$(LOGF)")"

# --- C11: not-harness-unread is not proof ----------------------------------------------------------
fresh; plant
echo "not-harness-unread $LSLUG#61" >> "$H/state/merge-conductor/attempts.txt"
wake pr 61 >/dev/null
run
[ "$(calls)" = 1 ] && grep -qx "$SLUG#61" "$STUB_CALLS" && ok "C11 a not-harness-unread line only: still one call" \
  || bad "C11 calls=$(calls): $(cat "$(LOGF)")"

# --- C12: the lane lock held -------------------------------------------------------------------------
fresh; plant
wake pr 62 >/dev/null; C0=$(cursor)
( flock -n 9 && sleep 20 ) 9>"$H/locks/merge-conductor-wake.lock" &
LPID=$!; PIDS+=("$LPID"); sleep 0.3
run
[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && [ "$(cursor)" = "$C0" ] && ok "C12 lock held: exit 0, 0 calls, cursor unchanged" \
  || bad "C12 rc $RC calls=$(calls) cursor $(cursor)"
kill "$LPID" 2>/dev/null

# --- C13: one sha heads two PRs, the budget ends between them ----------------------------------------
fresh; plant
setting lane.merge-conductor-wake.mc_wake_budget 1
prstate 53 WAIT_CI "$C"; prstate 54 READY "$C"
wake checks "$C" check_run.completed >/dev/null
run
[ "$(calls)" = 1 ] && grep -qx "$SLUG#53" "$STUB_CALLS" && ok "C13 budget 1: one call (#53)" || bad "C13 calls: $(cat "$STUB_CALLS")"
[[ "$(wakeline 54)" =~ action=carry\ reason=budget ]] && ok "C13 PR 54: carry reason=budget" || bad "C13 log: $(cat "$(LOGF)")"
grep -qx "$SLUG#54" <<<"$(cut -f1 "$H/state/merge-conductor-wake/carry.tsv" 2>/dev/null)" && ok "C13 PR 54 is in the carry" || bad "C13 carry"
[ "$(cursor)" = "$(maxid)" ] && ok "C13 the wake is complete (cursor = max)" || bad "C13 cursor $(cursor)"

echo "mc-wake-consumer.bh-6975: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
