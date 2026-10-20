#!/bin/bash
# tests/pool-rereview-row.bh-7635-test.sh — BH-7635 slice C1: the pool runs a
# conductor RE-REVIEW row (`RR-<pr>-<head8>`, meta kind=rereview).
#
# WHAT THIS IS ABOUT. A lane-run machine cannot run the detached re-review (its
# job file would never reach the hub), so C2 will queue it as a pool row, the
# same way a rebase is queued (RB-*). C1 is the pool side, and it ships first
# because, before it, a pool that saw an RR-* row read it as an ordinary BUILD
# of "ticket <pr>": a PR and a board comment nobody asked for.
#
#   J1-J7  bin/lib/rereview-job.sh: the machine body maps mc_rereview's rc to
#          one REREVIEW* RESULT, spends at most one read, carries MC_RR_REASON
#   B1     fly/builder-runner.sh's _run_job sends a rereview job to
#          run_rereview_job and to nothing else
#   RT1    queue_row_job_file -> job.json -> run_rereview_job: same values
#   Q1-Q6  bin/lib/queue-row-job.sh: the row becomes a rereview job, or it is
#          refused (rc 3, row failed, one alert, no file); rebase unchanged
#   Q3     driven through bin/fly-dispatch.sh: one alert, and none next tick
#   P1-P9  the pool arms treat RR-* as a conductor row, never as a ticket
#   A1-A8  mc_pool_rereview_apply / mc_pool_rereview_fail write the hub job file
#   D1     the RESULTs the apply refuses
#   RT2    rereview_job_run -> mc_pool_rereview_apply: the body byte for byte
#   C1     the real headbound_review consumes the files the apply wrote
#   R1-R4  bin/fly-pool.sh's reap, BUILD_DEFERRED and death arms on an RR row
#
# Every vendor is a stub: mc_rereview, gh, fly, the jobs API. Each case uses
# its own keys and its own directories.
# Run from anywhere: bash tests/pool-rereview-row.bh-7635-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

HEAD=abcdef01aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REV=1111111111111111111111111111111111111111
SLUG=example-org/mk
URL=https://github.com/example-org/mk/pull/12
KEY=RR-12-abcdef01
BODY_FIX="$T/body.md"
printf 'Finding 1:\tthe fixture body\n--- review ---\na line that looks like the separator\nVERDICT: BLOCK\n' > "$BODY_FIX"

# ════════════════════════════════════════════════════════════════════════════
# J  the machine body (bin/lib/rereview-job.sh)
# ════════════════════════════════════════════════════════════════════════════
HJ="$T/hj"; mkdir -p "$HJ"
jrun() { # jrun <case> <stub-rc> <stub-verdict> <head> <reason> [body-file]
  local d="$T/j/$1"; mkdir -p "$d"
  ( RR_STUB_RC="$2" RR_STUB_V="$3" RR_STUB_BODY="${6:-$BODY_FIX}" CALLS="$d/calls" ROWS="$d/rows"
    export RR_STUB_RC RR_STUB_V RR_STUB_BODY CALLS ROWS
    mc_rereview() { # slug num project url rev head rec out
      printf '%s|%s\n' "${MC_RR_REASON:-}" "$*" >> "$CALLS"
      cp "$RR_STUB_BODY" "$8"; printf 'model-fixture-1\n' > "$8.model"; printf 'claude\n' > "$8.runner"
      case "$RR_STUB_RC" in 2|3) printf 'call-guard repeat fp=review:x\n' > "$8.lanefail" ;; esac
      [ "$RR_STUB_RC" = 0 ] && printf '%s\n' "$RR_STUB_V"
      return "$RR_STUB_RC"
    }
    mc_rows_twin_on() { return 0; }
    mc_attempt_put() { printf '%s\n' "$*" >> "$ROWS"; }
    # shellcheck source=bin/lib/rereview-job.sh
    . "$DIR/bin/lib/rereview-job.sh" || exit 9
    rereview_job_run "$SLUG" 12 mk "$URL" "$REV" "$4" "$5" "$d/RESULT" "$HJ" )
  JD="$d"
}
calls() { [ -f "$JD/calls" ] && wc -l < "$JD/calls" | tr -d ' ' || echo 0; }

jrun j1 0 APPROVE "$HEAD" ""
[ "$(head -1 "$JD/RESULT" 2>/dev/null)" = "REREVIEWED APPROVE" ] && ok || bad "J1 line 1 is REREVIEWED APPROVE: $(head -3 "$JD/RESULT" 2>/dev/null)"
grep -qx "PR: $URL" "$JD/RESULT" 2>/dev/null && ok || bad "J1 the PR: line"
grep -qx "HEAD: $HEAD" "$JD/RESULT" 2>/dev/null && ok || bad "J1 the HEAD: line"
grep -qx "REVIEWED: $REV" "$JD/RESULT" 2>/dev/null && ok || bad "J1 the REVIEWED: line"
grep -qx "MODEL: model-fixture-1" "$JD/RESULT" 2>/dev/null && ok || bad "J1 the MODEL: line"
sed '1,/^--- review ---$/d' "$JD/RESULT" 2>/dev/null | cmp -s - "$BODY_FIX" && ok || bad "J1 the body after the first separator is the review verbatim"
[ "$(calls)" = 1 ] && ok || bad "J1 exactly one mc_rereview call, got $(calls)"
[ "$(cut -d'|' -f1 "$JD/calls" 2>/dev/null)" = "" ] && ok || bad "J1 MC_RR_REASON is the job's (empty)"
grep -qx "rrjob $SLUG#12 $HEAD done" "$JD/rows" 2>/dev/null && ok || bad "J1 a verdict writes the rrjob done row"

jrun j2 0 BLOCK "$HEAD" noverdict
[ "$(head -1 "$JD/RESULT" 2>/dev/null)" = "REREVIEWED BLOCK" ] && ok || bad "J2 REREVIEWED BLOCK"
sed '1,/^--- review ---$/d' "$JD/RESULT" 2>/dev/null | cmp -s - "$BODY_FIX" && ok || bad "J2 the whole BLOCK body is kept"
[ "$(cut -d'|' -f1 "$JD/calls" 2>/dev/null)" = noverdict ] && ok || bad "J2 the stub saw MC_RR_REASON=noverdict: $(cat "$JD/calls" 2>/dev/null)"

jrun j3 1 "" "$HEAD" prov
[ "$(head -1 "$JD/RESULT" 2>/dev/null)" = "REREVIEW_NOVERDICT" ] && ok || bad "J3 rc 1 is REREVIEW_NOVERDICT: $(head -1 "$JD/RESULT" 2>/dev/null)"
[ "$(cut -d'|' -f1 "$JD/calls" 2>/dev/null)" = prov ] && ok || bad "J3 MC_RR_REASON=prov"
[ -s "$JD/rows" ] && bad "J3 no verdict, no rrjob row" || ok

jrun j4 2 "" "$HEAD" ""
[ "$(head -1 "$JD/RESULT" 2>/dev/null)" = "REREVIEW_LANE_FAILED call-guard repeat fp=review:x" ] && ok || bad "J4 rc 2 is REREVIEW_LANE_FAILED <why>: $(head -1 "$JD/RESULT" 2>/dev/null)"
[ "$(calls)" = 1 ] && ok || bad "J4 one call"

jrun j5 3 "" "$HEAD" ""
[ "$(head -1 "$JD/RESULT" 2>/dev/null)" = "REREVIEW_DEFERRED call-guard repeat fp=review:x" ] && ok || bad "J5 rc 3 is REREVIEW_DEFERRED <why>: $(head -1 "$JD/RESULT" 2>/dev/null)"

jrun j6 0 APPROVE "abcdef01 bad" ""
[ "$(head -1 "$JD/RESULT" 2>/dev/null)" = "REREVIEW_SETUP_FAILED head" ] && ok || bad "J6 a bad head is REREVIEW_SETUP_FAILED head: $(head -1 "$JD/RESULT" 2>/dev/null)"
[ "$(calls)" = 0 ] && ok || bad "J6 a refused job spends no read, got $(calls)"
jrun j6b 0 APPROVE "$HEAD" "x"
[ "$(head -1 "$JD/RESULT" 2>/dev/null)" = "REREVIEW_SETUP_FAILED reason" ] && ok || bad "J6 a bad reason is refused: $(head -1 "$JD/RESULT" 2>/dev/null)"
[ "$(calls)" = 0 ] && ok || bad "J6 a bad reason spends no read"

head -c 300000 /dev/zero | tr '\0' 'x' > "$T/big.md"; printf '\nVERDICT: APPROVE\n' >> "$T/big.md"
jrun j7 0 APPROVE "$HEAD" "" "$T/big.md"
case "$(head -1 "$JD/RESULT" 2>/dev/null)" in "REREVIEW_LANE_FAILED review body over 262144 bytes") ok ;; *) bad "J7 an oversized body is a lane failure: $(head -1 "$JD/RESULT" 2>/dev/null)" ;; esac
grep -q '^--- review ---$' "$JD/RESULT" 2>/dev/null && bad "J7 no body is written, a review is never cut" || ok
[ -s "$JD/rows" ] && bad "J7 a verdict the hub never gets writes no rrjob row" || ok

# ════════════════════════════════════════════════════════════════════════════
# B1 / RT1  fly/builder-runner.sh dispatch, and the job.json round trip
# ════════════════════════════════════════════════════════════════════════════
HR="$T/hr"; mkdir -p "$HR/bin/lib"
# On the merge base bin/lib/rereview-job.sh does not exist: the install fails
# and B1 goes red, which is part of this suite's reproduction.
scratch_install_closure bin/lib/rereview-job.sh "$HR" >/dev/null 2>&1 || echo "note: bin/lib/rereview-job.sh is not installable"
awk '/^_run_job\(\) \{/,/^\}/; /^run_rereview_job\(\) \{/,/^\}/; /^rereview_setup_result\(\) \{/,/^\}/' \
  "$DIR/fly/builder-runner.sh" > "$T/runner-fns.sh"
QRJ_ALERTS="$T/qrj-alerts"
qrj() { # qrj <dest> <key> <ticket> <meta> -> rc of queue_row_job_file
  ( mkdir -p "$T/hq/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$QRJ_ALERTS" > "$T/hq/bin/alert-line.sh"; chmod +x "$T/hq/bin/alert-line.sh"
    queue_done() { printf '%s\n' "$*" >> "$T/qdone"; }
    # shellcheck source=bin/lib/queue-row-job.sh
    . "$DIR/bin/lib/queue-row-job.sh"
    HARNESS="$T/hq" queue_row_job_file mk "$1" "$2" "$3" 0 "$4" >/dev/null )
}
RMETA=$(jq -nc --arg s "$SLUG" --arg u "$URL" --arg r "$REV" --arg h "$HEAD" \
  '{kind:"rereview",slug:$s,url:$u,pr:12,reviewed:$r,head:$h,reason:"noverdict",dedup:"dd-fixture-1",by:"machine"}')
mkdir -p "$T/b1"
qrj "$T/b1/job.json" "$KEY" 12 "$RMETA"
( JOB="$T/b1/job.json" RESULT_FILE="$T/b1/RESULT" HARNESS="$HR" PROJECT=mk SINK="$T/b1/sink" CALLS="$T/b1/calls"
  export SINK CALLS
  log() { :; }; beat() { printf 'beat %s\n' "$*" >> "$SINK"; }
  load_env() { :; }; model_routes_warm() { :; }; start_heartbeat() { :; }; stop_heartbeat() { :; }
  warm_up() { printf 'warm_up\n' >> "$SINK"; return 0; }
  run_rebase_job() { printf 'run_rebase_job\n' >> "$SINK"; return 0; }
  slot_preflight() { printf 'build path\n' >> "$SINK"; return 1; }
  mc_rereview() { printf '%s|%s\n' "${MC_RR_REASON:-}" "$*" >> "$CALLS"; printf 'ok\nVERDICT: APPROVE\n' > "$8"; echo APPROVE; return 0; }
  mc_rows_twin_on() { return 1; }
  # shellcheck source=/dev/null
  . "$T/runner-fns.sh"
  _run_job )
[ "$(head -1 "$T/b1/RESULT" 2>/dev/null)" = "REREVIEWED APPROVE" ] && ok || bad "B1 a rereview job.json runs the re-review: $(head -1 "$T/b1/RESULT" 2>/dev/null)"
grep -q 'run_rebase_job' "$T/b1/sink" 2>/dev/null && bad "B1 a rereview job is never a rebase" || ok
grep -q 'build path' "$T/b1/sink" 2>/dev/null && bad "B1 THE POINT: a rereview job never reaches the build path" || ok
grep -q '"stage":"rereview_done"' "$T/b1/sink" 2>/dev/null && ok || bad "B1 the runner beats rereview_done: $(cat "$T/b1/sink" 2>/dev/null)"
# RT1: the values the stub saw are the values the queue row carried.
case "$(cat "$T/b1/calls" 2>/dev/null)" in
  "noverdict|$SLUG 12 mk $URL $REV $HEAD  "*) ok ;;
  *) bad "RT1 the runner hands mc_rereview the row's slug, pr, url, reviewed, head and reason: $(cat "$T/b1/calls" 2>/dev/null)" ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# Q  bin/lib/queue-row-job.sh
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/q"
qrj "$T/q/q1.json" "$KEY" 12 "$RMETA"; rc=$?
[ "$rc" = 0 ] && ok || bad "Q1 a good rereview row is written, rc $rc"
[ "$(jq -r '.rereview.kind // ""' "$T/q/q1.json" 2>/dev/null)" = rereview ] && ok || bad "Q1 THE POINT: job.json carries rereview.kind — got $(cat "$T/q/q1.json" 2>/dev/null)"
[ "$(jq -r '.rereview | [.slug,(.pr|tostring),.head,.reviewed,.reason,.url] | join(" ")' "$T/q/q1.json" 2>/dev/null)" = "$SLUG 12 $HEAD $REV noverdict $URL" ] \
  && ok || bad "Q1 the rereview fields survive: $(jq -c .rereview "$T/q/q1.json" 2>/dev/null)"
jq -e 'has("rebase")' "$T/q/q1.json" >/dev/null 2>&1 && bad "Q1 a rereview row is not a rebase" || ok
NEST=$(jq -nc --argjson r "$RMETA" '{kind:"rereview",rereview:($r|del(.kind))}')
qrj "$T/q/q2.json" "$KEY" 12 "$NEST"
[ "$(jq -c .rereview "$T/q/q2.json" 2>/dev/null)" = "$(jq -c .rereview "$T/q/q1.json" 2>/dev/null)" ] && ok || bad "Q2 the nested meta gives the same object: $(cat "$T/q/q2.json" 2>/dev/null)"
FRESH=$(printf '%s' "$RMETA" | jq -c '.reviewed="-" | .reason=""')
qrj "$T/q/q2b.json" "$KEY" 12 "$FRESH" && [ "$(jq -r '.rereview.reviewed' "$T/q/q2b.json" 2>/dev/null)" = "-" ] && ok || bad "Q2 reviewed '-' (a fresh review) is a job"
qrefused() { # qrefused <case> <key> <meta> <field>
  local rc
  rm -f "$T/qdone" "$QRJ_ALERTS" "$T/q/r.json"
  qrj "$T/q/r.json" "$2" 12 "$3"; rc=$?
  [ "$rc" = 3 ] && ok || bad "$1 rc 3 (refused), got $rc"
  [ -f "$T/q/r.json" ] && bad "$1 THE POINT: a refused row writes no job file — $(cat "$T/q/r.json")" || ok
  grep -q "failed rereview meta rejected ($4)" "$T/qdone" 2>/dev/null && ok || bad "$1 the row is closed failed naming '$4': $(cat "$T/qdone" 2>/dev/null)"
  [ "$(wc -l < "$QRJ_ALERTS" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "$1 exactly one alert line"
}
qrefused "Q3 pr 12x"         "$KEY" "$(printf '%s' "$RMETA" | jq -c '.pr="12x"')" pr
qrefused "Q3 head space"     "$KEY" "$(printf '%s' "$RMETA" | jq -c '.head="abcdef01 aaaa"')" head
qrefused "Q3 slug space"     "$KEY" "$(printf '%s' "$RMETA" | jq -c '.slug="a b/c"')" slug
qrefused "Q4 reason x"       "$KEY" "$(printf '%s' "$RMETA" | jq -c '.reason="x"')" reason
qrefused "Q5 rereview on T-9" T-9   "$RMETA" key
qrefused "Q5 RR with no meta" "$KEY" "" kind
qrefused "Q5 RR with rebase"  "$KEY" '{"kind":"rebase","slug":"o/r","url":"https://github.com/o/r/pull/12","pr":12,"branch":"ticket/x","head":"abcdef01aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","base":"main"}' kind
qrefused "Q5 head8 not the key" RR-12-ffffffff "$RMETA" key
# Q6: the rebase and plain rows give the same bytes as before.
nostamp() { sed 's/"enqueued_at":"[^"]*"/"enqueued_at":"TS"/' "$1"; }
RBMETA='{"kind":"rebase","slug":"o/r","url":"https://github.com/o/r/pull/21","pr":21,"branch":"ticket/TK-21","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","base":"main"}'
qrj "$T/q/q6.json" RB-21-aaaaaaaa 21 "$RBMETA"
[ "$(nostamp "$T/q/q6.json")" = '{"ticket_id":"21","key":"RB-21-aaaaaaaa","attempt":0,"deferrals":0,"enqueued_at":"TS","source":"db","rebase":{"kind":"rebase","slug":"o/r","url":"https://github.com/o/r/pull/21","pr":21,"branch":"ticket/TK-21","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","base":"main"}}' ] \
  && ok || bad "Q6 a rebase row writes the same bytes as before: $(nostamp "$T/q/q6.json")"
qrj "$T/q/q6b.json" TK-9 9 ''
[ "$(nostamp "$T/q/q6b.json")" = '{"ticket_id":"9","key":"TK-9","attempt":0,"deferrals":0,"enqueued_at":"TS","source":"db"}' ] \
  && ok || bad "Q6 a plain build row writes the same bytes as before: $(nostamp "$T/q/q6b.json")"

# Q3 through bin/fly-dispatch.sh: one alert for the bad row, none on the next
# tick, because the closed row is not offered again.
HD="$T/hd"
mkdir -p "$HD/bin" "$HD/logs" "$HD/flags" "$HD/locks" "$HD/env" "$HD/state/build-queue/tproj" "$T/dbin"
cp "$DIR/bin/fleet-conf.sh" "$HD/bin/"
scratch_install_closure bin/jobs-client.sh "$HD" >/dev/null || { echo "closure install of bin/jobs-client.sh failed"; exit 1; }
scratch_install_closure bin/fly-dispatch.sh "$HD" >/dev/null || { echo "closure install of bin/fly-dispatch.sh failed"; exit 1; }
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/d-alerts"\n' "$T" > "$HD/bin/alert-line.sh"; chmod +x "$HD/bin/alert-line.sh"
cp "$DIR/fleet.conf" "$HD/fleet.conf"
: > "$HD/env/global.env"; : > "$HD/env/fly.env"; touch "$HD/flags/builder-fly-tproj"
printf '#!/bin/bash\nexit 0\n' > "$T/dbin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/dbin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/dbin/ssh"; printf '#!/bin/bash\nexit 0\n' > "$T/dbin/scp"
cat > "$T/dbin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/queue/claim)
    KEY=$(printf '%s' "$BODY" | jq -r '.key // ""' 2>/dev/null)
    printf '{"queued":{"project":"tproj","ticket_key":"%s","ticket_id":"x","target":"fly","attempt":0,"status":"claimed"},"claimed":true}\n200\n' "$KEY" ;;
  */api/queue\?*)
    if [ -s "$ROWSET" ]; then cat "$ROWSET"; printf '\n200\n'; else printf '{"queue":[]}\n200\n'; fi ;;
  */api/queue)
    # A row closed `failed` is not offered again: the next GET is empty.
    case "$M $BODY" in PATCH*'"status":"failed"'*) : > "$ROWSET" ;; esac
    printf '{"ok":true}\n200\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/dbin"/*
jq -nc --argjson m "$(printf '%s' "$RMETA" | jq -c '.pr="12x"')" --arg k "$KEY" \
  '{queue:[{project:"tproj",ticket_key:$k,ticket_id:"12",status:"queued",target:"fly",attempt:0,claimed_by:null,enqueued_at:"2026-10-20T01:00:00Z",reason:null,meta:$m}]}' > "$T/rowset.json"
dtick() {
  ( export PATH="$T/dbin:$PATH" HARNESS="$HD" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid \
           JOBS_BOX=hub JOBS_RETRIES=0 REQ_SINK="$T/dreq" ROWSET="$T/rowset.json" FLEET_CONF="$HD/fleet.conf"
    bash "$DIR/bin/fly-dispatch.sh" >"$T/dout" 2>&1 )
}
dtick
[ "$(wc -l < "$T/d-alerts" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "Q3 the dispatcher's tick over a bad rereview row: exactly one alert, got $(cat "$T/d-alerts" 2>/dev/null)"
ls "$HD/state/build-queue/tproj"/RR-*.json >/dev/null 2>&1 && bad "Q3 THE POINT: no queue file for the refused row" || ok
grep -q "rereview meta rejected (pr)" "$T/dreq" 2>/dev/null && ok || bad "Q3 the row is closed failed with the field named: $(cat "$T/dreq" 2>/dev/null)"
dtick
[ "$(wc -l < "$T/d-alerts" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "Q3 the next tick over the closed row adds no alert"

# ════════════════════════════════════════════════════════════════════════════
# P  the pool arms (bin/fly-pool.sh and the pool libs)
# ════════════════════════════════════════════════════════════════════════════
awk '/^pool_spawn_decision\(\) \{/,/^\}/' "$DIR/bin/fly-pool.sh" > "$T/psd.sh"
P1OUT=$( SINK="$T/p1sink"; export SINK
  say() { printf '%s\n' "$*"; }
  for f in pool_tick_budget_spent psr_marker_has psr_marker_put psr_marker_clear hold_check pool_hold_check pool_spawn_cap_check; do
    eval "$f() { printf '%s\n' $f >> \"\$SINK\"; return 1; }"
  done
  _POOL_ROWS_DECIDED=1
  # shellcheck source=/dev/null
  . "$T/psd.sh"
  pool_spawn_decision "$T/q/q1.json" "$KEY" 12; echo "rc=$?" )
case "$P1OUT" in *"re-review row"*"rc=0"*) ok ;; *) bad "P1 an RR row answers rc 0 with the conductor-row line: $P1OUT" ;; esac
[ -s "$T/p1sink" ] && bad "P1 THE POINT: no ticket gate is asked of an RR row: $(tr '\n' ' ' < "$T/p1sink")" || ok

sed -n '/^job_is_hot() {/,/^}/p; /^job_is_now() {/,/^}/p; /^hotfix_first() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$T/hf.sh"
QW="$T/qw"; mkdir -p "$QW" "$T/hw/state/dispatch-now/p"
printf '{"key":"TK-1"}\n' > "$QW/TK-1.json"; printf '{"key":"TK-2","hotfix": true}\n' > "$QW/TK-2.json"
printf '{"key":"RR-9-aaaa"}\n' > "$QW/RR-9-aaaa.json"; printf '{"key":"RB-8-bbbb"}\n' > "$QW/RB-8-bbbb.json"
OUT=$(HOTFIX_ON=1 HARNESS="$T/hw" P=p bash -c '. "$1"; shift; hotfix_first "$@"' _ "$T/hf.sh" \
  "$QW/TK-1.json" "$QW/RR-9-aaaa.json" "$QW/TK-2.json" "$QW/RB-8-bbbb.json" | xargs -n1 basename | tr '\n' ' ')
[ "$OUT" = "TK-2.json RR-9-aaaa.json RB-8-bbbb.json TK-1.json " ] && ok || bad "P2 the walk is hot, then RB/RR rows, then builds, each once: $OUT"

# shellcheck source=bin/lib/pool-stall.sh
P3=$( . "$DIR/bin/lib/pool-stall.sh"; pool_inflight_hold_due 12 "$KEY" ok 1 "a|1" "b|1" 0 4 )
[ "$P3" = "$(printf 'skip\trereview')" ] && ok || bad "P3 pool-stall skips an RR row: '$P3'"
# shellcheck source=bin/lib/pool-orphan-rows.sh
P4=$( . "$DIR/bin/lib/pool-orphan-rows.sh"; pool_orphan_row_verdict claimed fly pool-x pool-x "$KEY" 9999 60 0 0 0 "" )
[ "$P4" = "$(printf 'keep\trereview')" ] && ok || bad "P4 pool-orphan-rows keeps an RR row: '$P4'"
P5=$( SINK="$T/p5sink"; export SINK
  ta_gate() { printf 'ta_gate\n' >> "$SINK"; PROJECT_2_LINE=fixture; return 1; }
  say() { :; }; QROW() { printf 'QROW %s\n' "$*" >> "$SINK"; }; pool_hold_clear() { :; }
  # shellcheck source=bin/lib/pool-actor-gate.sh
  . "$DIR/bin/lib/pool-actor-gate.sh"; P=mk; pool_actor_gate "$T/q/q1.json" "$KEY" 12; echo "rc=$?" )
[ "$P5" = "rc=0" ] && [ ! -s "$T/p5sink" ] && ok || bad "P5 pool-actor-gate passes an RR row without the actor check: $P5 $(cat "$T/p5sink" 2>/dev/null)"
P6=$( SINK="$T/p6sink"; export SINK
  # shellcheck source=bin/lib/ticket-ownership.sh
  . "$DIR/bin/lib/ticket-ownership.sh" 2>/dev/null
  to_issue_repo() { printf 'to_issue_repo\n' >> "$SINK"; echo o/r; }
  to_hold_verdict() { printf 'to_hold_verdict\n' >> "$SINK"; return 0; }
  to_build_hold mk 12 "$KEY" >/dev/null; echo "rc=$?" )
[ "$P6" = "rc=1" ] && [ ! -s "$T/p6sink" ] && ok || bad "P6 ticket-ownership: an RR row is not a ticket to hold: $P6 $(cat "$T/p6sink" 2>/dev/null)"
# shellcheck source=bin/lib/docker-pool-host.sh
( . "$DIR/bin/lib/docker-pool-host.sh" >/dev/null 2>&1; dph_key_ok "$KEY" ) && bad "P7 dph_key_ok refuses RR-*" || ok
( . "$DIR/bin/lib/docker-pool-host.sh" >/dev/null 2>&1; dph_key_ok TK-12 ) && ok || bad "P7 near miss: a plain key is still ok"
grep -q 'RR-\*' "$DIR/bin/docker-pool-runner.sh" && ok || bad "P7 the docker runner's refusal text names RR-*"
# shellcheck source=bin/lib/ticket-identity.sh
( . "$DIR/bin/lib/ticket-identity.sh" >/dev/null 2>&1; _ti_is_build_row "$RMETA" ) && bad "P8 an RR row is not a build row of ticket 12" || ok
( . "$DIR/bin/lib/ticket-identity.sh" >/dev/null 2>&1; _ti_is_build_row '{"hotfix":true}' ) && ok || bad "P8 near miss: a build meta is still a build row"
RPO="$DIR/bin/result-prefix-ok.sh"
bash "$RPO" "REREVIEWED APPROVE" && ok || bad "P9 REREVIEWED APPROVE is a RESULT"
bash "$RPO" "REREVIEW_LANE_FAILED x" && ok || bad "P9 REREVIEW_LANE_FAILED is a RESULT"
bash "$RPO" "REREVIEW_NOVERDICT" && ok || bad "P9 REREVIEW_NOVERDICT is a RESULT"
bash "$RPO" "REREVIEWX" && bad "P9 REREVIEWX is not a RESULT" || ok
bash "$RPO" "RR_APPROVE" && bad "P9 RR_APPROVE is not a RESULT" || ok
bash "$RPO" " REREVIEWED APPROVE" && bad "P9 a leading space is a miss" || ok

# ════════════════════════════════════════════════════════════════════════════
# A / D1 / RT2 / C1  the hub apply (bin/lib/mc/rebase.sh) and its reader
# ════════════════════════════════════════════════════════════════════════════
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
[ -d "$DIR/bin/lib/mc" ] || exit 1   # impact: this suite runs when bin/lib/mc/ changes
ARUN="$T/arun.sh"
cat > "$ARUN" <<'EOS'
# sourced in a subshell by `a` below: the real conductor lib in a scratch harness
export HARNESS="$AH"
. "$AH/bin/lib/merge-conductor-lib.sh" || exit 9
mc_init >/dev/null 2>&1
EOS
AH="$T/h"; export AH
( export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" ) || { echo "fx_mc_harness failed"; exit 1; }
result() { # result <file> <line1> [head] [url] [with-body 0|1]
  { printf '%s\nPR: %s\nHEAD: %s\nREVIEWED: %s\nREASON: -\nMODEL: model-fixture-1\nRUNNER: claude\n' "$2" "${4:-$URL}" "${3:-$HEAD}" "$REV"
    [ "${5:-1}" = 1 ] && { printf -- '--- review ---\n'; cat "$BODY_FIX"; }; } > "$1"
}
a() { ( . "$ARUN"; "$@" ); }
JF="$T/h/state/merge-conductor/rereview/example-org_mk_12_$HEAD.json"
st() { ( . "$ARUN"; mc_rr_state "$JF" ); }
fld() { ( . "$ARUN"; mc_rr_field "$JF" "$1" ); }

result "$T/a1" "REREVIEWED APPROVE"
a mc_pool_rereview_apply mk "$KEY" "$T/a1"; rc=$?
[ "$rc" = 0 ] && ok || bad "A1 the apply answers rc 0, got $rc"
[ "$(st)" = done ] && ok || bad "A1 the job file is done: $(st)"
[ "$(fld verdict)" = APPROVE ] && ok || bad "A1 verdict APPROVE: $(fld verdict)"
[ "$(fld head_sha)" = "$HEAD" ] && [ "$(fld reviewed_sha)" = "$REV" ] && ok || bad "A1 the head and reviewed shas"
cmp -s "$(fld out_file)" "$BODY_FIX" && ok || bad "A1 out_file holds the body byte for byte"
[ "$(head -1 "$(fld out_file).model" 2>/dev/null)" = model-fixture-1 ] && ok || bad "A1 the .out.model line"
cp "$JF" "$T/a1.snap"
a mc_pool_rereview_apply mk "$KEY" "$T/a1"; rc=$?
[ "$rc" = 0 ] && cmp -s "$JF" "$T/a1.snap" && ok || bad "A7 a second apply of the same RESULT is a no-op, rc $rc"
result "$T/a7b" "REREVIEW_NOVERDICT" "$HEAD" "$URL" 0
a mc_pool_rereview_apply mk "$KEY" "$T/a7b"
cmp -s "$JF" "$T/a1.snap" && ok || bad "A7 a done file of the same head is never overwritten"
a mc_pool_rereview_fail mk "$KEY" "fixture death"
cmp -s "$JF" "$T/a1.snap" && ok || bad "A8 the fail never overwrites a done file"

# C1: the real headbound_review reads that file and binds the approval.
C1=$( . "$ARUN"
  hb_approve_bind() { printf 'BIND %s|%s\n' "${10}" "${11:-}"; return 0; }
  hb_block_park() { printf 'PARK %s|%s\n' "$7" "${9:-}"; return 0; }
  mc_hv_override() { return 1; }
  headbound_review moved "$SLUG#12" "$SLUG" 12 mk "$URL" "" "$HEAD" "$REV" APPROVE CLEAN green )
case "$C1" in "BIND "*"(model-fixture-1)"*"APPROVE"*"|$(fld out_file)") ok ;; *) bad "C1 headbound_review binds the pool APPROVE with the body file: $C1" ;; esac
rm -f "$JF" "$T/h/state/merge-conductor/attempts.txt"
result "$T/a2" "REREVIEWED BLOCK"
a mc_pool_rereview_apply mk "$KEY" "$T/a2"
[ "$(st)" = done ] && [ "$(fld verdict)" = BLOCK ] && ok || bad "A2 done BLOCK: $(st) $(fld verdict)"
C1B=$( . "$ARUN"
  hb_approve_bind() { printf 'BIND %s\n' "$*"; return 0; }
  hb_block_park() { printf 'PARK|%s\n' "${9:-}"; return 0; }
  mc_hv_override() { return 1; }
  headbound_review moved "$SLUG#12" "$SLUG" 12 mk "$URL" "" "$HEAD" "$REV" APPROVE CLEAN green )
[ "$C1B" = "PARK|$(fld out_file)" ] && cmp -s "$(fld out_file)" "$BODY_FIX" && ok || bad "C1 headbound_review parks the pool BLOCK with the body in the post: $C1B"
for c in "A3|REREVIEW_LANE_FAILED x|lanefail|x" "A3|REREVIEW_SETUP_FAILED no conductor lib|lanefail|no conductor lib" "A4|REREVIEW_NOVERDICT|failed|"; do
  IFS='|' read -r n l want why <<<"$c"
  rm -f "$JF"; result "$T/a3" "$l" "$HEAD" "$URL" 0
  a mc_pool_rereview_apply mk "$KEY" "$T/a3"; rc=$?
  [ "$rc" = 0 ] && [ "$(st)" = "$want" ] && ok || bad "$n '$l' gives $want, got rc $rc $(st)"
  [ -z "$why" ] || { [ "$(fld reason)" = "$why" ] && ok || bad "$n the reason is '$why': $(fld reason)"; }
done
result "$T/a5" "REREVIEW_DEFERRED call-guard repeat" "$HEAD" "$URL" 0
a mc_pool_rereview_apply mk "$KEY" "$T/a5"; rc=$?
[ "$rc" = 0 ] && [ ! -f "$JF" ] && ok || bad "A5 a deferral removes the job file (the none case), rc $rc"
rm -f "$JF"
result "$T/a6" "REREVIEWED APPROVE" "ffffffff$(printf '%.32s' "$HEAD" | tr 'a-f' '0-5')"
a mc_pool_rereview_apply mk "$KEY" "$T/a6"; rc=$?
[ "$rc" = 1 ] && ! ls "$T/h/state/merge-conductor/rereview/"*.json >/dev/null 2>&1 && ok || bad "A6 a head8 that is not the key's is refused with no file, rc $rc"
a mc_pool_rereview_fail mk "$KEY" "the pool machine died" "$RMETA"; rc=$?
[ "$rc" = 0 ] && [ "$(st)" = lanefail ] && ok || bad "A8 a machine death is lane-failed, never failed: rc $rc $(st)"
[ "$(fld reviewed_sha)" = "$REV" ] && ok || bad "A8 the fail carries the row's reviewed sha"
rm -f "$JF"
# D1: the refused list — rc 1, no file.
drefuse() { # drefuse <case> <key> <file>
  rm -f "$T/h/state/merge-conductor/rereview/"*.json
  a mc_pool_rereview_apply mk "$2" "$3"; local rc=$?
  [ "$rc" = 1 ] && ! ls "$T/h/state/merge-conductor/rereview/"*.json >/dev/null 2>&1 && ok || bad "D1 $1 is refused with no file, rc $rc"
}
result "$T/d1" "REREVIEWED MAYBE";   drefuse "REREVIEWED MAYBE" "$KEY" "$T/d1"
result "$T/d2" "REVIEW_BLOCKED x";   drefuse "a build word" "$KEY" "$T/d2"
result "$T/d3" "REBASED abc";        drefuse "a rebase word on an RR key" "$KEY" "$T/d3"
result "$T/d4" "REREVIEWED APPROVE" "$HEAD" "$URL" 0; drefuse "REREVIEWED with no review body" "$KEY" "$T/d4"
: > "$T/d5";                         drefuse "an empty RESULT" "$KEY" "$T/d5"
result "$T/d6" "REREVIEWED APPROVE" "$HEAD" "https://github.com/example-org/mk/pull/13"; drefuse "a PR: line for another PR" "$KEY" "$T/d6"
result "$T/d7" "REREVIEWED APPROVE"; drefuse "a key that is not RR-" RB-12-abcdef01 "$T/d7"
# RT2: the machine writer and the hub reader agree, body byte for byte.
jrun rt2 0 BLOCK "$HEAD" ""
rm -f "$JF"
a mc_pool_rereview_apply mk "$KEY" "$JD/RESULT"; rc=$?
[ "$rc" = 0 ] && [ "$(fld verdict)" = BLOCK ] && cmp -s "$(fld out_file)" "$BODY_FIX" && ok \
  || bad "RT2 rereview_job_run -> mc_pool_rereview_apply keeps the verdict and the body (only the first separator splits), rc $rc"
rm -f "$JF"

# ════════════════════════════════════════════════════════════════════════════
# R  bin/fly-pool.sh: the reap, BUILD_DEFERRED and death arms on an RR row
# ════════════════════════════════════════════════════════════════════════════
H="$T/p"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$H/state/fly" \
         "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" "$H/state/build-queue/tproj" "$T/pbin" "$T/relay"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/psink"; return 0; }
queue_put() { printf 'put %s\n' "\$*" >> "$T/psink"; echo queued; return 0; }
queue_status() { echo claimed; return 0; }
_jobs_req() { printf 'req %s\n' "\$*" >> "$T/psink"; cat "$T/prow.json" 2>/dev/null; }
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
printf 'HARNESS_SECRET=fixture-secret\n' > "$H/env/global.env"
printf 'FLY_API_TOKEN_TPROJ=tok-fixture-1\n' > "$H/env/fly.env"
printf 'tproj example-org/mk - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-tproj"; printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/pbeat"\nexit 0\n' "$T" > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/pbin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/pbin/flock"; printf '#!/bin/bash\nexit 0\n' > "$T/pbin/sleep"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/pgh"\nexit 1\n' "$T" > "$T/pbin/gh"
cat > "$T/pbin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/pfly"
case "\$*" in
  *"machine status"*) echo "State: \$(cat "$T/pmstate" 2>/dev/null || echo started)"; exit 0 ;;
  *"ssh console"*"head"*"RESULT"*) head -1 "$T/relay/RESULT" 2>/dev/null; exit 0 ;;
  *"ssh console"*"base64"*"RESULT"*) [ -s "$T/relay/RESULT" ] && base64 -w0 "$T/relay/RESULT"; exit 0 ;;
  *"ssh console"*) exit 0 ;;
  *"machines list"*) echo '[]' ;;
esac
exit 0
FLY
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$T/pbin"/*
jq -nc --argjson m "$RMETA" --arg k "$KEY" \
  '{queue:[{project:"tproj",ticket_key:$k,ticket_id:"12",status:"claimed",target:"fly",attempt:0,meta:$m}]}' > "$T/prow.json"
PJF="$H/state/merge-conductor/rereview/example-org_mk_12_$HEAD.json"
preap() { # preap <key> <result-file-or-empty> [machine-state]
  local p
  for p in "$H/builds"/* "$H/state/merge-conductor/rereview" "$H/state/build-queue/tproj"/* "$H/logs/ALERTS.log" \
           "$T/psink" "$T/pbeat" "$T/pgh" "$T/pfly" "$T/relay/RESULT" "$T/pmstate"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  [ -n "$2" ] && cp "$2" "$T/relay/RESULT"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$T/pmstate"
  : > "$H/logs/fly-pool.log"
  jq -nc --arg k "$1" '{machine:"m1",key:$k,ticket_id:"12",attempt:0}' > "$H/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/pbin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" FLY_API_TOKEN_TPROJ=tok-fixture-1 \
           FLY_BIN_DIR="$T/pbin" POOL_SPAWN=0 GH_TOKEN="" POOL_PR_VERIFY_SLEEP=0
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  PLOCAL=$(ls -d "$H/builds/pool-tproj-$1-"* 2>/dev/null | head -1)
}
pst() { ( AH="$H"; . "$ARUN"; mc_rr_state "$PJF" ); }

result "$T/r1" "REREVIEWED APPROVE"
preap "$KEY" "$T/r1"
grep -q "^done tproj $KEY done REREVIEWED APPROVE" "$T/psink" 2>/dev/null && ok || bad "R1 the row is closed done with RESULT line 1: $(cat "$T/psink" 2>/dev/null)"
[ "$(pst)" = done ] && ok || bad "R1 THE POINT: the reap writes the conductor's job file: $(pst)"
[ -f "$PLOCAL/COMMENTED" ] && ok || bad "R1 the dir owes no board close-out (COMMENTED)"
# The tick's own preamble asks gh for the repo id and a token; the reap must
# add no PR read and no comment.
grep -E 'pulls|issues|comments' "$T/pgh" 2>/dev/null && bad "R1 no PR read and no board comment for a re-review row: $(cat "$T/pgh")" || ok
ls "$H/state/remote-results/tproj/"* >/dev/null 2>&1 && bad "R1 a re-review RESULT is never a remote result" || ok
grep -q "pool rereview RESULT reaped" "$H/logs/fly-pool.log" && ok || bad "R1 the reap line is logged: $(tail -5 "$H/logs/fly-pool.log")"
grep -q '"stage":"pool_result"' "$T/pbeat" 2>/dev/null && bad "R1 a re-review does not beat as a finished build" || ok
grep -q 'machine destroy\|machine stop' "$T/pfly" 2>/dev/null && ok || bad "R1 the machine is still handled"

result "$T/r4" "REREVIEWED APPROVE" "ffffffff$(printf '%.32s' "$HEAD" | tr 'a-f' '0-5')"
preap "$KEY" "$T/r4"
grep -q "^done tproj $KEY" "$T/psink" 2>/dev/null && bad "R4 THE POINT: a refused apply leaves the row claimed: $(cat "$T/psink")" || ok
[ -f "$PJF" ] && bad "R4 a refused apply writes no job file" || ok
[ "$(grep -c "$PLOCAL/RESULT" "$H/logs/ALERTS.log" 2>/dev/null | head -1)" = 1 ] && ok || bad "R4 exactly one ALERTS line naming the RESULT path: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "pool rereview RESULT reaped" "$H/logs/fly-pool.log" && bad "R4 no reaped line when the apply refused" || ok

result "$T/r5" "REBASED bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
preap "$KEY" "$T/r5"
grep -q "^done tproj $KEY failed" "$T/psink" 2>/dev/null && ok || bad "R1 a rebase word on an RR key fails the row: $(cat "$T/psink" 2>/dev/null)"
ls "$H/state/merge-conductor/rebase/"*.json >/dev/null 2>&1 && bad "R1 a rebase word on an RR key is never applied as a rebase" || ok
result "$T/r6" "PR_CREATED https://github.com/example-org/mk/pull/55"
preap "$KEY" "$T/r6"
ls "$H/state/remote-results/tproj/"* >/dev/null 2>&1 && bad "R1 THE POINT: a build word on an RR key is never read as a build" || ok
grep -E 'pulls|issues|comments' "$T/pgh" 2>/dev/null && bad "R1 a build word on an RR key reads no PR and posts nothing" || ok

preap "$KEY" "" stopped
grep -q "^done tproj $KEY failed" "$T/psink" 2>/dev/null && ok || bad "R2 a dead RR machine fails the row: $(cat "$T/psink" 2>/dev/null)"
grep -qE "^done tproj $KEY failed .*(died|deferred) [0-9]+ times" "$T/psink" 2>/dev/null && bad "R2 the reason is no blocked-resolver trigger" || ok
grep -q "^put tproj $KEY" "$T/psink" 2>/dev/null && bad "R2 THE POINT: a dead RR row is never requeued" || ok
ls "$H/state/build-queue/tproj/"* >/dev/null 2>&1 && bad "R2 no queue file and no .failed.json: $(ls "$H/state/build-queue/tproj")" || ok
[ "$(pst)" = lanefail ] && ok || bad "R2 the job file is lane-failed (no strike): $(pst)"

result "$T/r3" "BUILD_DEFERRED warm-up failed" "$HEAD" "$URL" 0
preap "$KEY" "$T/r3"
grep -q "^done tproj $KEY failed" "$T/psink" 2>/dev/null && ok || bad "R3 a stand-down fails the row: $(cat "$T/psink" 2>/dev/null)"
grep -qE "^done tproj $KEY failed .*(died|deferred) [0-9]+ times" "$T/psink" 2>/dev/null && bad "R3 the reason is no blocked-resolver trigger" || ok
grep -q "^put tproj $KEY" "$T/psink" 2>/dev/null && bad "R3 THE POINT: a deferred RR row is never requeued" || ok
ls "$H/state/build-queue/tproj/"* >/dev/null 2>&1 && bad "R3 no queue file and no .failed.json" || ok
[ "$(pst)" = lanefail ] && ok || bad "R3 the job file is lane-failed: $(pst)"
[ -f "$PLOCAL/COMMENTED" ] && ok || bad "R3 COMMENTED is stamped"

echo "pool-rereview-row.bh-7635-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
