#!/bin/bash
# tests/mc-verdict-read-bound.bh-8020-test.sh — BH-8020: the merge conductor's
# verdict-read step names, times and bounds each call it makes.
#
# Sentry CROMFORD-HARNESS-T: a worker was killed at its 419 s deadline in step
# verdict-read, and the event named the step but no call. The step's reads
# (mc_verdict, mc_contradiction_words in bin/lib/mc/classify.sh) ran with no
# bound and no call file.
#
#   V1  a normal step: one VERDICT_READ line with each call's seconds and rc;
#       the verdict is the one mc_verdict gives outside the step
#   V2  a read 1 s under the bound completes
#   V3  a hung headbound read ends at the bound: one VERDICT_READ_TIMEOUT line,
#       mc_vr_end rc 1, no alert, no Sentry event, no ready-why on a QUEUED row
#   V4  knob 0: a slow read completes; mc_vr_bound_s over its decision table
#   V5  a fast outage (rc 1) and no ledger row (rc 2) fall back to the record
#   V6  after a cut, a later read of the step runs nothing
#   V7  the PR lock is free when the worker returns; no stub process is left
#   V8  a cut on a READY row: fan-in reads READY held:verdict-read-timeout and
#       the row file is unchanged
#   V9  under 1 s of worker time left: no call runs, a took=0s timeout line
#   V10 a slow write (-w) is never cut
#   V11 outside the step: same verdict, no VERDICT_READ line, call file untouched
#   C1  while a read runs the call file holds the 5-field BH-7029 line; then empty
#   D1  a real deadline kill in verdict-read: the Sentry tags carry the call
#   D2  the WORKER_DEADLINE line carries ` | call: verdict-read/headbound (`
#   P1  the WHOLE bin/merge-conductor.sh tick with a hung /api/verdict read:
#       VERDICT_READ_TIMEOUT, no enqueue step; P0 is the same tick, not hung
#   K1  lane_env_apply merge-conductor gives MC_VERDICT_READ_CALL_TIMEOUT_S=45
#
# Every read is a stub function or a stub curl: 0 vendor calls. A hang is a
# stub `sleep 30.8020N` (N per case), so V7 can look for its own leftovers.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-verdict-read-bound.bh-8020-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

VP="$REPO/bin/lib/verdict-parse.sh"
CL="$REPO/bin/lib/mc/classify.sh"
FANIN="$REPO/bin/lib/fanin.sh"
FRAG="$REPO/bin/merge-conductor.d/bh-8020-verdict-read-bound.sh"
HEADSHA=6a7867e3ff00000000000000000000000000f1a7
URL=https://github.com/o/r/pull/81
WANT=$(printf 'APPROVE\tjudge\t%s\tJ-fixture-1\tn/a' "$HEADSHA")

# The stubs every case starts from: every read answers at once.
STUBS='
job_verdict_headbound() { printf "n/a"; }
job_verdict() { printf "APPROVE\t2\tjudge\t-\tJ-fixture-1\t%s\n" "$HEADSHA"; }
_mc_fanin_alert() { echo alert >> "$c/alerts"; }
sentry_report() { echo sentry >> "$c/alerts"; }
mc_row_field() { awk -F"\t" -v k="$1" -v n="$2" "\$1 == k { print \$n }" "$c/rows"; }
mc_now() { date +%s; }
mc_attempt_has() { return 1; }
mc_attempt_put() { :; }
'
STEP='mc_vr_begin; mc_verdict "$URL" "$c/rec" > "$c/verdict"; mc_vr_end; echo $? > "$c/rc"'

# vr_case <name> <setup + body> [env...] — one shell with the real verdict
# reader, fan-in lib and fragment loaded. Leaves rc, took, log, alerts and
# verdict in $T/<name>. The row file holds one QUEUED row for o/r#81.
vr_case() {
  local c="$T/$1" body="$2" t0; shift 2
  mkdir -p "$c/rec" "$c/state"; : > "$c/log"; : > "$c/alerts"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$c/rec/review.md"; echo "$HEADSHA" > "$c/rec/reviewed-sha"
  printf 'o/r#81\t%s\t%s\n' "${ROWST:-QUEUED}" "$HEADSHA" > "$c/rows"
  t0=$SECONDS
  env "$@" HEADSHA="$HEADSHA" URL="$URL" bash -c '
    c=$1; . "$2" || exit 1; . "$3" || exit 1; . "$4" || exit 1; . "$5" || exit 1
    mc_log() { printf "%s\n" "$*" >> "$c/log"; }
    KEY=o/r#81; HEAD=$HEADSHA; MC_STATE_DIR="$c/state"
    eval "$6"; eval "$7"
  ' _ "$c" "$VP" "$CL" "$FANIN" "$FRAG" "$STUBS" "$body" > "$c/out" 2>&1
  echo $((SECONDS - t0)) > "$c/took"
}
rc()   { cat "$T/$1/rc" 2>/dev/null; }
took() { cat "$T/$1/took" 2>/dev/null; }
lg()   { cat "$T/$1/log" "$T/$1/out" 2>/dev/null; }

# ---- V1 a normal step ----------------------------------------------------------
vr_case v1 'mc_verdict "$URL" "$c/rec" > "$c/plain"; '"$STEP" MC_VERDICT_READ_CALL_TIMEOUT_S=5
[ "$(rc v1)" = 0 ] && ok "V1 mc_vr_end rc 0" || bad "V1 rc: $(rc v1) $(lg v1)"
[ "$(grep -c 'VERDICT_READ took=' "$T/v1/log")" = 1 ] && ok "V1 one VERDICT_READ line" || bad "V1 lines: $(lg v1)"
grep -Eq '^o/r#81 VERDICT_READ took=[0-9]+\.[0-9]s calls: review-file=[0-9]+\.[0-9]s rc=0 headbound=[0-9]+\.[0-9]s rc=0 ledger-verdict=[0-9]+\.[0-9]s rc=0$' "$T/v1/log" \
  && ok "V1 the line names each call with its seconds and rc" || bad "V1 line: $(lg v1)"
! grep -q VERDICT_READ_TIMEOUT "$T/v1/log" && ok "V1 no timeout line" || bad "V1 timeout: $(lg v1)"
[ "$(cat "$T/v1/verdict")" = "$WANT" ] && [ "$(cat "$T/v1/plain")" = "$WANT" ] \
  && ok "V1 the verdict equals the one outside the step" || bad "V1 verdict: '$(cat "$T/v1/verdict")' plain '$(cat "$T/v1/plain")'"

# ---- V2 a read 1 s under the bound -----------------------------------------------
vr_case v2 'job_verdict_headbound() { sleep 2; printf "n/a"; }; '"$STEP" MC_VERDICT_READ_CALL_TIMEOUT_S=3   # determinism: ok a slow read that must NOT be cut
[ "$(rc v2)" = 0 ] && ok "V2 rc 0" || bad "V2 rc: $(rc v2) $(lg v2)"
! grep -q VERDICT_READ_TIMEOUT "$T/v2/log" && ok "V2 no timeout line" || bad "V2 log: $(lg v2)"
[ "$(cat "$T/v2/verdict")" = "$WANT" ] && ok "V2 the slow answer counts" || bad "V2 verdict: $(cat "$T/v2/verdict")"

# ---- V3 a hung headbound read ends at the bound -----------------------------------
vr_case v3 'job_verdict_headbound() { sleep 30.80203; }; '"$STEP" MC_VERDICT_READ_CALL_TIMEOUT_S=2   # determinism: ok the stub IS the hung read the bound cuts
[ "$(rc v3)" = 1 ] && ok "V3 mc_vr_end rc 1" || bad "V3 rc: $(rc v3) $(lg v3)"
[ "$(took v3)" -le 10 ] && ok "V3 ended in $(took v3)s (<= 10)" || bad "V3 took $(took v3)s"
grep -Eq '^o/r#81 VERDICT_READ_TIMEOUT call=verdict-read/headbound took=[23]s timeout=2s rc=124: ' "$T/v3/log" \
  && ok "V3 VERDICT_READ_TIMEOUT names the call, took, bound and rc" || bad "V3 log: $(lg v3)"
[ "$(grep -c VERDICT_READ_TIMEOUT "$T/v3/log")" = 1 ] && ok "V3 one timeout line" || bad "V3 lines: $(lg v3)"
grep -Eq '^o/r#81 VERDICT_READ took=.* headbound=[0-9.]+s rc=124 ' "$T/v3/log" && ok "V3 the step line shows rc=124" || bad "V3 step line: $(lg v3)"
[ ! -s "$T/v3/alerts" ] && ok "V3 no alert, no Sentry event" || bad "V3 alerts: $(cat "$T/v3/alerts")"
[ -z "$(ls "$T/v3/state/ready-why" 2>/dev/null)" ] && ok "V3 a QUEUED row gets no ready-why note" || bad "V3 ready-why: $(ls "$T/v3/state/ready-why")"

# ---- V4 knob 0: no bound; the bound's decision table ------------------------------
vr_case v4 'job_verdict_headbound() { sleep 2; printf "n/a"; }; '"$STEP" MC_VERDICT_READ_CALL_TIMEOUT_S=0   # determinism: ok a slow read that must NOT be cut
[ "$(rc v4)" = 0 ] && ! grep -q VERDICT_READ_TIMEOUT "$T/v4/log" && ok "V4 knob 0: the slow read completes" || bad "V4 knob 0: $(lg v4)"
bound() {
  env -u MC_VERDICT_READ_CALL_TIMEOUT_S -u MC_WORKER_DEADLINE_AT "$@" bash -c '
    . "$1" || exit 1; . "$2" || exit 1; b=$(mc_vr_bound_s); echo "$?:$b"' _ "$FANIN" "$FRAG" 2>&1
}
NOWS=$(date +%s)
while IFS='|' read -r knob at want; do
  args=()
  [ "$knob" = - ] || args+=("MC_VERDICT_READ_CALL_TIMEOUT_S=$knob")
  [ "$at" = - ] || args+=("MC_WORKER_DEADLINE_AT=$((NOWS + at))")
  got=$(bound "${args[@]}")
  [[ "$got" =~ ^($want)$ ]] && ok "V4 knob '$knob' deadline '$at' -> $got" || bad "V4 knob '$knob' deadline '$at': want $want, got $got"
done <<'EOF'
-|-|0:45
0|-|0:0
abc|-|0:45
-5|-|0:45
10|-|0:10
10|600|0:10
45|30|0:1[45]
0|5|0:0
45|5|1:
EOF

# ---- V5 a fast outage, and no ledger row, fall back to the record -------------------
for r in 1 2; do
  vr_case "v5r$r" "job_verdict() { return $r; }; $STEP" MC_VERDICT_READ_CALL_TIMEOUT_S=5
  [ "$(rc "v5r$r")" = 0 ] && ok "V5 job_verdict rc $r: mc_vr_end rc 0" || bad "V5 rc $r: $(rc "v5r$r") $(lg "v5r$r")"
  [ "$(cut -f1,3 "$T/v5r$r/verdict")" = "$(printf 'APPROVE\t%s' "$HEADSHA")" ] && ok "V5 rc $r: the record's verdict" || bad "V5 rc $r verdict: $(cat "$T/v5r$r/verdict")"
  grep -Eq "ledger-verdict=[0-9.]+s rc=$r( |\$)" "$T/v5r$r/log" && ok "V5 rc $r is in the step line" || bad "V5 rc $r line: $(lg "v5r$r")"
done

# ---- V6 after a cut, a later read runs nothing ----------------------------------------
vr_case v6 'job_verdict_headbound() { sleep 30.80206; }; job_verdict() { echo ran > "$c/ran"; return 1; }; '"$STEP" MC_VERDICT_READ_CALL_TIMEOUT_S=1   # determinism: ok the stub IS the hung read the bound cuts
[ ! -e "$T/v6/ran" ] && ok "V6 the ledger read did not run after the cut" || bad "V6 the ledger read ran"
grep -Eq 'ledger-verdict=0\.0s rc=124' "$T/v6/log" && ok "V6 the skipped read reads rc=124" || bad "V6 log: $(lg v6)"
[ "$(grep -c VERDICT_READ_TIMEOUT "$T/v6/log")" = 1 ] && ok "V6 still one timeout line" || bad "V6 lines: $(lg v6)"

# ---- V7 the PR lock is free when the worker returns ------------------------------------
vr_case v7 'job_verdict_headbound() { sleep 30.80207; }   # determinism: ok the stub IS the hung read the bound cuts
  ( exec 9>"$c/lock"; flock 9 || exit 9; mc_vr_begin; mc_verdict "$URL" "$c/rec" > /dev/null; mc_vr_end; echo $? > "$c/rc" )
  if flock -n "$c/lock" true; then echo free > "$c/lockstate"; else echo held > "$c/lockstate"; fi' MC_VERDICT_READ_CALL_TIMEOUT_S=2
[ "$(rc v7)" = 1 ] && ok "V7 the worker stopped on the cut (rc 1)" || bad "V7 rc: $(rc v7) $(lg v7)"
[ "$(cat "$T/v7/lockstate" 2>/dev/null)" = free ] && ok "V7 the PR lock is free at once" || bad "V7 lock: $(cat "$T/v7/lockstate" 2>/dev/null)"
left=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f '30[.]8020[37]' >/dev/null 2>&1 || { left=0; break; }
  sleep 0.5   # determinism: ok a bounded poll for the condition, not a race
done
[ "$left" = 0 ] && ok "V7 no stub sleep left after the cut" || bad "V7 left: $(pgrep -af '30[.]8020[37]')"

# ---- V8 a cut on a READY row: fan-in reads it as held ----------------------------------
ROWST=READY vr_case v8 'job_verdict_headbound() { sleep 30.80208; }   # determinism: ok the stub IS the hung read the bound cuts
  cksum < "$c/rows" > "$c/rows.before"
  '"$STEP"'
  SLUG=o/r; MC_FANIN_T0=0; MC_TICK_ID=t8
  mc_fanin_outcome 0 "$(printf "81\t%s\t%s\tbr\tfalse\tCLEAN\t-" "$URL" "$HEAD")" > "$c/word"' MC_VERDICT_READ_CALL_TIMEOUT_S=1
[ "$(cat "$T/v8/word" 2>/dev/null)" = "READY held:verdict-read-timeout" ] && ok "V8 fan-in: READY held:verdict-read-timeout" || bad "V8 word: '$(cat "$T/v8/word" 2>/dev/null)' $(lg v8)"
[ "$(cksum < "$T/v8/rows")" = "$(cat "$T/v8/rows.before")" ] && ok "V8 the row file is unchanged" || bad "V8 rows: $(cat "$T/v8/rows")"
! grep -q READY_UNEXPLAINED "$T/v8/log" && [ ! -s "$T/v8/alerts" ] && ok "V8 no READY_UNEXPLAINED, no alert" || bad "V8 log: $(lg v8)"
grep -q "verdict-read-timeout	" "$T/v8/state/ready-why/"* 2>/dev/null && ok "V8 the ready-why note names the kind" || bad "V8 note: $(cat "$T/v8/state/ready-why/"* 2>/dev/null)"

# ---- V9 under 1 s of worker time left ----------------------------------------------------
vr_case v9 'job_verdict_headbound() { echo ran > "$c/ran"; printf "n/a"; }; '"$STEP" MC_VERDICT_READ_CALL_TIMEOUT_S=45 MC_WORKER_DEADLINE_AT=$(( $(date +%s) + 10 ))
[ ! -e "$T/v9/ran" ] && ok "V9 no read ran" || bad "V9 a read ran"
[ "$(rc v9)" = 1 ] && ok "V9 mc_vr_end rc 1" || bad "V9 rc: $(rc v9) $(lg v9)"
grep -Eq '^o/r#81 VERDICT_READ_TIMEOUT call=verdict-read/review-file took=0s timeout=0s rc=124: ' "$T/v9/log" \
  && ok "V9 a took=0s timeout line" || bad "V9 log: $(lg v9)"

# ---- V10 a slow write is never cut --------------------------------------------------------
vr_case v10 'slow_write() { sleep 2; echo w > "$c/wrote"; }   # determinism: ok a slow write that must NOT be cut
  mc_vr_begin; mc_vr_run -w eject-rebased slow_write; echo $? > "$c/wrc"; mc_vr_end; echo $? > "$c/rc"' MC_VERDICT_READ_CALL_TIMEOUT_S=1
[ "$(cat "$T/v10/wrc")" = 0 ] && [ -e "$T/v10/wrote" ] && ok "V10 the write ran to its end (rc 0)" || bad "V10 wrc: $(cat "$T/v10/wrc") $(lg v10)"
[ "$(rc v10)" = 0 ] && ! grep -q VERDICT_READ_TIMEOUT "$T/v10/log" && ok "V10 no timeout, step goes on" || bad "V10: $(lg v10)"
grep -Eq 'eject-rebased=[2-9]\.[0-9]s rc=0' "$T/v10/log" && ok "V10 the write is named and timed" || bad "V10 line: $(lg v10)"

# ---- V11 outside the step nothing changes --------------------------------------------------
vr_case v11 'job_verdict_headbound() { sleep 2; printf "n/a"; }   # determinism: ok a slow read outside the step must NOT be cut
  MC_CALL_FILE="$c/mcall"; printf "stale\n" > "$MC_CALL_FILE"
  mc_verdict "$URL" "$c/rec" > "$c/verdict"; mc_contradiction_words "$URL" "$c/rec" > "$c/words"
  mc_vr_run -w eject-rebased true; echo $? > "$c/rc"' MC_VERDICT_READ_CALL_TIMEOUT_S=1
[ "$(cat "$T/v11/verdict")" = "$WANT" ] && ok "V11 the verdict is today's, the slow read not cut" || bad "V11 verdict: '$(cat "$T/v11/verdict")' $(lg v11)"
[ "$(cat "$T/v11/words")" = "ledger APPROVE vs record APPROVE" ] && ok "V11 contradiction words unchanged" || bad "V11 words: $(cat "$T/v11/words")"
[ "$(rc v11)" = 0 ] && ok "V11 mc_vr_run passes rc through" || bad "V11 rc: $(rc v11)"
! grep -q VERDICT_READ "$T/v11/log" && ok "V11 no VERDICT_READ line" || bad "V11 log: $(lg v11)"
[ "$(cat "$T/v11/mcall")" = stale ] && ok "V11 the call file is untouched" || bad "V11 call file: $(cat "$T/v11/mcall")"

# ---- C1 the call line ------------------------------------------------------------------------
vr_case c1 'MC_CALL_FILE="$c/mcall"; job_verdict_headbound() { cp "$MC_CALL_FILE" "$c/seen"; printf "n/a"; }; '"$STEP" MC_VERDICT_READ_CALL_TIMEOUT_S=5
ct=""; cp=""; cw=""; cpid=""; ccs=""
IFS=$'\t' read -r ct cp cw cpid ccs < "$T/c1/seen" 2>/dev/null
[ "$(awk -F'\t' '{ print NF }' "$T/c1/seen" 2>/dev/null)" = 5 ] && ok "C1 five tab fields" || bad "C1 fields: $(cat -A "$T/c1/seen" 2>/dev/null)"
[[ "$ct" =~ ^[0-9]+$ ]] && [ "$cp" = verdict-read/headbound ] && [ "$cw" = r ] && [[ "$cpid" =~ ^[0-9]+$ ]] && [[ "$ccs" =~ ^[0-9]+$ ]] \
  && ok "C1 epoch, verdict-read/headbound, r, pid, centiseconds" || bad "C1 line: $(cat "$T/c1/seen" 2>/dev/null)"
[ -e "$T/c1/mcall" ] && [ ! -s "$T/c1/mcall" ] && ok "C1 the call file is empty after the step" || bad "C1 after: $(cat "$T/c1/mcall" 2>/dev/null)"

# ---- D1/D2 a real deadline kill in verdict-read names the call ----------------------------------
c="$T/d1"; mkdir -p "$c/rec" "$c/state"; : > "$c/ev"; : > "$c/log"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$c/rec/review.md"; echo "$HEADSHA" > "$c/rec/reviewed-sha"
env MC_WORKER_DEADLINE_S=4 MC_STEP_TIMEOUT_S=0 MC_WORKER_DEADLINE_CAP_S= MC_VERDICT_READ_CALL_TIMEOUT_S=0 HEADSHA="$HEADSHA" URL="$URL" bash -c '
  c=$1; . "$2" || exit 1; . "$3" || exit 1; . "$4" || exit 1; . "$5" || exit 1
  SLUG=o/r MC_STATE_DIR="$c/state" MC_TICK_ID=t1 MC_LOG="$c/lanelog" MC_FANIN_T0=0; : > "$MC_LOG"
  mc_log() { printf "%s\n" "$*" >> "$c/log"; }; _mc_fanin_alert() { :; }
  mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; mc_row_field() { echo QUEUED; }
  sentry_report() {
    jq -nc --arg message "$4" --argjson extra "${5:-null}" --argjson tags "${6:-null}" "{message:\$message,extra:\$extra,tags:\$tags}" >> "$c/ev"
  }
  job_verdict_headbound() { sleep 30.80201; }   # determinism: ok the stub IS the stall the deadline kills
  job_verdict() { return 2; }
  pr_worker() { KEY="o/r#81"; HEAD=$HEADSHA; mc_step verdict-read; mc_vr_begin; mc_verdict "$URL" "$c/rec" >/dev/null; mc_vr_end; mc_step done; }
  row=$(printf "81\t%s\t%s\tbr\tfalse\tCLEAN\t-" "$URL" "$HEADSHA")
  mc_worker_bounded "$row"; mc_fanin_outcome $? "$row" > "$c/word"' _ "$c" "$VP" "$CL" "$FANIN" "$FRAG" > "$c/out" 2>&1
ev() { jq -rc "$1" "$T/d1/ev" 2>/dev/null | head -1; }
[ "$(cat "$c/word" 2>/dev/null)" = killed:deadline ] && ok "D1 outcome killed:deadline" || bad "D1 outcome: $(cat "$c/word" "$c/out" 2>/dev/null)"
[ "$(ev .tags.call)" = verdict-read/headbound ] && ok "D1 Sentry tag call = verdict-read/headbound" || bad "D1 tags: $(ev .tags)"
[ "$(ev .tags.step)" = verdict-read ] && ok "D1 Sentry tag step = verdict-read" || bad "D1 tags: $(ev .tags)"
[ "$(ev .extra.call)" = verdict-read/headbound ] && [[ "$(ev .extra.call_s)" =~ ^[0-9]+$ ]] && ok "D1 extra call and call_s" || bad "D1 extra: $(ev .extra)"
grep -Eq '^o/r#81 WORKER_DEADLINE: .*\| step: verdict-read \([0-9]+s\) .*\| call: verdict-read/headbound \([0-9]+s\) \| calls: ' "$c/log" \
  && ok "D2 the WORKER_DEADLINE line names the call" || bad "D2 log: $(cat "$c/log")"
pgrep -f '30[.]80201' >/dev/null 2>&1 && sleep 6   # determinism: ok the killer's KILL pass is 5 s after its TERM

# ---- P0/P1 the WHOLE conductor tick -------------------------------------------------------------
# The K1 fixture of tests/conductor-machine-lands-nothing.bh-6495-test.sh: one
# READY PR #31 on a Mergify repo. The curl stub answers the jobs ledger's
# /api/verdict read, and hangs it while $KT/hang exists.
NOW=$(date +%s)
KT="$T/k"; KH="$KT/h"; KB="$KT/fakebin"
mkdir -p "$KH/bin/lib" "$KH/bin/merge-conductor.d" "$KH/logs" "$KH/state" "$KH/flags" "$KH/locks" "$KH/builds" "$KH/env" "$KH/tmp" "$KB"
scratch_install_closure bin/merge-conductor.sh "$KH" >/dev/null || { echo "setup: closure failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$KH" >/dev/null || { echo "setup: closure jobs failed"; exit 1; }
cp "$FRAG" "$KH/bin/merge-conductor.d/"
cp "$REPO/bin/fleet-conf.sh" "$KH/bin/fleet-conf.sh"
mkdir -p "$KH/catalog"; cp "$REPO/catalog/lead-protected-paths.seed.tsv" "$KH/catalog/"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$KH/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$KT" > "$KH/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$KT" > "$KH/bin/alert-line.sh"
chmod +x "$KH/bin/"*.sh
cp "$REPO/tests/lib/rest-emit.sh" "$KB/restpr"; chmod +x "$KB/restpr"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$REPO/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
KSLUG=example-org/mgfy-os; KHEAD=$(printf 'a%.0s' {1..40}); KMAIN=$(printf 'd%.0s' {1..40}); KU="https://github.com/$KSLUG/pull"
printf 'mgfy %s - - 2 box-m\n' "$KSLUG" > "$KH/fleet.conf"
: > "$KH/env/global.env"
REC="$KH/builds/pool-mgfy-MG-31-202610220001"; mkdir -p "$REC"
echo "PR_CREATED $KU/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$KHEAD" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
cat > "$KT/list.json" <<J
[{"number":31,"url":"$KU/31","headRefOid":"$KHEAD","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
jq -nc --arg r "$KSLUG" --arg h "$KHEAD" '[{number:31, html_url:("https://github.com/"+$r+"/pull/31"), title:"t", draft:false, state:"open",
  updated_at:"2026-10-22T00:00:00Z", created_at:"2026-10-21T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
  head:{sha:$h, ref:"ticket/mg-31", repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}}}]' > "$KT/rest-list.json"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$KB/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *"api -i -X GET repos/$KSLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/$KSLUG/commits/main"*|*"api -i -X GET repos/$KSLUG/git/ref/heads/main"*) restpr --raw 200 '{"sha":"$KMAIN","object":{"sha":"$KMAIN"}}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-22T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-22T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*) restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*|*"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$KT/cmds.txt" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$KT/cmds.txt"; restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$KT/merges.txt"; exit 1 ;;
  *"api -i -X GET repos/$KSLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*|*"api --paginate repos/"*"/reviews"*) echo '[]' ;;
  *"api repos/"*"/comments --paginate"*) : ;;
  *"api repos/$KSLUG/issues/31"*) printf '{"number":31,"state":"open","labels":[],"body":""}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*) restpr OPEN "$KHEAD" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls?state=open"*) restpr --raw 200 "\$(cat "$KT/rest-list.json")" ;;
  *"api -i -X GET repos/"*"/pulls?state=open"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*|*"api -i -X GET repos/"*"/pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"api repos/$KSLUG -q .id"*) echo 1 ;;
  *"pr list -R $KSLUG --state open"*) cat "$KT/list.json" ;;
  *"pr list"*) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$KB/gh"
cat > "$KB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/lead-protected-paths*) "$KB/lpp-answer" GET "\$URL"; exit 0 ;;
  */api/verdict\?*) [ -e "$KT/hang" ] && sleep 30.80209   # determinism: ok the stub IS the hung ledger read
                    printf '{"error":"not found"}\n404\n' ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$KB/curl"
. "$REPO/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$KT/lpp.json" "$KSLUG"
lpp_install "$KB" "$KT/lpp.json" "$KT/lpp-down"
touch "$KH/flags/merge-conductor-actions" "$KH/flags/merge-conductor-merge"
KLOG="$KH/logs/merge-conductor.log"
PRS="$KH/state/merge-conductor/pr-state.tsv"
ktick() {
  ( cd "$KT" && env PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-fixture \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 FLEET_CONF="$KH/fleet.conf" MC_ONLY_PR="$KSLUG#31" "$@" \
    bash "$KH/bin/merge-conductor.sh" >/dev/null 2>"$KT/tick.err" ); }
kreset() {
  scratch_rm "$KH/state/merge-conductor"
  mkdir -p "$KH/state/merge-conductor/prequeue"
  printf 'green %s 1 -\n' "$NOW" > "$KH/state/merge-conductor/prequeue/example-org_mgfy-os_31_${KHEAD}_${KMAIN}"
  : > "$KLOG"; rm -f "$KT/cmds.txt" "$KT/merges.txt" "$KT/alerts.txt" "$KT/hang"
}
klog() { grep -F "$KSLUG#31" "$KLOG" 2>/dev/null | tail -8; }

# P0 control: no hang. One VERDICT_READ line for #31, and the tick enqueues it.
kreset; ktick MC_VERDICT_READ_CALL_TIMEOUT_S=2
[ "$(grep -c "$KSLUG#31 VERDICT_READ took=" "$KLOG")" = 1 ] && ok "P0 one VERDICT_READ line for #31" || bad "P0 lines: $(klog) $(tail -3 "$KT/tick.err")"
grep -q "$KSLUG#31 STEP_START step=enqueue" "$KLOG" && ok "P0 the worker reaches step enqueue" || bad "P0 no enqueue step: $(klog)"

# P1 the ledger read hangs: the worker stops at the bound and enqueues nothing.
kreset; touch "$KT/hang"; t0=$SECONDS
ktick MC_VERDICT_READ_CALL_TIMEOUT_S=2
P1T=$((SECONDS - t0))   # determinism: ok race-wall-bound a hang-only ceiling: the unbounded tick takes 68 s or more
grep -Eq "$KSLUG#31 VERDICT_READ_TIMEOUT call=verdict-read/headbound took=[23]s timeout=2s rc=124: " "$KLOG" \
  && ok "P1 VERDICT_READ_TIMEOUT names verdict-read/headbound" || bad "P1 log: $(klog) $(tail -3 "$KT/tick.err")"
! grep -q "$KSLUG#31 STEP_START step=enqueue" "$KLOG" && [ ! -s "$KT/cmds.txt" ] && [ ! -s "$KT/merges.txt" ] \
  && ok "P1 no enqueue step, nothing commented or merged" || bad "P1 landed: $(klog)"
! grep -q "WORKER_DEADLINE\|STEP_TIMEOUT" "$KLOG" && ok "P1 no deadline kill, no step timeout" || bad "P1 killed: $(klog)"
! grep -q "$KSLUG#31 .*->" "$KLOG" && ok "P1 no transition for #31" || bad "P1 transition: $(klog)"
[ "$P1T" -le 60 ] && ok "P1 the tick ended in ${P1T}s" || bad "P1 tick took ${P1T}s"
rm -f "$KT/hang"
pgrep -f '30[.]80209' >/dev/null 2>&1 && bad "P1 a hung curl stub is left: $(pgrep -af '30[.]80209')" || ok "P1 no hung curl stub left"

# ---- K1 the conductor gets the registry default -------------------------------------------------
c="$T/k1"; mkdir -p "$c/h/logs" "$c/h/state" "$c/h/flags"
if "$REPO/bin/lanes-build.sh" --to "$c/reg.json" >/dev/null 2>"$c/err"; then
  jq -e '[.lanes[] | select(.id == "merge-conductor") | .knobs[] | select(.env == "MC_VERDICT_READ_CALL_TIMEOUT_S")]
         | length == 1 and .[0].default == 45' "$c/reg.json" >/dev/null \
    && ok "K1 registered on merge-conductor, default 45" || bad "K1 registry: $(jq -c '[.lanes[] | select(.id == "merge-conductor") | .knobs[] | select(.env == "MC_VERDICT_READ_CALL_TIMEOUT_S")]' "$c/reg.json")"
  got=$(env -u MC_VERDICT_READ_CALL_TIMEOUT_S HARNESS="$c/h" LANE_REGISTRY="$c/reg.json" LANE_GATE_CACHE_S=0 bash -c '
    . "$1" || exit 1; lane_env_apply merge-conductor >/dev/null 2>&1; printf "%s" "${MC_VERDICT_READ_CALL_TIMEOUT_S:-unset}"' _ "$REPO/bin/lib/lane-gate.sh" 2>"$c/err2")
  [ "$got" = 45 ] && ok "K1 lane_env_apply merge-conductor with no row: 45" || bad "K1 lane_env_apply gave '$got' $(cat "$c/err2")"
else
  bad "K1 lanes-build: $(cat "$c/err")"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
