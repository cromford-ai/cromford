#!/bin/bash
# tests/conductor-detached-lanes-test.sh — the merge conductor's three DETACHED
# lanes: the head-bound re-review (#307), the rebase and the deploy verifier
# (2026-09-14). One claim runs through all of them: a lane job must never hold
# or inherit the lock of the thing that spawned it, and the tick must never
# wait for one.
#
# THE INCIDENT THIS PINS. bin/merge-conductor.sh holds a flock on fd 9 while it
# works on a PR — locks/merge-conductor-<project>.lock for the whole tick until
# 2026-09-15, locks/merge-conductor-<project>-<pr>.lock since (section 2.1).
# Either way a child spawned from inside that section INHERITS fd 9 and
# therefore holds the lock for as long as it lives. On 2026-09-14 a deploy verifier spawned at
# 03:54Z held project-5's lock until 04:02Z: every tick in between logged "an
# earlier conductor tick still holds this project's lock" and skipped the
# project outright. #310 closed the fd at the one verifier spawn site and
# shipped WITHOUT a test; this file is that test, and it covers all three lanes
# so the next lane cannot reintroduce the shape.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q '9>&-' bin/...` passes on a redirection
# attached to the wrong command, and it says nothing about a lane that takes a
# lock of its own. Here a real flock is HELD the way tick_project holds it, a
# real job is spawned under it, and the assertions are (a) the lock is free the
# moment the holder releases it, while the job is still running, and (b) the
# job's own /proc fd table does not contain the lock file.
#
# Run from anywhere: tests/conductor-detached-lanes-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
SLUG=example-org/demo-os
URL="https://github.com/$SLUG/pull/21"

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
# bin/lib/gh-rest.sh rides along with the conductor lib (BH-784): every decision
# read below is a REST call judged on its HTTP status line, and without the lib
# the fail-closed shims answer "unverifiable" to all of them.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
# verdict-parse.sh is mc_rereview's one verdict reader: without it every review
# is "no verdict", and section 1b could not see the stub's APPROVE (BH-3856).
# Its window comes from the registry default in the scratch tree's own catalog,
# never from whatever the invoking shell exported.
cp "$DIR/bin/lib/verdict-parse.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/catalog/lanes.d" && cp "$DIR/catalog/lanes.d/_lib.json" "$T/h/catalog/lanes.d/"
unset _VP_WINDOW VERDICT_WINDOW_LINES
# The shared REST answer emitter — tests/lib/rest-emit.sh documents the shapes.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-2504: the conductor pushes only through bin/lib/hold-push.sh (+ hold.sh).
cp "$DIR/bin/lib/hold-push.sh" "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/deploy-request.sh" "$T/h/bin/"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf 'job_verdict_rebind() { return 0; }\n' > "$T/h/bin/jobs-client.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/lane-alerts.txt" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
# The re-review lane's agent call and the deploy verifier: both SLEEP, so a lane
# that ran inline would be visible as a tick that took that long. The stub takes
# the real caller's argv (bin/lib/mc/rebase.sh mc_rereview: review <proj>
# <model> <timeout> <out> <prompt>), so its verdict goes to "$5", the <out>.
# Until BH-3856 it wrote "$4", the 1200 timeout, as a file named 1200 in the
# lane's cwd. Each call is logged tab-separated (an empty <model> keeps its
# slot) with the cwd it ran in. Keep this one line: the BH-3856 REPRO evals it.
printf '#!/bin/bash\n{ printf "%%s\\t" "$@"; printf "cwd=%%s\\n" "$PWD"; } >> "%s"\nsleep "${FAKE_AGENT_SLEEP:-0}"; printf "VERDICT: APPROVE\\n" > "$5"; exit 0\n' "$T/agent-call-argv.txt" > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"
cat > "$T/h/bin/deploy-verify.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/dv-argv.txt"
sleep "\${FAKE_DV_SLEEP:-0}"
exit "\${FAKE_DV_RC:-0}"
EOF
chmod +x "$T/h/bin/deploy-verify.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/prod-url.txt" > "$T/h/bin/prod-url.sh"
chmod +x "$T/h/bin/prod-url.sh"

# --- the fake git: every shape mc_rebase drives, with a controllable delay ----
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
printf '%s\n' "\$A" >> "$T/git-argv.txt"
case "\$A" in
  *" merge "*)  sleep "\${FAKE_GIT_MERGE_SLEEP:-0}"; exit 0 ;;
  *rev-parse*)  if [ -f "$T/rev2" ]; then printf '%s\n' "$NEW"; else touch "$T/rev2"; printf '%s\n' "$OLD"; fi; exit 0 ;;
  *merge-base*) echo base0000base0000; exit 0 ;;
  *patch-id*)   md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*)   printf 'a stable patch\n'; exit 0 ;;
  *push*)       touch "$T/pushed"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
# gh: PR 21 is approved at its head and DIRTY = NEEDS_REBASE. No write verb is
# expected anywhere in this file; one is a failure.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"pr review"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*) echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R $SLUG --state open"*)
    cat <<'J'
[{"number":21,"url":"$URL","headRefOid":"$OLD","headRefName":"ticket/TK-21","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "" ;;
  *"actions/runs"*) printf 'completed|success\n' ;;
  # The REST decision reads (BH-784). The v3.diff arm comes FIRST: it shares the
  # pull path with the plain read and differs only by the Accept header.
  *"v3.diff"*) restpr --diff ;;
  # By the time mc_settle_merged reads it the PR really is merged, and REST says
  # that as state closed + merged_at set, with the merge sha in merge_commit_sha.
  *"api -i -X GET repos/$SLUG/pulls/21"*) restpr MERGED "$OLD" ticket/TK-21 main "" MERGEABLE CLEAN app/cromford "$NEW" "plain body" ;;
  *"api -i -X GET repos/$SLUG/pulls/22"*) restpr MERGED "$OLD" ticket/TK-22 main "" MERGEABLE CLEAN app/cromford "$NEW" "plain body" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
REC="$T/h/builds/demo-os-TK-21-202609120021"
mkdir -p "$REC"
echo "PR_CREATED $URL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$OLD" > "$REC/reviewed-sha"
touch "$T/h/flags/merge-conductor-actions"

export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
LOCK="$T/h/locks/merge-conductor-demo-os.lock"

# tick <extra env...> — one whole conductor run, with the lanes pointed at the
# stub bin (in prod MC_RR_PATH is cron's named PATH).
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_REPOS="$T/repos" \
            MC_RR_PATH="$T/fakebin:$PATH" "$@" bash "$T/h/bin/merge-conductor.sh" \
            >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reset21() { echo "$OLD" > "$REC/reviewed-sha"; rm -f "$T/rev2" "$T/pushed" "$REC"/patch-id.* "$REC/rebind.log"
            rm -f "$T/h/state/merge-conductor/rebase"/*.json "$T/h/state/merge-conductor/rebase"/*.out
            awk -F'\t' '$1!="'"$SLUG"'#21"' "$T/h/state/merge-conductor/pr-state.tsv" > "$T/rows.tmp" 2>/dev/null
            mv -f "$T/rows.tmp" "$T/h/state/merge-conductor/pr-state.tsv"
            grep -v "$SLUG#21" "$T/h/state/merge-conductor/attempts.txt" > "$T/att.tmp" 2>/dev/null
            mv -f "$T/att.tmp" "$T/h/state/merge-conductor/attempts.txt"; }
# wait_status <job-file> <status> — the lane is asynchronous by design, so the
# test waits for the FILE, never for a wall-clock guess.
wait_status() {
  local f="$1" want="$2" i
  for i in $(seq 1 150); do [ "$(jq -r .status "$f" 2>/dev/null)" = "$want" ] && return 0; sleep 0.2; done
  return 1
}
# holds_fd <pid> <path> — rc 0 when that process has the file open. rc 2 where
# /proc is not readable (then the flock probe beside it carries the claim).
holds_fd() {
  local p="$1" f="$2" l tgt
  [ -d "/proc/$p/fd" ] || return 2
  tgt=$(readlink -f "$f" 2>/dev/null)
  for l in "/proc/$p/fd/"*; do
    [ -e "$l" ] || continue
    [ "$(readlink -f "$l" 2>/dev/null)" = "$tgt" ] && return 0
  done
  return 1
}

# ============================================================================
# 1. NO LANE JOB INHERITS THE TICK'S LOCK (the 03:54-04:02Z project-5 shape)
#
# Each lane is spawned from inside a shell holding the project lock on fd 9,
# exactly as tick_project holds it. The moment that shell releases, the lock
# must be free — and the job must still be running, or the test proved nothing.
# ============================================================================
probe_lane() { # probe_lane <name> <job-file-var-name> <spawn command...>
  # BH-684: the spawn names the stub PATH the way tick() does. A lane inherits
  # nothing but MC_RR_PATH, so without this it re-execs on the host's real
  # PATH: the re-review lane's `gh pr diff` dies network-less in tens of
  # milliseconds and the "still running" claim below races that death (5 of 6
  # runs on the test host, main included). Under the stub bin the lane reaches
  # agent-call.sh's FAKE_AGENT_SLEEP=8 and genuinely lives through the probe,
  # so the fd/lock assertions prove something on every run.
  # BH-3856: the spawn runs from $T with TMPDIR inside it, so nothing a lane
  # writes by a relative path or a bare mktemp can land in the caller's cwd.
  local name="$1" jf="$2"; shift 2
  ( cd "$T" || exit 1; export TMPDIR="$T/h/tmp"
    exec 9>"$LOCK"; flock -n 9 || exit 1; MC_RR_PATH="$T/fakebin:$PATH"; "$@" >/dev/null 2>&1 )
  local rc=$? pid i line out want_cwd
  [ "$rc" = 0 ] || { bad "$name: the spawn under the lock failed (rc $rc)"; return; }
  [ "$(jq -r .status "$jf" 2>/dev/null)" = running ] && ok || { bad "$name: no running job file was written ($jf)"; return; }
  pid=$(jq -r .pid "$jf" 2>/dev/null)
  flock -n "$LOCK" true >/dev/null 2>&1 && ok \
    || bad "$name: the project lock is STILL HELD after the tick released it — the job inherited fd 9 (this is the 2026-09-14 project-5 stall)"
  holds_fd "$pid" "$LOCK"; case $? in
    0) bad "$name: /proc/$pid/fd still points at $LOCK — the lane job inherited the tick's lock fd" ;;
    1) ok ;;
    *) ok ;;   # no /proc here; the flock probe above is the claim
  esac
  [ "$(jq -r .status "$jf" 2>/dev/null)" = running ] && ok \
    || bad "$name: the job was already finished, so the lock probe above proved nothing"
  # CDL_PROBES_ONLY=1 (BH-3856): hold the re-review lane until it is INSIDE the
  # agent-call stub, so the kill below lands on a lane with a sleeping child —
  # the shape that orphaned the stub and left ./1200 behind on a loaded box.
  if [ "${CDL_PROBES_ONLY:-}" = 1 ]; then case $jf in "$MC_RR_DIR"/*)
    out="${jf%.json}.out"; line=""
    for i in $(seq 1 75); do
      line=$(awk -F'\t' -v o="$out" '$5==o' "$T/agent-call-argv.txt" 2>/dev/null | head -1)
      [ -n "$line" ] && break; sleep 0.2
    done
    if [ -z "$line" ]; then
      bad "$name: the lane never reached agent-call.sh, so the orphan scenario was not exercised"
    else
      PROBE_AGENT_REACHED=1
      [ "$(printf '%s' "$line" | awk -F'\t' '{print $5}')" = "$out" ] && ok \
        || bad "$name: the stub's 5th argument is not the lane's <out> ($line)"
      # BH-8103: the lane runs the agent from a private dir under TMPDIR. The
      # probe's TMPDIR is inside $T, so this dir proves BH-3856 and BH-8103.
      want_cwd="$T/h/tmp/mc-rereview-$EUID/${SLUG##*/}-21-${NEW:0:12}"
      [ "$(printf '%s' "$line" | awk -F'\t' '{print $NF}')" = "cwd=$want_cwd" ] && ok \
        || bad "$name: the lane ran agent-call.sh outside its private dir under \$T (want $want_cwd; got $line)"
    fi
  esac; fi
  # The job is a setsid session leader, so its pid is its process group: kill
  # the GROUP, or the lane's agent-call.sh / sleep child lives on, orphaned, and
  # writes after this suite has exited (BH-3856). A pid that is not a positive
  # integer is never signalled — `kill -- -0` would hit this test's own group.
  case $pid in ''|*[!0-9]*|0) bad "$name: the job file's pid is not a usable pid ($pid)"; return ;; esac
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  for i in $(seq 1 50); do kill -0 -- "-$pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 -- "-$pid" 2>/dev/null \
    && bad "$name: the lane's process group (pgid $pid) outlived the kill — an orphaned stub can still write after the test exits" \
    || ok
}
export FAKE_GIT_MERGE_SLEEP=8 FAKE_AGENT_SLEEP=8 FAKE_DV_SLEEP=8
RBJ=$(mc_rb_file "$SLUG" 21 "$OLD")
probe_lane "rebase lane" "$RBJ" mc_rebase_spawn "$SLUG" 21 demo-os ticket/TK-21 "$OLD" "$URL"
DVPROBE=7777777777777777777777777777777777777777
DVJ=$(mc_dv_file demo-os "$DVPROBE")
probe_lane "deploy-verify lane" "$DVJ" mc_dv_spawn demo-os "$SLUG" "$DVPROBE" "$REC"
RRJ=$(mc_rr_file "$SLUG" 21 "$NEW")
probe_lane "re-review lane (#310)" "$RRJ" mc_rereview_spawn "$SLUG" 21 demo-os "$URL" "$OLD" "$NEW" "$REC"
unset FAKE_GIT_MERGE_SLEEP FAKE_AGENT_SLEEP FAKE_DV_SLEEP
rm -f "$T/h/state/merge-conductor/rebase"/*.json "$T/h/state/merge-conductor/rereview"/*.json \
      "$T/h/state/merge-conductor/deploy-verify"/*.json "$T/h/state/merge-conductor/attempts.txt"
touch "$T/h/state/merge-conductor/attempts.txt"

# ============================================================================
# 1b. The agent-call stub reads the REAL caller's argv (BH-3856)
#
# Driven through mc_rereview_spawn -> mc_rereview -> the stub, so the argv is the
# one bin/lib/mc/rebase.sh builds. The verdict must land in <out> ($5), never in
# a file named after the 1200 timeout ($4).
# ============================================================================
RRJ3=$(mc_rr_file "$SLUG" 21 3333333333333333333333333333333333333333)
( cd "$T" && export TMPDIR="$T/h/tmp" && FAKE_AGENT_SLEEP=0 MC_RR_PATH="$T/fakebin:$PATH" \
    mc_rereview_spawn "$SLUG" 21 demo-os "$URL" "$OLD" 3333333333333333333333333333333333333333 "$REC" ) >/dev/null 2>&1
wait_status "$RRJ3" done && ok || bad "1b: the re-review job for 3333 never finished (status $(jq -r .status "$RRJ3" 2>/dev/null))"
[ "$(jq -r .verdict "$RRJ3" 2>/dev/null)" = APPROVE ] && ok \
  || bad "1b: the job's verdict must be APPROVE read from <out> (got $(jq -r .verdict "$RRJ3" 2>/dev/null))"
RRO3=$(jq -r .out_file "$RRJ3" 2>/dev/null)
grep -q 'VERDICT: APPROVE' "$RRO3" 2>/dev/null && ok || bad "1b: the stub's verdict did not land in the job's out_file ($RRO3)"
RRA3=$(awk -F'\t' -v o="${RRJ3%.json}.out" '$5==o' "$T/agent-call-argv.txt" 2>/dev/null | head -1)
[ "$(printf '%s' "$RRA3" | awk -F'\t' '{print $4 "|" $5}')" = "1200|${RRJ3%.json}.out" ] && ok \
  || bad "1b: the stub must see the real caller's argv (<timeout> 1200 as \$4, <out> as \$5); got: ${RRA3:-no call logged}"
[ -e "$T/1200" ] || [ -e "$DIR/1200" ] && bad "1b: a file named 1200 was written — the stub took the timeout for its out file" || ok
rm -f "$RRJ3" "${RRJ3%.json}".out*

# CDL_PROBES_ONLY=1 ends the suite here, right after the probes killed their
# lanes: tests/conductor-detached-lanes.bh-3856-test.sh runs it that way and
# checks that nothing those lanes started writes outside $T afterwards.
if [ "${CDL_PROBES_ONLY:-}" = 1 ]; then
  [ "${PROBE_AGENT_REACHED:-}" = 1 ] && echo "conductor-detached-lanes-test: probes-only: agent-call reached"
  echo "conductor-detached-lanes-test: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# ============================================================================
# 2. The tick SPAWNS the rebase and reads its result on a later tick
# ============================================================================
reset21
T0=$(date -u +%s); tick env FAKE_GIT_MERGE_SLEEP=12; T1=$(date -u +%s)
RBJ=$(mc_rb_file "$SLUG" 21 "$OLD")
[ $((T1-T0)) -lt 10 ] && ok || bad "the tick must not wait for the rebase (took $((T1-T0))s — it ran inline)"
grep -q "$SLUG#21 REBASE_SPAWNED" "$T/h/logs/merge-conductor.log" && ok || bad "the spawn must be logged as REBASE_SPAWNED"
[ -f "$RBJ" ] && ok || bad "a NEEDS_REBASE PR must get a detached rebase job file ($RBJ)"
[ "$(mc_rb_state "$RBJ")" = running ] && ok || bad "the spawned rebase must be running while the tick is already done (got $(mc_rb_state "$RBJ"))"
[ "$(state_of "$SLUG#21")" = REBASING ] && ok || bad "a PR whose rebase is running must be REBASING (got $(state_of "$SLUG#21"))"
[ -f "$T/pushed" ] && bad "the tick itself must never push" || ok
# a second tick over a RUNNING job reads it and moves on, still not waiting
T0=$(date -u +%s); tick; T1=$(date -u +%s)
[ $((T1-T0)) -lt 10 ] && ok || bad "a tick over a running rebase must not wait either (took $((T1-T0))s)"
grep -q "$SLUG#21 REBASING ${OLD:0:8} — detached job" "$T/h/logs/merge-conductor.log" && ok || bad "a running rebase must log REBASING"
[ "$(grep -c "REBASE_SPAWNED" "$T/h/logs/merge-conductor.log")" = 1 ] && ok || bad "one rebase per (PR, head): the second tick spawned another"
# the job finishes; the NEXT tick consumes the result
wait_status "$RBJ" done && ok || bad "the detached rebase never finished (status $(jq -r .status "$RBJ" 2>/dev/null))"
[ "$(jq -r .rc "$RBJ")" = 0 ] && ok || bad "the job must record mc_rebase's rc (got $(jq -r .rc "$RBJ"))"
[ "$(jq -r .new_head "$RBJ")" = "$NEW" ] && ok || bad "the job must record the head it pushed (got $(jq -r .new_head "$RBJ"))"
[ -f "$T/pushed" ] && ok || bad "the detached job must actually push"
grep -q "$SLUG#21 detached rebase of ${OLD:0:8} finished rc=0" "$T/h/logs/merge-conductor.log" && ok || bad "the job must log its own outcome"
tick
[ "$(state_of "$SLUG#21")" = WAIT_CI ] && ok || bad "a consumed rc-0 rebase must move the row to WAIT_CI (got $(state_of "$SLUG#21"))"
grep -q "$SLUG#21 rebased: pushed ${NEW:0:8} over ${OLD:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "the consumed result must log the rebase exactly as the inline path did"
N=$(grep -c "rebased: pushed" "$T/h/logs/merge-conductor.log"); tick
[ "$(grep -c "rebased: pushed" "$T/h/logs/merge-conductor.log")" = "$N" ] && ok || bad "a rebase result must be consumed once per (PR, head), not on every tick"
[ -s "$T/gh-writes.txt" ] && bad "a write verb ran: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# 3. The MC_REBASE_PARALLEL cap, and what a refused spawn must NOT do
# ============================================================================
reset21
mc_rb_write "$T/h/state/merge-conductor/rebase/other.json" running "$$" "$(mc_now)" 0 - deadbeef - /dev/null
tick env MC_REBASE_PARALLEL=1
RBJ=$(mc_rb_file "$SLUG" 21 "$OLD")
[ -f "$RBJ" ] && bad "at the MC_REBASE_PARALLEL limit no second rebase may be spawned" || ok
grep -q "$SLUG#21 REBASE_QUEUED" "$T/h/logs/merge-conductor.log" && ok || bad "a spawn refused at the cap must log REBASE_QUEUED"
grep -qxF "rebase $SLUG#21 $OLD" "$T/h/state/merge-conductor/attempts.txt" \
  && bad "a spawn refused at the cap must NOT burn this head's one rebase — the next tick would never retry it" || ok
rm -f "$T/h/state/merge-conductor/rebase/other.json"
tick
[ -f "$RBJ" ] && ok || bad "once the cap frees up, the next tick must spawn the rebase it deferred"
wait_status "$RBJ" done >/dev/null

# ============================================================================
# 4. A rebase job that is not coming back
# ============================================================================
reset21
RBJ=$(mc_rb_file "$SLUG" 21 "$OLD")
mc_rb_write "$RBJ" running "$$" "$(( $(mc_now) - 4000 ))" 0 - "$OLD" - "${RBJ%.json}.out"
[ "$(mc_rb_state "$RBJ")" = stale ] && ok || bad "a job past MC_REBASE_TIMEOUT_SECS must read as stale even with a live pid"
tick
[ "$(jq -r .status "$RBJ")" = failed ] && ok || bad "a timed-out rebase must be marked failed (got $(jq -r .status "$RBJ"))"
[ "$(state_of "$SLUG#21")" = NEEDS_REBASE ] && ok || bad "a rebase that never came back leaves the PR in NEEDS_REBASE (got $(state_of "$SLUG#21"))"
grep -q "$SLUG#21 detached rebase on ${OLD:0:8} is gone" "$T/h/logs/merge-conductor.log" && ok || bad "a stale rebase must say so in the log"

# ============================================================================
# 5. KILL FLAG: MC_DETACHED_REBASE=0 is exactly today's inline rebase
# ============================================================================
reset21
rm -f "$T/pushed"
tick env MC_DETACHED_REBASE=0
RBJ=$(mc_rb_file "$SLUG" 21 "$OLD")
[ -f "$RBJ" ] && bad "MC_DETACHED_REBASE=0 must spawn NO lane job" || ok
[ -f "$T/pushed" ] && ok || bad "MC_DETACHED_REBASE=0 must rebase INSIDE the tick (nothing pushed)"
[ "$(state_of "$SLUG#21")" = WAIT_CI ] && ok || bad "the inline rebase must land the same WAIT_CI row it always did (got $(state_of "$SLUG#21"))"
grep -q "$SLUG#21 rebased: pushed ${NEW:0:8} over ${OLD:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "the inline path must log the same line"
grep -qxF "rebase $SLUG#21 $OLD" "$T/h/state/merge-conductor/attempts.txt" && ok || bad "the inline path must keep its one-rebase-per-head ledger line"

# ============================================================================
# 6. The deploy-verify lane: spawn, run, result, ONE reading, and the kill flag
# ============================================================================
DVSHA=3333333333333333333333333333333333333333
DVJ=$(mc_dv_file demo-os "$DVSHA")
FAKE_DV_SLEEP=1 mc_dv_spawn demo-os "$SLUG" "$DVSHA" "$REC" && ok || bad "mc_dv_spawn must spawn the verifier lane"
wait_status "$DVJ" done && ok || bad "the verifier lane never finished (status $(jq -r .status "$DVJ" 2>/dev/null))"
[ "$(jq -r .rc "$DVJ")" = 0 ] && ok || bad "the lane must record deploy-verify's exit code (got $(jq -r .rc "$DVJ"))"
grep -q "demo-os $SLUG $DVSHA $REC" "$T/dv-argv.txt" && ok || bad "deploy-request.sh must have run the verifier in the FOREGROUND with the lane's arguments (got '$(cat "$T/dv-argv.txt" 2>/dev/null)')"
mc_dv_reap
grep -q "demo-os deploy-verify OK for ${DVSHA:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "the reap must log a finished verifier"
N=$(grep -c "deploy-verify OK for ${DVSHA:0:8}" "$T/h/logs/merge-conductor.log"); mc_dv_reap
[ "$(grep -c "deploy-verify OK for ${DVSHA:0:8}" "$T/h/logs/merge-conductor.log")" = "$N" ] && ok || bad "a verifier result must be read once, not on every tick"
# a FAILING verifier is recorded as such
DVSHA2=4444444444444444444444444444444444444444
DVJ2=$(mc_dv_file demo-os "$DVSHA2")
FAKE_DV_RC=1 mc_dv_spawn demo-os "$SLUG" "$DVSHA2" "$REC"
wait_status "$DVJ2" done && ok || bad "the failing verifier lane never finished"
mc_dv_reap
grep -q "demo-os deploy-verify FAILED (rc 1) for ${DVSHA2:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "a failed verifier must be logged as failed, not swallowed"
# a verifier that never came back is an ALERT, never a quiet wait
DVSHA3=5555555555555555555555555555555555555555
DVJ3=$(mc_dv_file demo-os "$DVSHA3")
mc_dv_write "$DVJ3" running "$$" "$(( $(mc_now) - 9000 ))" 0 - demo-os "$DVSHA3" "$REC" "${DVJ3%.json}.out"
[ "$(mc_dv_state "$DVJ3")" = stale ] && ok || bad "a verifier past MC_DV_TIMEOUT_SECS must read as stale"
mc_dv_reap
[ "$(jq -r .status "$DVJ3")" = failed ] && ok || bad "a stale verifier must be marked failed"
grep -q "DEPLOY_VERIFY" "$T/lane-alerts.txt" 2>/dev/null && ok || bad "a verifier that never finished must raise ONE alert — nothing waits silently"
N=$(wc -l < "$T/lane-alerts.txt"); mc_dv_reap
[ "$(wc -l < "$T/lane-alerts.txt")" = "$N" ] && ok || bad "the stale-verifier alert must fire once, not every tick"
# THE KILL FLAG. MC_DETACHED_DEPLOY_VERIFY=0 makes the settle call
# deploy-request.sh itself, from the tick, exactly as it did before this change.
# deploy-request.sh is swapped for a recorder so the call is visible either way.
cp "$T/h/bin/deploy-request.sh" "$T/dr-real.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/dr-argv.txt" > "$T/h/bin/deploy-request.sh"
chmod +x "$T/h/bin/deploy-request.sh"
( MC_DETACHED_DEPLOY_VERIFY=0
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh"
  mc_settle_merged "$SLUG#21" "$URL" demo-os "$SLUG" ticket/TK-21 "$REC" - "$OLD" >/dev/null )
grep -q "demo-os $SLUG" "$T/dr-argv.txt" 2>/dev/null && ok || bad "MC_DETACHED_DEPLOY_VERIFY=0 must call deploy-request.sh from the tick, exactly as before"
[ -f "$(mc_dv_file demo-os "$NEW")" ] && bad "the kill flag must spawn no lane job" || ok
# and with the flag DEFAULT, the same settle spawns the lane instead
: > "$T/dr-argv.txt"
( unset MC_DETACHED_DEPLOY_VERIFY
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh"
  mc_settle_merged "$SLUG#22" "https://github.com/$SLUG/pull/22" demo-os "$SLUG" ticket/TK-22 "$REC" - "$OLD" >/dev/null )
grep -q "DEPLOY_VERIFY_SPAWNED" "$T/h/logs/merge-conductor.log" && ok || bad "by default the settle must spawn the verifier LANE and log DEPLOY_VERIFY_SPAWNED"
# The lane job runs deploy-request.sh too — in its OWN process, with the tick
# long gone. What the flag changes is WHO calls it, so the witness is the job
# file: under the default there is one, under the kill flag there is not.
[ -f "$(mc_dv_file demo-os "$NEW")" ] && ok || bad "the default path must write a lane job file for the merge sha"
cp "$T/dr-real.sh" "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"

# ============================================================================
# 7. THE #799 SHAPE: DIRTY, AND GITHUB NEVER RAN A CHECK ON IT (2026-09-14)
#
#   2026-09-14 17:40:33Z example-org/project-5#799 - -> WAIT_CI head=b8927898
#       reviewed=b8927898 merge=DIRTY reason=checks none
# It was still in that row four hours later, and no rebase line and no resolver
# line was ever written for it. GitHub runs no `pull_request` workflow on a PR
# it cannot merge, so `checks none` is what EVERY dirty PR reports — and the
# classifier tested CI before it tested DIRTY, so no conflicted PR on the fleet
# ever reached the rebase lane. #838, #826 and #863 sat in the same row.
#
# Driven with NO runs on the head at all, and with `git merge-tree` answering
# CLEAN while GitHub says DIRTY — #799's own disagreement — so this pins both
# halves: the row goes NEEDS_REBASE instead of WAIT_CI, and the merge-tree skip
# still caps out at MC_MERGE_TREE_MAX and hands the head to the rebase.
# ============================================================================
URL23="https://github.com/$SLUG/pull/23"
REC23="$T/h/builds/demo-os-TK-23-202609120023"; mkdir -p "$REC23"
echo "PR_CREATED $URL23" > "$REC23/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC23/review.md"
echo "$OLD" > "$REC23/reviewed-sha"
# git: 2.45 (so merge-tree is available) and merge-tree answers CLEAN.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
case "\$A" in
  *--version*)  echo "git version 2.45.0"; exit 0 ;;
  *merge-tree*) exit 0 ;;
  *rev-parse*)  printf '%s\n' "$NEW"; exit 0 ;;
  *merge-base*) echo base0000base0000; exit 0 ;;
  *patch-id*)   md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*)   printf 'a stable patch\n'; exit 0 ;;
  *push*)       touch "$T/pushed23"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
# gh: PR 23 is DIRTY and there is NOT ONE workflow run on its head.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"pr review"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*) echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R $SLUG --state open"*)
    cat <<'J'
[{"number":23,"url":"$URL23","headRefOid":"$OLD","headRefName":"ticket/TK-23","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN","labels":[],"baseRefName":"main"}]
J
    ;;
  *"pr list"*) echo "" ;;
  *"actions/runs"*) printf '' ;;
  # The REST decision reads (BH-784); the v3.diff arm before the plain pull arm.
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/$SLUG/pulls/23"*) restpr OPEN "$OLD" ticket/TK-23 main "" CONFLICTING DIRTY app/cromford "" "plain body" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
rm -f "$T/h/state/merge-conductor/rebase"/*.json "$T/pushed23"
RBJ23=$(mc_rb_file "$SLUG" 23 "$OLD")
tick
[ "$(state_of "$SLUG#23")" = NEEDS_REBASE ] && ok || bad "the #799 shape: a DIRTY PR with NO CI runs must be NEEDS_REBASE, not WAIT_CI — this is the row four project-5 PRs were stranded in (got $(state_of "$SLUG#23"))"
grep -q "$SLUG#23 MERGE_TREE clean — ${OLD:0:8} merges into origin/main with no conflict" "$T/h/logs/merge-conductor.log" && ok || bad "the merge-tree test must run on a NEEDS_REBASE row, which a conflicted PR could never reach before"
[ -f "$RBJ23" ] && bad "while merge-tree says clean the head must be left alone" || ok
tick; tick
grep -q "$SLUG#23 MERGE_TREE clean on ${OLD:0:8} for the 3th tick while GitHub still says DIRTY — trusting GitHub and rebasing" "$T/h/logs/merge-conductor.log" && ok || bad "after MC_MERGE_TREE_MAX observations the conductor must trust GitHub and rebase — #799's exact disagreement"
[ -f "$RBJ23" ] && ok || bad "the capped-out merge-tree skip must end in a detached rebase job"
grep -q "$SLUG#23 REBASE_SPAWNED" "$T/h/logs/merge-conductor.log" && ok || bad "the rebase of the conflicted head must be spawned and logged"
[ "$(state_of "$SLUG#23")" = REBASING ] && ok || bad "a PR whose rebase is running must be REBASING (got $(state_of "$SLUG#23"))"
[ -s "$T/gh-writes.txt" ] && bad "a write verb ran: $(cat "$T/gh-writes.txt")" || ok
# rc 5 on a PR THAT NEVER HAD AN APPROVAL is not a failure. A conflicted PR with
# no verdict only reaches this lane because DIRTY now outranks the no-verdict
# branch, and for it `job_verdict_rebind` answering "no claim to move" is the
# expected answer — parking it NEEDS_REBASE would loop a PR that has just
# stopped conflicting.
reset21
rebase_source() { sed -n '/^rebase_result() {/,/^}/p' "$T/h/bin/lib/mc/rebase.sh"; }
( # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh"
  eval "$(rebase_source)"
  MERGES=0
  rebase_result "$SLUG#24" "https://github.com/$SLUG/pull/24" "" "$OLD" "-" "-" DIRTY 5 "$NEW"
  rebase_result "$SLUG#25" "https://github.com/$SLUG/pull/25" "" "$OLD" "$OLD" APPROVE DIRTY 5 "$NEW" )
[ "$(state_of "$SLUG#24")" = WAIT_CI ] && ok || bad "a rebase of a PR with no approval must land WAIT_CI on the pushed head, not loop in NEEDS_REBASE (got $(state_of "$SLUG#24"))"
grep -q "$SLUG#24 rebased: pushed ${NEW:0:8} over ${OLD:0:8}; no approval to rebind" "$T/h/logs/merge-conductor.log" && ok || bad "the no-approval case must say what it actually is"
[ "$(state_of "$SLUG#25")" = NEEDS_REBASE ] && ok || bad "a rebind that failed on a PR that DID have an approval must still be NEEDS_REBASE rebind-failed (got $(state_of "$SLUG#25"))"
grep -q "$SLUG#25 rebased to ${NEW:0:8} but the approval rebind FAILED" "$T/h/logs/merge-conductor.log" && ok || bad "a real rebind failure must still be reported as one"

echo "conductor-detached-lanes-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
