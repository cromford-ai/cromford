#!/bin/bash
# tests/pool-rebase-result-row.bh-7656-test.sh — BH-7656: a pool REBASE that
# finished on a machine which then autostopped is applied from its pool-result
# row, not failed as a death.
#
# The runner writes an RB- key's pool-result row with the whole RESULT in
# detail.result (fly/builder-runner.sh pool_result_row_write, `full`). The hub
# reap (bin/fly-pool.sh) reads that row for an RB- key on a machine that is not
# started, and a rebase word in it goes to the existing RB apply arm. Any other
# answer is a miss and takes the existing dead arm.
#
# Cases:
#   W1 RB key, POOL_MODE=1 -> one ledger-put, detail.result carries the PR: line
#   W2 build key -> detail keys are exactly rline,machine,at (no result)
#   W3 POOL_MODE unset -> no write
#   W4 empty key -> no write
#   G1 round trip REBASED (PR:/HEAD: lines, TIMINGS: last) -> the real
#      mc_pool_rebase_apply rc 0, hub job file done rc 0
#   G2 round trip CONFLICT -> apply rc 0, hub job file done rc 1
#   G3 row with no `result` field -> the outfile gets the rline
#   A1 bin/fly-pool.sh whole: machine stopped, row of this machine, GATE_RED
#      -> apply, queue row done (reason = first 200 bytes), say lines, no
#      `died (state=stopped)` ALERTS line
#   A2 REBASED <sha> + PR: -> apply rc 0, row done
#   A3 REBASE_SETUP_FAILED -> apply path, row done
#   A4 row of another machine -> dead arm
#   A5 row older than spawn - 60 s -> dead arm
#   A6 RB row with a BUILD_DEFERRED rline -> dead arm
#   A7 rline `Oops goroutine` -> dead arm
#   A8 ledger unreadable (rc 1) -> dead arm plus one `unreadable` say line
#   A9 machine started -> the ssh path, no pool-result row read
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pool-rebase-result-row.bh-7656-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

RSHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NSHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
RKEY=RB-21-aaaaaaaa
PRURL=https://github.com/o/r/pull/21
RB_TAIL="PR: $PRURL
HEAD: $RSHA
BRANCH: ticket/TK-21
BASE: main"

# ════════════════════════════════════════════════════════════════════════════
# W  the runner writes the row (fly/builder-runner.sh, lifted)
# ════════════════════════════════════════════════════════════════════════════
W="$T/w"
mkdir -p "$W/run"
scratch_install_closure bin/lib/pool-result-row.sh "$W" >/dev/null \
  || { echo "cannot install bin/lib/pool-result-row.sh"; exit 1; }
cat > "$W/bin/jobs-client.sh" <<JC
#!/bin/bash
printf '%s\n' "\$@" > "$T/w-argv"
exit 0
JC
chmod +x "$W/bin/jobs-client.sh"

awk '/^run_job\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$W/run/runjob.sh"
awk '/^pool_result_row_write\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" >> "$W/run/runjob.sh"
grep -q '^run_job()' "$W/run/runjob.sh" && grep -q '^pool_result_row_write()' "$W/run/runjob.sh" \
  && ok || bad "W0 could not lift run_job / pool_result_row_write out of fly/builder-runner.sh"

W_RESULT="GATE_RED typecheck
$RB_TAIL
GATE: typecheck=1 unit=skipped
TIMINGS: setup=40 merge=2 gates=88 push=-"

drive_runner() { # drive_runner <key> <POOL_MODE>
  rm -f "$T/w-argv"
  ( HARNESS="$W"; PROJECT=tproj; JOB="$W/run/job.json"; RESULT_FILE="$W/run/RESULT"
    export POOL_MODE="$2" FLY_MACHINE_ID=m1
    jq -nc --arg k "$1" '{ticket_id:"21",key:$k}' > "$JOB"
    log() { echo "$*" >> "$W/run/log"; }
    cost_rows_flush() { :; }
    _run_job() { printf '%s\n' "$W_RESULT" > "$RESULT_FILE"; return 0; }
    unset -f pool_result_row_put pool_result_row_get pool_result_row_key
    . "$W/run/runjob.sh"
    run_job; echo "rc=$?" > "$W/run/rc" )
}

# W1
drive_runner "$RKEY" 1
mapfile -t A < "$T/w-argv" 2>/dev/null || A=()
[ "${A[0]:-} ${A[1]:-} ${A[2]:-} ${A[3]:-}" = "ledger-put pool-result tproj/$RKEY result" ] \
  && ok || bad "W1 an RB key must write one ledger-put: $(tr '\n' ' ' < "$T/w-argv" 2>/dev/null)"
W1DET="${A[4]:-}"
printf '%s' "$W1DET" | jq -e --arg u "PR: $PRURL" '.result | split("\n") | index($u) != null' >/dev/null 2>&1 \
  && ok || bad "W1 detail.result must carry the PR: line: $W1DET"
[ "$(printf '%s' "$W1DET" | jq -r .rline 2>/dev/null)" = "GATE_RED typecheck" ] \
  && ok || bad "W1 detail.rline is the RESULT's first line: $W1DET"
[ "$(cat "$W/run/rc" 2>/dev/null)" = rc=0 ] && ok || bad "W1 run_job's rc changed: $(cat "$W/run/rc" 2>/dev/null)"

# W2
drive_runner BH-21 1
mapfile -t A < "$T/w-argv" 2>/dev/null || A=()
[ "${A[0]:-} ${A[2]:-}" = "ledger-put tproj/BH-21" ] \
  && ok || bad "W2 a build key still writes its row: $(tr '\n' ' ' < "$T/w-argv" 2>/dev/null)"
[ "$(printf '%s' "${A[4]:-}" | jq -c 'keys_unsorted' 2>/dev/null)" = '["rline","machine","at"]' ] \
  && ok || bad "W2 a build row's detail keys are exactly rline,machine,at: ${A[4]:-}"

# W3
drive_runner "$RKEY" ""
[ -e "$T/w-argv" ] && bad "W3 POOL_MODE unset must write no row: $(tr '\n' ' ' < "$T/w-argv")" || ok

# W4
drive_runner "" 1
[ -e "$T/w-argv" ] && bad "W4 an empty key must write no row: $(tr '\n' ' ' < "$T/w-argv")" || ok

# ════════════════════════════════════════════════════════════════════════════
# G  round trip: put -> fake ledger store -> get (real lib) -> real apply
# ════════════════════════════════════════════════════════════════════════════
G="$T/g"
mkdir -p "$G/logs" "$T/gstore"
scratch_install_closure bin/lib/pool-result-row.sh "$G" >/dev/null \
  || { echo "cannot install bin/lib/pool-result-row.sh"; exit 1; }
for s in bin/lib/merge-conductor-lib.sh bin/result-prefix-ok.sh; do
  scratch_install_closure "$s" "$G" >/dev/null || { echo "cannot install the closure of $s"; exit 1; }
done
# The fake jobs-client: ledger-put stores {status,detail} under the key.
cat > "$G/bin/jobs-client.sh" <<JC
#!/bin/bash
[ "\$1" = ledger-put ] || exit 1
jq -nc --arg s "\$4" --arg d "\$5" '{status:\$s,detail:\$d}' > "$T/gstore/\$(printf '%s_%s' "\$2" "\$3" | tr '/' '_')"
JC
chmod +x "$G/bin/jobs-client.sh"

GSPAT=$(date -u -d "@$((NOW-900))" '+%Y-%m-%d %H:%M:%SZ')

# round_trip <case> <result-text> [strip-result]
#   prints "<get-rc> <apply-rc>"; the outfile lands at $T/g-out-<case>.
round_trip() {
  ( export HARNESS="$G" MC_TTL_NEEDS_REBASE=1800
    printf '%s\n' "$2" > "$T/g-result-$1"
    rm -f "$T/gstore"/*
    # shellcheck source=bin/lib/pool-result-row.sh
    . "$G/bin/lib/pool-result-row.sh" || exit 9
    pool_result_row_put tproj "$RKEY" m1 "$T/g-result-$1" full || { echo "put-failed -"; exit 0; }
    SF="$T/gstore/pool-result_tproj_$RKEY"
    if [ "${3:-}" = strip ]; then
      jq -c '.detail |= (fromjson | del(.result) | tojson)' "$SF" > "$SF.n" && mv "$SF.n" "$SF"
    fi
    job_ledger_row() { [ -s "$T/gstore/$(printf '%s_%s' "$1" "$2" | tr '/' '_')" ] || return 2; cat "$T/gstore/$(printf '%s_%s' "$1" "$2" | tr '/' '_')"; }
    pool_result_row_get tproj "$RKEY" m1 "$GSPAT" "$T/g-out-$1" > "$T/g-rline-$1"; GRC=$?
    # shellcheck source=bin/lib/merge-conductor-lib.sh
    . "$G/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || { echo "$GRC lib"; exit 0; }
    job_verdict_rebind() { printf '%s\n' "$*" >> "$T/g-rebind"; return 0; }
    job_ledger_put() { return 0; }
    mc_pool_rebase_apply tproj "$RKEY" "$T/g-out-$1" >/dev/null 2>&1; ARC=$?
    echo "$GRC $ARC" )
}
GJF="$G/state/merge-conductor/rebase/o_r_21_$RSHA.json"

# G1 REBASED with a TIMINGS: line last
G1_RES="REBASED $NSHA
$RB_TAIL
GATE: typecheck=0 unit=0
TIMINGS: setup=31 merge=3 gates=120 push=4"
: > "$T/g-rebind"
OUT=$(round_trip g1 "$G1_RES")
[ "$OUT" = "0 0" ] && ok || bad "G1 get rc / apply rc want '0 0', got '$OUT'"
[ "$(cat "$T/g-out-g1" 2>/dev/null)" = "$G1_RES" ] \
  && ok || bad "G1 the outfile is the whole RESULT: $(cat "$T/g-out-g1" 2>/dev/null)"
[ "$(cat "$T/g-rline-g1" 2>/dev/null)" = "REBASED $NSHA" ] && ok || bad "G1 the get prints the rline"
[ "$(jq -r '.status + " " + .rc + " " + .new_head' "$GJF" 2>/dev/null)" = "done 0 $NSHA" ] \
  && ok || bad "G1 hub job file must be done rc 0 new_head $NSHA: $(cat "$GJF" 2>/dev/null)"
grep -q "^$PRURL $NSHA\$" "$T/g-rebind" && ok || bad "G1 the rebind got the PR and the new sha: $(cat "$T/g-rebind")"

# G2 CONFLICT
rm -f "$GJF"
OUT=$(round_trip g2 "CONFLICT a.txt b.txt
$RB_TAIL
TIMINGS: setup=20 merge=1 gates=- push=-")
[ "$OUT" = "0 0" ] && ok || bad "G2 get rc / apply rc want '0 0', got '$OUT'"
[ "$(jq -r '.status + " " + .rc' "$GJF" 2>/dev/null)" = "done 1" ] \
  && ok || bad "G2 hub job file must be done rc 1 (CONFLICT): $(cat "$GJF" 2>/dev/null)"

# G3 no `result` field: the outfile gets the rline and a newline
OUT=$(round_trip g3 "GATE_RED unit
$RB_TAIL" strip)
case "$OUT" in "0 "*) ok ;; *) bad "G3 the get still answers rc 0 for a row with no result: '$OUT'" ;; esac
[ "$(od -An -c "$T/g-out-g3" 2>/dev/null | tr -s ' ' | tr -d '\n')" = "$(printf 'GATE_RED unit\n' | od -An -c | tr -s ' ' | tr -d '\n')" ] \
  && ok || bad "G3 the outfile is the rline + newline: $(cat "$T/g-out-g3" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# A  bin/fly-pool.sh whole, with stubbed fly / mexec / jobs worker
# ════════════════════════════════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$H/state/fly" \
         "$H/state/fly-pool/tproj" "$H/state/remote-results/tproj" \
         "$H/state/build-queue/tproj" "$T/fakebin" "$T/led"
for s in bin/fly-pool.sh bin/jobs-client.sh bin/alert-line.sh bin/result-prefix-ok.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "cannot install the closure of $s"; exit 1; }
done
printf 'tproj example-org/tproj - - 0 local\n' > "$H/fleet.conf"
printf 'HARNESS_SECRET=fixture-secret\n' > "$H/env/global.env"
printf 'FLY_API_TOKEN_TPROJ=fixture-token\n' > "$H/env/fly.env"
printf '3\n'           > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n'  > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"

printf '#!/bin/bash\nexit 0\n'            > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n'            > "$T/fakebin/sleep"
printf '#!/bin/bash\nshift; exec "$@"\n'  > "$T/fakebin/timeout"
printf '#!/bin/bash\necho "ssh $*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/ssh"
printf '#!/bin/bash\necho "scp $*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/scp"
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_SINK"
printf 'HTTP/2.0 200 OK\n\n{"state":"open","merged_at":null}\n'
exit 0
STUB
# The machine: listed in $MSTATE_FIX; ssh answers the RESULT fixture only when
# it is non-empty (a stopped machine answers nothing). Every argv recorded.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "fly $*" >> "$FLY_SINK"
case "$*" in
  *"machines list"*)  printf '[{"id":"m1","state":"%s"}]\n' "${MSTATE_FIX:-started}" ;;
  *"machine status"*) echo "State: ${MSTATE_FIX:-started}" ;;
  *base64*RESULT*)    [ -s "${RESULT_FIXTURE:-/dev/null}" ] && base64 -w0 "$RESULT_FIXTURE" ;;
  *base64*)           : ;;
  *head*RESULT*)      head -1 "${RESULT_FIXTURE:-/dev/null}" 2>/dev/null ;;
  *ls*builds*)        echo "/data/harness/builds/tproj-x-1" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
STUB
# The jobs worker. The pool-result ledger row comes from $LED/mode:
#   row  -> 200 with $LED/row     none -> 404     down -> 500
# The verdict read answers a bound verdict so the REAL rebind succeeds.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$M $URL" in
  "GET "*/api/ledger\?kind=pool-result*)
    case "$(cat "$LED/mode" 2>/dev/null)" in
      row)  cat "$LED/row"; printf '\n200\n' ;;
      down) printf '{"error":"fixture outage"}\n500\n' ;;
      *)    printf '{"error":"not found"}\n404\n' ;;
    esac ;;
  "GET "*/api/ledger\?*) printf '{"error":"not found"}\n404\n' ;;
  "GET "*/api/verdict\?*)
    printf '{"job_id":"j-fixture","verdict":"APPROVE","reviewed_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifacts":[{"artifact_kind":"verdict","detail":"{}"}]}\n200\n' ;;
  *" "*/api/queue/claim)
    KEY=$(printf '%s' "$BODY" | jq -r '.key // ""' 2>/dev/null)
    printf '{"queued":{"project":"tproj","ticket_key":"%s","ticket_id":"x","target":"fly","attempt":0,"status":"claimed"},"claimed":true}\n200\n' "$KEY" ;;
  "GET "*/api/queue\?*) printf '{"queue":[]}\n200\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin"/*

RBD="$H/state/merge-conductor/rebase"
JF="$RBD/o_r_21_$RSHA.json"
SPAWN_EPOCH=$((NOW-900))
SPAWNED_AT=$(date -u -d "@$SPAWN_EPOCH" '+%Y-%m-%d %H:%M:%SZ')

seed_job() { # the hub job file mc_pool_rebase_enqueue leaves at `pool`
  mkdir -p "$RBD"
  jq -nc --arg h "$RSHA" --arg o "$RBD/o_r_21_$RSHA.out" \
    '{status:"pool",pid:0,started_at:1000,finished_at:0,rc:"-",head_sha:$h,new_head:"-",out_file:$o}' > "$JF"
}
# led_row <rline> <machine> <at-epoch> [result-text]
led_row() {
  jq -nc --arg r "$1" --arg m "$2" --argjson a "$3" --arg res "${4:-}" \
    '{ledger:{status:"result",detail:({rline:$r,machine:$m,at:$a} + (if $res == "" then {} else {result:$res} end) | tojson)}}' \
    > "$T/led/row"
  echo row > "$T/led/mode"
}

# pool <machine-state> [ssh-result-text]
pool() {
  local p
  for p in "$H/builds"/* "$H/state/remote-results/tproj"/* "$H/state/build-queue/tproj"/* \
           "$H/state/fly-pool/tproj"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"; : > "$H/logs/fly-pool.log"
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/fly.txt"; : > "$T/beat.txt"; : > "$T/gh.txt"
  printf '%s' "${2:-}" > "$T/result.txt"
  jq -nc --arg k "$RKEY" --arg ts "$SPAWNED_AT" \
    '{machine:"m1",key:$k,ticket_id:"21",attempt:0,deferrals:0,deaths:0,spawned_at:$ts}' \
    > "$H/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=fixture-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
           FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=fixture-token POOL_PR_VERIFY_SLEEP=0 POOL_SPAWN=0 \
           REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" FLY_SINK="$T/fly.txt" \
           BEAT_SINK="$T/beat.txt" GH_SINK="$T/gh.txt" LED="$T/led" \
           RESULT_FIXTURE="$T/result.txt" MSTATE_FIX="$1"
    bash "$H/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  LOCALDIR=$(ls -d "$H/builds/pool-tproj-$RKEY-"* 2>/dev/null | head -1)
  # The tick must reach the reap at all (the scratch copy of the script is what
  # runs, so an edit in the checkout cannot trip pts_stop_due mid-suite).
  grep -q 'tick stopped at a row boundary' "$H/logs/fly-pool.log" \
    && bad "harness: the tick stopped before the reap: $(grep 'tick stopped' "$H/logs/fly-pool.log")"
  return 0
}
LOG="$H/logs/fly-pool.log"
queue_reason() { # queue_reason <status> -> the reason of the PATCH that closed the row <status>
  grep "^PATCH https://jobs.invalid/api/queue " "$T/req.txt" | cut -d' ' -f3- \
    | jq -rs --arg k "$RKEY" --arg s "$1" '[.[] | select(.key==$k and .status==$s) | .reason // ""] | first // ""' 2>/dev/null
}
row_closed() { # row_closed <status>
  grep "^PATCH https://jobs.invalid/api/queue " "$T/req.txt" | cut -d' ' -f3- \
    | jq -e --arg k "$RKEY" --arg s "$1" 'select(.key==$k and .status==$s)' >/dev/null 2>&1
}
row_reads() { grep -c "^GET https://jobs.invalid/api/ledger?kind=pool-result&key=tproj%2F$RKEY" "$T/req.txt" | head -1; }

# expect_dead <case>: the existing dead arm, unchanged.
expect_dead() {
  row_closed failed && ok || bad "$1 the dead arm closes the row failed: $(cat "$T/req.txt")"
  row_closed done && bad "$1 a miss must never close the row done" || ok
  grep -q "$RKEY: rebase machine m1 died (state=stopped)" "$H/logs/ALERTS.log" \
    && ok || bad "$1 the dead arm's ALERTS line: $(cat "$H/logs/ALERTS.log")"
  [ "$(jq -r .status "$JF" 2>/dev/null)" = failed ] \
    && ok || bad "$1 the hub job file is failed by the dead arm: $(cat "$JF" 2>/dev/null)"
  grep -q 'taken from the pool-result row' "$LOG" && bad "$1 a miss was taken as a result: $(cat "$LOG")" || ok
  [ -n "$LOCALDIR" ] && [ -f "$LOCALDIR/REBASE" ] && bad "$1 no REBASE sentinel on a miss" || ok
}

# A1 GATE_RED from the row of this machine
A1_RES="GATE_RED typecheck src/a.ts(12,3): error TS2322: Type 'string' is not assignable to type 'number'.
$RB_TAIL
GATE: typecheck=1 unit=skipped
TIMINGS: setup=41 merge=2 gates=97 push=-"
seed_job
led_row "GATE_RED typecheck src/a.ts(12,3): error TS2322: Type 'string' is not assignable to type 'number'." m1 $((SPAWN_EPOCH+31)) "$A1_RES"
pool stopped
[ "$(row_reads)" -ge 1 ] && ok || bad "A1 the row must be read for an RB key on a stopped machine: $(cat "$T/req.txt")"
row_closed done && ok || bad "A1 THE POINT: the queue row is closed done: $(cat "$T/req.txt")"
WANT=$(head -c 200 < <(printf '%s\n' "$A1_RES"))
[ "$(queue_reason done)" = "$WANT" ] && ok || bad "A1 the done reason is the first 200 bytes of the RESULT: '$(queue_reason done)'"
grep -q "result for $RKEY taken from the pool-result row (machine m1 state=stopped" "$LOG" \
  && ok || bad "A1 the say line names the row and the machine: $(cat "$LOG")"
grep -q "reaped rebase $RKEY from m1: .* timings: setup=41 merge=2 gates=97 push=-" "$LOG" \
  && ok || bad "A1 the reaped line carries the timings: $(grep reaped "$LOG")"
grep -q 'died (state=stopped)' "$H/logs/ALERTS.log" \
  && bad "A1 THE POINT: no died ALERTS line: $(cat "$H/logs/ALERTS.log")" || ok
row_closed failed && bad "A1 the row must not be failed" || ok
[ "$(jq -r '.status + " " + .rc' "$JF" 2>/dev/null)" = "done 2" ] \
  && ok || bad "A1 the real apply wrote the hub job file done rc 2: $(cat "$JF" 2>/dev/null)"
[ -n "$LOCALDIR" ] && [ "$(cat "$LOCALDIR/RESULT" 2>/dev/null)" = "$A1_RES" ] \
  && ok || bad "A1 \$LOCAL/RESULT is the row's whole text: $(cat "$LOCALDIR/RESULT" 2>/dev/null)"
[ -n "$LOCALDIR" ] && [ -f "$LOCALDIR/REBASE" ] && ok || bad "A1 the REBASE sentinel is stamped"
grep -q 'machine destroy' "$T/fly.txt" && ok || bad "A1 the stopped machine is still destroyed"

# A2 REBASED <sha> + PR:
seed_job
A2_RES="REBASED $NSHA
$RB_TAIL
GATE: typecheck=0 unit=0
TIMINGS: setup=30 merge=3 gates=101 push=5"
led_row "REBASED $NSHA" m1 $((SPAWN_EPOCH+300)) "$A2_RES"
pool stopped
row_closed done && ok || bad "A2 the queue row is closed done: $(cat "$T/req.txt")"
[ "$(jq -r '.status + " " + .rc + " " + .new_head' "$JF" 2>/dev/null)" = "done 0 $NSHA" ] \
  && ok || bad "A2 the apply recorded rc 0 and the new head: $(cat "$JF" 2>/dev/null)"
grep -q 'died (state=stopped)' "$H/logs/ALERTS.log" && bad "A2 no died ALERTS line" || ok

# A3 REBASE_SETUP_FAILED
seed_job
A3_RES="REBASE_SETUP_FAILED warm-up failed
$RB_TAIL
GATE: typecheck=skipped unit=skipped
TIMINGS: setup=600 merge=- gates=- push=-"
led_row "REBASE_SETUP_FAILED warm-up failed" m1 $((SPAWN_EPOCH+620)) "$A3_RES"
pool stopped
row_closed done && ok || bad "A3 the queue row is closed done: $(cat "$T/req.txt")"
[ "$(jq -r '.status + " " + .rc' "$JF" 2>/dev/null)" = "done 4" ] \
  && ok || bad "A3 the apply recorded rc 4: $(cat "$JF" 2>/dev/null)"
grep -q 'died (state=stopped)' "$H/logs/ALERTS.log" && bad "A3 no died ALERTS line" || ok

# A4 row of another machine
seed_job
led_row "GATE_RED typecheck" m2 $((SPAWN_EPOCH+31)) "$A1_RES"
pool stopped
expect_dead A4

# A5 row older than spawn - 60 s
seed_job
led_row "GATE_RED typecheck" m1 $((SPAWN_EPOCH-61)) "$A1_RES"
pool stopped
expect_dead A5

# A6 BUILD_DEFERRED in an RB row
seed_job
led_row "BUILD_DEFERRED warm-up failed" m1 $((SPAWN_EPOCH+31)) "BUILD_DEFERRED warm-up failed
$RB_TAIL"
pool stopped
expect_dead A6
grep -q 'DEFERRED' "$LOG" && bad "A6 the RB row's deferral must not take the deferral arm: $(cat "$LOG")" || ok

# A7 ssh-panic noise as the rline
seed_job
led_row "Oops goroutine 1 [running]:" m1 $((SPAWN_EPOCH+31)) "Oops goroutine 1 [running]:"
pool stopped
expect_dead A7

# A8 ledger unreadable
seed_job
led_row "GATE_RED typecheck" m1 $((SPAWN_EPOCH+31)) "$A1_RES"
echo down > "$T/led/mode"
pool stopped
expect_dead A8
N=$(grep -c "pool-result row for $RKEY unreadable" "$LOG" | head -1)
[ "$N" = 1 ] && ok || bad "A8 exactly one unreadable say line, got $N: $(cat "$LOG")"

# A9 machine started: ssh path, no row read
seed_job
led_row "CONFLICT from-the-row.txt" m1 $((SPAWN_EPOCH+31)) "CONFLICT from-the-row.txt
$RB_TAIL"
pool started "CONFLICT from-ssh.txt
$RB_TAIL"
[ "$(row_reads)" = 0 ] && ok || bad "A9 THE POINT: a started machine reads no pool-result row: $(grep 'kind=pool-result' "$T/req.txt")"
grep -q 'ssh console' "$T/fly.txt" && ok || bad "A9 the ssh path is used: $(cat "$T/fly.txt")"
row_closed done && ok || bad "A9 the ssh RESULT is applied and the row closed done: $(cat "$T/req.txt")"
case "$(queue_reason done)" in "CONFLICT from-ssh.txt"*) ok ;; *) bad "A9 the applied RESULT is the ssh one: '$(queue_reason done)'" ;; esac
grep -q 'taken from the pool-result row' "$LOG" && bad "A9 no row say line on the ssh path" || ok

echo "pool-rebase-result-row.bh-7656-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
