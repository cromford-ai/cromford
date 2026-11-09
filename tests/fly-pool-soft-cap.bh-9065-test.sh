#!/bin/bash
# tests/fly-pool-soft-cap.bh-9065-test.sh — BH-9065: a pool machine has a soft
# cap of 2 hours (row lane.fly-pool.<p>.pool_machine_soft_cap_s). At the cap
# the build checkpoints its branch, writes brief.md and answers CAPPED; the
# reap re-offers the key on a fresh machine with the brief, and moves no
# counter. The record names the cap, never GATE_RED or EXECUTE_EMPTY.
#
# PINNED:
#   K1     the registry carries POOL_MACHINE_SOFT_CAP_S (int, default 7200, 0 = off).
#   C1-C6  ps_cap_due / ps_cap_clamp on a fake clock (PS_UPTIME_S).
#   F1-F5  ps_cap_fire against a real git worktree and a bare remote: the wip
#          commit is PUSHED before the RESULT, brief.md, the plan published;
#          a push that fails, or checkpoints switched off (F6), writes no CAPPED.
#   G1-G4  CC() (extracted from the real bin/lib/rb/plan.sh): past the cap it
#          caps before it buys the call; before the cap it clamps the
#          session's timeout; with the knob off nothing changes; a fire that
#          did not land keeps the full timeout (G5); an open PR never caps (G6).
#   D1-D5  DRIVEN (`bash bin/fly-pool.sh project-5`, fake fly): the reap of
#          CAPPED requeues with the brief, fresh_spawn, attempt/deferrals/
#          deaths unchanged, the spawn-cap entry kept, the reason `cap: …`,
#          no GATE_RED / EXECUTE_EMPTY text, every other state file unchanged.
#   D7     a CAPPED machine with a second key queued is destroyed, not handed it.
#   N1-N6  next_job_or_destroy (sourced alone): a machine at or past the cap by
#          booted_at is destroyed, not reused; the hand-off carries booted_at.
#   J1     _job_finish (gates.sh) parks CAPPED and PLANNED, never fails them.
# Run from anywhere: bash tests/fly-pool-soft-cap.bh-9065-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
PSL="$DIR/bin/lib/pool-stage.sh"
mkdir -p "$T/reg/catalog"; cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/"
bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 || bad "K0: lanes-build.sh --write failed on a scratch copy"
REG="$T/reg/catalog/lanes.json"

# ══ K1 ══════════════════════════════════════════════════════════════════════
kf() { jq -r --arg e "$1" --arg f "$2" '.lanes[]? | select(.id=="fly-pool") | .knobs[]? | select(.env==$e) | .[$f] | tostring' "$REG" 2>/dev/null; }
[ "$(kf POOL_MACHINE_SOFT_CAP_S type)" = int ] && [ "$(kf POOL_MACHINE_SOFT_CAP_S default)" = 7200 ] && [ "$(kf POOL_MACHINE_SOFT_CAP_S min)" = 0 ] && ok \
  || bad "K1: POOL_MACHINE_SOFT_CAP_S must be int 7200, min 0: '$(kf POOL_MACHINE_SOFT_CAP_S type)' '$(kf POOL_MACHINE_SOFT_CAP_S default)'"

# ══ C: the clock ════════════════════════════════════════════════════════════
cd_() { env -i PATH="$PATH" "$@" bash -c '. "$1"; ps_cap_due && echo due || echo no' _ "$PSL"; }
# C7: a backgrounded subshell (a review lens) never caps: only the build's shell does.
[ "$(env -i PATH="$PATH" POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7300 bash -c '. "$1"; ( ps_cap_due && echo due || echo no )' _ "$PSL")" = no ] && ok \
  || bad "C7: ps_cap_due in a subshell of the build must answer no"
[ "$(cd_ POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7201)" = due ] && ok || bad "C1: past the cap is due"
[ "$(cd_ POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7200)" = due ] && ok || bad "C2: at the cap is due"
[ "$(cd_ POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7199)" = no ] && ok || bad "C3: before the cap is not due"
[ "$(cd_ POOL_SOFT_CAP_S=0 PS_UPTIME_S=99999)" = no ] && ok || bad "C4: cap 0 is off"
[ "$(cd_ PS_UPTIME_S=99999)" = no ] && ok || bad "C5: no soft_cap_s on the job (a machine spawned before the knob) is never capped"
cl() { env -i PATH="$PATH" "$@" bash -c '. "$1"; ps_cap_clamp 3600' _ "$PSL"; }
[ "$(cl POOL_SOFT_CAP_S=7200 PS_UPTIME_S=6000)" = 1200 ] && [ "$(cl POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7190)" = 10 ] \
  && [ "$(cl POOL_SOFT_CAP_S=7200 PS_UPTIME_S=100)" = 3600 ] && [ "$(cl PS_UPTIME_S=7000)" = 3600 ] && ok \
  || bad "C6: clamp to the time left, unchanged when off"
[ "$(cl POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7300)" = 3600 ] && ok \
  || bad "C8: past the cap (the fire did not land) the clamp keeps the full timeout, never 1 s: '$(cl POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7300)'"
[ "$(cd_ POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7300 RB_PR_OPEN=1)" = no ] && [ "$(cl POOL_SOFT_CAP_S=7200 PS_UPTIME_S=6000 RB_PR_OPEN=1)" = 3600 ] && ok \
  || bad "C9: once the PR is open the cap is off: neither due nor clamped"

# ══ F: ps_cap_fire against a real worktree ══════════════════════════════════
HC="$T/hc"; mkdir -p "$HC/logs"
scratch_install_closure bin/lane-checkpoint.sh "$HC" >/dev/null || { echo "closure install of bin/lane-checkpoint.sh failed"; exit 1; }
gitc() { git -c user.email=t@t -c user.name=t "$@"; }
fire_case() { # fire_case <name> [no-remote] [ENV=val ...] -> sets FB (build dir), FW (worktree), FR (remote); runs ps_cap_fire
  FB="$T/$1/build"; FW="$T/$1/wt"; FR="$T/$1/remote.git"; mkdir -p "$FB"
  git init -q --bare "$FR"
  git init -q "$FW"; gitc -C "$FW" commit -q --allow-empty -m base; git -C "$FW" branch -M main
  [ "${2:-}" = no-remote ] || { git -C "$FW" remote add origin "$FR"; git -C "$FW" push -q origin main 2>/dev/null; }
  git -C "$FW" checkout -q -b ticket/bh-7
  echo "work in progress" > "$FW/feature.txt"
  jq -nc '{project:"project-5",key:"BH-7"}' > "$FB/job.json"
  printf '# Plan\nFILES: feature.txt\n' > "$FB/plan.md"; : > "$FB/pipeline.log"
  ( HARNESS="$HC"; BUILD="$FB"; WT="$FW"; BRANCH=ticket/bh-7; BASE=main; PROJECT=project-5; KEY=BH-7
    [ "$#" -gt 2 ] && export "${@:3}"
    export POOL_SOFT_CAP_S=7200 PS_UPTIME_S=7300 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    STAMP() { echo now; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }
    preplan_record() { git -C "$2" rev-parse "$3" > "$1/base-sha"; }
    preplan_put() { cp -r "$3" "$BUILD/published"; return 0; }
    . "$PSL"
    ps_cap_fire execute; echo "$?" > "$BUILD/fire-rc" )
}
fire_case f1
[ "$(cat "$FB/fire-rc")" = 0 ] && [ "$(cat "$FB/RESULT" 2>/dev/null)" = "CAPPED stage=execute after=7300s" ] && ok \
  || bad "F1: the cap answers 'CAPPED stage=execute after=7300s', rc 0: rc=$(cat "$FB/fire-rc") '$(cat "$FB/RESULT" 2>/dev/null)' / $(cat "$FB/pipeline.log")"
RH=$(git --git-dir="$FR" rev-parse --verify -q refs/heads/ticket/bh-7)
RS=$(git --git-dir="$FR" log -1 --format=%s "$RH" 2>/dev/null)
[ -n "$RH" ] && [ "$RH" = "$(git -C "$FW" rev-parse HEAD)" ] && grep -q '^wip: checkpoint ' <<<"$RS" && ok \
  || bad "F2: the wip checkpoint commit must be PUSHED to the remote branch: remote=$RH local=$(git -C "$FW" rev-parse HEAD)"
grep -q 'capped at stage: execute, after 7300s (cap 7200s)' "$FB/brief.md" 2>/dev/null && grep -q 'ticket/bh-7' "$FB/brief.md" && ok \
  || bad "F3: brief.md names the stage, the time and the branch: $(cat "$FB/brief.md" 2>/dev/null)"
cmp -s "$FB/plan.md" "$FB/published/plan.md" && [ "$(cat "$FB/published/key" 2>/dev/null)" = BH-7 ] && ok \
  || bad "F4: the plan is published for the next machine"
grep -qE 'GATE_RED|EXECUTE_EMPTY' "$FB/RESULT" && bad "F4b: the RESULT must not read as a gate or an empty execute" || ok
fire_case f5 no-remote
[ "$(cat "$FB/fire-rc")" = 1 ] && [ ! -e "$FB/RESULT" ] && [ ! -e "$FB/brief.md" ] && ok \
  || bad "F5: a checkpoint that did not land writes no CAPPED and no brief: rc=$(cat "$FB/fire-rc") '$(cat "$FB/RESULT" 2>/dev/null)'"
grep -q 'not capped, the build goes on' "$FB/pipeline.log" && ok || bad "F5b: one pipeline line: $(cat "$FB/pipeline.log")"
# F6: lane-checkpoint answers rc 0 when switched off, but nothing was committed or
# pushed. The uncommitted work must not be capped away with the machine.
fire_case f6 remote CHECKPOINTS=0
[ "$(cat "$FB/fire-rc")" = 1 ] && [ ! -e "$FB/RESULT" ] && [ ! -e "$FB/brief.md" ] && [ -s "$FW/feature.txt" ] \
  && [ -z "$(git --git-dir="$FR" rev-parse --verify -q refs/heads/ticket/bh-7)" ] && ok \
  || bad "F6: checkpoints switched off writes no CAPPED: rc=$(cat "$FB/fire-rc") '$(cat "$FB/RESULT" 2>/dev/null)'"
grep -q 'not on origin/ticket/bh-7' "$FB/pipeline.log" && ok || bad "F6b: the log names the unlanded tree: $(cat "$FB/pipeline.log")"

# ══ G: CC() from the real plan.sh ═══════════════════════════════════════════
CCFN=$(sed -n '/^CC() {/,/^}/p' "$DIR/bin/lib/rb/plan.sh")
[ -n "$CCFN" ] && ok || bad "G0: CC() not found in bin/lib/rb/plan.sh"
HG="$T/hg"; mkdir -p "$HG/bin"
printf '#!/bin/bash\necho "$4" >> "%s/agent-calls"\nexit 0\n' "$T" > "$HG/bin/agent-call.sh"; chmod +x "$HG/bin/agent-call.sh"
cc_case() { # cc_case <uptime> [cap] [fire-fails|pr-open] -> prints rc|RESULT|timeouts
  local b="$T/g-$1-${2:-off}-${3:-}"; mkdir -p "$b"; : > "$T/agent-calls"; : > "$b/pipeline.log"
  ( HARNESS="$HG"; BUILD="$b"; WT=""; BRANCH=""; BASE=main; PROJECT=project-5; KEY=BH-7
    export PS_UPTIME_S="$1" POOL_SOFT_CAP_S="${2:-}" PS_MAIN_PID="$BASHPID"
    [ "${3:-}" = pr-open ] && RB_PR_OPEN=1
    CG_ORIENT=""; VMAP_ORIENT=""; STAMP() { echo now; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; BB() { :; }
    . "$PSL"; eval "$CCFN"
    [ "${3:-}" = fire-fails ] && ps_cap_fire() { return 1; }
    CC review model-x 1800 "$b/out.txt" "prompt" )
  echo "$?|$(cat "$b/RESULT" 2>/dev/null)|$(paste -sd, "$T/agent-calls")"
}
[ "$(cc_case 7300 7200)" = "3|CAPPED stage=review after=7300s|" ] && ok || bad "G1: past the cap, CC caps before the call (no agent call): '$(cc_case 7300 7200)'"
[ "$(cc_case 6600 7200)" = "0||600" ] && ok || bad "G2: before the cap, the session timeout is clamped to the 600 s left: '$(cc_case 6600 7200)'"
[ "$(cc_case 100 7200)" = "0||1800" ] && ok || bad "G3: far from the cap, the timeout is unchanged: '$(cc_case 100 7200)'"
[ "$(cc_case 99999)" = "0||1800" ] && ok || bad "G4: no cap on the job, nothing changes: '$(cc_case 99999)'"
[ "$(cc_case 7300 7200 fire-fails)" = "0||1800" ] && ok \
  || bad "G5: past the cap with a fire that did not land, the call keeps its full timeout: '$(cc_case 7300 7200 fire-fails)'"
[ "$(cc_case 7300 7200 pr-open)" = "0||1800" ] && ok \
  || bad "G6: once the PR is open (rb_settle's re-review), CC never caps: '$(cc_case 7300 7200 pr-open)'"

# ══ D: the reap of CAPPED, driven ═══════════════════════════════════════════
. "$(dirname "$0")/lib/pool-stage-fixture.bh-9065.sh" || exit 1
reset_case
machine 1234567890abcd BH-2 compute "CAPPED stage=execute after=7300s" 4 1 2
printf '# Soft-cap brief — BH-2\n- capped at stage: execute\n' > "$T/brief/1234567890abcd"
printf '3\n' > "$PD/BH-2.ci-repair"; printf '1\n' > "$PD/BH-2.execute-empty"
SCB=$(cat "$PD/BH-2.spawns")
before=$(cd "$PD" && for f in *; do [ "$f" = BH-2.spawns ] && continue; printf '%s %s\n' "$f" "$(md5sum < "$f")"; done)
run_pool POOL_SPAWN=0
Q="$QD/BH-2.json"
[ "$(jq -c '[.attempt,.deferrals,.deaths,.stage,.fresh_spawn]' "$Q" 2>/dev/null)" = '[2,4,1,"execute",true]' ] && ok \
  || bad "D1: requeued with attempt/deferrals/deaths unchanged, stage execute, fresh_spawn: $(cat "$Q" 2>/dev/null) / $(log)"
jq -r '.cap_brief' "$Q" 2>/dev/null | grep -q 'capped at stage: execute' && ok || bad "D2: the queue row carries the brief: $(cat "$Q" 2>/dev/null)"
grep -q $'^done\tproject-5\tBH-2\tfailed\tcap: CAPPED stage=execute after=7300s' "$H/qrow.log" && ok || bad "D3: the row's reason names the cap: $(cat "$H/qrow.log")"
grep -q $'^put\tproject-5\tBH-2\t1\tfly\t2\t.*"cap_brief"' "$H/qrow.log" && ok || bad "D3b: the row requeue carries the brief in its meta: $(cat "$H/qrow.log")"
grep -qE 'GATE_RED|EXECUTE_EMPTY' "$H/qrow.log" "$Q" && bad "D4: the record must never read GATE_RED or EXECUTE_EMPTY" || ok
after=$(cd "$PD" && for f in *; do [ "$f" = BH-2.spawns ] && continue; printf '%s %s\n' "$f" "$(md5sum < "$f")"; done)
[ "$before" = "$after" ] && ok || bad "D5: the counter files must be unchanged: before=[$before] after=[$after]"
[ "$(cat "$PD/BH-2.spawns" 2>/dev/null)" = "$SCB" ] && ok || bad "D5b: CAPPED keeps its spawn-cap entry (a capped loop stays bounded)"
grep -q 'CAPPED BH-2 on 1234567890abcd: cap:' "$H/logs/fly-pool.log" && ok || bad "D5c: one reap line: $(log)"
# D6: POOL_CAP_BRIEF_BYTES cuts the brief the re-offer carries.
reset_case
machine 1234567890abcd BH-3 compute "CAPPED stage=execute after=7300s"
printf '# Soft-cap brief — BH-3\n- capped at stage: execute\n' > "$T/brief/1234567890abcd"
run_pool POOL_SPAWN=0 POOL_CAP_BRIEF_BYTES=10
[ "$(jq -j '.cap_brief' "$QD/BH-3.json" 2>/dev/null | wc -c | tr -d ' ')" = 10 ] && ok \
  || bad "D6: POOL_CAP_BRIEF_BYTES=10 must cut the brief to 10 bytes: $(cat "$QD/BH-3.json" 2>/dev/null)"
# D7: a CAPPED machine with a second key queued is destroyed, never handed
# that key: its uptime is past the cap, so the next build would cap on its
# first call and spend one of that key's spawns (review of bfb27ca23).
reset_case
machine 1234567890abcd BH-2 compute "CAPPED stage=execute after=7300s"
queued BH-4
SC4=$(cat "$PD/BH-4.spawns" 2>/dev/null)
run_pool POOL_SPAWN=0
grep -q 'machine destroy 1234567890abcd' "$T/fly.txt" && ok || bad "D7: the capped machine must be destroyed: $(log)"
[ ! -e "$T/pushed/1234567890abcd" ] && [ ! -e "$POOLD/1234567890abcd.json" ] && ok \
  || bad "D7b: no job may be pushed to the capped machine, and no machine json may stay: $(ls "$T/pushed" "$POOLD" 2>/dev/null)"
[ -s "$QD/BH-4.json" ] && [ "$(cat "$PD/BH-4.spawns" 2>/dev/null)" = "$SC4" ] && ok \
  || bad "D7c: BH-4 stays queued and its spawn-cap log is unchanged: $(cat "$PD/BH-4.spawns" 2>/dev/null)"
[ -s "$QD/BH-2.json" ] && ok || bad "D7d: the capped key is still re-offered: $(ls "$QD")"
grep -q 'at its soft cap (7200s)' "$H/logs/fly-pool.log" && ok || bad "D7e: one destroy-instead-of-reuse line: $(log)"

# N: the age arm of next_job_or_destroy, sourced alone. booted_at (or the first
# spawned_at) against POOL_MACHINE_SOFT_CAP_S, for a RESULT that is not CAPPED.
NR="$T/njd"; mkdir -p "$NR/bin"
sed -n '/^next_job_or_destroy() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$NR/fn.sh"
grep -q 'REUSED=0' "$NR/fn.sh" && ok || bad "N0: could not extract next_job_or_destroy from bin/fly-pool.sh"
printf '#!/bin/bash\necho "$*" >> "${FAKE_FLY_LOG:?}"\n' > "$NR/fly"; chmod +x "$NR/fly"
printf '#!/bin/bash\nexit 0\n' > "$NR/bin/beat.sh"; chmod +x "$NR/bin/beat.sh"
NCASE=0
njd() { # njd <boot-age-s|-> <cap|-> -> sets NOUT DESTROYED|REUSED, NBOOTS the boot stamp; the case dir is $NC
  NCASE=$((NCASE+1)); NC="$NR/c$NCASE"; mkdir -p "$NC/q" "$NC/pool" "$NC/local"
  jq -nc '{key:"BH-8",ticket_id:"2",attempt:0}' > "$NC/q/BH-8.json"
  jq -nc '{machine:"m1",key:"BH-0"}' > "$NC/pool/m1.json"
  echo "PR_CREATED https://x/pull/1" > "$NC/local/RESULT"
  NBOOTS=""; [ "$1" = - ] || NBOOTS=$(date -u -d "$1 seconds ago" '+%Y-%m-%d %H:%M:%SZ')
  NOUT=$(
    set +u
    HARNESS="$NR"; P=project-5; APP=app; FLY="$NR/fly"; export FAKE_FLY_LOG="$NC/flylog"
    QDIR="$NC/q"; POOL="$NC/pool"; LOG="$NC/log"; LOCAL="$NC/local"
    MID=m1; MSTATE=started; KEY=BH-0; MF="$NC/pool/m1.json"; MACCT=""; MBOOT="$NBOOTS"
    [ "$2" = - ] || POOL_MACHINE_SOFT_CAP_S="$2"
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }; say() { echo "$*" >> "$LOG"; }
    mexec() { return 0; }; mput() { return 0; }; push_preplan() { :; }
    push_reroute() { :; }; push_build_note() { :; }; push_bake_evidence() { :; }
    pool_account_release() { :; }; pool_account_armed() { return 1; }
    . "$NR/fn.sh"
    next_job_or_destroy >/dev/null 2>&1
    if grep -q 'machine destroy m1' "$NC/flylog" 2>/dev/null; then echo DESTROYED; else echo REUSED; fi
  )
}
njd 10800 -;   [ "$NOUT" = DESTROYED ] && ok || bad "N1: a machine up 3 h (default cap 7200 s) must be destroyed, not reused: $(cat "$NC/log" 2>/dev/null)"
njd 7200 7200; [ "$NOUT" = DESTROYED ] && ok || bad "N2: a machine at the cap must be destroyed: $(cat "$NC/log" 2>/dev/null)"
njd 1800 -;    [ "$NOUT" = REUSED ] && ok || bad "N3: a machine up 30 min is reused: $(cat "$NC/log" 2>/dev/null)"
[ "$(jq -r '[.key,.booted_at]|join("|")' "$NC/pool/m1.json" 2>/dev/null)" = "BH-8|$NBOOTS" ] && ok \
  || bad "N4: the hand-off carries the machine's first boot as booted_at: $(cat "$NC/pool/m1.json")"
njd 10800 0;   [ "$NOUT" = REUSED ] && ok || bad "N5: cap 0 is off, an old machine is reused: $(cat "$NC/log" 2>/dev/null)"
njd - -;       [ "$NOUT" = REUSED ] && ok || bad "N6: no boot stamp (a machine json from before the knob) is reused as before: $(cat "$NC/log" 2>/dev/null)"

# J1: _job_finish parks CAPPED / PLANNED.
JF=$(sed -n '/^_job_finish() {/,/^}/p' "$DIR/bin/lib/rb/gates.sh")
JN=0
for w in "CAPPED stage=execute after=7300s" "PLANNED stage=plan BH-7"; do
  JN=$((JN+1)); jb="$T/j-$JN"; mkdir -p "$jb"; echo "$w" > "$jb/RESULT"
  st=$( BUILD="$jb"; JOB_ID=j1; JOB_BEAT=""; TL_STATE=""
    job_update() { echo "$2"; }; job_beat_stop() { :; }
    eval "$JF"; _job_finish 2>/dev/null | head -1 )
  [ "$st" = status=parked ] && ok || bad "J1: '$w' must close the job row parked, got '$st'"
done

echo "fly-pool-soft-cap (BH-9065): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
