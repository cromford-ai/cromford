#!/bin/bash
# tests/scheduler-enforce.bh-6979-test.sh — BH-6979 (BH-6547.3): with
# scheduler.mode=enforce the scheduler's ready set decides dispatch. Driven
# over real curl against the REAL jobs worker (tests/lib/scheduler-shadow.
# bh-6978.mjs, used as is) on node:sqlite with the composed schema. Settings
# rows go through the worker. GitHub is a gh_rest stub; bin/sibling-serial.sh,
# bin/overlap-schedule.sh and bin/free-slots.sh are recorder stubs.
#
#   G1-G8  sched_gate (bin/lib/sched-gate.sh): the gate table
#   D1-D2  pool_spawn_decision gate 0c (extracted from bin/fly-pool.sh):
#          enforce holds a not-ready ticket with no machine; shadow is today's
#   P1-P3  the pool: a wait leaves the row; an admit does not ask
#          sibling-serial; a fallback asks it as today
#   D3     the REAL bin/scheduler.sh in enforce posts every verdict, and
#          GET /api/scheduler/ready plus sched_gate read each one back
#   E1-E3  the lane reads sibling-serial for its data in enforce only, with a
#          check cap
#   E4-E5  a failed or timed-out `parts` or `check` is unknown, never yes
#   T1-T6  the run-build blocks (extracted from bin/lib/rb/gates.sh): the
#          scheduler gate and the stacked-child arm; STACK_BASE is dropped only
#          when sched_gate ADMITTED the key (rc 0), never on a fallback
#   O1-O3  the triage prompt: the scope section, the shard SOP, and the REAL
#          bin/overlap-schedule.sh --key (bin/lib/rt/shards.sh is not edited)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/scheduler-enforce.bh-6979-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/scheduler-shadow.bh-6978.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/prompts"
for L in bin/scheduler.sh bin/lib/scheduler.sh bin/lib/sched-gate.sh bin/jobs-client.sh bin/fleet-conf.sh bin/alert-line.sh; do
  [ -f "$REPO/$L" ] || { bad "setup: $L does not exist"; continue; }
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
# A pool machine exports BUILDER_EXEC=1; the run-build cases set it themselves.
unset BUILDER_EXEC RESUME_BUILD STACK_BASE STACKED_BUILDS SCHED_ADMITTED
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
echo 'proj  example-org/proj   -                 -           0 local -' > "$H/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> BH-<issue-number> > x' > "$H/prompts/proj.md"

# --- stubs -------------------------------------------------------------------
GH="$T/gh"; mkdir -p "$GH"
cat > "$H/bin/lib/gh-rest.sh" <<SH
# gh_rest stub (BH-6979 suite): one fixture file per path, 404 (rc 44) when absent.
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/gh.log"
  local f="$GH/\$(printf '%s' "\$2" | tr '/?&=:' '_____')"
  [ -r "\$f" ] || return 44
  cat "\$f"
}
SH
ghfix() { printf '%s\n' "$2" > "$GH/$(printf '%s' "$1" | tr '/?&=:' '_____')"; }
issues() {
  ghfix 'repos/example-org/proj/issues?state=open&labels=ai-build&per_page=100&page=1' \
    "$(printf '%s\n' "$@" | jq -s -c 'map({number: .})')"; }
printf '#!/bin/bash\necho "$*" >> "%s"\ncat "%s" 2>/dev/null\nexit 0\n' "$T/ov.log" "$T/overlap.txt" > "$H/bin/overlap-schedule.sh"
printf '#!/bin/bash\necho "unlimited (fixture)"\n' > "$H/bin/free-slots.sh"
cat > "$H/bin/sibling-serial.sh" <<SH
#!/bin/bash
# sibling-serial stub: parts prints \$T/parts.txt (exits \$T/parts.rc when it
# exists: 124 is what timeout(1) returns); check exits \$T/sibrc/<KEY> when it
# exists, else answers rc 3 with the line in \$T/sibwait/<KEY>, else rc 0.
echo "\$* stack=\${SIBLING_STACK:-}" >> "$T/sib.log"
case "\$1" in
  parts) cat "$T/parts.txt" 2>/dev/null; [ -r "$T/parts.rc" ] && exit "\$(cat "$T/parts.rc")"; exit 0 ;;
  check) [ -r "$T/sibrc/\$3" ] && exit "\$(cat "$T/sibrc/\$3")"
         [ -r "$T/sibwait/\$3" ] && { cat "$T/sibwait/\$3"; exit 3; }; exit 0 ;;
esac
exit 0
SH
chmod +x "$H/bin/"*.sh

# --- the worker ----------------------------------------------------------------
: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null' EXIT

sql() { curl -sS -X POST -d "$(jq -nc --arg s "$1" '{sql:$s}')" "$JOBS_URL/__sql" > /dev/null; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" > /dev/null; }
answer() { curl -sS -X PUT -d "$1" "$JOBS_URL/__answer" > /dev/null; }
job() { sql "INSERT INTO jobs (id,project,ticket_id,kind,box,stage,status,created_at,updated_at,meta) VALUES
       ('$1','proj','$2','build','fixture-box','execute','$3','2026-09-30T00:00:00Z','2026-09-30T00:00:00Z','${4:-{\}}')"; }
pr_row() { sql "INSERT INTO ledgers (kind,key,status,created_at,updated_at) VALUES ('pr_state','example-org/proj#$1','$2','2026-09-30T00:00:00Z','2026-09-30T00:00:00Z')"; }
edge() { sql "INSERT INTO ticket_edges (project,parent,child,kind,source,at) VALUES ('proj','$1','$2','$3','planner','2026-09-30T00:00:00Z')"; }
hold() { sql "INSERT INTO ticket_holds (project,ticket,state,by,at,comment_id) VALUES ('proj','$1','$2','$3','2026-09-30T08:00:00Z','$4')"; }
# post_tick <at> <mode> <candidates> <verdicts-json> — through the real POST route.
post_tick() {
  curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
    -d "$(jq -nc --arg at "$1" --arg m "$2" --argjson c "$3" --argjson v "$4" \
      '{project:"proj", at:$at, mode:$m, counts:{candidates:$c, ready:0, not_ready:0, unknown:0, in_flight:0, compared:0, agreed:0, idle:0}, diffs:[], verdicts:$v}')" \
    "$JOBS_URL/api/scheduler/diffs" > "$T/post.out"
  jq -e '.ok == true' "$T/post.out" >/dev/null 2>&1 || bad "setup: post_tick $1 $2: $(cat "$T/post.out")"
}
VSET='[{"ticket":"501","ready":"yes","reason":""},{"ticket":"502","ready":"no","reason":"parent #500 open"},
  {"ticket":"503","ready":"unknown","reason":"parent #9 unreadable"},{"ticket":"504","ready":"in-flight","reason":"in flight"}]'

NOW=$(date -u -d 2026-10-01T10:00:20Z +%s)   # determinism: ok a fixed instant, not the clock
AT0=2026-10-01T10:00:00Z
AT0_S=$(date -u -d "$AT0" +%s)
GNOW=$((AT0_S + 60))
reset() {
  curl -sS -X POST "$JOBS_URL/__reset" > /dev/null
  scratch_rm "$GH"; scratch_rm "$H/state/scheduler"; scratch_rm "$T/sibwait"; scratch_rm "$T/sibrc"; scratch_rm "$T/q"
  rm -f "$H/flags/"alerted-* "$H/state/settings-cache.json" "$T/parts.txt" "$T/parts.rc" "$T/overlap.txt"
  mkdir -p "$GH" "$T/sibwait" "$T/sibrc" "$T/q"
  : > "$H/logs/scheduler.log"; : > "$H/logs/ALERTS.log"; : > "$H/logs/proj.log"
  : > "$T/gh.log"; : > "$T/srv.log"; : > "$T/sib.log"; : > "$T/ov.log"; : > "$T/say.log"; : > "$T/qrow.log"
  setting scheduler.projects proj
}
# gate <KEY> [now] [project] -> "<rc> <line>"
gate() {
  local out rc
  out=$( cd "$T" && SCHED_NOW="${2:-$GNOW}" bash -c '. "$HARNESS/bin/lib/sched-gate.sh" || exit 9; sched_gate "$1" "$2"' _ "${3:-proj}" "$1" 2>/dev/null ); rc=$?
  printf '%s %s' "$rc" "$out"
}
alerts() { grep -c 'scheduler.mode=enforce but the ready set is' "$H/logs/ALERTS.log"; }

# ============================================================================
echo "G: sched_gate"
reset
post_tick "$AT0" enforce 4 "$VSET"
sql "DELETE FROM settings WHERE key='scheduler.mode'"
[ "$(gate BH-502)" = "2 SCHED_PASS BH-502 not enforced" ] && ok "G1 no scheduler.mode row -> pass (today's path)" || bad "G1: $(gate BH-502)"
setting scheduler.mode enforce
[ "$(gate BH-501)" = "0 SCHED_READY BH-501 (tick $AT0)" ] && ok "G2 enforce + yes -> rc 0" || bad "G2: $(gate BH-501)"
[ "$(gate BH-502)" = "3 SCHED_WAIT BH-502 reason=parent #500 open (tick $AT0)" ] && ok "G3 no -> rc 3 with the reason" || bad "G3: $(gate BH-502)"
[ "$(gate BH-503)" = "3 SCHED_WAIT BH-503 reason=parent #9 unreadable (tick $AT0)" ] && ok "G4 unknown -> rc 3" || bad "G4: $(gate BH-503)"
[ "$(gate BH-504)" = "2 SCHED_PASS BH-504 verdict in-flight (tick $AT0)" ] && ok "G5 in-flight -> rc 2" || bad "G5: $(gate BH-504)"
[ "$(gate BH-505)" = "3 SCHED_WAIT BH-505 reason=not in ready set (tick $AT0)" ] && ok "G5b absent from a fresh complete set -> rc 3 not in ready set" || bad "G5b: $(gate BH-505)"
answer '{"method":"GET","path":"/api/scheduler/ready","status":503,"body":"{\"error\":\"fixture outage\"}"}'
G6=$(gate BH-502)
[ "$G6" = "2 SCHED_PASS BH-502 ready set unreadable" ] && [ "$(alerts)" = 1 ] && ok "G6 route 503 -> rc 2 and one ALERTS line" || bad "G6: $G6 alerts=$(alerts) $(cat "$H/logs/ALERTS.log")"
gate BH-501 > /dev/null; answer '{}'
[ "$(alerts)" = 1 ] && ok "G6 a second fallback the same day writes no second line" || bad "G6 second: alerts=$(alerts)"
rm -f "$H/flags/"alerted-*
[ "$(gate BH-501 $((AT0_S + 899)))" = "0 SCHED_READY BH-501 (tick $AT0)" ] && ok "G7 a set 899 s old admits" || bad "G7 899: $(gate BH-501 $((AT0_S + 899)))"
[ "$(gate BH-501 $((AT0_S + 901)))" = "2 SCHED_PASS BH-501 ready set stale" ] && ok "G7 a set 901 s old passes as stale" || bad "G7 901: $(gate BH-501 $((AT0_S + 901)))"
post_tick 2026-10-01T10:05:00Z enforce 4 '[{"ticket":"501","ready":"yes","reason":""}]'
[ "$(gate BH-502 $((AT0_S + 360)))" = "2 SCHED_PASS BH-502 ready set incomplete" ] && ok "G8 complete:false -> pass" || bad "G8 incomplete: $(gate BH-502 $((AT0_S + 360)))"
post_tick 2026-10-01T10:10:00Z shadow 4 "$VSET"
[ "$(gate BH-502 $((AT0_S + 660)))" = "2 SCHED_PASS BH-502 ready set shadow-tick" ] && ok "G8 a tick posted in shadow -> pass" || bad "G8 shadow tick: $(gate BH-502 $((AT0_S + 660)))"
post_tick 2026-10-01T10:15:00Z enforce 4 "$VSET"
[ "$(gate RB-7 $((AT0_S + 960)))" = "2 SCHED_PASS RB-7 key not BH-<n>" ] && ok "G8 RB-7 -> pass" || bad "G8 RB-7: $(gate RB-7 $((AT0_S + 960)))"
[ "$(gate BH-502 $((AT0_S + 960)) other)" = "2 SCHED_PASS BH-502 not enforced" ] && ok "G8 a project not in scheduler.projects -> pass" || bad "G8 project: $(gate BH-502 $((AT0_S + 960)) other)"
setting scheduler.mode Enforce
[ "$(gate BH-502 $((AT0_S + 960)))" = "2 SCHED_PASS BH-502 not enforced" ] && ok "G8 mode Enforce (not the word) -> pass" || bad "G8 Enforce: $(gate BH-502 $((AT0_S + 960)))"
setting scheduler.mode shadow
[ "$(gate BH-502 $((AT0_S + 960)))" = "2 SCHED_PASS BH-502 not enforced" ] && ok "G8 rollback: the row back to shadow -> pass" || bad "G8 shadow: $(gate BH-502 $((AT0_S + 960)))"

# ============================================================================
echo "D/P: pool_spawn_decision gate 0c"
awk '/^pool_spawn_decision\(\) \{/{f=1} f; f && /^}/{exit}' "$REPO/bin/fly-pool.sh" > "$T/psd.sh"
grep -q 'sched_gate' "$T/psd.sh" || bad "D setup: pool_spawn_decision does not call sched_gate"
grep -qE '^\. "\$HARNESS/bin/lib/sched-gate.sh"' "$REPO/bin/fly-pool.sh" || bad "D setup: bin/fly-pool.sh does not source bin/lib/sched-gate.sh"
# pool <KEY> -> rc of pool_spawn_decision; its say lines go to $T/say.log
pool() {
  echo '{}' > "$T/q/$1.json"
  ( cd "$T" && export SCHED_NOW="$GNOW"
    . "$H/bin/jobs-client.sh"; . "$H/bin/lib/sched-gate.sh"
    # shellcheck disable=SC2034 # read by the extracted function
    P=proj; QDIR="$T/q"; LOG="$T/pool.err"; _POOL_GATES_SAID=1
    say() { echo "$*" >> "$T/say.log"; }
    QROW() { echo "QROW $*" >> "$T/qrow.log"; }
    pool_sibling_stack() { echo "STACK $*" >> "$T/qrow.log"; }
    pool_gates_applicable() { return 1; }   # the gates after 0c are not under test
    # shellcheck disable=SC1091
    . "$T/psd.sh"
    pool_spawn_decision "$T/q/$1.json" "$1" "${1#BH-}" ) >/dev/null 2>&1
}
checks() { grep -c '^check ' "$T/sib.log"; }
reset; setting scheduler.mode enforce; post_tick "$AT0" enforce 4 "$VSET"
pool BH-502; R=$?
[ "$R" = 1 ] && grep -q "SCHED_WAIT BH-502 reason=parent #500 open (tick $AT0) — no machine spawned" "$T/say.log" \
  && ok "D1 enforce: BH-502 (parent #500 open) is not dispatched" || bad "D1 502 rc=$R say=$(cat "$T/say.log")"
[ -e "$T/q/BH-502.json" ] && [ ! -s "$T/qrow.log" ] && ok "P1 the wait leaves the queue file; no QROW write, no stack requeue" || bad "P1 qrow=$(cat "$T/qrow.log")"
: > "$T/sib.log"
pool BH-501; R=$?
[ "$R" = 0 ] && grep -q "SCHED_READY BH-501 (tick $AT0) — sibling-serial not consulted" "$T/say.log" \
  && ok "D1 enforce: BH-501 (ready) passes gate 0c" || bad "D1 501 rc=$R say=$(cat "$T/say.log")"
[ "$(checks)" = 0 ] && ok "P2 an admit does not call sibling-serial" || bad "P2 sib=$(cat "$T/sib.log")"
pool BH-503; R=$?
[ "$R" = 1 ] && grep -q 'SCHED_WAIT BH-503 reason=parent #9 unreadable' "$T/say.log" && ok "D1 enforce: unknown waits" || bad "D1 503 rc=$R"
pool BH-509; R=$?
[ "$R" = 1 ] && grep -q 'SCHED_WAIT BH-509 reason=not in ready set' "$T/say.log" && ok "D1 enforce: a key absent from the set waits" || bad "D1 509 rc=$R"
: > "$T/sib.log"; echo 'SIBLING_SERIAL BH-501 waits for BH-499 on a.sh' > "$T/sibwait/BH-501"
pool BH-501; R=$?
[ "$R" = 0 ] && [ "$(checks)" = 0 ] && ok "D1 enforce: a sibling-serial wait no longer holds a ready ticket" || bad "D1 sib rc=$R sib=$(cat "$T/sib.log")"
rm -f "$T/sibwait/BH-501"
answer '{"method":"GET","path":"/api/scheduler/ready","status":503,"body":"{}"}'
: > "$T/sib.log"
pool BH-502; R=$?; answer '{}'
[ "$R" = 0 ] && [ "$(checks)" = 1 ] && ok "P3 a fallback (route 503) asks sibling-serial as today" || bad "P3 rc=$R sib=$(cat "$T/sib.log")"
setting scheduler.mode shadow; : > "$T/sib.log"; : > "$T/say.log"
pool BH-501; R1=$?; pool BH-502; R2=$?
[ "$R1" = 0 ] && [ "$R2" = 0 ] && [ "$(checks)" = 2 ] && ! grep -q SCHED_ "$T/say.log" \
  && ok "D2 shadow: today's path, sibling-serial asked for both keys, BH-502 not held" || bad "D2 r=$R1/$R2 sib=$(cat "$T/sib.log") say=$(cat "$T/say.log")"

# ============================================================================
echo "D3/E: the lane in enforce"
run() { ( cd "$T" && SCHED_NOW="${1:-$NOW}" bash "$H/bin/scheduler.sh" proj ) > "$T/run.out" 2>&1; RC=$?; }
sched() { grep "SCHED ticket=BH-$1 " "$H/logs/scheduler.log" | tail -1 | sed 's/^[^ ]* //'; }
tickline() { grep 'SCHED-TICK' "$H/logs/scheduler.log" | tail -1; }
reset; setting scheduler.mode enforce; setting scheduler.parent_reads_max 0
issues 801 802 803 804 805
edge 790 802 hard; edge 791 804 hard
job job-790 BH-790 done '{"result":"PR_CREATED https://github.com/example-org/proj/pull/900 | built"}'
pr_row 900 OPEN
hold 803 hold operator 7001
job job-805 BH-805 running
run
[ "$RC" = 0 ] && grep -q "SCHED-TICK project=proj mode=enforce at=$AT0 candidates=5 .* post=ok " <<<"$(tickline)" \
  && ok "D3 the lane runs in enforce and posts" || bad "D3 rc=$RC tick=$(tickline) out=$(cat "$T/run.out")"
RD=$(curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/scheduler/ready?project=proj")
[ "$(jq -c '[.complete, .mode, .candidates]' <<<"$RD")" = '[true,"enforce",5]' ] \
  && [ "$(jq -r '.verdicts[] | "\(.ticket)|\(.ready)|\(.reason)"' <<<"$RD" | paste -sd' ' -)" = "801|yes| 802|no|parent #790 open 803|no|hold by operator 804|unknown|parent #791 unreadable 805|in-flight|in flight" ] \
  && ok "D3 GET /api/scheduler/ready: complete, one verdict per candidate with its reason" || bad "D3 ready: $RD"
G801=$(gate BH-801 "$NOW"); G802=$(gate BH-802 "$NOW"); G803=$(gate BH-803 "$NOW"); G804=$(gate BH-804 "$NOW"); G805=$(gate BH-805 "$NOW")
[ "${G801%% *}|${G802%% *}|${G803%% *}|${G804%% *}|${G805%% *}" = "0|3|3|3|2" ] && [[ $G803 == *"reason=hold by operator"* ]] \
  && ok "D3 sched_gate reads every posted verdict back (yes, no, no, unknown, in-flight)" || bad "D3 gate: $G801 / $G802 / $G803 / $G804 / $G805"
grep -q '^parts proj' "$T/sib.log" && ok "D3 enforce reads the sibling-serial parts map" || bad "D3 sib: $(cat "$T/sib.log")"

reset; setting scheduler.mode enforce
issues 600 601
printf 'BH-600\tBH-599\t0\nBH-601\tBH-599\t1\n' > "$T/parts.txt"
echo 'SIBLING_SERIAL BH-601 waits for BH-600 on a.sh' > "$T/sibwait/BH-601"
run
[ "$(sched 601)" = "SCHED ticket=BH-601 ready=no reason=files claimed by #600" ] && [ "$(sched 600)" = "SCHED ticket=BH-600 ready=yes reason=" ] \
  && ok "E1 a sibling-serial wait is the verdict no / files claimed by #600" || bad "E1: $(sched 600) / $(sched 601) sib=$(cat "$T/sib.log")"
[ "$(grep -c '^check proj BH-60[01] stack=0$' "$T/sib.log")" = 2 ] && ok "E1 one check per part, SIBLING_STACK=0" || bad "E1 checks: $(cat "$T/sib.log")"
reset; setting scheduler.mode shadow
issues 600 601
printf 'BH-600\tBH-599\t0\nBH-601\tBH-599\t1\n' > "$T/parts.txt"
echo 'SIBLING_SERIAL BH-601 waits for BH-600 on a.sh' > "$T/sibwait/BH-601"
run
[ ! -s "$T/sib.log" ] && [ "$(sched 601)" = "SCHED ticket=BH-601 ready=yes reason=" ] && grep -q 'SCHED-TICK project=proj mode=shadow ' <<<"$(tickline)" \
  && ok "E2 shadow: sibling-serial is never called; the wave-2 verdict" || bad "E2: $(sched 601) sib=$(cat "$T/sib.log")"
reset; setting scheduler.mode enforce
issues $(seq 701 721)
for i in $(seq 701 721); do printf 'BH-%s\tBH-700\t%s\n' "$i" "$((i - 700))"; done > "$T/parts.txt"
run
[ "$(grep -c '^check ' "$T/sib.log")" = 20 ] && [ "$(sched 721)" = "SCHED ticket=BH-721 ready=unknown reason=sibling check cap" ] \
  && [ "$(sched 720)" = "SCHED ticket=BH-720 ready=yes reason=" ] \
  && ok "E3 21 parts: 20 checks, the 21st is unknown / sibling check cap" || bad "E3: checks=$(grep -c '^check ' "$T/sib.log") $(sched 721)"
# E4: `parts` failed or timed out -> no part map, so every candidate not in
# flight is unknown / sibling check failed (it used to read "not a part": yes).
for prc in 1 124; do
  reset; setting scheduler.mode enforce
  issues 600 601
  printf 'BH-600\tBH-599\t0\nBH-601\tBH-599\t1\n' > "$T/parts.txt"
  echo "$prc" > "$T/parts.rc"
  run
  [ "$(sched 600)" = "SCHED ticket=BH-600 ready=unknown reason=sibling check failed" ] \
    && [ "$(sched 601)" = "SCHED ticket=BH-601 ready=unknown reason=sibling check failed" ] \
    && [ "$(grep -c '^check ' "$T/sib.log")" = 0 ] \
    && ok "E4 parts rc $prc: every candidate is unknown / sibling check failed, never yes" || bad "E4 rc $prc: $(sched 600) / $(sched 601) sib=$(cat "$T/sib.log")"
done
# E5: a `check` that timed out (124) or failed (1), or rc 3 with no parseable
# line, is unknown / sibling check failed; rc 0 is still yes.
reset; setting scheduler.mode enforce
issues 600 601 602 603
printf 'BH-600\tBH-599\t0\nBH-601\tBH-599\t1\nBH-602\tBH-599\t2\nBH-603\tBH-599\t3\n' > "$T/parts.txt"
echo 124 > "$T/sibrc/BH-601"; echo 1 > "$T/sibrc/BH-602"; echo 'garbled' > "$T/sibwait/BH-603"
run
[ "$(sched 600)" = "SCHED ticket=BH-600 ready=yes reason=" ] \
  && [ "$(sched 601)" = "SCHED ticket=BH-601 ready=unknown reason=sibling check failed" ] \
  && [ "$(sched 602)" = "SCHED ticket=BH-602 ready=unknown reason=sibling check failed" ] \
  && [ "$(sched 603)" = "SCHED ticket=BH-603 ready=unknown reason=sibling check failed" ] \
  && ok "E5 check timeout / error / unparseable wait: unknown, never yes; rc 0 stays yes" || bad "E5: $(sched 600) / $(sched 601) / $(sched 602) / $(sched 603)"

# ============================================================================
echo "T: the run-build blocks"
GATES="$REPO/bin/lib/rb/gates.sh"
awk 'index($0,"# >>> scheduler enforce gate (BH-6979)")==1{f=1} f; index($0,"# <<< scheduler enforce gate")==1{exit}' "$GATES" > "$T/sg.sh"
awk 'index($0,"# >>> stacked child builds")==1{f=1} f; index($0,"# <<< stacked child builds")==1{exit}' "$GATES" > "$T/stack.sh"
grep -q sched_gate "$T/sg.sh" || bad "T setup: no '# >>> scheduler enforce gate (BH-6979)' block calling sched_gate"
ln_of() { grep -n -m1 -F "$1" "$GATES" | cut -d: -f1; }
L_DM=$(ln_of '# <<< dispatch mode gate'); L_SG=$(ln_of '# >>> scheduler enforce gate (BH-6979)'); L_BL=$(ln_of '# >>> budget launch gate')
[ -n "$L_SG" ] && [ "$L_DM" -lt "$L_SG" ] && [ "$L_SG" -lt "$L_BL" ] \
  && ok "T0 the scheduler gate runs after the dispatch-mode gate, before the budget gate and the Fly enqueue" || bad "T0 lines dm=$L_DM sg=$L_SG bl=$L_BL"
# rb <KEY> -> rc of the extracted block; RESULT and pipeline.log in $T/b
rb() {
  scratch_rm "$T/b"; mkdir -p "$T/b"
  ( cd "$T" && export SCHED_NOW="$GNOW"
    # shellcheck disable=SC2034
    PROJECT=proj; KEY=$1; BUILD="$T/b"
    STAMP() { echo TS; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    # shellcheck disable=SC1091
    . "$T/sg.sh"
    echo through > "$BUILD/through" ) >/dev/null 2>"$T/rb.err"
}
reset; setting scheduler.mode enforce; post_tick "$AT0" enforce 4 "$VSET"
rb BH-502; R=$?
[ "$R" = 3 ] && [ "$(cat "$T/b/RESULT")" = "BUILD_DEFERRED scheduler: BH-502 waits — parent #500 open (tick $AT0)" ] && [ ! -e "$T/b/through" ] \
  && grep -q 'scheduler: BH-502 waits' "$H/logs/proj.log" && ok "T1 enforce + no -> BUILD_DEFERRED, exit 3, before the enqueue" || bad "T1 rc=$R result=$(cat "$T/b/RESULT" 2>/dev/null) err=$(head -c 600 "$T/rb.err")"
rb BH-501; R=$?
[ "$R" = 0 ] && [ -e "$T/b/through" ] && grep -q "scheduler: BH-501 admitted from the ready set (tick $AT0)" "$T/b/pipeline.log" \
  && ok "T1 enforce + yes -> admitted, one log line" || bad "T1 501 rc=$R log=$(cat "$T/b/pipeline.log" 2>/dev/null)"
: > "$T/srv.log"
BUILDER_EXEC=1 rb BH-502; R=$?
[ "$R" = 0 ] && [ -e "$T/b/through" ] && ! grep -q 'scheduler' "$T/srv.log" && ok "T2 a pool machine (BUILDER_EXEC=1) is not asked" || bad "T2 rc=$R srv=$(cat "$T/srv.log")"
RESUME_BUILD=1 rb BH-502; R=$?
[ "$R" = 0 ] && [ -e "$T/b/through" ] && ! grep -q 'scheduler' "$T/srv.log" && ok "T3 a resume is not asked" || bad "T3 rc=$R srv=$(cat "$T/srv.log")"
setting scheduler.mode shadow
rb BH-502; R=$?
[ "$R" = 0 ] && [ -e "$T/b/through" ] && [ ! -s "$T/b/pipeline.log" ] && ok "T5 shadow: the gate block passes with no line" || bad "T5 gate rc=$R log=$(cat "$T/b/pipeline.log" 2>/dev/null)"
# stk [KEY] -> "STACK_ON=<v> BASE=<v>"; sw_parent_pr and git calls in $T/sw.log.
# The block runs alone, as on a pool machine or a resume: the gate block did
# not run in this shell, so the stack block asks sched_gate itself.
stk() {
  scratch_rm "$T/b"; mkdir -p "$T/b"; : > "$T/sw.log"
  ( cd "$T" && export SCHED_NOW="$GNOW"
    # shellcheck disable=SC2034
    PROJECT=proj; KEY=${1:-BH-501}; BUILD="$T/b"; BASE=main; REPO="$T/norepo"; STACK_BASE=ticket/bh-500
    STAMP() { echo TS; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    sw_parent_pr() { echo "sw $*" >> "$T/sw.log"; echo "merged 5 https://github.com/example-org/proj/pull/5"; }
    git() { echo "git $*" >> "$T/sw.log"; return 1; }
    # shellcheck disable=SC1091
    . "$T/stack.sh"
    echo "STACK_ON=$STACK_ON BASE=$BASE" ) 2>/dev/null
}
setting scheduler.mode enforce
S4=$(stk BH-501)
[ "$S4" = "STACK_ON= BASE=main" ] && grep -q 'STACK_BASE=ticket/bh-500 ignored — scheduler.mode=enforce owns build order; building on main' "$T/b/pipeline.log" \
  && ! grep -q 'stack-wait:' "$T/b/pipeline.log" && [ ! -s "$T/sw.log" ] \
  && ok "T4 enforce + STACK_BASE + admitted (yes): ignored, no stack-wait read or deferral" || bad "T4 $S4 log=$(cat "$T/b/pipeline.log") sw=$(cat "$T/sw.log")"
# T6: enforce, but sched_gate did NOT admit the key (rc 2: the verdict is
# in-flight; rc 3: no) -> STACK_BASE is kept and today's arm runs.
for k in BH-504 BH-502; do
  stk "$k" > /dev/null
  grep -q '^sw ' "$T/sw.log" && grep -q 'stack-wait: parent PR #5 is merged' "$T/b/pipeline.log" \
    && ! grep -q 'scheduler.mode=enforce owns build order' "$T/b/pipeline.log" \
    && ok "T6 enforce + STACK_BASE + $k not admitted: today's arm (sw_parent_pr asked)" || bad "T6 $k log=$(cat "$T/b/pipeline.log") sw=$(cat "$T/sw.log")"
done
# T6b: the gate block and the stack block in ONE shell, as bin/run-build.sh
# runs them: an admit is remembered (one sched_gate read), a fallback is not.
both() {
  scratch_rm "$T/b"; mkdir -p "$T/b"; : > "$T/sw.log"; : > "$T/srv.log"
  ( cd "$T" && export SCHED_NOW="$GNOW"
    # shellcheck disable=SC2034
    PROJECT=proj; KEY=$1; BUILD="$T/b"; BASE=main; REPO="$T/norepo"; STACK_BASE=ticket/bh-500
    STAMP() { echo TS; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    sw_parent_pr() { echo "sw $*" >> "$T/sw.log"; echo "merged 5 https://github.com/example-org/proj/pull/5"; }
    git() { echo "git $*" >> "$T/sw.log"; return 1; }
    # shellcheck disable=SC1091
    . "$T/sg.sh"
    # shellcheck disable=SC1091
    . "$T/stack.sh"
    echo "STACK_ON=$STACK_ON BASE=$BASE" ) 2>/dev/null
}
S6=$(both BH-501)
[ "$S6" = "STACK_ON= BASE=main" ] && grep -q 'scheduler.mode=enforce owns build order' "$T/b/pipeline.log" && [ ! -s "$T/sw.log" ] \
  && ok "T6b gate admitted BH-501 then the stack block drops STACK_BASE" || bad "T6b 501 $S6 log=$(cat "$T/b/pipeline.log")"
both BH-504 > /dev/null
grep -q '^sw ' "$T/sw.log" && ! grep -q 'scheduler.mode=enforce owns build order' "$T/b/pipeline.log" \
  && ok "T6b gate fell back (in-flight) then the stack block keeps STACK_BASE" || bad "T6b 504 log=$(cat "$T/b/pipeline.log") sw=$(cat "$T/sw.log")"
setting scheduler.mode shadow
S5=$(stk)
grep -q '^sw ' "$T/sw.log" && grep -q 'stack-wait: parent PR #5 is merged' "$T/b/pipeline.log" \
  && ok "T5 shadow + STACK_BASE: today's arm (sw_parent_pr asked)" || bad "T5 $S5 log=$(cat "$T/b/pipeline.log") sw=$(cat "$T/sw.log")"

# ============================================================================
echo "O: the triage prompt"
awk 'index($0,"# >>> overlap schedule feed")==1{f=1} f; index($0,"# <<< overlap schedule feed")==1{exit}' "$REPO/bin/lib/rt/scope.sh" > "$T/scope.sh"
# sc [sop] -> OVERLAP_SEC, or with `sop` the SHARD_SOP the driver hands rt_shards.
sc() {
  ( cd "$T" && export SCHED_NOW="$GNOW"
    # shellcheck disable=SC2034
    PROJECT=proj; STAMP=TS; LOG="$T/triage.log"; SHARD_SOP="SOP-TEXT"
    . "$H/bin/jobs-client.sh"
    # shellcheck disable=SC1091
    . "$T/scope.sh"
    if [ "${1:-}" = sop ]; then printf '%s' "$SHARD_SOP"; else printf '%s' "$OVERLAP_SEC"; fi ) 2>/dev/null
}
# The REAL bin/overlap-schedule.sh with a recorder preplan-lib: its
# overlap_schedule logs "asked" to $T/osk.log and answers 0 (off), so a call that
# gets past the enforce check leaves one line and prints nothing.
OSD="$T/osh"
( cd "$REPO" && scratch_install_closure bin/overlap-schedule.sh "$OSD" ) >/dev/null 2>&1 || bad "setup: could not install bin/overlap-schedule.sh"
[ -r "$OSD/bin/lib/sched-gate.sh" ] || bad "setup: the overlap-schedule.sh closure has no bin/lib/sched-gate.sh"
printf 'overlap_schedule() { echo asked >> "%s"; echo 0; }\n' "$T/osk.log" > "$OSD/bin/lib/preplan-lib.sh"
oskey() { ( export SCHED_NOW="$GNOW"; bash "$OSD/bin/overlap-schedule.sh" proj --key "$1"; echo "rc=$?" ) 2>/dev/null; }
reset; setting scheduler.mode enforce; post_tick "$AT0" enforce 4 "$VSET"
printf 'WAVE 1: BH-501\nHELD: BH-502 overlaps in-flight BH-9 on a.sh\n' > "$T/overlap.txt"
O1=$(sc)
[[ $O1 == "SCHEDULER READY SET (enforce, tick $AT0)"* ]] && [[ $O1 == *"READY: BH-501"* ]] && [[ $O1 == *"BH-502 — parent #500 open"* ]] \
  && [[ $O1 == *"BH-503 — parent #9 unreadable"* ]] && [[ $O1 != *"OVERLAP SCHEDULE"* ]] && [[ $O1 != *"BH-504"* ]] && [ ! -s "$T/ov.log" ] \
  && ok "O1 enforce: the scope carries SCHEDULER READY SET, not OVERLAP SCHEDULE; overlap-schedule not called" || bad "O1: $O1 ov=$(cat "$T/ov.log")"
O1S=$(sc sop)
[[ $O1S == "SOP-TEXT"$'\n\n'"SCHEDULER READY SET (enforce, tick $AT0)"* ]] && [[ $O1S == *"BH-502 — parent #500 open"* ]] \
  && [[ $O1S == *"A triage shard owns one ticket"* ]] && [[ $O1S != *"OVERLAP SCHEDULE"* ]] \
  && ok "O1 enforce: the shard SOP carries the ready set after the SOP" || bad "O1 sop: $O1S"
: > "$T/osk.log"; O2=$(oskey BH-502)
[ "$O2" = "rc=0" ] && [ ! -s "$T/osk.log" ] \
  && ok "O2 enforce: the real overlap-schedule.sh --key answers nothing and asks nothing" || bad "O2: [$O2] osk=$(cat "$T/osk.log")"
setting scheduler.mode shadow; : > "$T/ov.log"
O3=$(sc)
[[ $O3 == "OVERLAP SCHEDULE (deterministic"* ]] && [[ $O3 == *"WAVE 1: BH-501"* ]] && [ "$(wc -l < "$T/ov.log")" = 1 ] \
  && ok "O3 shadow: today's OVERLAP SCHEDULE section from overlap-schedule" || bad "O3: $O3 ov=$(cat "$T/ov.log")"
[ "$(sc sop)" = "SOP-TEXT" ] && ok "O3 shadow: the shard SOP is unchanged" || bad "O3 sop: $(sc sop)"
: > "$T/osk.log"; O3K=$(oskey BH-502)
[ "$O3K" = "rc=0" ] && [ "$(cat "$T/osk.log")" = asked ] \
  && ok "O3 shadow: the real overlap-schedule.sh --key goes on to today's verdict" || bad "O3 key: [$O3K] osk=$(cat "$T/osk.log")"

echo
echo "scheduler-enforce (BH-6979): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
