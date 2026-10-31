#!/bin/bash
# tests/blocked-resolver-lane-no-clone.bh-7630-test.sh — BH-7630: the
# blocked-resolver on a Fly lane machine (LANE_RUN_ID set, no /root/repos/<p>)
# hands its fix rounds to the owning box through fix_round_jobs, skips rung 1
# and rung 1b instead of calling mc_rebase with no clone, counts every rung that
# could not START, and sends ONE alert per placement per hour over
# BR_SETUP_BLOCKED_ALERT_N. The hub dispatch warns while the lane is placed fly
# and the Fly rows are over N.
#
# Every tick is the REAL bin/blocked-resolver.sh on the blocked-resolver
# fixture (tests/lib/fixture-harness.sh), the real bin/lib/fix-round-queue.sh
# and bin/lib/jobs/req.sh, and the fake worker
# tests/lib/fake-fix-round-worker.bh-2530.py behind a `curl` shim. The lane
# machine identity is LANE_RUN_ID=777 BOX_NAME=lane-run-a HUB_BOX_NAME=hubx;
# tproj is owned by box-tproj.
#
# Cases:
#   F1  lane machine, fix-round park, no clone: one queued row for box-tproj
#   F2  hub identity: one queued row (unchanged)
#   F3  owning box with a clone, no LANE_RUN_ID: no row, the round runs here
#   F3b LANE_RUN_ID empty is read as unset: no row
#   F4  --fix-here with LANE_RUN_ID set: runs here, no row
#   F5  a lane machine adopts a done row (the in-flight gate runs on Fly)
#   M1  lane machine, rung-1 park, no clone: no mc_rebase, one row carrying
#       hop_rung=mechanical, nothing spent
#   H1  the box runs that row: mc_rebase merges main cleanly, 0 fix rounds,
#       no agent; the lane machine adopts mechanicals=1 fixrounds=0
#   H2  the box runs that row and mc_rebase conflicts: then the fix round runs
#   L1  a lost write-back after an adopt: the record is restored from the
#       adopted row and no second paid round is queued
#   L2  the hub never heals: an adopted row is not re-read into its record
#   L3  a lane machine never heals from a terminal answer
#   M1b the same with a plain $REPOS/tproj dir and no .git
#   N1  the hop runs the Archie-first gate: afm_first answers 3, no row, nothing spent
#   N1b afm_first answers 1: one row as before
#   M2  lane machine WITH a clone: mc_rebase runs once
#   M3  hub with no clone: mc_rebase runs once (as today)
#   G1  rung 1b on a lane machine, no clone: no mc_rebase, regens unchanged, a row
#       carrying hop_rung=regen:fix-round
#   G2  rung 1b on a lane machine with a clone: mc_rebase runs
#   K1  br_setup_class: the live texts and the near misses
#   A1-A8 the setup-block rate alert (A7: the marker's epoch, not its mtime)
#   A9  the hold is 24 h: a 2-hour-old marker still holds (comment 6315926752)
#   A10 one alert per project, not one per PR: no per-park page under the hold
#   D1-D4 the dispatch placement warning
# Run: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-lane-no-clone.bh-7630-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq python3 git; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
for s in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/fix-round-queue.sh bin/lib/jobs/req.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || { echo "FAIL: cannot install $s"; exit 1; }
done
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# ---- the fake worker and the real transport -----------------------------------
FRW="$T/frw"; mkdir -p "$FRW" || exit 1
printf '#!/bin/bash\nFRW_STATE=%q exec python3 %q "$@"\n' "$FRW" "$DIR/tests/lib/fake-fix-round-worker.bh-2530.py" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl" || exit 1
{ printf 'JOBS_HARNESS=%q; HARNESS_SECRET=test-secret-fixture; JOBS_URL=https://jobs.invalid; JOBS_RETRIES=0\n' "$H"
  printf '. %q\n' "$H/bin/lib/jobs/req.sh"
  sed -n '/^job_ledger_row() {/,/^}/p;/^job_ledger_put() {/,/^}/p' "$DIR/bin/lib/jobs/jobs.sh"
} >> "$H/bin/jobs-client.sh" || exit 1

printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent.txt"\nexit 0\n' "$T" > "$H/bin/agent-call.sh"
chmod +x "$H/bin/agent-call.sh"

LANE=(LANE_RUN_ID=777 BOX_NAME=lane-run-a HUB_BOX_NAME=hubx)
HUB=(BOX_NAME=hubx HUB_BOX_NAME=hubx)
OWNER=(BOX_NAME=box-tproj HUB_BOX_NAME=hubx)
IDENT=(); REPOS="$T/repos"
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$REPOS" \
           BR_SSH="$T/fakebin/br-ssh" env "${IDENT[@]}" ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ); }
LOGF="$H/logs/blocked-resolver.log"
SB="$H/state/blocked-resolver/tproj/setup-blocked.tsv"
MARK="$H/state/blocked-resolver/tproj/setup-blocked.alerted"
mkdir -p "$T/norepos" "$T/plainrepos/tproj"

RESET() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/state/heartbeat"
  scratch_rm "$H/tmp"
  scratch_rm "$FRW"; mkdir -p "$FRW"
  rm -f "$H/flags/blocked-resolver-observe" "$H/locks/"*.lock
  : > "$LOGF"; : > "$H/logs/ALERTS.log"
  : > "$T/agent.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/rebase.txt"
  : > "$T/lane-alert.txt"; rm -f "$T/rebase-rc" "$T/rebase-out"
  printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
  echo OPEN > "$T/prstate"
  BRENV=(); IDENT=(); REPOS="$T/repos"
}
PARK() { # PARK <n> <reason> — park PR #n of ticket TK-n on its own branch
  printf 'ticket/ts-%s\n' "$1" > "$T/prbranch"; osha "ticket/ts-$1" > "$T/prhead"
  ROW "o/tproj#$1" "$2" "https://github.com/o/tproj/pull/$1"
}
SEED() { # SEED <n> <mechanicals> [regens] — a ledger record for TK-n
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg k "tproj-TK-$1" --argjson m "$2" --argjson g "${3:-0}" \
    '{project:"tproj",rkey:$k,mechanicals:$m,fixrounds:0,regens:$g,rebuilds:0,outcome:"",attempts:[]}' \
    > "$H/state/blocked-resolver/tproj/tproj-TK-$1.json"
}
REC() { jq -r "$2" "$H/state/blocked-resolver/tproj/tproj-TK-$1.json" 2>/dev/null; }
ROWS() { cat "$FRW/rows.json" 2>/dev/null || echo "[]"; }
NROWS() { ROWS | jq 'length'; }
ROWF() { ROWS | jq -r "$1"; }
NREB() { grep -c . "$T/rebase.txt"; }
NALERT() { grep -c -- "--id $1 " "$T/lane-alert.txt"; }
AID=resolver-setup-blocked-fly-tproj

# ============================================================================
# F. THE FIX ROUND GOES TO THE OWNING BOX FROM A LANE MACHINE
# ============================================================================
# ---- F1. lane machine, review park (straight to the fix round), no clone
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 91 head-not-reapproved
RUN
[ "$(NROWS)" = 1 ] && [ "$(ROWF '.[0].box')" = box-tproj ] && [ "$(ROWF '.[0].status')" = queued ] && ok \
  || bad "F1: a lane machine queues ONE row for box-tproj (rows: $(ROWS); log: $(tail -3 "$LOGF"))"
grep -q 'fix round queued for box-tproj as row ' "$LOGF" && ok || bad "F1: the log says the round was queued (log: $(tail -3 "$LOGF"))"
grep -q 'could not START' "$LOGF" && bad "F1: no 'could not START' on a lane machine ($(grep 'could not START' "$LOGF"))" || ok
[ -s "$T/agent.txt" ] && bad "F1: no agent runs on the lane machine ($(cat "$T/agent.txt"))" || ok
[ -e "$SB" ] && bad "F1: a queued round is not a setup block ($(cat "$SB"))" || ok

# ---- F2. hub identity: unchanged, one row
RESET; IDENT=("${HUB[@]}"); REPOS="$T/norepos"; PARK 91 head-not-reapproved
RUN
[ "$(NROWS)" = 1 ] && [ "$(ROWF '.[0].box')" = box-tproj ] && ok || bad "F2: the hub still queues one row (rows: $(ROWS))"

# ---- F3. the owning box with a clone runs the round itself
RESET; IDENT=("${OWNER[@]}"); PARK 91 head-not-reapproved
RUN
[ "$(NROWS)" = 0 ] && ok || bad "F3: the owning box queues no row (rows: $(ROWS))"
[ -s "$T/agent.txt" ] && ok || bad "F3: the owning box runs the round here (agent not called; log: $(tail -4 "$LOGF"))"
# ---- F3b. LANE_RUN_ID set but empty is unset
RESET; IDENT=("${OWNER[@]}" LANE_RUN_ID=); PARK 91 head-not-reapproved
RUN
[ "$(NROWS)" = 0 ] && [ -s "$T/agent.txt" ] && ok || bad "F3b: an empty LANE_RUN_ID is not a lane machine (rows: $(ROWS))"

# ---- F4. --fix-here with LANE_RUN_ID set: the round runs here, nothing queued
RESET; IDENT=("${LANE[@]}"); PARK 91 head-not-reapproved
FH=$(jq -nc '{project:"tproj",rkey:"tproj-TK-91",mechanicals:0,fixrounds:0,rebuilds:0,outcome:"",attempts:[]}' \
  | RUN --fix-here tproj o-tproj-91 head-not-reapproved https://github.com/o/tproj/pull/91 - TK-91; tail -n 50 "$T/run.log")
[ "$(NROWS)" = 0 ] && ok || bad "F4: --fix-here never queues a row (rows: $(ROWS))"
[ -s "$T/agent.txt" ] && ok || bad "F4: --fix-here runs the round here (log: $(tail -4 "$LOGF"); out: $(printf '%s' "$FH" | grep FIX_ | tail -2))"

# ---- F5. a lane machine reads the queue and adopts a done row
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 91 head-not-reapproved; SEED 91 0
NOWI=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -nc --arg up "$NOWI" --arg res "box-paused $(printf 'all-off on box-tproj' | base64 -w0)" \
  '[{id:1,project:"tproj",cap_key:"tproj-TK-91",box:"box-tproj",args:["tproj","o-tproj-91","head-not-reapproved","x","-","TK-91"],
     record_in:null,hotfix:0,status:"done",attempt:1,claimed_by:"box-tproj",result:$res,record_out:null,enqueued_at:$up,updated_at:$up}]' \
  > "$FRW/rows.json"
RUN
[ "$(ROWF '.[0].status')" = adopted ] && ok || bad "F5: the lane machine adopts the done row (got $(ROWF '.[0].status'); log: $(tail -3 "$LOGF"))"
[ "$(NROWS)" = 1 ] && ok || bad "F5: no second row (rows: $(ROWS | jq -c 'map({id,status})'))"

# ============================================================================
# M. RUNG 1 ON A LANE MACHINE WITH NO CLONE
# ============================================================================
CONF="conflict-unresolvable: CONFLICT (content): a.txt"
# ---- M1. no clone dir at all
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 94 "$CONF"; SEED 94 0
RUN
[ "$(NREB)" = 0 ] && ok || bad "M1: mc_rebase is not called with no clone ($(cat "$T/rebase.txt"))"
[ "$(ROWF '[.[] | select(.cap_key == "tproj-TK-94")] | length')" = 1 ] && ok || bad "M1: the park is queued for the box (rows: $(ROWS); log: $(tail -4 "$LOGF"))"
[ "$(ROWF '.[0].record_in | fromjson | .hop_rung')" = mechanical ] && ok || bad "M1: the row carries hop_rung=mechanical (record_in: $(ROWF '.[0].record_in'))"
grep -q 'EVENT resolver_rung tproj/tproj-TK-94 .*rung 1 mechanical queued for box-tproj' "$LOGF" && ok || bad "M1: the event names rung 1 (log: $(grep EVENT "$LOGF" | tail -2))"
[ "$(REC 94 .mechanicals)" = 0 ] && ok || bad "M1: mechanicals is unchanged (got $(REC 94 .mechanicals))"
grep -q 'rung 1 is not run on a lane machine with no clone of tproj' "$LOGF" && ok || bad "M1: the skip is said (log: $(tail -4 "$LOGF"))"
grep -q 'could not START' "$LOGF" && bad "M1: no setup block ($(grep 'could not START' "$LOGF"))" || ok
# ---- M1b. a plain dir with no .git is no clone
RESET; IDENT=("${LANE[@]}"); REPOS="$T/plainrepos"; PARK 94 "$CONF"; SEED 94 0
RUN
[ "$(NREB)" = 0 ] && [ "$(NROWS)" = 1 ] && [ "$(REC 94 .mechanicals)" = 0 ] && ok \
  || bad "M1b: a dir with no .git is no clone (rebase: $(NREB), rows: $(NROWS), mech: $(REC 94 .mechanicals))"
# ---- N1. Archie owns the head (BH-4585): the hop queues nothing and spends nothing
# The box runs the hopped rung under --fix-here, where br_fix_round skips the
# Archie-first gate, so the gate must run BEFORE the row is queued.
printf '%s\n' '# stub archie-fm (BH-7630 N1)' > "$H/bin/lib/archie-fm.sh"
cat > "$H/bin/lib/archie-fm-repair.sh" <<'STUB'
afm_first() { echo x >> "$AFM_CALLS"; return "$(cat "$AFM_RC" 2>/dev/null || echo 1)"; }
STUB
export AFM_CALLS="$T/afm-calls.txt" AFM_RC="$T/afm-rc"
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 94 "$CONF"; SEED 94 0; : > "$AFM_CALLS"; echo 3 > "$AFM_RC"
RUN
[ "$(grep -c . "$AFM_CALLS")" -ge 1 ] && ok || bad "N1: the Archie gate ran before the hop (afm calls 0; log: $(tail -4 "$LOGF"))"
[ "$(NROWS)" = 0 ] && ok || bad "N1: Archie owns the head, so no row is queued (rows: $(ROWS | jq -c 'map({id,status})'))"
[ "$(REC 94 .mechanicals)" = 0 ] && [ "$(REC 94 .fixrounds)" = 0 ] && ok || bad "N1: nothing spent (mech $(REC 94 .mechanicals), fix $(REC 94 .fixrounds))"
[ -s "$T/agent.txt" ] && bad "N1: no agent round ($(cat "$T/agent.txt"))" || ok
grep -q 'Archie (archie-fm) is working head' "$LOGF" && ok || bad "N1: the hold is said (log: $(tail -4 "$LOGF"))"
# ---- N1b. Archie does not own it (rc 1): the hop queues its one row as before
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 94 "$CONF"; SEED 94 0; : > "$AFM_CALLS"; echo 1 > "$AFM_RC"
RUN
[ "$(NROWS)" = 1 ] && ok || bad "N1b: with the gate open the hop queues one row (rows: $(NROWS); log: $(tail -4 "$LOGF"))"
rm -f "$H/bin/lib/archie-fm.sh" "$H/bin/lib/archie-fm-repair.sh"
# ---- M2. a lane machine WITH a clone runs rung 1
RESET; IDENT=("${LANE[@]}"); PARK 94 "$CONF"; SEED 94 0
echo 1 > "$T/rebase-rc"; printf 'a.txt\n' > "$T/rebase-out"
RUN
[ "$(NREB)" = 1 ] && ok || bad "M2: a lane machine with a clone calls mc_rebase once (got $(NREB); log: $(tail -4 "$LOGF"))"
# ---- M3. the hub with no clone: as today
RESET; IDENT=("${HUB[@]}"); REPOS="$T/norepos"; PARK 94 "$CONF"; SEED 94 0
RUN
[ "$(NREB)" = 1 ] && ok || bad "M3: the hub calls mc_rebase as today (got $(NREB); log: $(tail -4 "$LOGF"))"

# ============================================================================
# H. THE OWNING BOX RUNS THE HOPPED RUNG 1 FIRST
# ============================================================================
BOXRUN() { # BOXRUN — the owning box's --fix-here on row 0, its record on stdin
  local a=() r
  mapfile -t a < <(ROWS | jq -r '.[0].args[]')
  r=$(ROWF '.[0].record_in')
  : > "$T/run.log"
  printf '%s' "$r" | ( IDENT=("${OWNER[@]}"); REPOS="$T/repos"; RUN --fix-here "${a[@]}" )
  FIXREC=$(grep '^FIX_RECORD ' "$T/run.log" | tail -n 1 | cut -d' ' -f2 | base64 -d 2>/dev/null)
  FIXRES=$(grep '^FIX_RESULT ' "$T/run.log" | head -n 1 | cut -d' ' -f2-)
}
FINISH() { # FINISH — the claimer's finish of row 0 with the box's answer
  jq --arg ro "$FIXREC" --arg res "${FIXRES:-done}" \
    '.[0] += {status:"done",claimed_by:"box-tproj",result:$res,record_out:$ro}' "$FRW/rows.json" > "$FRW/rows.json.t" \
    && mv "$FRW/rows.json.t" "$FRW/rows.json"
}
# ---- H1. main merges cleanly on the box: 0 fix rounds end to end
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 94 "$CONF"; SEED 94 0
RUN
echo 0 > "$T/rebase-rc"; printf 'beefbeefbeefbeefbeefbeefbeefbeefbeefbeef' > "$T/rebase-out"
BOXRUN
[ "$(NREB)" = 1 ] && ok || bad "H1: the box calls mc_rebase once (got $(NREB); log: $(tail -4 "$LOGF"))"
[ -s "$T/agent.txt" ] && bad "H1: a clean merge buys no agent round ($(cat "$T/agent.txt"))" || ok
[ "$(printf '%s' "$FIXREC" | jq -r '.mechanicals')" = 1 ] && [ "$(printf '%s' "$FIXREC" | jq -r '.fixrounds')" = 0 ] && ok \
  || bad "H1: the box's record has mechanicals=1 fixrounds=0 ($FIXREC)"
printf '%s' "$FIXREC" | jq -e 'has("hop_rung") | not' >/dev/null && ok || bad "H1: FIX_RECORD carries no hop_rung ($FIXREC)"
FINISH; IDENT=("${LANE[@]}"); REPOS="$T/norepos"
RUN
[ "$(ROWF '.[0].status')" = adopted ] && ok || bad "H1: the lane machine adopts the row (got $(ROWF '.[0].status'))"
[ "$(REC 94 .mechanicals)" = 1 ] && [ "$(REC 94 .fixrounds)" = 0 ] && ok \
  || bad "H1: the adopted record spent 0 fix rounds (mech $(REC 94 .mechanicals), fix $(REC 94 .fixrounds))"
[ "$(NROWS)" = 1 ] && ok || bad "H1: nothing else queued (rows: $(ROWS | jq -c 'map({id,status})'))"
# ---- H2. main still conflicts on the box: the paid round runs only then
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 94 "$CONF"; SEED 94 0
RUN
echo 1 > "$T/rebase-rc"; printf 'a.txt\n' > "$T/rebase-out"
BOXRUN
[ "$(NREB)" = 1 ] && [ -s "$T/agent.txt" ] && ok || bad "H2: a conflict on the box runs the fix round after mc_rebase (rebase $(NREB), agent: $(wc -l < "$T/agent.txt"); log: $(tail -4 "$LOGF"))"

# ============================================================================
# L. A LOST WRITE-BACK AFTER AN ADOPT
# ============================================================================
# ---- L1. the row is adopted, the lane machine's record never had the round
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 91 head-not-reapproved; SEED 91 0
NOWI=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
RO=$(jq -nc '{project:"tproj",rkey:"tproj-TK-91",mechanicals:0,fixrounds:1,regens:0,rebuilds:0,outcome:"",
  attempts:[{rung:"fixround",detail:"pushed 1234abcd"}]}')
jq -nc --arg up "$NOWI" --arg ro "$RO" \
  '[{id:1,project:"tproj",cap_key:"tproj-TK-91",box:"box-tproj",args:["tproj","o-tproj-91","head-not-reapproved","x","-","TK-91"],
     record_in:null,hotfix:0,status:"adopted",attempt:1,claimed_by:"box-tproj",result:"done",record_out:$ro,enqueued_at:$up,updated_at:$up}]' \
  > "$FRW/rows.json"
RUN
[ "$(REC 91 .fixrounds)" = 1 ] && ok || bad "L1: the record is restored from the adopted row (fixrounds $(REC 91 .fixrounds); log: $(tail -4 "$LOGF"))"
grep -q 'restored from the adopted row' "$LOGF" && ok || bad "L1: the heal is said (log: $(tail -4 "$LOGF"))"
[ "$(NROWS)" = 1 ] && ok || bad "L1: no second paid round is queued (rows: $(ROWS | jq -c 'map({id,status})'))"
[ -s "$T/agent.txt" ] && bad "L1: no agent runs ($(cat "$T/agent.txt"))" || ok
# 3 GETs on this tick: the in-flight poll, and two reads elsewhere in the tick.
# The heal reads the poll's answer; a heal that asks the queue again is a 4th.
L1_GETS=$(grep -c '^GET /api/fix-rounds$' "$FRW/requests.log")
[ "$L1_GETS" = 3 ] && ok || bad "L1: the heal reuses the poll's GET (expected 3 GETs, got $L1_GETS)"
# ---- L2. the hub saves its own adopt, so it has no write-back to lose: no heal
#      (an adopted row is never re-acted on the hub, BH-2530 N2)
RESET; IDENT=("${HUB[@]}"); REPOS="$T/norepos"; PARK 91 head-not-reapproved; SEED 91 0
jq -nc --arg up "$NOWI" --arg ro "$RO" \
  '[{id:1,project:"tproj",cap_key:"tproj-TK-91",box:"box-tproj",args:["tproj","o-tproj-91","head-not-reapproved","x","-","TK-91"],
     record_in:null,hotfix:0,status:"adopted",attempt:1,claimed_by:"box-tproj",result:"done",record_out:$ro,enqueued_at:$up,updated_at:$up}]' \
  > "$FRW/rows.json"
RUN
[ "$(REC 91 .fixrounds)" = 0 ] && ok || bad "L2: the hub does not restore the record from an adopted row (fixrounds $(REC 91 .fixrounds); log: $(tail -4 "$LOGF"))"
grep -q 'restored from the adopted row' "$LOGF" && bad "L2: the hub says no heal (log: $(tail -4 "$LOGF"))" || ok
# ---- L3. a terminal answer was acted on at its adopt: a lane machine never heals from it
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 91 head-not-reapproved; SEED 91 0
jq -nc --arg up "$NOWI" --arg ro "$RO" \
  '[{id:1,project:"tproj",cap_key:"tproj-TK-91",box:"box-tproj",args:["tproj","o-tproj-91","head-not-reapproved","x","-","TK-91"],
     record_in:null,hotfix:0,status:"adopted",attempt:1,claimed_by:"box-tproj",result:"terminal",record_out:$ro,enqueued_at:$up,updated_at:$up}]' \
  > "$FRW/rows.json"
RUN
[ "$(REC 91 .fixrounds)" = 0 ] && ok || bad "L3: no heal from a terminal row (fixrounds $(REC 91 .fixrounds); log: $(tail -4 "$LOGF"))"
grep -q 'restored from the adopted row' "$LOGF" && bad "L3: no heal is said (log: $(tail -4 "$LOGF"))" || ok

# ============================================================================
# G. RUNG 1b (REGENERATE) ON A LANE MACHINE
# ============================================================================
# ---- G1. no clone: no mc_rebase, regens unchanged, the displaced fix round queued
RESET; IDENT=("${LANE[@]}"); REPOS="$T/norepos"; PARK 95 red-twice; SEED 95 1
RUN
[ "$(NREB)" = 0 ] && ok || bad "G1: rung 1b calls no mc_rebase with no clone ($(cat "$T/rebase.txt"); log: $(tail -4 "$LOGF"))"
[ "$(REC 95 '.regens // 0')" = 0 ] && ok || bad "G1: regens is unchanged (got $(REC 95 .regens))"
grep -q 'rung 1b is not run on a lane machine with no clone of tproj' "$LOGF" && ok || bad "G1: the skip is said (log: $(tail -4 "$LOGF"))"
[ "$(NROWS)" = 1 ] && ok || bad "G1: the regenerate rung is queued for the box (rows: $(ROWS))"
[ "$(ROWF '.[0].record_in | fromjson | .hop_rung')" = regen:fix-round ] && ok || bad "G1: the row carries hop_rung=regen:fix-round (record_in: $(ROWF '.[0].record_in'))"
# ---- G2. with a clone: rung 1b runs
RESET; IDENT=("${LANE[@]}"); PARK 95 red-twice; SEED 95 1
echo 1 > "$T/rebase-rc"; printf 'a.txt\n' > "$T/rebase-out"
RUN
[ "$(NREB)" = 1 ] && ok || bad "G2: rung 1b with a clone calls mc_rebase (got $(NREB); log: $(tail -4 "$LOGF"))"

# ============================================================================
# K1. THE CLASS TABLE
# ============================================================================
# The repo's own module, by path: the scratch copy under $H is what the lane
# sources above, and this reads the file that copy came from (an orphan check
# counts only a suite that names the script, BH-1253).
K=$( eval "$(awk '/^br_setup_class\(\) \{/,/^}/' "$DIR/bin/lib/br/lane.sh")"
  while IFS='|' read -r want text; do
    got=$(br_setup_class "$text" 2>/dev/null) || got="(rc $?)"
    [ "$got" = "$want" ] || printf '%s <- [%s] got [%s]\n' "$want" "$text" "$got"
  done <<'EOF'
no-clone|there is no local clone at /root/repos/x for the fix round to work in
mc-rebase-setup|mc_rebase rc=4 on example-org/x — a clone or credential problem; see the credential line in merge-conductor.log
mc-rebase-setup|mc_rebase rc=99 on example-org/x — a clone or credential problem
worktree|worktree add failed for origin/ticket/x in /root/repos/x
no-owner-box|no non-hub box owns x in fleet.conf (box-for.sh answered 'hubx') — the hub runs no agent build work
no-branch|no repo/branch could be resolved for https://github.com/o/x/pull/1 even after re-reading it
ref-unresolved|origin/b will not resolve in /root/repos/x
other|a local clone exists
other|
EOF
)
[ -z "$K" ] && grep -q '^br_setup_class() {' "$DIR/bin/lib/br/lane.sh" && ok || bad "K1: the class table (mismatches: ${K:-br_setup_class is not defined})"

# ============================================================================
# A. THE RATE ALERT (N = 2 by the code default)
# ============================================================================
# The real setup block on a lane machine WITH a clone: mc_rebase answers rc 4.
APARK() { IDENT=("${LANE[@]}"); PARK 94 "$CONF"; echo 4 > "$T/rebase-rc"; }
# ---- A1. two blocks in the hour: rows, no alert
RESET; APARK; SEED 94 0
RUN; RUN
[ "$(grep -c . "$SB" 2>/dev/null)" = 2 ] && ok || bad "A1: each block is one row ($(cat "$SB" 2>/dev/null))"
[ "$(awk -F'\t' '$2=="fly" && $3=="mc-rebase-setup" && $4=="mechanical" && $5=="o-tproj-94"' "$SB" | grep -c .)" = 2 ] && ok \
  || bad "A1: the rows carry placement, class, rung and rkey ($(cat "$SB" 2>/dev/null))"
[ "$(NALERT "$AID")" = 0 ] && ok || bad "A1: 2 blocks do not alert ($(cat "$T/lane-alert.txt"))"
# ---- A2. the third: ONE alert naming placement, setting and class
RUN
cp "$SB" "$T/a2.tsv" 2>/dev/null
[ "$(NALERT "$AID")" = 1 ] && ok || bad "A2: 3 blocks send one alert ($(cat "$T/lane-alert.txt"))"
AL=$(grep -- "--id $AID " "$T/lane-alert.txt")
case "$AL" in *"tproj: 3 rung(s) could not START in the last hour on placement fly (lane_placement.blocked-resolver)"*"[mc-rebase-setup]"*"setting-set lane_placement.blocked-resolver hub"*) ok ;;
  *) bad "A2: the alert names count, placement, setting, class and the kill row ($AL)" ;; esac
grep -q -- '--severity warn ' <<<"$AL" && ok || bad "A2: one project over N is a warning ($AL)"
[ -e "$MARK" ] && ok || bad "A2: the hourly marker is written"
grep -qx '[0-9]\{10,\}' "$MARK" && ok || bad "A2: the marker holds the epoch ($(cat "$MARK"))"
# ---- A3. ten rows in the hour: still one alert
for _ in 1 2 3 4 5 6; do tail -n 1 "$T/a2.tsv" >> "$SB"; done
RUN
[ "$(grep -c . "$SB")" = 10 ] && ok || bad "A3: ten rows in the file (got $(grep -c . "$SB"))"
[ "$(NALERT "$AID")" = 1 ] && ok || bad "A3: still ONE alert in the hour ($(cat "$T/lane-alert.txt"))"
# ---- A4. two of three rows are older than an hour: no alert, old rows pruned
RESET; APARK; SEED 94 0
OLD=$(( $(date -u +%s) - 7200 ))
awk -F'\t' -v OFS='\t' -v t="$OLD" 'NR<=2 {$1=t; print}' "$T/a2.tsv" > "$SB"
RUN
[ "$(NALERT "$AID")" = 0 ] && ok || bad "A4: old rows do not count ($(cat "$T/lane-alert.txt"))"
[ "$(grep -c . "$SB")" = 1 ] && ! grep -q "^$OLD	" "$SB" && ok || bad "A4: rows older than 3600 s are pruned ($(cat "$SB"))"
# ---- A5. three hub rows plus one fly block: the fly count is 1
RESET; APARK; SEED 94 0
awk -F'\t' -v OFS='\t' '{$2="hub"; print}' "$T/a2.tsv" > "$SB"
RUN
[ "$(grep -c . "$SB")" = 4 ] && ok || bad "A5: the hub rows stay in the file ($(cat "$SB"))"
[ -s "$T/lane-alert.txt" ] && grep -q -- '--id resolver-setup-blocked-' "$T/lane-alert.txt" \
  && bad "A5: rows of the other placement do not count ($(cat "$T/lane-alert.txt"))" || ok
# ---- A6. a marker older than the 24 h hold: a second alert
RESET; APARK; SEED 94 0
cp "$T/a2.tsv" "$SB"; mkdir -p "$(dirname "$MARK")"; : > "$MARK"; touch -d '-25 hours' "$MARK"
RUN
[ "$(NALERT "$AID")" = 1 ] && ok || bad "A6: an old marker lets one alert through ($(cat "$T/lane-alert.txt"))"
# ---- A7. the marker's epoch is the hold, not its mtime
RESET; APARK; SEED 94 0
cp "$T/a2.tsv" "$SB"; mkdir -p "$(dirname "$MARK")"; echo $(( $(date -u +%s) - 90000 )) > "$MARK"
RUN
[ "$(NALERT "$AID")" = 1 ] && ok || bad "A7: an old epoch in a fresh file lets one alert through ($(cat "$T/lane-alert.txt"))"
RESET; APARK; SEED 94 0
cp "$T/a2.tsv" "$SB"; date -u +%s > "$MARK"; touch -d '-25 hours' "$MARK"
RUN
[ "$(NALERT "$AID")" = 0 ] && ok || bad "A7: a fresh epoch in an old file holds the alert ($(cat "$T/lane-alert.txt"))"
# ---- A8. two projects over N on one placement: warn (plan), count in the text, per-project id
RESET; APARK; SEED 94 0
cp "$T/a2.tsv" "$SB"; mkdir -p "$H/state/blocked-resolver/oproj"; cp "$T/a2.tsv" "$H/state/blocked-resolver/oproj/setup-blocked.tsv"
RUN
AL=$(grep -- "--id $AID " "$T/lane-alert.txt")
grep -q -- '--severity warn ' <<<"$AL" && grep -q '2 projects are over 2 on placement fly' <<<"$AL" && ok \
  || bad "A8: two projects over N send warn with the count ($AL)"
# and the knob is read: N=10 holds 4 rows silent
RESET; APARK; SEED 94 0; BRENV=(BR_SETUP_BLOCKED_ALERT_N=10)
cp "$T/a2.tsv" "$SB"
RUN
[ "$(NALERT "$AID")" = 0 ] && ok || bad "A8b: BR_SETUP_BLOCKED_ALERT_N=10 is read ($(cat "$T/lane-alert.txt"))"
# ---- A9. the hold is 24 h (comment 6315926752): a 2-hour-old epoch still holds
RESET; APARK; SEED 94 0
cp "$T/a2.tsv" "$SB"; mkdir -p "$(dirname "$MARK")"; echo $(( $(date -u +%s) - 7200 )) > "$MARK"
RUN
[ "$(NALERT "$AID")" = 0 ] && ok || bad "A9: a 2-hour-old alert holds the next one for 24 h ($(cat "$T/lane-alert.txt"))"
# and the knob is read: BR_SETUP_BLOCKED_ALERT_HOLD_S=3600 lets that one through
RESET; APARK; SEED 94 0; BRENV=(BR_SETUP_BLOCKED_ALERT_HOLD_S=3600)
cp "$T/a2.tsv" "$SB"; mkdir -p "$(dirname "$MARK")"; echo $(( $(date -u +%s) - 7200 )) > "$MARK"
RUN
[ "$(NALERT "$AID")" = 1 ] && ok || bad "A9: BR_SETUP_BLOCKED_ALERT_HOLD_S=3600 is read ($(cat "$T/lane-alert.txt"))"
# ---- A10. rc=4 on four PRs of one project: ONE project alert, not one page per PR
# (comment 6315926752). The first two parks page as before; the third trips the
# rate alert and sends no page of its own; the fourth sends nothing new.
NPAGE() { grep -v -- '--id ' "$T/lane-alert.txt" | grep -c "rung cannot START"; }
RESET; IDENT=("${LANE[@]}"); echo 4 > "$T/rebase-rc"
for n in 88 89 94; do SEED "$n" 0; PARK "$n" "$CONF"; RUN; done
[ "$(NPAGE)" = 2 ] && ok || bad "A10: only the parks before the rate alert page ($(cat "$T/lane-alert.txt"))"
[ "$(NALERT "$AID")" = 1 ] && ok || bad "A10: three PRs send one project alert ($(cat "$T/lane-alert.txt"))"
SEED 95 0; PARK 95 "$CONF"; RUN
[ "$(NPAGE)" = 2 ] && [ "$(NALERT "$AID")" = 1 ] && ok \
  || bad "A10: a fourth PR inside the hold sends no page and no alert ($(cat "$T/lane-alert.txt"))"
[ "$(REC 95 '.attempts | map(select(.action == "mechanical-blocked")) | length')" = 1 ] && ok \
  || bad "A10: the held park still writes its record ($(STATEJSON tproj-TK-95))"

# ============================================================================
# D. THE DISPATCH PLACEMENT WARNING
# ============================================================================
# The placement read is stubbed (lp_decide from $T/placement); pl_dispatch is
# recorded. Everything else is the real --dispatch verb.
cat > "$H/bin/lib/project-lanes.sh" <<EOF
lp_decide() { LP_PLACE=\$(cat "$T/placement" 2>/dev/null || echo hub); LP_WHY="lane_placement.\$1=\$LP_PLACE"; return 0; }
pl_dispatch() { printf '%s\n' "\$*" >> "$T/dispatch.txt"; echo "\$1 dispatch: fixture"; return 0; }
EOF
DSEED() { # DSEED <placement-col> <age-s> — tproj gets the A2 rows, oproj one more
  local t=$(( $(date -u +%s) - $2 ))
  mkdir -p "$H/state/blocked-resolver/tproj" "$H/state/blocked-resolver/oproj"
  awk -F'\t' -v OFS='\t' -v t="$t" -v pl="$1" 'NR<=2 {$1=t; $2=pl; print}' "$T/a2.tsv" > "$SB"
  awk -F'\t' -v OFS='\t' -v t="$t" -v pl="$1" 'NR==1 {$1=t; $2=pl; $3="no-clone"; print}' "$T/a2.tsv" \
    > "$H/state/blocked-resolver/oproj/setup-blocked.tsv"
}
DRUN() { : > "$T/dispatch.txt"; IDENT=("${HUB[@]}"); DRC=0; RUN --dispatch || DRC=$?; }
# ---- D1. placed fly, three fly rows over two projects: one warning
RESET; echo fly > "$T/placement"; DSEED fly 60
DRUN
[ "$(NALERT lane-placement-unready-blocked-resolver)" = 1 ] && ok || bad "D1: one placement warning ($(cat "$T/lane-alert.txt"); log: $(tail -3 "$LOGF"))"
DW=$(grep -- '--id lane-placement-unready-blocked-resolver ' "$T/lane-alert.txt")
case "$DW" in *"lane_placement.blocked-resolver=fly"*"3 rung(s) could not START"*"oproj:1"*"tproj:2"*"setting-set lane_placement.blocked-resolver hub"*) ok ;;
  *) bad "D1: the warning names the count, projects and the kill row ($DW)" ;; esac
[ "$DRC" = 0 ] && [ -s "$T/dispatch.txt" ] && ok || bad "D1: the warning does not stop the dispatch (rc $DRC, dispatch: $(cat "$T/dispatch.txt"))"
# ---- D2. placed fly, only hub rows: none
RESET; echo fly > "$T/placement"; DSEED hub 60
DRUN
[ "$(NALERT lane-placement-unready-blocked-resolver)" = 0 ] && ok || bad "D2: hub rows do not warn ($(cat "$T/lane-alert.txt"))"
[ "$DRC" = 0 ] && [ -s "$T/dispatch.txt" ] && ok || bad "D2: the dispatch runs (rc $DRC)"
# ---- D3. placed fly, fly rows older than an hour: none
RESET; echo fly > "$T/placement"; DSEED fly 7200
DRUN
[ "$(NALERT lane-placement-unready-blocked-resolver)" = 0 ] && ok || bad "D3: old fly rows do not warn ($(cat "$T/lane-alert.txt"))"
# ---- D4. placed hub, fly rows: none
RESET; echo hub > "$T/placement"; DSEED fly 60
DRUN
[ "$(NALERT lane-placement-unready-blocked-resolver)" = 0 ] && ok || bad "D4: placement hub does not warn ($(cat "$T/lane-alert.txt"))"
[ "$DRC" = 0 ] && [ -s "$T/dispatch.txt" ] && ok || bad "D4: the dispatch runs (rc $DRC)"

echo "blocked-resolver-lane-no-clone.bh-7630: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
