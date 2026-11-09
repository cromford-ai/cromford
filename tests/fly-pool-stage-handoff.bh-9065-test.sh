#!/bin/bash
# tests/fly-pool-stage-handoff.bh-9065-test.sh — BH-9065: a stage hand-off
# moves the branch, not the machine. With vm_class `plan=model` (a row, or
# the fallback map when there is no row), a build
# key plans on a shared-cpu machine, publishes the plan and answers PLANNED;
# the reap re-offers it as execute, which spawns on performance-8x and adopts
# the published plan.
#
# PINNED:
#   K1-K9  pool_vm_job_kind and pool_job_stamp (the hub lib and fragment).
#   M1-M5  ps_plan_handoff (bin/lib/pool-stage.sh), the machine half: publish,
#          RESULT, refusal; the published record round-trips through
#          preplan_fetch + preplan_find, the reader the execute machine uses.
#   D1-D6  DRIVEN (`bash bin/fly-pool.sh project-5`, fake fly): spawn 1 is
#          shared-cpu-2x with stage:"plan" on its job.json; the reap of
#          PLANNED requeues stage:"execute" with no counter moved and the
#          plan spawn's cap entry taken back; spawn 2 is performance-8x with
#          stage:"execute". No row: the fallback map, the same plan spawn
#          (D6). Row build=compute: one performance-8x spawn, no stage (D7).
#   Q1     queue_row_job_file carries stage and cap_brief from the row meta.
#   R1     result-prefix-ok.sh accepts PLANNED (a mexec miss otherwise).
# Run from anywhere: bash tests/fly-pool-stage-handoff.bh-9065-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/pool-vm-size.sh"
mkdir -p "$T/reg/catalog"; cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/"
bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 || bad "K0: lanes-build.sh --write failed on a scratch copy"
REG="$T/reg/catalog/lanes.json"

# ══ K: the job kind and the stamp ═══════════════════════════════════════════
printf '{"key":"BH-1"}\n' > "$T/j-none.json"
printf '{"key":"BH-1","stage":"execute"}\n' > "$T/j-exec.json"
jk() { env -i PATH="$PATH" VM_CLASS="${3:-}" bash -c '. "$1"; pool_vm_job_kind "$2" "$3"' _ "$LIB" "$1" "$2"; }
[ "$(jk BH-1 "$T/j-none.json" "plan=model")" = plan ] && ok || bad "K1: a build key under plan=model is a plan job"
[ "$(jk BH-1 "$T/j-exec.json" "plan=model")" = execute ] && ok || bad "K2: stage:execute is an execute job"
[ "$(jk BH-1 "$T/j-none.json" "")" = plan ] && ok || bad "K3: no row: the fallback map makes a build key a plan job"
[ "$(jk BH-1 "$T/j-none.json" "build=compute")" = build ] && ok || bad "K3b: row build=compute: a whole build"
[ "$(jk BH-1 "$T/j-exec.json" "")" = execute ] && ok || bad "K3c: no row: stage:execute is an execute job"
[ "$(jk LR-1-abcdef12 "$T/j-none.json" "plan=model")" = leadreview ] && ok || bad "K4: an LR key stays leadreview"
STAMPFN=$(sed -n '/^pool_job_stamp() {/,/^}/p; /^pool_job_stamp_path() {/,/^}/p; /^pool_job_stamp_done() {/,/^}/p' "$DIR/bin/fly-pool.sh")
[ "$(grep -c '^pool_job_stamp\(_path\|_done\)\?() {' <<<"$STAMPFN")" = 3 ] && ok || bad "K5: pool_job_stamp/_path/_done not all in bin/fly-pool.sh"
eval "$STAMPFN"
# The stamp goes on a private copy: the queue file is never rewritten.
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
cp "$T/j-none.json" "$T/s1.json"; P1=$(pool_job_stamp_path "$T/s1.json" plan)
[ "$P1" != "$T/s1.json" ] && [ "$(jq -c '[.stage,.soft_cap_s]' "$P1")" = '["plan",7200]' ] && ok || bad "K6: a plan job's pushed copy gets stage plan and soft_cap_s 7200: $P1 $(cat "$P1")"
cmp -s "$T/j-none.json" "$T/s1.json" && ok || bad "K6b: the queue file is unchanged by the stamp: $(cat "$T/s1.json")"
cp "$T/j-exec.json" "$T/s2.json"; P2=$(POOL_MACHINE_SOFT_CAP_S=0 pool_job_stamp_path "$T/s2.json" build)
[ "$(jq -c '[.stage,.soft_cap_s]' "$P2")" = '[null,null]' ] && ok || bad "K7: a whole build drops stage, cap 0 drops soft_cap_s: $(cat "$P2")"
cmp -s "$T/j-exec.json" "$T/s2.json" && ok || bad "K7b: the queue file is unchanged by the stamp: $(cat "$T/s2.json")"
printf '{"key":"RR-1-abcdef12"}\n' > "$T/s3.json"; P3=$(pool_job_stamp_path "$T/s3.json" rereview)
[ "$P3" = "$T/s3.json" ] && [ "$(cat "$T/s3.json")" = '{"key":"RR-1-abcdef12"}' ] && ok || bad "K8: a re-review job is pushed as it is: $P3 $(cat "$P3")"
# pool_job_stamp_done removes the copy and never the job file.
pool_job_stamp_done "$T/s1.json" "$P1"; pool_job_stamp_done "$T/s3.json" "$P3"
[ ! -e "$P1" ] && [ -e "$T/s1.json" ] && [ -e "$T/s3.json" ] && ok || bad "K9: the copy is removed, the job files stay"
pool_job_stamp_done "$T/s2.json" "$T/s1.json"
[ -e "$T/s1.json" ] && ok || bad "K9b: a path outside \$TMPDIR/pool-job-stamp.* is never removed"
pool_job_stamp_done "$T/s2.json" "$P2"
[ -z "$(ls -A "$TMPDIR")" ] && ok || bad "K9c: no stamped copy is left behind: $(ls "$TMPDIR")"
unset TMPDIR

# ══ M: the machine half ═════════════════════════════════════════════════════
REPO="$T/repo"; git init -q "$REPO" && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
MN=0
newb() { MN=$((MN+1)); MB="$T/build-$MN"; mkdir -p "$MB"; }   # in this shell, before each mh
mh() { # mh <stage-only> <put-rc> -> runs ps_plan_handoff in $MB; prints rc|RESULT
  local b="$MB"
  printf '# Plan\nFILES: bin/x.sh\n' > "$b/plan.md"; printf 'fp-1\n' > "$b/ticket-fp"; : > "$b/pipeline.log"
  ( HARNESS="$DIR"; BUILD="$b"; WT="$REPO"; BASE=HEAD; PROJECT=project-5; KEY=BH-7; export RB_STAGE_ONLY="$1"
    STAMP() { echo now; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }
    preplan_put() { cp -r "$3" "$BUILD/published"; printf '%s %s\n' "$1" "$2" > "$BUILD/put-args"; return "$PUTRC"; }
    . "$DIR/bin/lib/preplan-lib.sh"; . "$DIR/bin/lib/pool-stage.sh"
    PUTRC="$2" ps_plan_handoff; echo "$?|$(cat "$BUILD/RESULT" 2>/dev/null)" )
}
newb; O=$(mh plan 0)
[ "$O" = "0|PLANNED stage=plan BH-7" ] && ok || bad "M1: a plan job hands off: got '$O'"
[ "$(cat "$MB/put-args" 2>/dev/null)" = "project-5 BH-7" ] && [ "$(cat "$MB/published/key" 2>/dev/null)" = BH-7 ] \
  && [ -s "$MB/published/base-sha" ] && cmp -s "$MB/plan.md" "$MB/published/plan.md" && ok \
  || bad "M2: the published record carries plan.md, key, base-sha: $(ls "$MB/published" 2>/dev/null)"
grep -q 'STAGE hand-off: plan published' "$MB/pipeline.log" && ok || bad "M2b: one pipeline line: $(cat "$MB/pipeline.log")"
newb; O=$(mh plan 1)
[ "$O" = "1|" ] && ok || bad "M3: a publish that failed hands nothing off, writes no RESULT: '$O'"
grep -q 'hand-off refused' "$MB/pipeline.log" && ok || bad "M3b: the refusal is logged: $(cat "$MB/pipeline.log")"
newb; O=$(mh "" 0)
[ "$O" = "1|" ] && [ ! -e "$MB/put-args" ] && ok || bad "M4: a whole build never publishes or answers PLANNED: '$O'"
# M5: round trip. preplan_fetch reads the published row back into the relay
# shape, and preplan_find (the execute machine's reader) accepts it for BH-7.
newb; mh plan 0 >/dev/null
ROW=$(jq -n --rawfile plan "$MB/published/plan.md" --arg sha "$(cat "$MB/published/base-sha")" --rawfile fp "$MB/published/ticket-fp" \
  '{preplan:{project:"project-5",ticket_key:"BH-7",base_sha:$sha,plan_md:$plan,ticket_fp:$fp}}')
RT=$( HARNESS="$T/rt"; mkdir -p "$HARNESS/state"
  _jobs_req() { printf '%s' "$ROW"; return 0; }; _preplan_client() { return 0; }
  . "$DIR/bin/jobs-client.sh" 2>/dev/null; _jobs_req() { printf '%s' "$ROW"; return 0; }
  . "$DIR/bin/lib/preplan-lib.sh"
  preplan_fetch "$HARNESS" project-5 BH-7 "$T/relay" >/dev/null 2>&1; echo "rc=$?"
  cat "$T/relay/key" 2>/dev/null )
grep -q '^rc=0' <<<"$RT" && grep -q '^BH-7$' <<<"$RT" && cmp -s "$MB/plan.md" "$T/relay/plan.md" && ok \
  || bad "M5: the published plan must round-trip through preplan_fetch: $RT"

# ══ D: driven through bin/fly-pool.sh ═══════════════════════════════════════
. "$(dirname "$0")/lib/pool-stage-fixture.bh-9065.sh" || exit 1
# D1: spawn 1 — a build key under plan=model.
reset_case; rows "vm_class=plan=model"; queued BH-1
run_pool
runline | grep -q -- '--vm-size shared-cpu-2x --vm-memory 4096 ' && ok \
  || bad "D1: the plan spawn must be shared-cpu-2x/4096: $(runline) / $(log)"
grep -q 'vm class model shared-cpu-2x/4096 for BH-1 (plan)' "$H/logs/fly-pool.log" && ok || bad "D1: the log names the plan kind: $(log)"
[ "$(jq -r '.stage' "$T/pushed/1234567890abcd" 2>/dev/null)" = plan ] && [ "$(jq -r '.soft_cap_s' "$T/pushed/1234567890abcd" 2>/dev/null)" = 7200 ] && ok \
  || bad "D1: the pushed job.json must carry stage plan and soft_cap_s: $(cat "$T/pushed/1234567890abcd" 2>/dev/null)"
# D2-D4: the reap of PLANNED.
reset_case; rows "vm_class=plan=model"
machine 1234567890abcd BH-1 model "PLANNED stage=plan BH-1" 2 1 3
run_pool POOL_SPAWN=0
[ "$(jq -r '.stage' "$QD/BH-1.json" 2>/dev/null)" = execute ] && ok || bad "D2: the requeue carries stage execute: $(cat "$QD/BH-1.json" 2>/dev/null) / $(log)"
[ "$(jq -c '[.attempt,.deferrals,.deaths]' "$QD/BH-1.json" 2>/dev/null)" = "[3,2,1]" ] && ok \
  || bad "D3: attempt, deferrals and deaths must not move: $(cat "$QD/BH-1.json" 2>/dev/null)"
grep -q $'^put\tproject-5\tBH-1\t1\tfly\t3\t.*"stage":"execute"' "$H/qrow.log" && ok || bad "D3: the row requeue carries the stage in its meta: $(cat "$H/qrow.log")"
[ ! -s "$PD/BH-1.spawns" ] && ok || bad "D4: the plan spawn's cap entry is taken back: $(cat "$PD/BH-1.spawns" 2>/dev/null)"
grep -q 'PLANNED BH-1 on 1234567890abcd: stage hand-off' "$H/logs/fly-pool.log" && ok || bad "D4: one reap line: $(log)"
grep -qE 'GATE_RED|EXECUTE_EMPTY' "$H/qrow.log" && bad "D4: the requeue reason must not read as a gate or an empty execute" || ok
# D5: spawn 2 — the execute re-offer goes to a compute machine.
scratch_rm "$POOLD/1234567890abcd.json" 2>/dev/null; scratch_rm "$T/pushed/1234567890abcd" 2>/dev/null
run_pool
runline | grep -q -- '--vm-size performance-8x --vm-memory 16384 ' && ok \
  || bad "D5: the execute spawn must be performance-8x/16384: $(runline) / $(log)"
grep -q 'vm class compute performance-8x/16384 for BH-1 (execute)' "$H/logs/fly-pool.log" && ok || bad "D5: the log names the execute kind: $(log)"
[ "$(jq -r '.stage' "$T/pushed/1234567890abcd" 2>/dev/null)" = execute ] && ok || bad "D5: the pushed job.json carries stage execute: $(cat "$T/pushed/1234567890abcd" 2>/dev/null)"
# D6: no row — the fallback map: the plan spawn on shared-cpu-2x, stage plan.
reset_case; queued BH-1
run_pool
runline | grep -q -- '--vm-size shared-cpu-2x --vm-memory 4096 ' && ok || bad "D6: no row: the plan spawn must be shared-cpu-2x/4096: $(runline)"
[ "$(jq -r '.stage // "none"' "$T/pushed/1234567890abcd" 2>/dev/null)" = plan ] && ok || bad "D6: no row: the job carries stage plan: $(cat "$T/pushed/1234567890abcd" 2>/dev/null)"
# D7: row build=compute — one whole build on performance-8x, no stage.
reset_case; rows "vm_class=build=compute"; queued BH-1
run_pool
runline | grep -q -- '--vm-size performance-8x ' && ok || bad "D7: row build=compute keeps a build on performance-8x: $(runline)"
[ "$(jq -r '.stage // "none"' "$T/pushed/1234567890abcd" 2>/dev/null)" = none ] && ok || bad "D7: no stage on a whole build: $(cat "$T/pushed/1234567890abcd" 2>/dev/null)"
# S: every fly call went to the stub.
[ -s "$T/fly.txt" ] && ok || bad "S1: the fly stub recorded no call"

# ══ Q1: queue_row_job_file carries stage and cap_brief ══════════════════════
QO=$( HARNESS="$T/q"; mkdir -p "$HARNESS"; . "$DIR/bin/lib/queue-row-job.sh"
  queue_row_job_file project-5 "$T/q/BH-9.json" BH-9 9 1 '{"deferrals":0,"stage":"execute","cap_brief":"b1"}' >/dev/null 2>&1
  jq -c '[.stage,.cap_brief]' "$T/q/BH-9.json" 2>/dev/null
  queue_row_job_file project-5 "$T/q/BH-8.json" BH-8 8 1 '{"deferrals":0,"stage":"rm -rf"}' >/dev/null 2>&1
  jq -c '[.stage]' "$T/q/BH-8.json" 2>/dev/null )
[ "$QO" = $'["execute","b1"]\n[null]' ] && ok || bad "Q1: stage/cap_brief carried, a bad stage dropped: $QO"

# ══ R1 ══════════════════════════════════════════════════════════════════════
bash "$DIR/bin/result-prefix-ok.sh" "PLANNED stage=plan BH-1" && ok || bad "R1: PLANNED must be a RESULT"
bash "$DIR/bin/result-prefix-ok.sh" "PLANNEDX" && bad "R1: PLANNEDX is not a RESULT" || ok

echo "fly-pool-stage-handoff (BH-9065): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
