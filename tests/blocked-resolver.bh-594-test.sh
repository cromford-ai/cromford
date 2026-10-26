#!/bin/bash
# tests/blocked-resolver.bh-594-test.sh — BH-594: the resolver must not burn a
# rung on a hub-no-build refusal, its fix rounds run on the box that OWNS the
# project, and it waits while the conductor's head-bound re-review is in flight.
#
# THE INCIDENT. On 2026-09-16 the hub's bin/agent-call.sh started refusing the
# execute stage (BH-393, rc 77 AGENT_CALL_REFUSED hub-no-build). The resolver's
# fix round read that refusal as a round that ran and produced nothing, spent
# the park's one fix round, and went straight to REBUILD FRESH, which closed
# project-5 #1740 (20:24Z) and #1813 (20:54Z) over a machine problem.
#
# Every case drives the REAL script: a whole tick through RUN, or the owning
# box's `--fix-here` entry exactly as bin/fix-round-claim.sh invokes it.
# Assertions are on the record JSON, the fix_round_jobs rows (the fake worker,
# tests/lib/fake-fix-round-worker.bh-2530.py), the beat/alert/gh/ssh/agent logs
# and the git remote.
#
# Cases:
#   1-4    agent-call rc 77/78 is a setup block, not a spent rung (rc 1 still spends)
#   5      hub_box_builds_here
#   6-10   the hub queues the fix round for the owning box (BH-2674), and when
#          it must not
#   11-12  the owning box's --fix-here entry: push, and a refusal carried back
#   13-16  the in-flight re-review wait, and what must NOT wait
# Run from anywhere: tests/blocked-resolver.bh-594-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE so bin/test-impact.sh
# selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
# The hub identity lib and the heartbeat lib, both of which the lane sources
# when they are present: this suite is about exactly those two behaviours.
cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/heartbeat.sh" "$H/bin/lib/" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1
# The hub's fix round is a fix_round_jobs row (BH-2674): the fake worker behind a
# `curl` shim, the real transport and the real bin/lib/fix-round-queue.sh.
FRW="$T/frw"; mkdir -p "$FRW" "$H/bin/lib/jobs" || exit 1
cp "$DIR/bin/lib/jobs/req.sh" "$H/bin/lib/jobs/" && cp "$DIR/bin/lib/fix-round-queue.sh" "$H/bin/lib/" || exit 1
printf '#!/bin/bash\nFRW_STATE=%q exec python3 %q "$@"\n' "$FRW" "$DIR/tests/lib/fake-fix-round-worker.bh-2530.py" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl" || exit 1
{ printf 'JOBS_HARNESS=%q; HARNESS_SECRET=test-secret; JOBS_URL=https://jobs.invalid; JOBS_RETRIES=0\n' "$H"
  printf '. %q\n' "$H/bin/lib/jobs/req.sh"
} >> "$H/bin/jobs-client.sh" || exit 1
ROWS() { cat "$FRW/rows.json" 2>/dev/null || echo "[]"; }
ROWF() { ROWS | jq -r "$1"; }

# ---- stubs this suite owns ---------------------------------------------------
# The "agent": records its argv, writes a refusal line into its OUT file ($5)
# when told to, commits a change when told to, and exits with $T/agent-rc.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
[ -f "$T/agent-refuse" ] && cat "$T/agent-refuse" > "\$5"
if [ -f "$T/agent-resolves" ]; then
  printf 'the fix\n' > fix.txt
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -q -m "fix round: answered the findings" >/dev/null 2>&1
fi
exit "\$(cat "$T/agent-rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$H/bin/agent-call.sh"
# beat.sh is RECORDED: "one resolver_setup_blocked event" is a fact about it.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beat.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
# The fake ssh: argv and stdin recorded, canned stdout, canned rc. Never a box.
cat > "$T/fakebin/fake-ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/ssh.txt"
cat > "$T/ssh-stdin.txt"
cat "$T/ssh-out" 2>/dev/null
exit "\$(cat "$T/ssh-rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/fakebin/fake-ssh"
# The same RUN as the fixture's, with the fake ssh in place of the recorder.
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/fake-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
LOGF="$H/logs/blocked-resolver.log"
FLEET_ORIG=$(cat "$H/fleet.conf")
PR91="https://github.com/o/tproj/pull/91"
H91=$(osha ticket/TK-91)
# ONE clock read for the whole suite; every stamp below is derived from it.
NOW=$(date -u +%s)

# RESET — a clean slate for one case: no record, no marker, no checkpoint
# branch, no logs, no stubs armed.
RESET() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/state/merge-conductor/handoff"
  scratch_rm "$H/state/merge-conductor/handoff-released"
  scratch_rm "$H/state/merge-conductor/rereview"
  scratch_rm "$H/state/heartbeat"
  scratch_rm "$H/tmp/brfix"
  rm -f "$H/flags/blocked-resolver-observe" "$H/locks/blocked-resolver-cron.lock"
  : > "$LOGF"; : > "$H/logs/merge-conductor.log"; : > "$H/logs/ALERTS.log"
  : > "$T/agent.txt"; : > "$T/beat.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"
  : > "$T/ssh.txt"; : > "$T/ssh-stdin.txt"; : > "$T/ssh-out"; : > "$T/lane-alert.txt"
  rm -f "$T/agent-refuse" "$T/agent-rc" "$T/agent-resolves" "$T/ssh-rc"
  scratch_rm "$FRW"; mkdir -p "$FRW"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" branch -D brfix/tproj-TK-91 >/dev/null 2>&1
  printf '%s\n' "$FLEET_ORIG" > "$H/fleet.conf"
  printf 'ticket/TK-91\n' > "$T/prbranch"; printf '%s' "$H91" > "$T/prhead"
  printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
  BRENV=()
}
REC() { cat "$H/state/blocked-resolver/tproj/tproj-TK-91.json" 2>/dev/null || echo "{}"; }
RECF() { REC | jq -r "$1" 2>/dev/null; }
PARK91() { ROW "o/tproj#91" "head-not-reapproved" "$PR91"; }
WORKTREES() { git -C "$T/repos/tproj" worktree list --porcelain 2>/dev/null | grep -c '^worktree '; }

# ============================================================================
# 1-4. agent-call rc 77 / 78 IS A SETUP BLOCK, NOT A SPENT RUNG.
# ============================================================================
# ---- 1. rc 77, the hub-no-build refusal (the REPRO)
RESET; PARK91
printf 'AGENT_CALL_REFUSED hub-no-build the execute lane does not run on the hub\n' > "$T/agent-refuse"
echo 77 > "$T/agent-rc"
RUN
[ -s "$T/agent.txt" ] && ok || bad "1: the round must reach the agent call (log: $(tail -3 "$LOGF"))"
[ "$(RECF '.fixrounds // 0')" = 0 ] && ok \
  || bad "1: an rc 77 refusal must NOT spend the fix round (fixrounds=$(RECF '.fixrounds'), last attempt: $(RECF '.attempts[-1].detail'))"
[ "$(RECF '.attempts[-1].action')" = fix-round-blocked ] && ok \
  || bad "1: the attempt must be fix-round-blocked (got '$(RECF '.attempts[-1].action')')"
RECF '.attempts[-1].detail' | grep -q 'rc=77' && ok || bad "1: the attempt must name rc=77 (got '$(RECF '.attempts[-1].detail')')"
RECF '.attempts[-1].detail' | grep -q 'AGENT_CALL_REFUSED hub-no-build' && ok \
  || bad "1: the attempt must quote the refusal line (got '$(RECF '.attempts[-1].detail')')"
grep -q '"event":"resolver_setup_blocked"' "$T/beat.txt" && ok || bad "1: one resolver_setup_blocked event must be beaten (beats: $(cat "$T/beat.txt"))"
[ -s "$T/closed.txt" ] && bad "1: a refusal must NOT close the PR (closed: $(cat "$T/closed.txt"))" || ok
[ -s "$T/queue.txt" ] && bad "1: a refusal must NOT enqueue a rebuild (queue: $(cat "$T/queue.txt"))" || ok
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-91.setup-alerted" ] && ok || bad "1: the setup episode marker must be written"
[ -s "$T/lane-alert.txt" ] && ok || bad "1: a setup block must page once"

# ---- 2. rc 78, the no-tools refusal
RESET; PARK91
printf 'AGENT_CALL_REFUSED no-tools contract cannot be enforced on runner codex\n' > "$T/agent-refuse"
echo 78 > "$T/agent-rc"
RUN
[ "$(RECF '.fixrounds // 0')" = 0 ] && ok || bad "2: an rc 78 refusal must NOT spend the fix round (fixrounds=$(RECF '.fixrounds'))"
[ "$(RECF '.attempts[-1].action')" = fix-round-blocked ] && ok || bad "2: the attempt must be fix-round-blocked (got '$(RECF '.attempts[-1].action')')"
RECF '.attempts[-1].detail' | grep -q 'rc=78' && ok || bad "2: the attempt must name rc=78"
[ -s "$T/closed.txt" ] && bad "2: an rc 78 refusal must NOT close the PR" || ok
[ -s "$T/queue.txt" ] && bad "2: an rc 78 refusal must NOT enqueue a rebuild" || ok

# ---- 3. a REVIEW park refused with rc 77 gives its head mark back
#         (driven through --fix-here, which runs the same br_fix_round with the
#         park's reason passed straight in)
RESET
REVB64=$(printf 'Findings.\n\nVERDICT: REQUEST_CHANGES\n\n---\n%sabc.' 'Automated harness review (Fable) of ' | base64 -w0)
mv "$T/fakebin/gh" "$T/fakebin/gh-base"
# The reviews list as GitHub's REST answers it (BH-2200 moved the read onto the
# REST contract, bin/lib/gh-rest.sh): the same one lane-footer review at H91.
# BH-8419: the lane's review is the App's (cromford[bot], type Bot).
REVJSON=$(jq -nc --arg c "$H91" --arg b "$(printf '%s' "$REVB64" | base64 -d)" \
  '[{user:{login:"cromford[bot]", type:"Bot"}, author_association:"MEMBER", commit_id:$c, state:"COMMENTED", body:$b}]')
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET"*"/pulls/91/reviews"*) printf 'HTTP/2 200\r\nserver: x\r\n\r\n%s' '$REVJSON'; exit 0 ;;
esac
exec "$T/fakebin/gh-base" "\$@"
EOF
chmod +x "$T/fakebin/gh"
printf 'AGENT_CALL_REFUSED hub-no-build the execute lane does not run on the hub\n' > "$T/agent-refuse"
echo 77 > "$T/agent-rc"
jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$T/rec-in.json"
FH3=$( ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
         bash "$H/bin/blocked-resolver.sh" --fix-here tproj o-tproj-91 review-changes-requested "$PR91" - TK-91 < "$T/rec-in.json" ) 2>>"$T/run.log")
[ -s "$T/agent.txt" ] && ok || bad "3: the review round must reach the agent call (log: $(tail -4 "$LOGF"))"
REC3=$(grep '^FIX_RECORD ' <<<"$FH3" | head -1 | cut -d' ' -f2 | base64 -d 2>/dev/null)
[ -n "$REC3" ] && ok || bad "3: --fix-here must carry the record back (stdout: $FH3)"
[ "$(jq -r --arg h "$H91" '(.review_fix_heads // []) | index($h) // "absent"' <<<"$REC3" 2>/dev/null)" = absent ] && ok \
  || bad "3: a refused review round must UN-mark its head, or that head is never offered again (review_fix_heads: $(jq -c '.review_fix_heads' <<<"$REC3" 2>/dev/null))"
grep -q '^FIX_RESULT setup-blocked ' <<<"$FH3" && ok || bad "3: the refusal must come back as setup-blocked (stdout: $FH3)"
mv -f "$T/fakebin/gh-base" "$T/fakebin/gh"

# ---- 4. NEGATIVE: a real failure (rc 1) still spends the rung, as today
RESET; PARK91
echo 1 > "$T/agent-rc"
RUN
[ "$(RECF '.fixrounds // 0')" = 1 ] && ok || bad "4: an rc 1 round is a real failed round and must spend the rung (fixrounds=$(RECF '.fixrounds'))"
grep -q 'agent rc=1, verify rc=' "$LOGF" && ok || bad "4: the failed round must say so (log: $(tail -3 "$LOGF"))"

# ============================================================================
# 5. hub_box_builds_here — the identity question, asked of hub-box.sh
# ============================================================================
H5="$T/h5"; mkdir -p "$H5/logs"
HB5() { ( unset HUB_BUILD_OK BOX_NAME HUB_BOX_NAME; export HARNESS="$H5" "$@"
          . "$DIR/bin/lib/hub-box.sh" && hub_box_builds_here ); }
HB5 HUB_BOX_NAME=hubx BOX_NAME=hubx; [ $? = 1 ] && ok || bad "5: the hub must answer rc 1 (may NOT build here)"
HB5 HUB_BOX_NAME=hubx BOX_NAME=hubx HUB_BUILD_OK=1; [ $? = 0 ] && ok || bad "5: HUB_BUILD_OK=1 must let the hub build here"
HB5 HUB_BOX_NAME=hubx BOX_NAME=boxy; [ $? = 0 ] && ok || bad "5: a non-hub box must build here"
[ -e "$H5/logs/ALERTS.log" ] && bad "5: the routing question must write no ALERTS line ($(cat "$H5/logs/ALERTS.log"))" || ok

# ============================================================================
# 6-10. THE HUB QUEUES THE FIX ROUND FOR THE OWNING BOX (BH-2674)
# ============================================================================
HUBENV=(HUB_BOX_NAME=hubx BOX_NAME=hubx)
# ---- 6. one queued row for the owning box, the six args, the hub's record; no ssh
RESET; PARK91; BRENV=("${HUBENV[@]}")
WT0=$(WORKTREES)
RUN
[ "$(ROWS | jq 'length')" = 1 ] && ok || bad "6: the hub must write ONE fix_round_jobs row (rows: $(ROWS); log: $(tail -4 "$LOGF"))"
[ "$(ROWF '.[0].status')" = queued ] && [ "$(ROWF '.[0].box')" = box-tproj ] && ok \
  || bad "6: the row is queued for the owning box (got $(ROWF '.[0] | {status,box}' | tr -d '\n'))"
[ "$(ROWF '.[0].args | join("|")')" = "tproj|o-tproj-91|head-not-reapproved|$PR91|-|TK-91" ] && ok \
  || bad "6: the row carries the six --fix-here args (got $(ROWF '.[0].args'))"
[ "$(ROWF '.[0].record_in | fromjson | .project' 2>/dev/null)" = tproj ] && ok || bad "6: the hub's record rides as record_in (got $(ROWF '.[0].record_in' | head -c 200))"
[ -s "$T/ssh.txt" ] && bad "6: the hub must not ssh to the box ($(cat "$T/ssh.txt"))" || ok
[ -s "$T/agent.txt" ] && bad "6: NOTHING may run on the hub — agent-call was invoked: $(cat "$T/agent.txt")" || ok
[ "$(WORKTREES)" = "$WT0" ] && ok || bad "6: the hub must not create a worktree ($(WORKTREES) vs $WT0)"
[ "$(RECF '.fixrounds // 0')" = 0 ] && ok || bad "6: queuing spends nothing (fixrounds=$(RECF .fixrounds))"
[ -s "$T/closed.txt" ] && bad "6: queuing closes nothing" || ok

# ---- 7. the worker down: no row, no ssh, nothing spent, the NOT-queued line
RESET; PARK91; BRENV=("${HUBENV[@]}")
touch "$FRW/down.POST"
RUN
rm -f "$FRW/down.POST"
[ "$(ROWS | jq 'length')" = 0 ] && ok || bad "7: no row when the write fails ($(ROWS))"
[ -s "$T/ssh.txt" ] && bad "7: no ssh fallback ($(cat "$T/ssh.txt"))" || ok
[ "$(RECF '.fixrounds // 0')" = 0 ] && [ "$(RECF '(.attempts // []) | length')" = 0 ] && ok \
  || bad "7: an unqueued round spends nothing (record: $(REC | head -c 300))"
grep -q 'fix round NOT queued — jobs DB unreachable, re-offered next tick' "$LOGF" && ok || bad "7: the failure is said (log: $(tail -3 "$LOGF"))"
[ -s "$T/closed.txt" ] && bad "7: nothing closed" || ok
[ -s "$T/queue.txt" ] && bad "7: nothing enqueued" || ok

# ---- 7b. the box finished done with garbage for a record: the hub's record is kept
RESET; PARK91; BRENV=("${HUBENV[@]}")
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$H/state/blocked-resolver/tproj/tproj-TK-91.json"
REC7B=$(REC)
jq -nc --arg u "$PR91" '[{id:1,project:"tproj",cap_key:"tproj-TK-91",box:"box-tproj",args:["tproj","o-tproj-91","head-not-reapproved",$u,"-","TK-91"],
  record_in:null,hotfix:0,status:"done",attempt:1,claimed_by:"box-tproj",result:"done",record_out:"not json",
  enqueued_at:"2026-09-27T00:00:00Z",updated_at:"2026-09-27T00:00:00Z"}]' > "$FRW/rows.json"
RUN
[ "$(REC)" = "$REC7B" ] && ok || bad "7b: an unparseable record_out must not overwrite the hub's record ($(REC))"
grep -q 'not a record for tproj' "$LOGF" && ok || bad "7b: the refusal to adopt must be said (log: $(tail -3 "$LOGF"))"
[ "$(ROWF '.[0].status')" = adopted ] && ok || bad "7b: the row is still adopted (got $(ROWF '.[0].status'))"

# ---- 8. the owner is the hub itself: never ssh'd
RESET; PARK91; BRENV=("${HUBENV[@]}")
printf 'tproj o/tproj - - 2 local 100.0.0.9\n' > "$H/fleet.conf"
RUN
[ -s "$T/ssh.txt" ] && bad "8: an owner of 'local' must never be ssh'd ($(cat "$T/ssh.txt"))" || ok
[ "$(RECF '.attempts[-1].action')" = fix-round-blocked ] && ok || bad "8: an owner of 'local' is a setup block (got '$(RECF '.attempts[-1].action')'; log: $(tail -3 "$LOGF"))"
[ -s "$T/agent.txt" ] && bad "8: and nothing runs on the hub either" || ok
RESET; PARK91; BRENV=("${HUBENV[@]}")
printf 'tproj o/tproj - - 2 hubx 100.0.0.9\n' > "$H/fleet.conf"
RUN
[ -s "$T/ssh.txt" ] && bad "8b: an owner named by the hub's fleet name must never be ssh'd" || ok
[ "$(RECF '.fixrounds // 0')" = 0 ] && ok || bad "8b: nothing spent"

# ---- 9. HUB_BUILD_OK=1: the local path, no hop
RESET; PARK91; BRENV=("${HUBENV[@]}" HUB_BUILD_OK=1)
RUN
[ -s "$T/ssh.txt" ] && bad "9: HUB_BUILD_OK=1 must not hop ($(cat "$T/ssh.txt"))" || ok
[ -s "$T/agent.txt" ] && ok || bad "9: HUB_BUILD_OK=1 runs the round locally (log: $(tail -3 "$LOGF"))"

# ---- 10. a non-hub box: the local path, today's behaviour
RESET; PARK91; BRENV=(HUB_BOX_NAME=hubx BOX_NAME=boxy)
RUN
[ -s "$T/ssh.txt" ] && bad "10: a non-hub box must not hop ($(cat "$T/ssh.txt"))" || ok
[ -s "$T/agent.txt" ] && ok || bad "10: a non-hub box runs the round locally"

# ============================================================================
# 11-12. THE OWNING BOX'S --fix-here ENTRY
# ============================================================================
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$H/bin/blocked-resolver.sh" --fix-here tproj o-tproj-91 head-not-reapproved "$PR91" - TK-91 < "$T/rec-in.json" ) 2>>"$T/run.log"; }
# ---- 11. the round runs, pushes, and reports the pushed sha
RESET; touch "$T/agent-resolves"
jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$T/rec-in.json"
BEFORE91=$(osha ticket/TK-91)
FH11=$(FIXHERE)
[ "$(grep -c '^FIX_RESULT ' <<<"$FH11")" = 1 ] && ok || bad "11: exactly one FIX_RESULT line (stdout: $FH11; log: $(tail -4 "$LOGF"))"
grep -qx 'FIX_RESULT done' <<<"$FH11" && ok || bad "11: a pushed round answers FIX_RESULT done (stdout: $FH11)"
[ "$(grep -c '^FIX_RECORD ' <<<"$FH11")" = 1 ] && ok || bad "11: exactly one FIX_RECORD line"
REC11=$(grep '^FIX_RECORD ' <<<"$FH11" | head -1 | cut -d' ' -f2 | base64 -d 2>/dev/null)
D11=$(jq -r '.attempts[-1].detail' <<<"$REC11" 2>/dev/null)
[[ "$D11" =~ ^pushed\ ([0-9a-f]+)\ to\  ]] && ok || bad "11: the carried record must say what was pushed (detail: '$D11')"
AFTER91=$(osha ticket/TK-91)
[ "$AFTER91" != "$BEFORE91" ] && ok || bad "11: the remote branch must have moved"
case "$AFTER91" in "${BASH_REMATCH[1]:-none}"*) ok ;; *) bad "11: the reported sha (${BASH_REMATCH[1]:-none}) must be the remote's new head ($AFTER91)" ;; esac
[ "$(jq -r .fixrounds <<<"$REC11")" = 1 ] && ok || bad "11: the box counts the round it ran"
[ -s "$T/beat.txt" ] && bad "11: the box beats no events — the hub owns them ($(cat "$T/beat.txt"))" || ok
[ -e "$H/state/heartbeat" ] && [ -n "$(ls -A "$H/state/heartbeat" 2>/dev/null)" ] \
  && bad "11: --fix-here must not start a heartbeat ($(ls "$H/state/heartbeat"))" || ok

# ---- 12. the box's own agent-call refuses: carried back as setup-blocked
RESET
jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$T/rec-in.json"
printf 'AGENT_CALL_REFUSED hub-no-build the execute lane does not run on the hub\n' > "$T/agent-refuse"
echo 77 > "$T/agent-rc"
FH12=$(FIXHERE)
R12=$(grep '^FIX_RESULT ' <<<"$FH12" | head -1)
case "$R12" in "FIX_RESULT setup-blocked "*) ok ;; *) bad "12: a refusal on the box answers setup-blocked (stdout: $FH12)" ;; esac
printf '%s' "${R12#FIX_RESULT setup-blocked }" | base64 -d 2>/dev/null | grep -q 'rc=77' && ok \
  || bad "12: the carried reason must name rc=77 (decoded: $(printf '%s' "${R12#FIX_RESULT setup-blocked }" | base64 -d 2>/dev/null))"
[ "$(grep -c '^FIX_RESULT ' <<<"$FH12")" = 1 ] && ok || bad "12: exactly one FIX_RESULT line (stdout: $FH12)"
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-91.setup-alerted" ] && bad "12: the episode marker lives on the hub, not the box" || ok
[ -s "$T/lane-alert.txt" ] && bad "12: the box must not page — the hub does ($(cat "$T/lane-alert.txt"))" || ok
[ -e "$H/locks/blocked-resolver-cron.lock" ] && bad "12: --fix-here must not take the cron single-flight lock" || ok
[ -n "$(ls -A "$H/state/heartbeat" 2>/dev/null)" ] && bad "12: --fix-here must not write a heartbeat" || ok

# ---- 12b. the box's lane is switched off: one FIX_RESULT box-paused, nothing
#           run (BH-2038 reversed the old "no FIX_RESULT at all" on purpose; the
#           other off-switches are tests/blocked-resolver.bh-2038-test.sh, the hub
#           half is tests/fix-round-hub-restart.bh-2530-test.sh N5)
RESET; touch "$H/flags/blocked-resolver-disabled"
jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:0,attempts:[]}' > "$T/rec-in.json"
FH12B=$(FIXHERE)
[ "$(grep -c '^FIX_RESULT ' <<<"$FH12B")" = 1 ] && grep -q '^FIX_RESULT box-paused ' <<<"$FH12B" && ok \
  || bad "12b: a disabled lane answers exactly one FIX_RESULT box-paused ($FH12B)"
[ -s "$T/agent.txt" ] && bad "12b: a disabled lane runs nothing" || ok
rm -f "$H/flags/blocked-resolver-disabled"

# ============================================================================
# 13-16. THE RESOLVER WAITS WHILE A HEAD-BOUND RE-REVIEW IS IN FLIGHT
# ============================================================================
RRDIR="$H/state/merge-conductor/rereview"
RRJ="$RRDIR/o_tproj_91_$H91.json"
ROWHEAD() { # ROWHEAD <state> <reason> <head>
  printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#91" "$1" "$NOW" "$3" "$3" "$2" "$PR91" \
    > "$H/state/merge-conductor/pr-state.tsv"; }
OBS() { touch "$H/flags/blocked-resolver-observe"; RUN; }
# ---- 13. the hand-off's row is back in HEAD_MOVED on the handed-off head
RESET
ROWHEAD HEAD_MOVED "head moved" "$H91"
printf '%s o/tproj#91 BLOCKED_AGENT head-not-reapproved: the moved head was not re-approved — handed to bin/blocked-resolver.sh (agent fix round): %s\n' \
  "$(date -u -d "@$((NOW - 300))" '+%Y-%m-%d %H:%M:%S')Z" "$PR91" > "$H/logs/merge-conductor.log"
mkdir -p "$H/state/merge-conductor/handoff"
printf '%s\t%s\thead-not-reapproved\t%s\n' "$NOW" "$H91" "$PR91" > "$H/state/merge-conductor/handoff/o_tproj_91"
OBS
grep -q "re-review in flight on ${H91:0:8}, resolver waits" "$LOGF" && ok \
  || bad "13: a HEAD_MOVED hand-off on the same head must wait (log: $(tail -4 "$LOGF"))"
grep -q 'recovered from the hand-off' "$LOGF" && bad "13: it must NOT be recovered while the conductor re-reviews it" || ok
grep -q 'WOULD run a fix round' "$LOGF" && bad "13: no candidate may be offered a rung" || ok

# ---- 14. BLOCKED_HUMAN row with a RUNNING job on its head
RESET
ROWHEAD BLOCKED_HUMAN head-not-reapproved "$H91"
mkdir -p "$RRDIR"
jq -nc --argjson p "$$" --argjson t "$NOW" --arg h "$H91" \
  '{status:"running",pid:$p,started_at:$t,finished_at:0,verdict:"-",head_sha:$h,reviewed_sha:$h,out_file:"x"}' > "$RRJ"
OBS
grep -q "re-review in flight on ${H91:0:8}, resolver waits" "$LOGF" && ok \
  || bad "14: a running re-review job must make the resolver wait (log: $(tail -4 "$LOGF"))"
grep -q 'WOULD run a fix round' "$LOGF" && bad "14: no rung while the job runs" || ok

# ---- 15. job json not written yet, its .out.prompt already is (the spawn window)
RESET
ROWHEAD BLOCKED_HUMAN head-not-reapproved "$H91"
mkdir -p "$RRDIR"; : > "${RRJ%.json}.out.prompt"
OBS
grep -q "re-review in flight on ${H91:0:8}, resolver waits" "$LOGF" && ok \
  || bad "15: a prompt with no job file yet is a spawn in progress (log: $(tail -4 "$LOGF"))"

# ---- 16. NEGATIVES: a finished job, and a stale one, must NOT make it wait
RESET
ROWHEAD BLOCKED_HUMAN head-not-reapproved "$H91"
mkdir -p "$RRDIR"
jq -nc --arg h "$H91" --argjson t "$NOW" \
  '{status:"done",pid:1,started_at:$t,finished_at:$t,verdict:"BLOCK",head_sha:$h,reviewed_sha:$h,out_file:"x"}' > "$RRJ"
OBS
grep -q 'resolver waits' "$LOGF" && bad "16a: a DONE job must not hold the park" || ok
grep -q 'WOULD run a fix round' "$LOGF" && ok || bad "16a: the park is offered its rung (log: $(tail -4 "$LOGF"))"
RESET
ROWHEAD BLOCKED_HUMAN head-not-reapproved "$H91"
mkdir -p "$RRDIR"
( exit 0 ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
jq -nc --argjson p "$DEADPID" --argjson t "$((NOW - 600))" --arg h "$H91" \
  '{status:"running",pid:$p,started_at:$t,finished_at:0,verdict:"-",head_sha:$h,reviewed_sha:$h,out_file:"x"}' > "$RRJ"
OBS
grep -q 'resolver waits' "$LOGF" && bad "16b: a STALE job (dead pid) must not hold the park" || ok
grep -q 'WOULD run a fix round' "$LOGF" && ok || bad "16b: the park is offered its rung (log: $(tail -4 "$LOGF"))"
RESET
ROWHEAD BLOCKED_HUMAN head-not-reapproved "$H91"
OBS
grep -q 'resolver waits' "$LOGF" && bad "16c: a park with no job at all must not wait" || ok
grep -q 'WOULD run a fix round' "$LOGF" && ok || bad "16c: the park is offered its rung"

echo "blocked-resolver.bh-594: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
