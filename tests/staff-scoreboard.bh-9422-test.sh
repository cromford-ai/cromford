#!/bin/bash
# tests/staff-scoreboard.bh-9422-test.sh — BH-9422 (C4 of BH-9187): the staff
# lever scoreboard in the weekly overlook report and in Archie's turn briefing.
# Drives the SHIPPED entry points: bin/lib/staff-scoreboard.sh (sourced),
# bin/archie-overlook.sh (run, sandboxed) and bin/orchestrate.sh's
# compose_v2_prompt (the real function text, the repo-activity.bh-8417 method).
#
#   S1  staff_scoreboard_line: the full line, `no sample`, `target n/a`,
#       `no metric row`, `precision n/a`, `0%`, `not on the scoreboard`; no em dash
#   S2  archie_staff_metrics_block with opt-in: the header names the window,
#       one `- <agent>: ...` line per scoreboard agent, archie absent
#   S3  the ARCHIE_STAFF_METRICS_TIMEOUT_S table; the one request carries
#       JOBS_TIMEOUT = the knob and JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
#   S4  sandbox without opt-in: 0 requests; a failed read: one UNREADABLE line, rc 0
#   W1  the weekly report: each `- <agent>: filed ..., spend $x` line is
#       unchanged and is followed by `  metric: <line>`
#   W2  a failed scoreboard read: one `staff metrics unreadable (` line, no
#       metric line, the report is sent and the ledger says sent
#   W3  7 agents: the report is not cut (<= 3500 chars) and has no em dash
#   P1  compose_v2_prompt: STAFF METRICS after REPO ACTIVITY, before RECENT
#       CONVERSATION
#   P2  the lib missing: no STAFF METRICS section, the turn briefing is whole
#   N1  the worker and console suites of this ticket, when their deps exist
#
# 0 vendor calls: _jobs_req is a fixture function; GitHub goes through the
# overlook fixture seam (ARCHIE_OVERLOOK_FIXTURE); the beat goes to a stub
# bin/archie-tg-send.sh; curl and gh on PATH log and fail.
#
# MUTATIONS (D1), each tried once by hand: precision null as 0% -> S1 red;
# swap now and then -> S1 red; drop the orchestrate block -> P1 red; drop the
# report metric line -> W1 red; return from weekly() on a failed read -> W2
# red; drop JOBS_RETRIES=0 -> S3 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-scoreboard.bh-9422-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
# The merge-queue shards do not set HARNESS_TEST_SANDBOX (.github/workflows/
# harness-ci.yml, "HARNESS_TEST_SANDBOX IS DELIBERATELY NOT SET HERE"), so the
# suite sets it itself, like tests/repo-activity.bh-8417-test.sh: S4 tests the
# sandbox guard of archie_staff_metrics_block, which reads this flag.
export HARNESS_TEST_SANDBOX=1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "staff-scoreboard: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

LIB_SRC="$DIR/bin/lib/staff-scoreboard.sh"
ROUTE_SRC="$DIR/worker/jobs/src/routes/staff-scoreboard.js"
SCORES_SRC="$DIR/console-ui/src/lib/staff-scores.js"
METRICS_SRC="$DIR/console-ui/src/screens/staff/staff-metrics.js"
KNOB_SRC="$DIR/catalog/lanes.d/archie.knobs.d/ARCHIE_STAFF_METRICS_TIMEOUT_S.json"
for SRC in "$LIB_SRC" "$ROUTE_SRC" "$SCORES_SRC" "$METRICS_SRC" "$KNOB_SRC"; do
  [ -r "$SRC" ] || bad "missing $SRC"
done

# The B1 answer shape: exactly the scorecardOf fields.
SB="$T/scoreboard.json"
cat > "$SB" <<'JSON'
{"ok":true,"days":7,"as_of":"2026-10-12T10:00:00Z","agents":[
 {"agent":"inspector","days":7,"metric":"hours_behind_main","target":2,"level":"observe","metric_now":{"value":3,"sampled_at":"2026-10-12T09:00:00Z"},"metric_then":{"value":41,"sampled_at":"2026-10-04T09:00:00Z"},"actions":2,"dry_runs":1,"settled":2,"moved":1,"precision":0.5},
 {"agent":"clerk","days":7,"metric":"needs_count","target":300,"level":"observe","metric_now":{"value":3.456,"sampled_at":"2026-10-12T09:00:00Z"},"metric_then":null,"actions":0,"dry_runs":0,"settled":0,"moved":0,"precision":null},
 {"agent":"tackler","days":7,"metric":null,"target":null,"level":"observe","metric_now":null,"metric_then":null,"actions":0,"dry_runs":0,"settled":0,"moved":0,"precision":null},
 {"agent":"watchman","days":7,"metric":"live_unrotated_secrets","target":0,"level":"act","metric_now":{"value":0,"sampled_at":"2026-10-12T09:00:00Z"},"metric_then":{"value":2,"sampled_at":"2026-10-05T09:00:00Z"},"actions":3,"dry_runs":0,"settled":2,"moved":0,"precision":0}
]}
JSON

# ═════ S: the lib ════════════════════════════════════════════════════════════
if [ -r "$LIB_SRC" ] && . "$LIB_SRC" && command -v staff_scoreboard_line >/dev/null 2>&1; then
  eq "S1 full line" "$(staff_scoreboard_line "$SB" inspector)" \
    "hours_behind_main now 3 (7d ago 41), target 2, level observe; actions 2, moved 1 of 2 settled, precision 50%"
  eq "S1 no sample, 2 decimals, precision n/a" "$(staff_scoreboard_line "$SB" clerk)" \
    "needs_count now 3.46 (7d ago no sample), target 300, level observe; actions 0, moved 0 of 0 settled, precision n/a"
  eq "S1 no metric row, target n/a" "$(staff_scoreboard_line "$SB" tackler)" \
    "no metric row, target n/a, level observe; actions 0, moved 0 of 0 settled, precision n/a"
  eq "S1 0 is 0 and 0% when settled" "$(staff_scoreboard_line "$SB" watchman)" \
    "live_unrotated_secrets now 0 (7d ago 2), target 0, level act; actions 3, moved 0 of 2 settled, precision 0%"
  eq "S1 not on the scoreboard" "$(staff_scoreboard_line "$SB" nobody)" "not on the scoreboard"
  ALL_LINES=$(for a in inspector clerk tackler watchman nobody; do staff_scoreboard_line "$SB" "$a"; done)
  check "S1 no em dash in any line" '! grep -q "—" <<<"$ALL_LINES"'

  # The worker fixture: records each request and its JOBS_* values.
  _jobs_req() {
    printf '%s %s timeout=%s retries=%s ovl=%s\n' "$1" "$2" "${JOBS_TIMEOUT:-}" "${JOBS_RETRIES:-}" "${JOBS_OVERLOAD_RETRIES:-}" >> "$T/req.log"
    [ -f "$T/req.fail" ] && { [ -n "${JOBS_STATUS_FILE:-}" ] && echo "http=503" > "$JOBS_STATUS_FILE"; return 1; }
    [ "$1 $2" = "GET /api/staff/levers/scoreboard" ] && { cat "$SB"; return 0; }
    return 1
  }
  : > "$T/req.log"
  OUT=$(ARCHIE_STAFF_METRICS_SANDBOX=1 archie_staff_metrics_block); rc=$?
  eq "S2 rc" "$rc" 0
  eq "S2 header" "$(head -1 <<<"$OUT")" "=== STAFF METRICS (lever scorecards, 7d window) ==="
  eq "S2 one line per agent" "$(grep -c '^- ' <<<"$OUT")" 4
  check "S2 the inspector line" 'grep -qxF -- "- inspector: hours_behind_main now 3 (7d ago 41), target 2, level observe; actions 2, moved 1 of 2 settled, precision 50%" <<<"$OUT"'
  check "S2 archie absent" '! grep -q "archie" <<<"$OUT"'
  eq "S3 one request, the knob timeout, no retry" "$(cat "$T/req.log")" "GET /api/staff/levers/scoreboard timeout=5 retries=0 ovl=0"
  : > "$T/req.log"
  ARCHIE_STAFF_METRICS_SANDBOX=1 ARCHIE_STAFF_METRICS_TIMEOUT_S=12 archie_staff_metrics_block >/dev/null
  eq "S3 knob 12 reaches the request" "$(cat "$T/req.log")" "GET /api/staff/levers/scoreboard timeout=12 retries=0 ovl=0"
  for v in 12:12 5:5 1:1 30:30 0:5 31:5 abc:5 5s:5; do
    eq "S3 knob ${v%%:*}" "$(ARCHIE_STAFF_METRICS_TIMEOUT_S="${v%%:*}" archie_staff_metrics_timeout_s)" "${v##*:}"
  done
  eq "S3 knob empty is the fallback" "$(ARCHIE_STAFF_METRICS_TIMEOUT_S='' archie_staff_metrics_timeout_s)" 5
  eq "S3 registry default" "$(jq .default "$KNOB_SRC" 2>/dev/null)" 5
  : > "$T/req.log"
  OUT=$(archie_staff_metrics_block); rc=$?
  eq "S4 sandbox: 0 requests" "$(grep -c . "$T/req.log")" 0
  eq "S4 sandbox: not read" "$(tail -1 <<<"$OUT")" "(not read: test sandbox)"
  touch "$T/req.fail"
  OUT=$(ARCHIE_STAFF_METRICS_SANDBOX=1 archie_staff_metrics_block); rc=$?
  eq "S4 failed read rc 0" "$rc" 0
  eq "S4 failed read line" "$(tail -1 <<<"$OUT")" "UNREADABLE staff scoreboard (http=503)"
  rm -f "$T/req.fail"
  unset -f _jobs_req
  eq "S4 no client" "$(staff_scoreboard_get "$T/x.json")" "no-jobs-client"
else
  bad "S0 bin/lib/staff-scoreboard.sh does not define staff_scoreboard_line"
fi

# ═════ W: the weekly report, through bin/archie-overlook.sh ══════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/catalog" "$H/env" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/agent-core" "$H/agent-core"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/lane-alert.sh" "$H/bin/archie-tg-send.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/beats.log"\nexit 0\n' > "$H/bin/lane-alert.sh"
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/tg.log"
exit 0
SH
chmod +x "$H/bin/lane-alert.sh" "$H/bin/archie-tg-send.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/staff/agents") cat "$FXT/agents.json"; return 0 ;;
    "GET /api/staff/levers/scoreboard")
      [ -f "$FXT/scoreboard.fail" ] && { [ -n "${JOBS_STATUS_FILE:-}" ] && echo "curl_rc=28" > "$JOBS_STATUS_FILE"; return 1; }
      cat "$FXT/scoreboard.json"; return 0 ;;
  esac
  return 1
}
job_ledger_get() { [ -f "$FXT/ledger/$1__$2" ] || return 2; head -1 "$FXT/ledger/$1__$2"; }
job_ledger_put() { mkdir -p "$FXT/ledger"; printf '%s\n' "$3" > "$FXT/ledger/$1__$2"; }
flag_active() { [ -e "$HARNESS/flags/$1" ]; }
flag_set() { return 1; }
gh_rest() { return 1; }
gh_rest_issue_list() { GH_REST_STATUS=200; echo '[]'; return 0; }
SH
MON=1791799200   # Mon 2026-10-12T10:00:00Z, ISO week 2026-W42
reset() { # reset <agent>...: a fresh fixture, the roster and the scoreboard for those agents
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/ledger" "$H/flags" "$H/logs"
  : > "$FXT/req.log"; : > "$FXT/tg.log"
  printf '%s\n' "$@" | jq -R . | jq -sc '{agents: [.[] | {name: ., role: "x", accountable: "operator@example.com", status: "active"}]}' > "$FXT/agents.json"
  printf '%s\n' "$@" | jq -R . | jq -sc '{ok: true, days: 7, as_of: "2026-10-12T10:00:00Z", agents: [.[] | {agent: ., days: 7,
    metric: "hours_behind_main", target: 2, level: "observe", metric_now: {value: 3, sampled_at: "2026-10-12T09:00:00Z"},
    metric_then: {value: 41, sampled_at: "2026-10-04T09:00:00Z"}, actions: 2, dry_runs: 1, settled: 2, moved: 1, precision: 0.5}]}' \
    > "$FXT/scoreboard.json"
  printf 'ts,box,project,stage,a,b,c,d,e,f,g,h,cost_usd\n2026-10-11T08:00:00Z,hub,fleet,staff.%s,claude,m,0,1,0,0,0,0,0.40\n' "$1" > "$H/logs/cost.csv"
}
ov() {
  env HARNESS="$H" FXT="$FXT" ARCHIE_OVERLOOK_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 JOBS_URL= ARCHIE_NOW="$MON" PATH="$T/fakebin:$PATH" \
    bash "$H/bin/archie-overlook.sh" >"$T/out.txt" 2>&1
}
MLINE="  metric: hours_behind_main now 3 (7d ago 41), target 2, level observe; actions 2, moved 1 of 2 settled, precision 50%"

reset quartermaster watchman clerk
ov; rc=$?
eq "W1 rc" "$rc" 0
R=$(jq -r .line "$FXT/tg.log" 2>/dev/null)
eq "W1 one scoreboard read" "$(grep -c 'GET /api/staff/levers/scoreboard' "$FXT/req.log")" 1
eq "W1 the agent line is unchanged" "$(grep '^- quartermaster:' <<<"$R")" "- quartermaster: filed 0, digested 0, precision n/a, spend \$0.40"
for a in quartermaster watchman clerk; do
  eq "W1 $a: metric line right after the agent line" "$(grep -A1 "^- $a: filed " <<<"$R" | tail -1)" "$MLINE"
done
eq "W1 three metric lines" "$(grep -c '^  metric: ' <<<"$R")" 3
check "W1 no unreadable line" '! grep -q "staff metrics unreadable" <<<"$R"'

reset quartermaster watchman clerk
touch "$FXT/scoreboard.fail"
ov; rc=$?
R=$(jq -r .line "$FXT/tg.log" 2>/dev/null)
eq "W2 rc" "$rc" 0
eq "W2 the report is sent" "$(grep -c . "$FXT/tg.log")" 1
eq "W2 ledger sent" "$(cat "$FXT/ledger/archie_overlook__weekly-2026-W42" 2>/dev/null)" sent
eq "W2 one unreadable line" "$(grep -c '^staff metrics unreadable (curl_rc=28)$' <<<"$R")" 1
eq "W2 no metric line" "$(grep -c '^  metric: ' <<<"$R")" 0
eq "W2 the agent lines stay" "$(grep -c '^- ' <<<"$R")" 3

reset quartermaster watchman dispatcher inspector millwright clerk archivist
ov
R=$(jq -r .line "$FXT/tg.log" 2>/dev/null)
eq "W3 seven metric lines" "$(grep -c '^  metric: ' <<<"$R")" 7
check "W3 the report is not cut (${#R} chars)" '[ "${#R}" -le 3500 ] && ! grep -q "cut to 3500" "$H/logs/archie-overlook.log" 2>/dev/null'
check "W3 no em dash" '! grep -q "—" <<<"$R"'
check "W3 no network" '[ ! -s "$T/net.log" ]'

# ═════ P: Archie's turn briefing, through compose_v2_prompt ══════════════════
FN=$(sed -n '/^compose_v2_prompt() {/,/^}/p' "$DIR/bin/orchestrate.sh")
FXFN=$(declare -f _jobs_req 2>/dev/null; cat <<'SH'
_jobs_req() { [ "$1 $2" = "GET /api/staff/levers/scoreboard" ] && { cat "$SB"; return 0; }; return 1; }
SH
)
mkdir -p "$T/orc"
brief() { # brief <harness root>
  env HARNESS="$1" SB="$SB" ARCHIE_ORC_DIR="$T/orc" ORC_TURN_STATE="$T/orc/STATE.md" TEXT=hi-fixture META_TRANSPORT=telegram ORIGIN="" \
    ARCHIE_STAFF_METRICS_SANDBOX=1 bash -c "$FXFN"$'\n'"$FN"$'\n''compose_v2_prompt' 2>/dev/null
}
V2=$(brief "$H")
SL=$(grep -n '^=== STAFF METRICS (lever scorecards, 7d window) ===$' <<<"$V2" | cut -d: -f1)
AL=$(grep -n '^=== REPO ACTIVITY' <<<"$V2" | cut -d: -f1)
RL=$(grep -n '^=== RECENT CONVERSATION' <<<"$V2" | cut -d: -f1)
check "P1 STAFF METRICS after REPO ACTIVITY and before RECENT CONVERSATION ($AL/$SL/$RL)" '[ -n "$SL" ] && [ -n "$AL" ] && [ -n "$RL" ] && [ "$AL" -lt "$SL" ] && [ "$SL" -lt "$RL" ]'
check "P1 the inspector line is in the briefing" 'grep -qxF -- "- inspector: hours_behind_main now 3 (7d ago 41), target 2, level observe; actions 2, moved 1 of 2 settled, precision 50%" <<<"$V2"'
rm -f "$H/bin/lib/staff-scoreboard.sh"
V2=$(brief "$H")
check "P2 no lib: no STAFF METRICS section" '! grep -q "STAFF METRICS" <<<"$V2"'
check "P2 no lib: the conversation and the message stay" 'grep -q "^=== RECENT CONVERSATION" <<<"$V2" && [ "$(tail -1 <<<"$V2")" = hi-fixture ]'

# ═════ N1: the node suites of this ticket ════════════════════════════════════
if [ -r "$DIR/worker/jobs/schema.sql" ] && [ -r "$DIR/catalog/lanes.json" ]; then
  (cd "$DIR/worker/jobs" && node --test test/staff-scoreboard.bh-9422.test.js >"$T/n1.txt" 2>&1) && ok || { bad "N1 worker suite"; tail -30 "$T/n1.txt"; }
else
  echo "N1 worker suite skipped: worker/jobs/schema.sql or catalog/lanes.json not rendered"
fi
if [ -d "$DIR/console-ui/node_modules" ]; then
  (cd "$DIR/console-ui" && node --test tests/staff-metrics.bh-9422.test.js >"$T/n2.txt" 2>&1) && ok || { bad "N1 console suite"; tail -30 "$T/n2.txt"; }
else
  echo "N1 console suite skipped: console-ui deps missing"
fi

echo "staff-scoreboard.bh-9422: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
