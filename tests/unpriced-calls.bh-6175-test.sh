#!/bin/bash
# tests/unpriced-calls.bh-6175-test.sh — BH-6175 (slice C5 of #5526): a failed
# call that bought nothing writes a priced $0 row, and a billed call stored with
# no cost raises one alert per lane per UTC day.
#
# WHAT IT PINS:
#   W1  _ac_unbilled in bin/agent-call.sh (extracted by its markers): the
#       decision table. rc != 0, no tokens, no money, row_source none,
#       transcript or result → unbilled. A timeout/kill rc (124/137/143) stays
#       unknown except on stage canary (BH-3222).
#   W2  the REAL bin/agent-call.sh, stage triage, a dead login (rc 1, no
#       usage): cost_usd 0, row_source unbilled.
#   W3  the same driver, billed calls (rc 0 with usage, rc 1 with input
#       tokens): never unbilled, one row per attempt.
#   U1-U3  bin/spend-alerts.sh unpriced: counts billed rows with a blank or
#       non-numeric cost per lane; skips priced $0, never-billed, refused,
#       settled, unbilled, before-since and duplicate lines; a csv that is not
#       a cost.csv exits 1 and prints nothing.
#   P1-P5  the `# >>> spend alerts` block of bin/pipeline-health.sh, extracted
#       by its markers: one spendunpriced:<lane> alert per lane, deduped for a
#       day by the REAL alert(); nothing refused; an unreadable `unpriced` is
#       the existing noeval alert and the p99 check still runs.
#   R1  round trip: the real agent-call.sh writes a failed row and a billed
#       unpriced row; the real spend-alerts.sh unpriced counts only the second.
#
# Mutation (run by hand once): make _ac_unbilled `return 1` → W1, W2 and R1 go
# red; drop the `unpriced` alert loop in pipeline-health.sh → P1, P2, P3 red;
# drop the never-billed rule in the reader → U2, P5 and R1 red.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unpriced-calls.bh-6175-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
command -v jq >/dev/null && command -v awk >/dev/null || { echo "jq/awk missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ============================ W1: the decision table ============================
awk '/^# >>> unbilled row \(BH-6175\)/{f=1;next} /^# <<< unbilled row/{exit} f' "$DIR/bin/agent-call.sh" > "$T/unbilled.sh"
grep -q '^_ac_unbilled()' "$T/unbilled.sh" && ok \
  || bad "W1 could not extract _ac_unbilled from bin/agent-call.sh (markers '# >>> unbilled row (BH-6175)' missing)"
# w1 <want 0|1> <label> RC STAGE ROW_SRC IN OUTT CR CW USD
w1() {
  local want="$1" label="$2" got
  ( RC="$3" STAGE="$4" ROW_SRC="$5" IN="$6" OUTT="$7" CR="$8" CW="$9" USD="${10}"
    . "$T/unbilled.sh" 2>/dev/null || exit 9
    command -v _ac_unbilled >/dev/null || exit 9
    _ac_unbilled )
  got=$?
  [ "$got" = "$want" ] && ok || bad "W1 $label: _ac_unbilled returned $got, want $want"
}
# tag
w1 0 "rc 1 none, no tokens, no usd, stage plan"      1   plan     none       ""  ""  ""  ""  ""
w1 0 "rc 127 none (command not found)"               127 review   none       ""  ""  ""  ""  ""
w1 0 "rc 1 transcript, 0 tokens, usd 0.000000"       1   triage   transcript 0   0   0   0   0.000000
w1 0 "stage canary rc 124 none (BH-3222 kept)"       124 canary   none       ""  ""  ""  ""  ""
# do not tag
w1 1 "rc 0 none, no tokens (cost-parity path)"       0   plan     none       ""  ""  ""  ""  ""
w1 1 "rc 1 with IN=7 (billed)"                       1   plan     result     7   0   0   0   ""
w1 1 "rc 124 stage plan (timeout may be billed)"     124 plan     none       ""  ""  ""  ""  ""
w1 1 "rc 143 none"                                   143 plan     none       ""  ""  ""  ""  ""
w1 1 "rc 1 killed"                                   1   plan     killed     ""  ""  ""  ""  ""
w1 1 "rc 1 none with usd 0.40"                       1   plan     none       ""  ""  ""  ""  0.40
w1 1 "rc 1 ledger"                                   1   plan     ledger     ""  ""  ""  ""  ""

# ===================== W2 / W3 / R1: the real bin/agent-call.sh =====================
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
mrs_fixture "$T" fixture-proj
echo '{}' > "$T/prices.json"       # no model is priced: a billed call with no cost stays blank
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) echo "  --resume"; exit 0 ;; esac
cat >/dev/null
case "${FAKE_MODE:-dead}" in
  dead) echo "Invalid API key · Please run /login"; exit 1 ;;
  okusage) echo '{"result":"ok","is_error":false,"total_cost_usd":0.0001,"usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}'; exit 0 ;;
  errusage) echo '{"result":"overloaded","is_error":true,"usage":{"input_tokens":7,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}'; exit 1 ;;
  nocost) echo '{"result":"ok","is_error":false,"usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}'; exit 0 ;;
esac
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho rules\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*

# call <stage> <out-name> [VAR=val ...] — one agent-call run on claude only,
# lane run-triage. Appends to logs/cost.csv; reset() empties it.
call() {
  local stage="$1" out="$2"; shift 2
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" MODEL_PRICES="$T/prices.json" \
      OPENROUTER_API_KEY= FIREWORKS_API_KEY= ACCOUNT_ROUTING=0 \
      LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=0 AGENT_CALL_LEDGER=0 \
      AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=run-triage AGENT_CALL_DEAD_ALERT=0 "$@"
    unset AGENT_CALL_TICKET AGENT_CALL_PR COST_RUN_ID
    cd / && bash "$DIR/bin/agent-call.sh" "$stage" fixture-proj claude-fixture-model 60 "$T/$out" 'reply ok' \
      </dev/null >/dev/null 2>&1 )
  echo $?
}
reset() { rm -f "$T/logs/cost.csv"; : > "$T/logs/ALERTS.log"; }
col() { tail -n +2 "$T/logs/cost.csv" 2>/dev/null | tail -1 | awk -F, -v c="$1" '{print $c}'; }
rows() { tail -n +2 "$T/logs/cost.csv" 2>/dev/null | grep -c . ; }

# W2 — a failed call that bought nothing
reset; RC=$(call triage w2.txt)
[ "$RC" -ne 0 ] && ok || bad "W2 a dead login must exit non-zero (rc=$RC)"
[ "$(rows)" = 1 ] && ok || bad "W2 want 1 cost row, got $(rows)"
[ "$(col 7)" != 0 ] && [ -n "$(col 7)" ] && ok || bad "W2 column 7 (rc) '$(col 7)' want non-zero"
[ "$(col 13)" = 0 ] && ok || bad "W2 column 13 (cost_usd) '$(col 13)' want 0"
[ "$(col 18)" = unbilled ] && ok || bad "W2 column 18 (row_source) '$(col 18)' want unbilled"
[ "$(col 4)" = triage ] && ok || bad "W2 column 4 (stage) '$(col 4)' want triage"

# W3 — billed calls keep their row as before
reset; RC=$(call triage w3a.txt FAKE_MODE=okusage)
[ "$RC" = 0 ] && ok || bad "W3 okusage rc=$RC want 0"
[ "$(rows)" = 1 ] && ok || bad "W3 okusage want 1 row, got $(rows)"
[ -n "$(col 18)" ] && [ "$(col 18)" != unbilled ] && ok || bad "W3 okusage row_source '$(col 18)' must be set and not unbilled"
[ -n "$(col 13)" ] && ok || bad "W3 okusage column 13 is empty"
reset; RC=$(call triage w3b.txt FAKE_MODE=errusage)
# A failed attempt is retried down the ladder: one row per attempt, none unbilled.
[ "$(rows)" -ge 1 ] && ok || bad "W3 errusage wrote no row"
n=$(tail -n +2 "$T/logs/cost.csv" 2>/dev/null | awk -F, '$18 == "unbilled" || $18 == ""' | grep -c .)
[ "$n" = 0 ] && ok || bad "W3 errusage: $n of $(rows) rows are unbilled or blank with input tokens"

# R1 — round trip through the real reader
reset
call triage r1a.txt >/dev/null
call triage r1b.txt FAKE_MODE=nocost >/dev/null
[ "$(rows)" = 2 ] && ok || bad "R1 want 2 rows in cost.csv, got $(rows)"
[ -z "$(col 13)" ] && ok || bad "R1 the billed no-price call's cost_usd '$(col 13)' is not blank (fixture broken)"
TODAY_ISO="$(date -u +%F)T00:00:00Z"
OUT=$(bash "$DIR/bin/spend-alerts.sh" unpriced --rows "$T/logs/cost.csv" --since "$TODAY_ISO" 2>"$T/r1.err"); rc=$?
[ "$rc" = 0 ] && ok || bad "R1 spend-alerts.sh unpriced exited $rc: $(cat "$T/r1.err")"
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 1 ] && ok || bad "R1 want exactly 1 line, got [$OUT]"
[ "$(printf '%s\n' "$OUT" | cut -f1,2)" = "$(printf 'run-triage\t1')" ] && ok \
  || bad "R1 want lane run-triage with 1 call, got [$OUT]"

# ============================ U1-U3: the reader ============================
H="$T/h"
mkdir -p "$H/bin" "$H/state/cost" "$H/logs" "$H/flags"
scratch_install_closure bin/spend-alerts.sh "$H" >/dev/null || bad "could not install the bin/spend-alerts.sh closure"
SA="$H/bin/spend-alerts.sh"
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
# urow <ts> <project> <stage> <lane_id> <rc> <input_toks> <cost_usd> [row_source] [model]
urow() {
  printf '%s,box-fixture,%s,%s,claude,%s,%s,1,%s,0,0,0,%s,api,,acct-fixture,,%s,,,,,,,%s,\n' \
    "$1" "$2" "$3" "${9:-claude-fixture-model}" "$5" "$6" "$7" "${8:-}" "$4"
}
D=2026-10-12
SINCE="${D}T00:00:00Z"
{
  echo "$HDR"
  urow ${D}T01:00:00Z fixture-proj exec lane-a 0 0   ""           # blank, rc 0, tokens 0
  urow ${D}T02:00:00Z fixture-proj exec lane-a 0 500 ""           # blank, rc 0, tokens 500
  urow ${D}T02:00:00Z fixture-proj exec lane-a 0 500 ""           # duplicate line: once
  urow ${D}T03:00:00Z fixture-proj triage-fixture "" 1 500 abc    # rc 1 after billing; cost not a number
} > "$T/u1.csv"
OUT=$("$SA" unpriced --rows "$T/u1.csv" --since "$SINCE" 2>"$T/u1.err"); rc=$?
[ "$rc" = 0 ] && ok || bad "U1 unpriced exited $rc: $(cat "$T/u1.err")"
L1=$(printf '%s\n' "$OUT" | sed -n 1p); L2=$(printf '%s\n' "$OUT" | sed -n 2p)
[ "$L1" = "$(printf 'lane-a\t2\tclaude/claude-fixture-model:2\tfixture-proj')" ] && ok \
  || bad "U1 line 1 want lane-a 2 claude/claude-fixture-model:2 fixture-proj, got [$L1] (all: [$OUT])"
[ "$L2" = "$(printf 'triage-fixture\t1\tclaude/claude-fixture-model:1\tfixture-proj')" ] && ok \
  || bad "U1 line 2 want triage-fixture 1 …, got [$L2]"
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] && ok || bad "U1 want 2 lines, got [$OUT]"
# pairs order and projects: two models, two projects on one lane
{
  echo "$HDR"
  urow ${D}T01:00:00Z p-two exec lane-c 0 5 "" "" m-fixture-b
  urow ${D}T02:00:00Z p-one exec lane-c 0 5 "" "" m-fixture-a
  urow ${D}T03:00:00Z p-one exec lane-c 0 6 "" "" m-fixture-b
} > "$T/u1b.csv"
OUT=$("$SA" unpriced --rows "$T/u1b.csv" --since "$SINCE" 2>/dev/null)
[ "$OUT" = "$(printf 'lane-c\t3\tclaude/m-fixture-b:2,claude/m-fixture-a:1\tp-one,p-two')" ] && ok \
  || bad "U1 pairs by count desc and sorted projects: got [$OUT]"

# U2 — nothing else counts
{
  echo "$HDR"
  urow ${D}T01:00:00Z fixture-proj exec lane-a 0 500 0            # priced \$0
  urow ${D}T01:00:00Z fixture-proj exec lane-a 0 500 0.000000     # priced \$0
  urow ${D}T02:00:00Z fixture-proj exec lane-a 1 0 ""             # never billed
  urow ${D}T03:00:00Z fixture-proj exec lane-a 127 "" ""          # never billed, no tokens
  urow ${D}T04:00:00Z fixture-proj exec lane-a 0 500 "" refused
  urow ${D}T05:00:00Z fixture-proj exec lane-a 0 500 "" settled
  urow ${D}T06:00:00Z fixture-proj exec lane-a 0 500 "" unbilled
  urow 2026-10-11T23:59:59Z fixture-proj exec lane-a 0 500 ""     # before since
} > "$T/u2.csv"
OUT=$("$SA" unpriced --rows "$T/u2.csv" --since "$SINCE" 2>"$T/u2.err"); rc=$?
[ "$rc" = 0 ] && [ -z "$OUT" ] && ok || bad "U2 want rc 0 and no output, got rc=$rc out=[$OUT] err=[$(cat "$T/u2.err")]"

# U3 — unreadable is not zero
printf 'ts,project,stage\n2026-10-12T10:00:00Z,p,x\n' > "$T/u3.csv"
OUT=$("$SA" unpriced --rows "$T/u3.csv" --since "$SINCE" 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$OUT" ] && ok || bad "U3 a csv with no cost_usd header: rc=$rc out=[$OUT] (want rc 1, nothing printed)"
OUT=$("$SA" unpriced --rows "$T/u1.csv" --bogus x 2>/dev/null); rc=$?
[ "$rc" = 2 ] && ok || bad "U3 an unknown flag: rc=$rc want 2"
OUT=$("$SA" unpriced --rows "$T/u1.csv" 2>/dev/null); rc=$?
[ "$rc" = 2 ] && ok || bad "U3 no --since: rc=$rc want 2"

# ===================== P1-P5: the production block in pipeline-health.sh =====================
FIXNOW=$(date -u -d "${D}T15:00:00Z" +%s)
awk '/^# >>> spend alerts/{f=1;next} /^# <<< spend alerts/{exit} f' "$DIR/bin/pipeline-health.sh" > "$H/blk.sh"
[ -s "$H/blk.sh" ] && ok || bad "could not extract the spend alerts block from bin/pipeline-health.sh"
awk '/^alert\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$H/alert-fn.sh"
[ -s "$H/alert-fn.sh" ] && ok || bad "could not extract alert() from bin/pipeline-health.sh"

# The 14-day history: fly-pool $40..$120 a day, p99 $120. Rows are priced.
prow() { printf '%s,box-fixture,fixture-busy,execute,claude,claude-fixture-model,0,1,10,0,0,0,%s,api,,,,result,,,,,,,%s,\n' "$1" "$3" "$2"; }
{
  echo "$HDR"
  i=0
  for c in 120 100 95 90 85 80 75 70 65 60 55 50 45 40; do
    i=$((i+1)); prow "$(date -u -d "$D -$i days" +%F)T10:00:00Z" fly-pool "$c"
  done
} > "$H/hist.csv"

cat > "$H/stubs.sh" <<'SH'
alert() { printf '%s\t%s\n' "$2" "$3" >> "$H/alerts.rec"; }
cost_rows_db_enabled() { return 0; }
cost_rows_fetch() { # <out> <since> [until]
  echo "$2 ${3:-}" >> "$H/fetch.rec"
  case "$2" in *T00:00:00Z) [ "$2" = "$(date -u -d "@$NOW" +%F)T00:00:00Z" ] && { cp "$H/today.csv" "$1"; return 0; } ;; esac
  cp "$H/hist.csv" "$1"
}
lane_knob() { return 0; }
flag_set()      { echo "flag_set $*" >> "$H/forbidden.rec"; }
cb_halt()       { echo "cb_halt $*" >> "$H/forbidden.rec"; }
page_critical() { echo "page_critical $*" >> "$H/forbidden.rec"; }
setting_set()   { echo "setting_set $*" >> "$H/forbidden.rec"; }
SH
cat > "$H/bin/ph-driver.sh" <<'SH'
#!/bin/bash
set -uo pipefail
H="$HARNESS"; NOW="$FIXNOW"
DEDUP="$H/state/health-alerted.json"; FIRED="$H/state/fired"
[ -s "$DEDUP" ] || echo '{}' > "$DEDUP"
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
. "$H/stubs.sh"
if [ "${REAL_ALERT:-0}" = 1 ]; then
  . "$H/alert-fn.sh"
  alert_emit() { printf '%s\t%s\n' "${2:-}" "$1" >> "$H/emit.rec"; }
fi
. "$H/blk.sh"
SH
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/ph-driver.sh" "$H/bin/beat.sh"

fresh() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/flags"
  rm -f "$H/alerts.rec" "$H/fetch.rec" "$H/forbidden.rec" "$H/emit.rec"
  mkdir -p "$H/state/cost" "$H/logs" "$H/flags"
}
drive() { # drive [now]
  HARNESS="$H" FIXNOW="${1:-$FIXNOW}" REAL_ALERT="${REAL_ALERT:-0}" bash "$H/bin/ph-driver.sh" 2>>"$H/drive.err"
}
nkey() { local n; n=$(grep -c "^$1	" "$H/alerts.rec" 2>/dev/null); echo "${n:-0}"; }
nun() { local n; n=$(grep -c '^spendunpriced:' "$H/alerts.rec" 2>/dev/null); echo "${n:-0}"; }

# P1 — one unpriced call raises one alert
fresh
{ echo "$HDR"; urow ${D}T09:00:00Z fixture-proj triage run-triage 0 500 ""; } > "$H/today.csv"
drive
[ "$(nkey 'spendunpriced:run-triage')" = 1 ] && ok \
  || bad "P1 want exactly one spendunpriced:run-triage alert, got $(nkey 'spendunpriced:run-triage') [$(cat "$H/alerts.rec" 2>/dev/null)] err=[$(cat "$H/drive.err" 2>/dev/null)]"
L=$(grep '^spendunpriced:run-triage	' "$H/alerts.rec" 2>/dev/null)
grep -qF '1 unpriced cost row(s)' <<<"$L" && ok || bad "P1 the text does not carry '1 unpriced cost row(s)': [$L]"
grep -qF 'claude/claude-fixture-model:1' <<<"$L" && ok || bad "P1 the text does not name the pair: [$L]"
grep -qF 'nothing is refused or held' <<<"$L" && ok || bad "P1 the text does not say nothing is refused or held: [$L]"
grep -qF 'projects fixture-proj' <<<"$L" && ok || bad "P1 the text does not name the project: [$L]"
[ "$(nun)" = 1 ] && ok || bad "P1 want 1 spendunpriced alert in total, got $(nun)"

# P2 — once a day, with the REAL alert()
fresh
REAL_ALERT=1 drive
rm -f "$H/state/spend-alerts.stamp"; REAL_ALERT=1 drive
rm -f "$H/state/spend-alerts.stamp"; REAL_ALERT=1 drive $((FIXNOW + 3600))
n=$(grep -c '^ph-spendunpriced_run-triage	' "$H/emit.rec" 2>/dev/null); n=${n:-0}
[ "$n" = 1 ] && ok || bad "P2 want 1 alert_emit for ph-spendunpriced_run-triage over three same-day runs, got $n err=[$(cat "$H/drive.err" 2>/dev/null)]"
# the next day the same lane alerts again (a new day's rows)
sed "s/^${D}T09/$(date -u -d "$D +1 day" +%F)T09/" "$H/today.csv" > "$H/today.next" && mv "$H/today.next" "$H/today.csv"
rm -f "$H/state/spend-alerts.stamp"; REAL_ALERT=1 drive $((FIXNOW + 86400))
n=$(grep -c '^ph-spendunpriced_run-triage	' "$H/emit.rec" 2>/dev/null); n=${n:-0}
[ "$n" = 2 ] && ok || bad "P2 want 2 alert_emit lines after a day, got $n"

# P3 — one key per lane, nothing refused
fresh
{ echo "$HDR"
  urow ${D}T01:00:00Z fixture-proj exec lane-a 0 500 ""
  urow ${D}T02:00:00Z fixture-proj exec lane-a 0 400 ""
  urow ${D}T03:00:00Z fixture-proj exec lane-b 0 300 ""; } > "$H/today.csv"
drive
[ "$(nkey 'spendunpriced:lane-a')" = 1 ] && [ "$(nkey 'spendunpriced:lane-b')" = 1 ] && [ "$(nun)" = 2 ] && ok \
  || bad "P3 want one key each for lane-a and lane-b, got [$(grep '^spendunpriced:' "$H/alerts.rec" 2>/dev/null)]"
grep '^spendunpriced:lane-a	' "$H/alerts.rec" 2>/dev/null | grep -qF '2 unpriced cost row(s)' && ok || bad "P3 lane-a does not say 2 rows"
[ ! -s "$H/forbidden.rec" ] && ok || bad "P3 a refusing verb was called: [$(cat "$H/forbidden.rec")]"
grep -qE '^(spend-hold-|paused-)' <<<"$(ls "$H/flags")" && bad "P3 a hold or pause flag was written" || ok

# P4 — the reader fails; the noeval alert names it and the p99 check still runs
fresh
{ echo "$HDR"
  urow ${D}T01:00:00Z fixture-proj exec lane-a 0 500 ""
  prow ${D}T02:00:00Z fly-pool 300; } > "$H/today.csv"
mv "$SA" "$H/bin/spend-alerts.real"
cat > "$SA" <<'SH'
#!/bin/bash
[ "${1:-}" = unpriced ] && exit 1
exec "$(dirname "$0")/spend-alerts.real" "$@"
SH
chmod +x "$SA"
drive
mv -f "$H/bin/spend-alerts.real" "$SA"
[ "$(nkey 'spendalertnoeval:fleet')" = 1 ] && ok || bad "P4 want one spendalertnoeval:fleet alert, got $(nkey 'spendalertnoeval:fleet') [$(cat "$H/alerts.rec" 2>/dev/null)]"
grep '^spendalertnoeval:fleet	' "$H/alerts.rec" 2>/dev/null | grep -q 'unpriced' && ok || bad "P4 the noeval alert does not name unpriced"
[ "$(nkey 'spendp99:lane:fly-pool')" = 1 ] && ok || bad "P4 the p99 check did not run after the unpriced read failed"
[ "$(nun)" = 0 ] && ok || bad "P4 a failed reader raised a spendunpriced alert"

# P5 — never-billed and unbilled rows do not alert
fresh
{ echo "$HDR"
  urow ${D}T01:00:00Z fixture-proj triage run-triage 1 0 ""
  urow ${D}T02:00:00Z fixture-proj triage run-triage 127 "" ""
  urow ${D}T03:00:00Z fixture-proj triage run-triage 1 "" 0 unbilled; } > "$H/today.csv"
drive
[ "$(nun)" = 0 ] && ok || bad "P5 never-billed rows raised [$(grep '^spendunpriced:' "$H/alerts.rec")]"
[ "$(nkey 'spendalertnoeval:fleet')" = 0 ] && ok || bad "P5 a good read raised noeval: [$(cat "$H/alerts.rec" 2>/dev/null)]"

echo "unpriced-calls.bh-6175: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
