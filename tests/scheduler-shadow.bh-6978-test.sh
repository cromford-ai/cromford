#!/bin/bash
# tests/scheduler-shadow.bh-6978-test.sh — BH-6978 (BH-6547.2): the scheduler
# computes the ready set in shadow. The REAL lane bin/scheduler.sh and its lib
# bin/lib/scheduler.sh, driven over real curl against the REAL jobs worker
# (tests/lib/scheduler-shadow.bh-6978.mjs) on node:sqlite with the composed
# schema. GitHub is a gh_rest stub that serves fixture JSON and logs each path;
# bin/overlap-schedule.sh and bin/free-slots.sh are stubs that print fixture
# text; the dispatch entry points (run-build, fly-dispatch, ready-queue) are
# recorder stubs.
#
#   D1-D9  sched_decide decision table on fixture dirs
#   L1-L5  sched_lanes_did: what each lane did in the window
#   C1-C7  sched_compare, one case per row of the compare table
#   S1     6 candidates: one reason per non-ready ticket, in flight not judged
#   S2     a parent whose branch exists but whose PR merged -> the child is
#          ready, and no branch or ref path is read (the #6537 case)
#   S3     a hold row -> not ready; a newer resume row -> ready
#   S4     shadow (and enforce) dispatch nothing
#   S5     a disagreement writes one sched_diffs row; the same tick again
#          writes nothing new
#   X1-X6  exit paths: the switch, mode off, an unreadable input, a lane input
#          503, the POST 503, the parent read cap
#   R1-R3  the daily-digest block and dd_render: the agreement line; a 404
#          leaves it out with one note; a read failure renders n/a
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/scheduler-shadow.bh-6978-test.sh
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
for L in bin/scheduler.sh bin/lib/scheduler.sh bin/jobs-client.sh bin/fleet-conf.sh bin/lib/daily-digest-render.sh; do
  [ -f "$REPO/$L" ] || { bad "setup: $L does not exist"; continue; }
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
echo 'proj  example-org/proj   -                 -           0 local -' > "$H/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> BH-<issue-number> > x' > "$H/prompts/proj.md"

# --- stubs -------------------------------------------------------------------
GH="$T/gh"; mkdir -p "$GH"
cat > "$H/bin/lib/gh-rest.sh" <<SH
# gh_rest stub (BH-6978 suite): one fixture file per path, 404 (rc 44) when absent.
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/gh.log"
  local f="$GH/\$(printf '%s' "\$2" | tr '/?&=:' '_____')"
  [ -r "\$f" ] || return 44
  cat "\$f"
}
SH
ghfix() { printf '%s\n' "$2" > "$GH/$(printf '%s' "$1" | tr '/?&=:' '_____')"; }
issues() { # issues <n>... -> the open ai-build listing, plus one PR entry that must be dropped
  ghfix 'repos/example-org/proj/issues?state=open&labels=ai-build&per_page=100&page=1' \
    "$(printf '%s\n' "$@" | jq -s -c 'map({number: .}) + [{number: 999, pull_request: {url: "x"}}]')"; }
printf '#!/bin/bash\ncat "%s" 2>/dev/null\nexit 0\n' "$T/overlap.txt" > "$H/bin/overlap-schedule.sh"
printf '#!/bin/bash\ncat "%s" 2>/dev/null || echo "unlimited (fixture)"\n' "$T/cap.txt" > "$H/bin/free-slots.sh"
for s in run-build.sh fly-dispatch.sh ready-queue.sh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$s" "$T/dispatch.log" > "$H/bin/$s"
done
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

rows() { curl -sS "$JOBS_URL/__rows?table=$1"; }
sql() { curl -sS -X POST -d "$(jq -nc --arg s "$1" '{sql:$s}')" "$JOBS_URL/__sql" > /dev/null; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" > /dev/null; }
answer() { curl -sS -X PUT -d "$1" "$JOBS_URL/__answer" > /dev/null; }
job() { # job <id> <ticket> <status> [meta] [created_at]
  sql "INSERT INTO jobs (id,project,ticket_id,kind,box,stage,status,created_at,updated_at,meta) VALUES
       ('$1','proj','$2','build','fixture-box','execute','$3','${5:-2026-10-15T00:00:00Z}','2026-10-15T00:00:00Z','${4:-{\}}')"; }
pr_row() { sql "INSERT INTO ledgers (kind,key,status,created_at,updated_at) VALUES ('pr_state','example-org/proj#$1','$2','2026-10-15T00:00:00Z','2026-10-15T00:00:00Z')"; }
edge() { sql "INSERT INTO ticket_edges (project,parent,child,kind,source,at) VALUES ('proj','$1','$2','$3','planner','2026-10-15T00:00:00Z')"; }
hold() { sql "INSERT INTO ticket_holds (project,ticket,state,by,at,comment_id) VALUES ('proj','$1','$2','$3','$4','$5')"; }
decision() { sql "INSERT INTO decisions (stamp,project,gate,scope,ticket,line,created_at) VALUES ('$1','proj','g','s','$2','[proj] gate=g scope=s $2 :: $3','$1')"; }

NOW=$(date -u -d 2026-10-01T10:00:20Z +%s)   # determinism: ok a fixed instant, not the clock
AT=2026-10-01T10:00:00Z
reset() {
  curl -sS -X POST "$JOBS_URL/__reset" > /dev/null
  scratch_rm "$GH"; scratch_rm "$H/state/scheduler"; rm -f "$H/flags/lane-off-scheduler" "$H/state/settings-cache.json"
  mkdir -p "$GH"
  : > "$H/logs/scheduler.log"; : > "$T/gh.log"; : > "$T/dispatch.log"; : > "$T/srv.log"
  rm -f "$T/overlap.txt" "$T/cap.txt" "$H/logs/fly-pool.log"
  : > "$H/logs/fly-pool.log"
}
run() { ( cd "$T" && SCHED_NOW="${1:-$NOW}" bash "$H/bin/scheduler.sh" "${2:-proj}" ) > "$T/run.out" 2>&1; RC=$?; }
sched() { grep "SCHED ticket=BH-$1 " "$H/logs/scheduler.log" | tail -1 | sed 's/^[^ ]* //'; }
tickline() { grep 'SCHED-TICK' "$H/logs/scheduler.log" | tail -1; }
posts() { grep -c '^POST /api/scheduler/diffs ' "$T/srv.log"; }

LIB=". '$H/bin/lib/scheduler.sh'"

# ============================================================================
echo "D: sched_decide"
dd() { # dd <name> -> a fresh inputs dir for the decision table
  local d="$T/dd/$1"; scratch_rm "$d"; mkdir -p "$d/planned" "$d/claims"
  : > "$d/in_flight"; echo '{"edges":[]}' > "$d/edges.json"; echo '{"holds":[]}' > "$d/holds.json"
  : > "$d/parents"; echo unlimited > "$d/cap"; printf '%s\n' "$d"; }
decide() { ( eval "$LIB"; sched_decide "$1" ) | tr '\t' '|' | paste -sd' ' -; }
d=$(dd d1); printf '10\n11\n' > "$d/candidates"
echo '{"edges":[{"parent":"5","child":"10","kind":"soft"},{"parent":"6","child":"11","kind":"hard"}]}' > "$d/edges.json"
printf '5\topen\n6\tmerged\n' > "$d/parents"
[ "$(decide "$d")" = "10|yes| 11|yes|" ] && ok "D1 a soft edge to an open parent is ignored; a merged parent clears" || bad "D1: $(decide "$d")"
d=$(dd d2); echo 20 > "$d/candidates"
echo '{"holds":[{"ticket":"20","state":"resume","by":"a","at":"2026-10-16T09:00:00Z"}]}' > "$d/holds.json"
[ "$(decide "$d")" = "20|yes|" ] && ok "D2 the latest row resume -> ready" || bad "D2: $(decide "$d")"
d=$(dd d3); printf '30\n31\n' > "$d/candidates"; echo 'bin/a.sh' > "$d/claims/BH-40"
printf 'SOURCE: plan\nbin/a.sh\n' > "$d/planned/31"
[ "$(decide "$d")" = "30|yes| 31|no|files claimed by #40" ] && ok "D3 no planned list is never claimed; a shared path is" || bad "D3: $(decide "$d")"
d=$(dd d4); printf '41\n42\n' > "$d/candidates"; echo 0 > "$d/cap"
[ "$(decide "$d")" = "41|no|wip cap 42|no|wip cap" ] && ok "D4 cap 0 -> every ready ticket is wip cap" || bad "D4: $(decide "$d")"
d=$(dd d5); printf '53\n51\n52\n' > "$d/candidates"; echo 2 > "$d/cap"
[ "$(decide "$d")" = "51|yes| 52|yes| 53|no|wip cap" ] && ok "D5 cap 2 with 3 ready -> the highest number is wip cap" || bad "D5: $(decide "$d")"
d=$(dd d6); printf '61\n62\n63\n' > "$d/candidates"
[ "$(decide "$d")" = "61|yes| 62|yes| 63|yes|" ] && ok "D6 cap unlimited -> no wip cap" || bad "D6: $(decide "$d")"
d=$(dd d7); echo 70 > "$d/candidates"
echo '{"edges":[{"parent":"7","child":"70","kind":"hard"}]}' > "$d/edges.json"; printf '7\tclosed-done\n' > "$d/parents"
[ "$(decide "$d")" = "70|yes|" ] && ok "D7 a closed-done parent clears the edge" || bad "D7: $(decide "$d")"
d=$(dd d8); printf '80\n81\n' > "$d/candidates"
echo '{"edges":[{"parent":"8","child":"80","kind":"hard"},{"parent":"9","child":"81","kind":"hard"},{"parent":"3","child":"81","kind":"hard"}]}' > "$d/edges.json"
printf '8\tunknown\n9\topen\n' > "$d/parents"
[ "$(decide "$d")" = "80|unknown|parent #8 unreadable 81|no|parent #9 open" ] \
  && ok "D8 an unknown parent -> unknown; an open parent beats an unlisted one" || bad "D8: $(decide "$d")"
d=$(dd d9); printf '90\n91\n92\n' > "$d/candidates"; echo 92 > "$d/in_flight"; echo 1 > "$d/cap"
echo '{"edges":[{"parent":"4","child":"90","kind":"hard"}]}' > "$d/edges.json"; printf '4\topen\n' > "$d/parents"
echo '{"holds":[{"ticket":"90","state":"hold","by":"x","at":"2026-10-16T09:00:00Z"}]}' > "$d/holds.json"
[ "$(decide "$d")" = "90|no|parent #4 open 91|yes|" ] \
  && ok "D9 first hit wins (parent before hold); in flight is not judged; a no does not use the cap" || bad "D9: $(decide "$d")"

# ============================================================================
echo "L: sched_lanes_did"
d=$(dd l1); printf '2026-10-16T09:55:00Z\t2026-10-16T10:00:00Z\n' > "$d/window"
jq -nc '{rows: [
  {stamp: "2026-10-16 09:58:00Z", ticket: "BH-11", line: "[proj] gate=g scope=s BH-11 :: defer :: overlap-guard DEFER"},
  {stamp: "2026-10-16 09:58:30Z", ticket: "12", line: "[proj] gate=g scope=s 12 :: Build :: ready"},
  {stamp: "2026-10-16 09:50:00Z", ticket: "BH-13", line: "[proj] gate=g scope=s BH-13 :: skip :: too old"}]}' > "$d/decisions.json"
jq -nc '{jobs: [{id: "j14", ticket_id: "BH-14", kind: "build", created_at: "2026-10-16T09:59:00.123Z"},
  {id: "j15", ticket_id: "BH-15", kind: "build", created_at: "2026-10-16T09:00:00Z"},
  {id: "j11", ticket_id: "BH-11", kind: "triage", created_at: "2026-10-16T09:59:00Z"}]}' > "$d/jobs.json"
echo '2026-10-16 09:57:00Z [pool/proj] SIBLING_SERIAL BH-16 waits for BH-1 on bin/x.sh — no machine spawned' > "$d/pool.log"
printf 'HELD: BH-16 overlaps in-flight BH-2 on bin/y.sh\nHELD: BH-17 waits for sibling BH-3 on bin/z.sh (SIBLING_SERIAL)\nHELD: BH-11 overlaps in-flight BH-4 on bin/w.sh\n' > "$d/overlap.out"
jq -nc '{ledgers: [{key: "proj BH-18 ticket/bh-5", status: "waiting"}, {key: "proj BH-19 ticket/bh-5", status: "stacked"},
  {key: "other BH-20 ticket/bh-5", status: "waiting"}]}' > "$d/stackwait.json"
LD=$( ( eval "$LIB"; sched_lanes_did "$d" BH proj ) )
lget() { awk -F'\t' -v n="$1" '$1 == n {print $2 "|" $3}' <<<"$LD"; }
[ "$(lget 11)" = "held:triage+overlap-schedule|overlap-guard DEFER" ] && ok "L1 a triage defer -> held:triage with its reason; lanes join in order" || bad "L1: $(lget 11)"
[ "$(lget 12 | cut -d'|' -f1)" = dispatched ] && [ "$(lget 14 | cut -d'|' -f1)" = dispatched ] \
  && ok "L2 a triage build and a build job in the window -> dispatched" || bad "L2: 12=$(lget 12) 14=$(lget 14)"
[ -z "$(lget 13)" ] && [ -z "$(lget 15)" ] && ok "L3 a decision or a job before the window -> no entry" || bad "L3: 13=$(lget 13) 15=$(lget 15)"
[ "$(lget 16 | cut -d'|' -f1)" = "held:sibling-serial+overlap-schedule" ] && [ "$(lget 17 | cut -d'|' -f1)" = "held:sibling-serial" ] \
  && ok "L4 the pool log and the overlap SIBLING_SERIAL line -> sibling-serial" || bad "L4: 16=$(lget 16) 17=$(lget 17)"
[ "$(lget 18 | cut -d'|' -f1)" = held:stacked-wait ] && [ -z "$(lget 19)" ] && [ -z "$(lget 20)" ] \
  && ok "L5 a waiting stack-wait row of this project -> stacked-wait; stacked or another project -> none" || bad "L5: 18=$(lget 18) 19=$(lget 19) 20=$(lget 20)"

# ============================================================================
echo "C: sched_compare"
printf '1\tyes\t\n2\tyes\t\n3\tyes\t\n4\tno\tparent #9 open\n5\tno\thold by x\n6\tno\tfiles claimed by #8\n7\tunknown\tparent #9 unreadable\n8\tno\twip cap\n' > "$T/dec.tsv"
printf '1\tdispatched\ttriage build\n2\theld:triage+sibling-serial\tDEFER now\n4\theld:triage\tskip\n6\tdispatched\tbuild job j6\n7\tdispatched\tx\n8\tdispatched\tbuild job j8\n' > "$T/lanes.tsv"
CMP=$( ( eval "$LIB"; sched_compare "$T/dec.tsv" "$T/lanes.tsv" ) )
[ "$(head -1 <<<"$CMP")" = "compared=6 agreed=3 idle=1" ] && ok "C0 counts: 6 compared, 3 agreed, 1 idle, unknown excluded" || bad "C0: $(head -1 <<<"$CMP")"
cget() { awk -F'\t' -v n="$1" '$1 == n {print $2 "|" $3 "|" $4 "|" $5}' <<<"$CMP"; }
[ -z "$(cget 1)" ] && ok "C1 yes + dispatched -> agree, no diff" || bad "C1: $(cget 1)"
[ "$(cget 2)" = "ready|held:triage+sibling-serial|DEFER now|lanes-held:triage" ] && ok "C2 yes + held -> diff with the lane's reason" || bad "C2: $(cget 2)"
[ -z "$(cget 3)" ] && ok "C3 yes + none -> idle, no diff" || bad "C3: $(cget 3)"
[ -z "$(cget 4)" ] && ok "C4 no + held -> agree" || bad "C4: $(cget 4)"
[ -z "$(cget 5)" ] && ok "C5 no + none -> agree" || bad "C5: $(cget 5)"
[ "$(cget 6)" = "not-ready|dispatched|files claimed by #8|files-claimed" ] && [ "$(cget 8)" = "not-ready|dispatched|wip cap|wip-cap" ] \
  && ok "C6 no + dispatched -> diff with the scheduler's reason and class" || bad "C6: 6=$(cget 6) 8=$(cget 8)"
[ -z "$(cget 7)" ] && ok "C7 unknown -> not compared" || bad "C7: $(cget 7)"
CMP=$( ( eval "$LIB"; sched_compare "$T/dec.tsv" "$T/no-such-file" ) )
[ "$(head -1 <<<"$CMP")" = "compared=4 agreed=4 idle=3" ] && ok "C8 no lanes file -> every yes idle, every no agrees" || bad "C8: $CMP"

# ============================================================================
echo "S1: six candidates, one reason each"
reset
issues 101 102 103 104 105 106
edge 90 102 hard; edge 90 105 soft
hold 103 hold operator 2026-10-16T08:00:00Z 7001
job job-110 BH-110 running; sql "INSERT INTO job_claims (job_id,planned_files,files_claimed_at,files_expires_at,updated_at) VALUES ('job-110','bin/a.sh','2026-10-16T08:00:00Z','2099-01-01T00:00:00Z','2026-10-16T08:00:00Z')"
sql "INSERT INTO preplans (project,ticket_key,base_sha,planned_files,plan_md,created_at,updated_at) VALUES ('proj','BH-104','abc','SOURCE: plan
bin/a.sh
','x','2026-10-16T08:00:00Z','2026-10-16T08:00:00Z')"
job job-106 BH-106 running
ghfix 'repos/example-org/proj/pulls?state=all&head=example-org:ticket/bh-90&per_page=100' '[]'
ghfix 'repos/example-org/proj/issues/90' '{"number":90,"state":"open"}'
run
[ "$RC" = 0 ] && ok "S1 rc 0" || bad "S1 rc $RC: $(cat "$T/run.out")"
[ "$(sched 101)" = "SCHED ticket=BH-101 ready=yes reason=" ] && ok "S1 #101 ready" || bad "S1 101: $(sched 101) | $(tickline)"
[ "$(sched 102)" = "SCHED ticket=BH-102 ready=no reason=parent #90 open" ] && ok "S1 #102 parent #90 open" || bad "S1 102: $(sched 102)"
[ "$(sched 103)" = "SCHED ticket=BH-103 ready=no reason=hold by operator" ] && ok "S1 #103 hold by operator" || bad "S1 103: $(sched 103)"
[ "$(sched 104)" = "SCHED ticket=BH-104 ready=no reason=files claimed by #110" ] && ok "S1 #104 files claimed by #110" || bad "S1 104: $(sched 104)"
[ "$(sched 105)" = "SCHED ticket=BH-105 ready=yes reason=" ] && ok "S1 #105 a soft edge -> ready" || bad "S1 105: $(sched 105)"
[ -z "$(sched 106)" ] && [ -z "$(sched 999)" ] && grep -q ' candidates=6 ready=2 not_ready=3 unknown=0 in_flight=1 ' <<<"$(tickline)" \
  && ok "S1 #106 in flight: no SCHED line; the PR entry is no candidate; summary counts" || bad "S1 106: '$(sched 106)' $(tickline)"
NBAD=$(grep 'SCHED ticket=' "$H/logs/scheduler.log" | grep -c 'ready=no reason=$')
NNO=$(grep -c 'SCHED ticket=.* ready=no reason=.' "$H/logs/scheduler.log")
[ "$NBAD" = 0 ] && [ "$NNO" = 3 ] && ok "S1 every ready=no line has one non-empty reason" || bad "S1 reasons: empty=$NBAD set=$NNO"
grep -q 'post=ok partial=-$' <<<"$(tickline)" && ok "S1 post=ok, no partial input" || bad "S1 tick: $(tickline) jobs-client: $(grep scheduler "$H/logs/jobs-client.log" 2>/dev/null | tail -2)"
[ "$(rows sched_ticks | jq -r '.[0] | [.project, .at, .mode, .candidates, .in_flight] | @tsv')" = $'proj\t2026-10-01T10:00:00Z\tshadow\t6\t1' ] \
  && ok "S1 one sched_ticks row for (proj, AT)" || bad "S1 ticks: $(rows sched_ticks)"

echo "S2: a parent whose branch exists but whose PR merged"
reset
issues 201
edge 200 201 hard
job job-200 BH-200 done '{"result":"PR_CREATED https://github.com/example-org/proj/pull/300 | built"}'
pr_row 300 MERGED
ghfix 'repos/example-org/proj/branches/ticket/bh-200' '{"name":"ticket/bh-200"}'
ghfix 'repos/example-org/proj/git/refs/heads/ticket/bh-200' '{"ref":"refs/heads/ticket/bh-200"}'
run
[ "$(sched 201)" = "SCHED ticket=BH-201 ready=yes reason=" ] && ok "S2 #201 ready (the parent PR merged)" || bad "S2: $(sched 201) | $(tickline)"
! grep -qE 'branches|git/refs' "$T/gh.log" && ok "S2 no branch or ref path read" || bad "S2 gh: $(cat "$T/gh.log")"

echo "S3: hold then resume"
reset
issues 301
hold 301 hold operator 2026-10-16T08:00:00Z 7101
run
[ "$(sched 301)" = "SCHED ticket=BH-301 ready=no reason=hold by operator" ] && ok "S3 a hold row -> not ready" || bad "S3 hold: $(sched 301)"
hold 301 resume operator 2026-10-16T09:00:00Z 7102
run $((NOW + 300))
[ "$(sched 301)" = "SCHED ticket=BH-301 ready=yes reason=" ] && ok "S3 a newer resume row -> ready" || bad "S3 resume: $(sched 301)"

echo "S4: shadow dispatches nothing"
for M in shadow enforce; do
  reset
  setting scheduler.mode "$M"
  issues 401 402 403
  run
  [ "$(grep -c 'ready=yes' "$H/logs/scheduler.log")" = 3 ] || bad "S4 $M setup: $(cat "$H/logs/scheduler.log")"
  [ ! -s "$T/dispatch.log" ] && ! grep -qE '^(POST /api/jobs|PUT /api/jobs/)' "$T/srv.log" \
    && [ -z "$(find "$H/state" -path '*fly-pool*' -type f 2>/dev/null)" ] \
    && ok "S4 mode=$M: no dispatch call, no job write, no pool queue file" || bad "S4 $M: dispatch=$(cat "$T/dispatch.log") srv=$(grep -E 'jobs' "$T/srv.log")"
done
grep -q 'mode=enforce not built in this wave' "$H/logs/scheduler.log" && grep -q 'SCHED-TICK project=proj mode=shadow ' "$H/logs/scheduler.log" \
  && ok "S4 enforce says it is not built and runs shadow" || bad "S4 enforce: $(cat "$H/logs/scheduler.log")"

echo "S5: a disagreement writes one diff row"
s5() {
  reset
  issues 401
  decision '2026-10-01 09:58:00Z' BH-401 'defer :: overlap-guard DEFER'
}
s5; run
D5=$(rows sched_diffs)
[ "$(jq 'length' <<<"$D5")" = 1 ] && [ "$(jq -r '.[0] | [.ticket, .scheduler_says, .lanes_did, .reason_class, .reason] | @tsv' <<<"$D5")" = $'401\tready\theld:triage\tlanes-held:triage\toverlap-guard DEFER' ] \
  && ok "S5 one sched_diffs row: ready vs held:triage" || bad "S5 diffs: $D5 | $(tickline)"
grep -q ' compared=1 agreed=0 idle=0 diffs=1 post=ok ' <<<"$(tickline)" && ok "S5 summary compared=1 diffs=1 post=ok" || bad "S5 tick: $(tickline)"
rm -f "$H/state/scheduler/proj.last"; run
[ "$(rows sched_diffs | jq 'length')" = 1 ] && [ "$(rows sched_ticks | jq 'length')" = 1 ] && [ "$(posts)" = 2 ] \
  && ok "S5 the same tick minute again: POSTed, still one row" || bad "S5 rerun: $(rows sched_diffs) posts=$(posts)"
[ "$(cat "$H/state/scheduler/proj.last")" = "$AT" ] && ok "S5 .last is the tick time after a 2xx" || bad "S5 last: $(cat "$H/state/scheduler/proj.last" 2>/dev/null)"

# ============================================================================
echo "X: exit paths"
reset; issues 401; touch "$H/flags/lane-off-scheduler"; : > "$T/srv.log"
run
# The lane gate reports its own liveness row (POST /api/lanes/liveness); that
# is the gate's request, not the lane's.
[ "$RC" = 0 ] && [ -z "$(grep -v '^POST /api/lanes/liveness ' "$T/srv.log")" ] && [ ! -s "$T/gh.log" ] && [ ! -s "$H/logs/scheduler.log" ] \
  && ok "X1 the lane switch: rc 0, no lane request, no GitHub read, no line" || bad "X1 rc=$RC srv=$(cat "$T/srv.log") log=$(cat "$H/logs/scheduler.log")"
reset; issues 401; setting scheduler.mode off; : > "$T/srv.log"
run
[ "$(posts)" = 0 ] && [ "$(tickline | sed 's/^[^ ]* //')" = "SCHED-TICK project=proj mode=off" ] && [ ! -s "$T/gh.log" ] \
  && ok "X2 mode off: one line, no POST, no GitHub read" || bad "X2: $(cat "$H/logs/scheduler.log") posts=$(posts)"
s5; mkdir -p "$H/state/scheduler"; echo '2026-10-01T09:56:00Z' > "$H/state/scheduler/proj.last"
answer '{"method":"GET","path":"/api/ticket-edges","status":404,"body":"{\"error\":\"not found\"}"}'
run; answer '{}'
grep -q 'skipped=inputs reads_failed=edges$' <<<"$(tickline)" && [ "$(posts)" = 0 ] && ! grep -q 'SCHED ticket=' "$H/logs/scheduler.log" \
  && [ "$(cat "$H/state/scheduler/proj.last")" = 2026-10-01T09:56:00Z ] \
  && ok "X3 edges 404: one skipped line, no SCHED line, no POST, .last unchanged" || bad "X3: $(cat "$H/logs/scheduler.log") posts=$(posts)"
s5; answer '{"method":"GET","path":"/api/decisions","status":503,"body":"{\"error\":\"fixture outage\"}"}'
run; answer '{}'
grep -q ' compared=0 agreed=0 idle=0 diffs=0 post=ok partial=decisions$' <<<"$(tickline)" && [ "$(rows sched_diffs | jq 'length')" = 0 ] \
  && [ "$(rows sched_ticks | jq -r '.[0].partial')" = decisions ] && [ "$(sched 401)" = "SCHED ticket=BH-401 ready=yes reason=" ] \
  && ok "X4 decisions 503: verdicts written, compared=0, no diff, partial=decisions" || bad "X4: $(tickline) diffs=$(rows sched_diffs)"
s5; answer '{"method":"POST","path":"/api/scheduler/diffs","status":503,"body":"{\"error\":\"fixture outage\"}"}'
run; answer '{}'
grep -q ' post=failed:503 ' <<<"$(tickline)" && [ ! -e "$H/state/scheduler/proj.last" ] \
  && ok "X5 POST 503: post=failed:503, .last not written" || bad "X5: $(tickline)"
reset; setting scheduler.parent_reads_max 1
issues 601 602
edge 598 601 hard; edge 599 602 hard
job job-598 BH-598 done; job job-599 BH-599 done
ghfix 'repos/example-org/proj/pulls?state=all&head=example-org:ticket/bh-598&per_page=100' '[{"number":5,"state":"closed","merged_at":"2026-10-15T00:00:00Z"}]'
ghfix 'repos/example-org/proj/pulls?state=all&head=example-org:ticket/bh-599&per_page=100' '[{"number":6,"state":"closed","merged_at":"2026-10-15T00:00:00Z"}]'
run
[ "$(sched 601)" = "SCHED ticket=BH-601 ready=yes reason=" ] && [ "$(sched 602)" = "SCHED ticket=BH-602 ready=unknown reason=parent #599 unreadable" ] \
  && [ "$(grep -c 'pulls' "$T/gh.log")" = 1 ] \
  && ok "X6 parent read cap 1: the first parent read, the second unknown" || bad "X6: $(sched 601) / $(sched 602) gh=$(cat "$T/gh.log")"

# ============================================================================
echo "R: the daily-digest line"
awk '/^# >>> scheduler shadow \(BH-6978\)/{f=1} f; /^# <<< scheduler shadow/{exit}' "$REPO/bin/daily-digest.sh" > "$T/dd-block.sh"
grep -q '/api/scheduler/agreement' "$T/dd-block.sh" || bad "R setup: no scheduler shadow block in bin/daily-digest.sh"
FIXDAY="$REPO/tests/fixtures/daily-digest/fixture-day.json"
digest() { # digest <day> -> $T/digest.txt, $T/notes
  : > "$T/notes"
  ( . "$H/bin/jobs-client.sh"; . "$H/bin/lib/daily-digest-render.sh"
    note() { printf '%s\n' "$*" >> "$T/notes"; }
    D=$1; TMP=$(mktemp -d "$T/dd.XXXXXX"); body=$(jq -c --arg d "$1" '.day = $d' "$FIXDAY")
    # shellcheck source=/dev/null
    . "$T/dd-block.sh"
    printf '%s\n' "$body" > "$T/digest.json"
    dd_render "$T/digest.json" "https://console.fixture.invalid/" - 10 20 - ) > "$T/digest.txt" 2> "$T/digest.err"
}
reset
sql "INSERT INTO sched_ticks (project,at,mode,candidates,ready,not_ready,unknown,in_flight,compared,agreed,idle) VALUES
  ('cromford','2026-10-15T01:00:00Z','shadow',5,3,2,0,0,6,5,2),
  ('cromford','2026-10-15T01:05:00Z','shadow',5,3,2,0,0,4,4,1),
  ('cromford','2026-10-16T00:00:00Z','shadow',5,3,2,0,0,9,0,0);
INSERT INTO sched_diffs (project,ticket,scheduler_says,lanes_did,reason,reason_class,at) VALUES
  ('cromford','11','ready','held:triage','x','lanes-held:triage','2026-10-15T01:00:00Z'),
  ('cromford','12','ready','held:triage','x','lanes-held:triage','2026-10-15T01:05:00Z'),
  ('cromford','13','not-ready','dispatched','hold by x','hold','2026-10-15T01:05:00Z'),
  ('cromford','14','ready','held:triage','x','lanes-held:triage','2026-10-16T00:00:00Z')"
digest 2026-10-15
SL=$(grep '^Scheduler shadow' "$T/digest.txt")
[[ $SL == "Scheduler shadow, cromford: 90% agree (9 of 10 compared, 3 idle, 2 ticks). Top disagreements: lanes-held:triage 2, hold 1. "* ]] \
  && ok "R1 one line: rate from the day's ticks, top classes in n order" || bad "R1: '$SL' err=$(cat "$T/digest.err")"
answer '{"method":"GET","path":"/api/scheduler/agreement","status":404,"body":"{\"error\":\"not found\"}"}'
digest 2026-10-15; answer '{}'
! grep -q '^Scheduler shadow' "$T/digest.txt" && [ "$(grep -c 'scheduler-shadow: GET /api/scheduler/agreement answered 404' "$T/notes")" = 1 ] \
  && grep -q . "$T/digest.txt" && ok "R2 a 404: no scheduler line, one note, the digest still renders" || bad "R2: $(grep Scheduler "$T/digest.txt") notes=$(cat "$T/notes")"
answer '{"method":"GET","path":"/api/scheduler/agreement","status":500,"body":"{\"error\":\"boom\"}"}'
digest 2026-10-15; answer '{}'
grep -q '^Scheduler shadow: n/a (read failed' "$T/digest.txt" && ok "R3 a 500: the line says n/a (read failed)" || bad "R3: $(grep -i scheduler "$T/digest.txt")"

echo
echo "scheduler-shadow (BH-6978): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
