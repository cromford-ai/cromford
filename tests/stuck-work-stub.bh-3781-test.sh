#!/bin/bash
# tests/stuck-work-stub.bh-3781-test.sh — BH-3789 (BH-3781.0): the stuck-work
# contract slice. The lane entry was a stub (BH-3793 filled its body), the fact readers are rc 1 stubs, and
# sw_first_seen is a real helper. BH-3790 filled the classifier bodies, whose
# behaviour tests/stuck-work-classify.bh-3781-test.sh pins.
#
#   S1 flags/stuck-work-off      -> one log line ending ` off`, rc 0
#   S2 STUCK_WORK_ENABLED=0      -> ` disabled`
#   S3 default, no worker and no GitHub App token -> ` no-token`, rc 0 (BH-3793
#      replaced the stub body; tests/stuck-work.bh-3781-test.sh pins the rest),
#      and no gh/curl call in S1-S3
#   S4 flags/all-off             -> rc 0 and no log line (the gate runs first)
#   S5 the built registry entry and the hub crontab line
#   S6 every swf_* stub answers rc 1 with empty stdout; every sw_* is a
#      function answering rc 0 with output (BH-3790)
#   S6b the FACTS field list in classify.sh equals the fixture README's
#   S7 sw_first_seen: write-once anchor, `?` on anything unreadable
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-stub.bh-3781-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date -u +%s)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LANE_SRC="$DIR/bin/stuck-work.sh"
CLASSIFY_SRC="$DIR/bin/lib/stuck-work/classify.sh"
FPR_SRC="$DIR/bin/lib/stuck-work/facts-pr.sh"
FTK_SRC="$DIR/bin/lib/stuck-work/facts-ticket.sh"
SEEN_SRC="$DIR/bin/lib/stuck-work/seen.sh"
README="$DIR/tests/fixtures/stuck-work/README"
for f in "$LANE_SRC" "$CLASSIFY_SRC" "$FPR_SRC" "$FTK_SRC" "$SEEN_SRC" "$README"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "stuck-work-stub: 0 passed, 1 failed"; exit 1; }
done

H="$T/h"
mkdir -p "$H/flags" "$T/shim"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
for c in gh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\nexit 1\n' "$c" "$T" > "$T/shim/$c"
  chmod +x "$T/shim/$c"
done
LOG="$H/logs/stuck-work.log"

# run_lane [VAR=val...] — the shipped entry, from the scratch harness, with a
# clean environment and no worker (JOBS_URL empty), so lane_switch reads the file.
run_lane() {
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= HARNESS_TEST_SANDBOX=1 "$@" \
    bash "$H/bin/stuck-work.sh" > "$T/lane.out" 2> "$T/lane.err"
}
lines() { if [ -f "$LOG" ]; then wc -l < "$LOG"; else echo 0; fi; }
last()  { tail -n 1 "$LOG" 2>/dev/null; }

# S1 — the reader switch wins over the knob, and writes exactly one ` off` line.
touch "$H/flags/stuck-work-off"
b=$(lines)
run_lane STUCK_WORK_ENABLED=0; rc=$?
[ "$rc" = 0 ] && ok || bad "S1 $LANE_SRC with flags/stuck-work-off exited $rc"
[ "$(( $(lines) - b ))" = 1 ] && ok || bad "S1 expected exactly one log line, got $(( $(lines) - b ))"
if last | grep -Eq '^[0-9T:Z-]+ off$'; then ok; else bad "S1 last log line is '$(last)', wanted '<ts> off'"; fi
[ -s "$T/lane.out" ] && bad "S1 the stub wrote to stdout: $(cat "$T/lane.out")" || ok
rm -f "$H/flags/stuck-work-off"

# S2 — STUCK_WORK_ENABLED=0.
b=$(lines)
run_lane STUCK_WORK_ENABLED=0; rc=$?
[ "$rc" = 0 ] && ok || bad "S2 $LANE_SRC STUCK_WORK_ENABLED=0 exited $rc"
[ "$(( $(lines) - b ))" = 1 ] && ok || bad "S2 expected exactly one log line, got $(( $(lines) - b ))"
if last | grep -Eq '^[0-9T:Z-]+ disabled$'; then ok; else bad "S2 last log line is '$(last)', wanted '<ts> disabled'"; fi

[ -e "$T/calls" ] && bad "S2 the lane called out while disabled: $(cat "$T/calls")" || ok

# S3 — the default tick, with no worker and no App token (an empty env dir, so
# no github-app.env), is one ` no-token` line.
mkdir -p "$T/env"
b=$(lines)
run_lane HARNESS_ENV_DIR="$T/env"; rc=$?
[ "$rc" = 0 ] && ok || bad "S3 $LANE_SRC default exited $rc"
[ "$(( $(lines) - b ))" = 1 ] && ok || bad "S3 expected exactly one log line, got $(( $(lines) - b ))"
if last | grep -Eq '^[0-9T:Z-]+ no-token$'; then ok; else bad "S3 last log line is '$(last)', wanted '<ts> no-token'"; fi
[ -e "$T/calls" ] && bad "S3 the no-token tick called out: $(cat "$T/calls")" || ok

# S4 — the fleet master switch stops the lane before the switch and the body.
touch "$H/flags/all-off"
b=$(lines)
run_lane; rc=$?
[ "$rc" = 0 ] && ok || bad "S4 $LANE_SRC under flags/all-off exited $rc"
[ "$(lines)" = "$b" ] && ok || bad "S4 the lane wrote a log line under all-off: $(last)"
rm -f "$H/flags/all-off"

# S5 — the registry entry as built, and the one hub crontab line.
got=$(jq -c '.lanes[]|select(.id=="stuck-work")|[.scope,.boxes,.switch.name,.script,.cadence,([.knobs[].env]|sort),([.knobs[]|select(.env=="STUCK_WORK_NOW")|.settable])]' "$H/catalog/lanes.json" 2>&1)
# TEST-CHANGE BH-4656: BH-4660 registers STUCK_WORK_CI_TTL_S and STUCK_WORK_THREAD_FULL_S.
# TEST-CHANGE (BH-5943): STUCK_WORK_DISPATCH_SPREAD_S and STUCK_WORK_PROJECTS are new registered knobs.
# TEST-CHANGE (BH-6976): STUCK_WORK_CI_QUIET_TTL_S is a new registered knob (the quiet-feed CI cache limit).
want='["hub",["hub"],"lane-off-stuck-work","bin/stuck-work.sh","*/5 * * * *",["HARNESS_TEST_SANDBOX","STUCK_WORK_CI_QUIET_TTL_S","STUCK_WORK_CI_TTL_S","STUCK_WORK_DISPATCH_SPREAD_S","STUCK_WORK_ENABLED","STUCK_WORK_FIXTURE","STUCK_WORK_MAX_ITEMS","STUCK_WORK_NOW","STUCK_WORK_PROJECTS","STUCK_WORK_REPAGE_FACTOR","STUCK_WORK_REPO","STUCK_WORK_SLA_BLOCKED_MIN","STUCK_WORK_SLA_BUILD_STAGES","STUCK_WORK_SLA_DEQUEUED_MIN","STUCK_WORK_SLA_HUMAN_MIN","STUCK_WORK_SLA_LEAD_REVIEW_MIN","STUCK_WORK_SLA_QUEUED_MIN","STUCK_WORK_SLA_READY_MIN","STUCK_WORK_SLA_UNLAUNCHED_MIN","STUCK_WORK_THREAD_FULL_S"],[false]]'
[ "$got" = "$want" ] && ok || bad "S5 registry entry is $got, wanted $want"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" hub > "$T/hub.cron" 2> "$T/hub.err"; rc=$?
[ "$rc" = 0 ] && ok || bad "S5 bin/render-cron.sh hub exited $rc: $(cat "$T/hub.err")"
n=$(grep -c 'bin/stuck-work.sh' "$T/hub.cron")
[ "$n" = 1 ] && ok || bad "S5 the hub crontab has $n stuck-work.sh lines, wanted 1"
case "$(grep 'bin/stuck-work.sh' "$T/hub.cron")" in
  '*/5 * * * * /root/harness/bin/hub-lease.sh check && '*) ok ;;
  *) bad "S5 the hub line is not hub-lease gated at */5: $(grep 'bin/stuck-work.sh' "$T/hub.cron")" ;;
esac

# S6 — the fact-reader stubs answer rc 1 to realistic args and print nothing;
# the classifier functions (BH-3790) answer rc 0 with output.
FACTS=$(printf 'pr\to/r#12\thttps://github.com/o/r/pull/12\t0\tai-build\tready\t1700000000\tAPPROVE\tabc\t1700000100\tabc\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t1700000000')
env -i PATH="$PATH" HOME="$T" FACTS="$FACTS" C="$CLASSIFY_SRC" P="$FPR_SRC" K="$FTK_SRC" T="$T" bash -c '
  . "$C" && . "$P" && . "$K" || { echo source-failed; exit 0; }
  probe() { local v=$1; shift
    if [ "$(type -t "$v")" != function ]; then echo "$v undefined"; return; fi
    "$v" "$@" > "$T/out.$v"; echo "$v rc=$? bytes=$(wc -c < "$T/out.$v")"; }
  probe sw_state "$FACTS"
  probe sw_sla_s ready
  probe sw_decide 900 1200 - 4
  probe sw_key o/r#12 ready 1700000000
  probe sw_page_text o/r#12 ready lead 1200 900 https://github.com/o/r/pull/12
  probe swf_pr_facts o/r
  probe swf_ticket_facts o/r "$T/open-prs"
' > "$T/s6.txt" 2>&1
for v in swf_pr_facts swf_ticket_facts; do
  grep -qx "$v rc=1 bytes=0" "$T/s6.txt" && ok \
    || bad "S6 $v: $(grep "^$v \|source-failed" "$T/s6.txt" || echo 'no answer') (want rc=1 bytes=0)"
done
for v in sw_sla_s sw_decide sw_key sw_page_text; do
  grep -Eqx "$v rc=0 bytes=[1-9][0-9]*" "$T/s6.txt" && ok \
    || bad "S6 $v: $(grep "^$v \|source-failed" "$T/s6.txt" || echo 'no answer') (want rc=0 and output)"
done
# The README sample: APPROVE on head and the lead marked it ready.
[ "$(cat "$T/out.sw_state" 2>/dev/null)" = "$(printf 'ready\tconductor\t1700000100\t-')" ] && ok \
  || bad "S6 sw_state on the README sample printed '$(cat "$T/out.sw_state" 2>/dev/null)'"

# S6b — the FACTS field list is the same in the header and the fixture README.
fields() { sed -n 's/^# *FACTS: *//p; s/^FACTS: *//p' "$1" | head -n 1; }
hf=$(fields "$CLASSIFY_SRC"); rf=$(fields "$README")
want="kind item url draft labels lead_status lead_status_at verdict verdict_sha verdict_at head mergify cond_state cond_since resolver_at dqw_action_at job_stage job_stage_seen issue_blocked issue_hold open_pr first_seen"
[ "$hf" = "$want" ] && ok || bad "S6b classify.sh FACTS fields are '$hf'"
[ "$rf" = "$hf" ] && ok || bad "S6b README FACTS fields '$rf' differ from classify.sh '$hf'"
[ "$(printf '%s' "$FACTS" | awk -F'\t' '{print NF}')" = "$(echo "$want" | wc -w)" ] && ok || bad "S6 the sample FACTS line is not 22 fields"

# S7 — sw_first_seen. ROW_RC/ROW_OUT drive the job_ledger_row double, PUT_RC
# the job_ledger_put double, which records every PUT to $T/puts.
seen() {  # seen <sandbox 0|1> [VAR=val...] -- prints "<stdout>|rc=<rc>"
  local sb=$1; shift
  local sbv=(); [ "$sb" = 1 ] && sbv=(HARNESS_TEST_SANDBOX=1)
  env -i PATH="$PATH" HOME="$T" "${sbv[@]}" STUCK_WORK_NOW="$NOW" T="$T" S="$SEEN_SRC" "$@" bash -c '
    job_ledger_row() { [ -n "${ROW_OUT:-}" ] && printf "%s\n" "$ROW_OUT"; return "${ROW_RC:-2}"; }
    job_ledger_put() { printf "%s\n" "$*" >> "$T/puts"; return "${PUT_RC:-0}"; }
    . "$S" || { echo source-failed; exit 0; }
    out=$(sw_first_seen "$KEY"); echo "$out|rc=$?"'
}
puts() { if [ -f "$T/puts" ]; then wc -l < "$T/puts"; else echo 0; fi; }

rm -f "$T/puts"
got=$(seen 1 KEY='o/r#12|ready' ROW_RC=2)
[ "$got" = "$NOW|rc=0" ] && ok || bad "S7a absent row printed '$got', wanted '$NOW|rc=0'"
[ "$(puts)" = 1 ] && ok || bad "S7a wanted exactly one PUT, got $(puts)"
[ "$(cat "$T/puts" 2>/dev/null)" = "stuck_work_seen o/r#12|ready seen {\"first_seen\":$NOW}" ] && ok \
  || bad "S7a the PUT was '$(cat "$T/puts" 2>/dev/null)'"

rm -f "$T/puts"
got=$(seen 1 KEY='o/r#12|ready' ROW_RC=0 ROW_OUT='{"status":"seen","detail":"{\"first_seen\":1700000000}"}')
[ "$got" = "1700000000|rc=0" ] && ok || bad "S7b present row printed '$got', wanted '1700000000|rc=0'"
[ "$(puts)" = 0 ] && ok || bad "S7b a present row was re-written: $(cat "$T/puts")"

rm -f "$T/puts"
got=$(seen 1 KEY='o/r#12|ready' ROW_RC=1)
[ "$got" = "?|rc=0" ] && ok || bad "S7c ledger down printed '$got', wanted '?|rc=0'"
[ "$(puts)" = 0 ] && ok || bad "S7c ledger down still PUT: $(cat "$T/puts")"

rm -f "$T/puts"
got=$(seen 1 KEY='o/r#12|ready' ROW_RC=0 ROW_OUT='{"status":"seen","detail":"not json"}')
[ "$got" = "?|rc=0" ] && ok || bad "S7d unparseable detail printed '$got', wanted '?|rc=0'"
[ "$(puts)" = 0 ] && ok || bad "S7d an unparseable row was overwritten: $(cat "$T/puts")"
got=$(seen 1 KEY='o/r#12|ready' ROW_RC=2 PUT_RC=1)
[ "$got" = "?|rc=0" ] && ok || bad "S7d absent row with a failed PUT printed '$got', wanted '?|rc=0'"
got=$(seen 1 KEY='')
case "$got" in *"|rc=1") ok ;; *) bad "S7d an empty key answered '$got', wanted rc=1" ;; esac

rm -f "$T/puts"
got=$(env -i PATH="$PATH" HOME="$T" HARNESS_TEST_SANDBOX=1 T="$T" S="$SEEN_SRC" bash -c '
  . "$S" || { echo source-failed; exit 0; }; out=$(sw_first_seen k); echo "$out|rc=$?"')
[ "$got" = "?|rc=0" ] && ok || bad "S7d with no jobs client loaded printed '$got', wanted '?|rc=0'"

got=$(seen 0 KEY='k' ROW_RC=2 STUCK_WORK_NOW=1)
v=${got%%|*}
if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "$NOW" ]; then ok
else bad "S7e outside the sandbox STUCK_WORK_NOW=1 was honoured: '$got'"; fi

echo "stuck-work-stub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
