#!/bin/bash
# tests/mc-jobs-rows.bh-2358-test.sh — BH-2358 (BH-2311.2, task 5.1): a
# detached rebase / re-review job that FINISHES records a terminal
# `rbjob|rrjob <key> <head> done` line (file + row), and a launch for that
# (PR, head) with no job file but a terminal line spawns nothing. The job file
# is a box-local cache; losing it (a wiped state dir, another box) must not buy
# the same metered re-review twice.
#
# WHAT IT PINS (flag up unless it says otherwise).
#   a. a real conductor tick spawns a head-bound re-review; it finishes and
#      records `rrjob KEY H2 done`. MC_RR_DIR is wiped, and the next REAL tick
#      buys nothing (the stub agent is not called again) — first with the
#      ledger line on disk, then with only the row to say so.
#   b. the same wiped state under a worker OUTAGE: the files decide, which is
#      today's behaviour — the tick spawns and the agent is called.
#   c. a finished rebase records `rbjob … done`; with MC_RB_DIR and the ledger
#      wiped, mc_rebase_spawn answers rc 4 and launches nothing (no git runs).
#   d. the two deliberate forgetters (the stuck re-kick and the release label)
#      forget `rbjob` too, so the next spawn proceeds.
#   g. the land arm re-rebases the SAME head onto a new main on purpose (its own
#      `landrebase` mark dedupes it), so it forgets an old `rbjob` first and
#      spawns — no LAND_DEFER loop once mc_lane_gc has removed the old job file.
#   h. the same for the queue-ejection arm (`ejectrebase` dedupes it).
#   e. negatives: a lane-failed re-review records no `rrjob`; `rrjob o/r#5 H`
#      blocks neither o/r#50 nor another head of o/r#5.
#   f. flag down: no `rbjob`/`rrjob` line, no pr-attempts request, spawns as today.
#
# HOW. (a)/(b) run bin/merge-conductor.sh end to end, as
# tests/merge-conductor-rereview-lanefail-test.sh does; (c)-(h) call the REAL
# lane functions through the REAL lib in a fresh process each. The worker is a
# curl shim with a row store and a request sink.
#
# Run from anywhere: tests/mc-jobs-rows.bh-2358-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The open-PR list is REST (BH-1585); this bridge answers it from the stub list.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=aaaaaaaa1111        # the sha the build's own review approved
H2=bbbbbbbb2222        # the head it moved to
SLUG=example-org/demo-os
URL="https://github.com/$SLUG/pull/12"
KEY="$SLUG#12"

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/fakebin" "$T/repos"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/main-red-gate.sh" "$DIR/bin/lib/review-provenance.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/" || exit 1
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR/bin/lib/hold-push.sh" "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"

# The review lane: every call is one line in $T/agent-calls.txt — the spend.
cat > "$T/h/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$2" >> "$T/agent-calls.txt"
printf 'claude\n' > "\$5.runner"
printf 'claude-fable-5-1\n' > "\$5.model"
printf 'findings\nVERDICT: APPROVE\n' > "\$5"
exit 0
EOF
chmod +x "$T/h/bin/agent-call.sh"
# git: every call recorded, so "no rebase ran" is observable.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
printf '%s\n' "\$A" >> "$T/git-argv.txt"
case "\$A" in
  *merge-base*) echo base0000base0000; exit 0 ;;
  *patch-id*)   md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*)   SHA="\${A##* }"; printf 'diff for %s\n' "\$SHA"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
# gh: PR 12, approved at H1, moved to H2, green CI.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*) exit 1 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/$SLUG/pulls/12"*)
    restpr OPEN "$H2" ticket/TK-12 main "" MERGEABLE CLEAN operator ccccmergecommit "plain body" ;;
  *"pr list -R $SLUG --state open"*)
    cat <<'J'
[{"number":12,"url":"$URL","headRefOid":"$H2","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# The worker: a row store keyed (repo, number, kind, sha); every pr-attempts
# request lands in the sink. /api/flags/* is a 404 so the flag FILE decides.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$URL" in */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;; esac
case "$METHOD $URL" in "PUT "*/api/ledger) printf '{"ok":true}\n200\n'; exit 0 ;; esac
case "$URL" in */api/pr-attempts*) ;; *) printf '{"error":"not found"}\n404\n'; exit 0 ;; esac
dec() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
repo=""; num=""; kind=""; sha=""
if [ -n "$BODY" ]; then
  repo=$(jq -r .repo <<<"$BODY"); num=$(jq -r .number <<<"$BODY")
  kind=$(jq -r .kind <<<"$BODY"); sha=$(jq -r .sha <<<"$BODY")
else
  q="${URL#*\?}"; [ "$q" = "$URL" ] && q=""
  IFS='&' read -r -a kv <<<"$q"
  for p in "${kv[@]}"; do
    v=$(dec "${p#*=}")
    case "${p%%=*}" in repo) repo="$v" ;; number) num="$v" ;; kind) kind="$v" ;; sha) sha="$v" ;; esac
  done
fi
printf '%s\t%s\t%s\t%s\t%s\n' "$METHOD" "$repo" "$num" "$kind" "$sha" >> "$REQ_LOG"
[ -f "$ROWS_DOWN" ] && exit 7
touch "$ROWS_FILE"
row=$(printf '%s\t%s\t%s\t%s' "$repo" "$num" "$kind" "$sha")
case "$METHOD" in
  PUT) grep -qxF "$row" "$ROWS_FILE" || printf '%s\n' "$row" >> "$ROWS_FILE"
       printf '{"ok":true}\n200\n' ;;
  DELETE) if grep -qxF "$row" "$ROWS_FILE"; then
            grep -vxF "$row" "$ROWS_FILE" > "$ROWS_FILE.t"; mv -f "$ROWS_FILE.t" "$ROWS_FILE"
            printf '{"ok":true}\n200\n'
          else printf '{"error":"no row"}\n404\n'; fi ;;
  GET) if [ -n "$sha" ]; then
         if grep -qxF "$row" "$ROWS_FILE"; then printf '{"ok":true}\n200\n'; else printf '{"error":"no row"}\n404\n'; fi
       else
         awk -F'\t' -v r="$repo" -v n="$num" -v k="$kind" '$1==r && $2==n && $3==k {print $4}' "$ROWS_FILE" \
           | jq -Rsc 'split("\n") | map(select(. != "")) | {attempts: map({sha: .}), count: length}'
         printf '200\n'
       fi ;;
esac
CURL
chmod +x "$T/fakebin/curl"

REC="$T/h/builds/pool-demo-os-TK-12-202609120002"
mkdir -p "$REC"
echo "PR_CREATED $URL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
touch "$T/h/flags/merge-conductor-actions"

export PATH="$T/fakebin:$PATH"
# Pure helpers only in THIS shell (file names); every decision runs in a fresh
# process so the per-process flag cache sees the flag file as it is now.
# shellcheck source=/dev/null
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
SD="$T/h/state/merge-conductor"
ATT="$SD/attempts.txt"
LOG="$T/h/logs/merge-conductor.log"
REQ="$T/req.log"; ROWS="$T/rows.tsv"; ERR="$T/err.log"
WENV=(HARNESS_SECRET=x JOBS_BOX=testbox JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test
      REQ_LOG="$REQ" ROWS_FILE="$ROWS" ROWS_DOWN="$T/rows-down" MC_REHYDRATE=0)

tick() { ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" "${WENV[@]}" \
             MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" \
             bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
           || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
cat > "$T/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 91
eval "$DRIVE_CODE"
DRV
drv() { env DRIVE_CODE="$1" PATH="$T/fakebin:$PATH" HARNESS="$T/h" "${WENV[@]}" \
          MC_RR_PATH="$T/fakebin:$PATH" bash "$T/drive.sh" 2>>"$ERR"; }
flag() { if [ "$1" = up ]; then : > "$T/h/flags/pr-state-rows"; else rm -f "$T/h/flags/pr-state-rows"; fi; }
calls() { local n; n=$(grep -c . "$T/agent-calls.txt" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
spawns() { local n; n=$(grep -c 'REREVIEW_SPAWNED' "$LOG" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
seen() { grep -qxF "$(printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5")" "$REQ"; }
nattreq() { local n; n=$(grep -cE '^(GET|PUT|DELETE)	' "$REQ" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
wait_status() {
  local f="$1" want="$2" i
  for i in $(seq 1 150); do [ "$(jq -r .status "$f" 2>/dev/null)" = "$want" ] && return 0; sleep 0.2; done
  return 1
}
# wait_gone <job-file> — a spawned job that nobody wants to read: wait for it to
# write its result so it cannot race the next case, then drop its traces.
wait_settled() { local i; for i in $(seq 1 150); do
  case "$(jq -r .status "$1" 2>/dev/null)" in running|'') sleep 0.2 ;; *) return 0 ;; esac; done; }
# wait_rrjob <slug> <num> <head> — a re-review that ends in a verdict writes its
# job file `done` FIRST and its `rrjob … done` line (row, then file) after, so
# wait_status/wait_settled alone return before that line exists and it lands in
# whatever runs next. No-op for a job that did not end `done`.
wait_rrjob() { local i
  [ "$(jq -r .status "$(mc_rr_file "$1" "$2" "$3")" 2>/dev/null)" = done ] || return 0
  for i in $(seq 1 150); do grep -qxF "rrjob $1#$2 $3 done" "$ATT" && return 0; sleep 0.2; done; }
reset_all() {
  : > "$REQ"; : > "$ERR"; : > "$ROWS"; : > "$ATT"; : > "$T/agent-calls.txt"; : > "$T/git-argv.txt"
  rm -f "$T/rows-down" "$SD"/rereview/* "$SD"/rebase/* "$SD/pr-state.tsv" "$SD"/rereviews-*.txt 2>/dev/null
  scratch_rm "$SD/tick"; touch "$SD/pr-state.tsv"; echo "$H1" > "$REC/reviewed-sha"
}
drop_line() { grep -vxF "$1" "$ATT" > "$T/att.t"; mv -f "$T/att.t" "$ATT"; }
RRJ=$(mc_rr_file "$SLUG" 12 "$H2")

echo "== a. a finished re-review is not bought again after its job file is lost =="
reset_all; flag up
tick
[ -f "$RRJ" ] && ok || bad "a: a moved head on green CI must spawn the re-review ($RRJ)"
wait_status "$RRJ" done && ok || bad "a: the re-review never finished ($(jq -r .status "$RRJ" 2>/dev/null))"
wait_rrjob "$SLUG" 12 "$H2"
[ "$(calls)" = 1 ] && ok || bad "a: one review bought, got $(calls)"
grep -qxF "rrjob $KEY $H2 done" "$ATT" && ok || bad "a: the finished job must record 'rrjob $KEY $H2 done': $(grep rrjob "$ATT")"
seen PUT "$SLUG" 12 rrjob "$H2 done" && ok || bad "a: the terminal line must also be a row: $(cat "$REQ")"
N=$(spawns)
rm -f "$SD"/rereview/*
tick
[ "$(calls)" = 1 ] && ok || bad "a: MC_RR_DIR wiped and the ledger line on disk — the tick bought the same review again ($(calls) calls)"
[ "$(spawns)" = "$N" ] && ok || bad "a: no spawn may be logged ($N -> $(spawns))"
[ ! -f "$RRJ" ] && ok || bad "a: a refused launch must write no job file"
grep -q "$KEY re-review of ${H2:0:8} already finished" "$LOG" && ok \
  || bad "a: the refusal must say why: $(tail -5 "$LOG")"
# Now the ledger line is gone too: only the row can say the review happened.
drop_line "rrjob $KEY $H2 done"; : > "$REQ"
tick
[ "$(calls)" = 1 ] && ok || bad "a: with only the row left the tick bought the review again ($(calls) calls)"
seen GET "$SLUG" 12 rrjob "$H2 done" && ok || bad "a: the answer must have come from the row: $(cat "$REQ")"

echo "== b. an outage: the files decide, as today =="
rm -f "$SD"/rereview/*; drop_line "rrjob $KEY $H2 done"; scratch_rm "$SD/tick"
touch "$T/rows-down"
tick
[ -f "$RRJ" ] && ok || bad "b: under an outage with no file line the tick must spawn as today"
wait_status "$RRJ" done >/dev/null; wait_rrjob "$SLUG" 12 "$H2"
[ "$(calls)" = 2 ] && ok || bad "b: the outage path must call the agent (today's behaviour), got $(calls)"
rm -f "$T/rows-down"

echo "== c. a finished rebase is not launched again after its job file is lost =="
reset_all; flag up
OUT=$(drv "mc_rebase() { echo 3333333333333333333333333333333333333333; return 0; }
           jf=\$(mc_rb_file o/r 5 $H2); mkdir -p \"\$MC_RB_DIR\"
           mc_rb_write \"\$jf\" running 0 \"\$(mc_now)\" 0 - $H2 - \"\${jf%.json}.out\"
           mc_rebase_run o/r 5 demo-os br $H2 https://github.com/o/r/pull/5 \"\$jf\" \"\${jf%.json}.out\"
           mc_rr_field \"\$jf\" status")
[ "$OUT" = done ] && ok || bad "c: the rebase job must finish (got '$OUT')"
grep -qxF "rbjob o/r#5 $H2 done" "$ATT" && ok || bad "c: the finished rebase must record 'rbjob o/r#5 $H2 done': $(cat "$ATT")"
seen PUT o/r 5 rbjob "$H2 done" && ok || bad "c: the terminal line must also be a row: $(cat "$REQ")"
rm -f "$SD"/rebase/*; drop_line "rbjob o/r#5 $H2 done"; : > "$T/git-argv.txt"
OUT=$(drv "mc_rebase_spawn o/r 5 demo-os br $H2 https://github.com/o/r/pull/5; echo rc=\$?")
[ "$OUT" = rc=4 ] && ok || bad "c: a launch with a terminal row must answer rc 4 (got '$OUT')"
[ -z "$(ls -A "$SD/rebase/" 2>/dev/null | grep -v '^\.lock$')" ] && ok || bad "c: a refused launch must write no job file: $(ls "$SD/rebase/")"
sleep 1
[ ! -s "$T/git-argv.txt" ] && ok || bad "c: a refused launch must run no rebase: $(head -3 "$T/git-argv.txt")"
grep -q "o/r#5 rebase of ${H2:0:8} already finished" "$LOG" && ok || bad "c: the refusal must be logged: $(tail -3 "$LOG")"

echo "== d. the stuck re-kick and the release label forget rbjob too =="
spawn_ok() { # the launch goes ahead; wait for the job so it cannot race the next case
  local out; out=$(drv "mc_rebase_spawn o/r 5 demo-os br $H2 https://github.com/o/r/pull/5; echo rc=\$?")
  [ "$out" = rc=0 ] && ok || bad "d: $1: the next spawn must proceed (got '$out')"
  wait_settled "$(mc_rb_file o/r 5 "$H2")"; rm -f "$SD"/rebase/*.json "$SD"/rebase/*.out
  drop_line "rbjob o/r#5 $H2 done"; : > "$ROWS"
}
drv "mc_attempt_put 'rbjob o/r#5 $H2 done'"; : > "$REQ"
drv "ACTIONS=1 stuck_rekick 'o/r#5' NEEDS_REBASE - o/r 5 https://github.com/o/r/pull/5 $H2 DIRTY CONFLICTING main main none"
seen DELETE o/r 5 rbjob "$H2 done" && ok || bad "d: the stuck re-kick must forget the rbjob row: $(cat "$REQ")"
grep -qxF "rbjob o/r#5 $H2 done" "$ATT" && bad "d: the stuck re-kick must forget the rbjob line" || ok
spawn_ok "after the stuck re-kick"
drv "mc_attempt_put 'rbjob o/r#5 $H2 done'"; : > "$REQ"
OUT=$(drv "MC_RELEASE_LABEL=conductor-release mc_handoff_human_release 'o/r#5' $H2 conductor-release https://github.com/o/r/pull/5; echo rc=\$?")
[ "$OUT" = rc=0 ] && ok || bad "d: the release label must release (got '$OUT')"
seen DELETE o/r 5 rbjob "$H2 done" && ok || bad "d: the release label must forget the rbjob row: $(cat "$REQ")"
spawn_ok "after the release label"

echo "== g. a landing is a NEW rebase job: an old rbjob line must not refuse it =="
# land_rebase_arm re-rebases the SAME head onto a new main on purpose, deduped
# by its own `landrebase <key> <main sha>` mark. A finished job for that head
# whose file mc_lane_gc has since removed must not turn that into LAND_DEFER
# on every tick.
reset_all; flag up
drv "mc_attempt_put 'rbjob o/r#5 $H2 done'"; : > "$REQ"
OUT=$(drv "MC_LAND_REBASE=1 LAND_FIRE=1 LAND_SHA=4444444444444444444444444444444444444444
     KEY='o/r#5' SLUG=o/r NUM=5 P=demo-os BR=br HEAD=$H2 URL=https://github.com/o/r/pull/5 REC='$REC'
     mc_land_needed() { return 0; }   # the merge-tree probe: main moved, this head needs it
     PBASE=main BASEREF=main STATE=WAIT_CI WHY=- RAWLBL= ACTIONS=1 REVIEWED=$H1 VERDICT=APPROVE MSTATE=BEHIND
     land_rebase_arm; echo rc=\$?")
[ "$OUT" = rc=0 ] && ok || bad "g: the land arm must spawn its rebase (got '$OUT'): $(tail -2 "$LOG")"
seen DELETE o/r 5 rbjob "$H2 done" && ok || bad "g: the land arm must forget the old rbjob row first: $(cat "$REQ")"
grep -q "o/r#5 LAND_REBASE_SPAWNED" "$LOG" && ok || bad "g: want LAND_REBASE_SPAWNED: $(tail -2 "$LOG")"
wait_settled "$(mc_rb_file o/r 5 "$H2")"

echo "== h. a queue ejection is a NEW rebase job too =="
# eject_rebase_arm is deduped by `ejectrebase`, and reaches a head a finished
# land rebase left in place (rc 1/5 pushes nothing, and writes no `rebase` line).
reset_all; flag up
drv "mc_attempt_put 'rbjob o/r#5 $H2 done'; mc_attempt_put 'ejectconflict o/r#5 $H2'"; : > "$REQ"
OUT=$(drv "KEY='o/r#5' SLUG=o/r NUM=5 P=demo-os BR=br HEAD=$H2 URL=https://github.com/o/r/pull/5 REC='$REC'
     MERGES=1 REVIEWED=$H1 VERDICT=APPROVE MSTATE=DIRTY
     eject_rebase_arm; echo rc=\$?")
[ "$OUT" = rc=0 ] && ok || bad "h: the eject arm must spawn its rebase (got '$OUT'): $(tail -2 "$LOG")"
seen DELETE o/r 5 rbjob "$H2 done" && ok || bad "h: the eject arm must forget the old rbjob row first: $(cat "$REQ")"
grep -q "EJECT_REBASE_SPAWNED o/r#5 $H2" "$LOG" && ok || bad "h: want EJECT_REBASE_SPAWNED: $(tail -2 "$LOG")"
wait_settled "$(mc_rb_file o/r 5 "$H2")"

echo "== e. negatives =="
reset_all; flag up
drv "mc_rereview() { return 2; }
     jf=\$(mc_rr_file o/r 5 $H2); mkdir -p \"\$MC_RR_DIR\"
     mc_rr_write \"\$jf\" running 0 \"\$(mc_now)\" 0 - $H2 $H1 \"\${jf%.json}.out\"
     mc_rereview_run o/r 5 demo-os https://github.com/o/r/pull/5 $H1 $H2 '$REC' \"\$jf\" \"\${jf%.json}.out\""
[ "$(jq -r .status "$(mc_rr_file o/r 5 "$H2")")" = lane-failed ] && ok || bad "e: the stub lane failure must be recorded lane-failed"
grep -q '^rrjob ' "$ATT" && bad "e: a lane-failed job is not done and must record no rrjob: $(grep rrjob "$ATT")" || ok
grep -q '	rrjob	' "$REQ" && bad "e: a lane-failed job must PUT no rrjob row: $(cat "$REQ")" || ok
rm -f "$SD"/rereview/*
drv "mc_attempt_put 'rrjob o/r#5 $H2 done'"
OUT=$(drv "mc_rereview_spawn o/r 5 demo-os https://github.com/o/r/pull/5 $H1 $H2 '$REC'; echo rc=\$?")
[ "$OUT" = rc=4 ] && ok || bad "e: the finished (PR, head) itself must be refused (got '$OUT')"
for spec in "50 $H2" "5 $H1"; do
  set -- $spec
  OUT=$(drv "mc_rereview_spawn o/r $1 demo-os https://github.com/o/r/pull/$1 $H1 $2 '$REC'; echo rc=\$?")
  [ "$OUT" = rc=0 ] && ok || bad "e: rrjob o/r#5 $H2 must not block o/r#$1 head $2 (got '$OUT')"
  wait_settled "$(mc_rr_file o/r "$1" "$2")"; wait_rrjob o/r "$1" "$2"
done

echo "== f. flag down: no terminal line, no row traffic, spawns as today =="
reset_all; flag down
drv "mc_rereview() { printf APPROVE; return 0; }
     jf=\$(mc_rr_file o/r 5 $H2); mkdir -p \"\$MC_RR_DIR\"
     mc_rr_write \"\$jf\" running 0 \"\$(mc_now)\" 0 - $H2 $H1 \"\${jf%.json}.out\"
     mc_rereview_run o/r 5 demo-os https://github.com/o/r/pull/5 $H1 $H2 '$REC' \"\$jf\" \"\${jf%.json}.out\"
     mc_rebase() { echo 3333333333333333333333333333333333333333; return 0; }
     jf=\$(mc_rb_file o/r 5 $H2); mkdir -p \"\$MC_RB_DIR\"
     mc_rb_write \"\$jf\" running 0 \"\$(mc_now)\" 0 - $H2 - \"\${jf%.json}.out\"
     mc_rebase_run o/r 5 demo-os br $H2 https://github.com/o/r/pull/5 \"\$jf\" \"\${jf%.json}.out\""
[ "$(jq -r .status "$(mc_rr_file o/r 5 "$H2")")" = done ] && ok || bad "f: the re-review job must finish"
grep -qE '^(rrjob|rbjob) ' "$ATT" && bad "f: flag down must write no terminal line: $(cat "$ATT")" || ok
rm -f "$SD"/rereview/* "$SD"/rebase/*
OUT=$(drv "mc_rebase_spawn o/r 5 demo-os br $H2 https://github.com/o/r/pull/5; echo rc=\$?")
[ "$OUT" = rc=0 ] && ok || bad "f: flag down, a wiped job file relaunches exactly as today (got '$OUT')"
wait_settled "$(mc_rb_file o/r 5 "$H2")"
[ "$(nattreq)" = 0 ] && ok || bad "f: flag down must make no pr-attempts request: $(cat "$REQ")"

[ -s "$ERR" ] && grep -qE 'command not found|unbound variable' "$ERR" && bad "driver errors: $(cat "$ERR")"
echo "mc-jobs-rows.bh-2358: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
