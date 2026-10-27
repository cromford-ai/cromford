#!/bin/bash
# tests/archie-fm-report.bh-4588-test.sh — BH-4588 (BH-4574.6): Archie's daily
# factory report and the stop-the-line beat, driven through the SHIPPED
# bin/archie-fm-report.sh (the ticket's archie-fm-report-test, keyed to the
# ticket per house rule).
#
# THE WORLD. A scratch $HARNESS with the lane's closure (scratch_install_closure)
# and the shipped catalog/archie-stop-the-line.tsv. The report the lane reads is
# the REAL route output: tests/fixtures/archie-fm-report.bh-4588/report.json
# (a seeded day) and empty.json (an empty day), both pinned against the live
# route by worker/jobs/test/archie-factory.bh-4588.test.js W1/W2.
#
# WHAT IS STUBBED, and only this. ARCHIE_FMR_FIXTURE=$T/fx.sh (sandbox-only):
#   _jobs_req   a jq model over $T/db.json of GET /api/settings/<key>,
#               GET /api/archie/factory-report (the fixture files), GET
#               /api/ledger (the archie_tg rows) and GET /api/alerts. The
#               shipped setting_get, job_ledger_get and alerts_list run on it.
# $H/bin/archie-tg-send.sh logs each send to $T/tg.jsonl, marks archie_tg sent
# on rc 0, and answers the rc in $T/tg.rc. PATH stubs curl, gh, git and
# wrangler log to $T/net.log and fail.
#
# Cases: R1-R8 (the report), S1-S7 (stop the line), K1 (the backstop knob),
# X1-X3 (mutations, D1).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-report.bh-4588-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-report: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-report: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie-fm-report.sh" "$DIR/bin/lib/archie-fm-report/render.sh" "$DIR/bin/lib/archie-fm-report/stl.sh" \
         "$DIR/catalog/archie-stop-the-line.tsv" "$DIR/catalog/lanes.d/archie-fm-report.json" \
         "$DIR/cron/lanes/729-archie-fm-report.cron" "$DIR/worker/jobs/src/routes/archie-factory.js" \
         "$DIR/tests/fixtures/archie-fm-report.bh-4588/report.json" "$DIR/tests/fixtures/archie-fm-report.bh-4588/empty.json"; do
  if [ -f "$f" ]; then ok; else bad "missing $f"; fi
done
if [ ! -f "$DIR/bin/archie-fm-report.sh" ]; then
  echo "archie-fm-report: $PASS passed, $FAIL failed"; exit 1
fi
FIX="$DIR/tests/fixtures/archie-fm-report.bh-4588"

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/env" "$H/catalog" "$T/fakebin"
scratch_install_closure bin/archie-fm-report.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
cp "$DIR/catalog/archie-stop-the-line.tsv" "$H/catalog/"
: > "$H/env/global.env"
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
rc=$(cat "$FXT/tg.rc" 2>/dev/null || echo 0)
jq -nc --arg a "$1" --arg t "$2" --argjson rc "$rc" '{akey: $a, text: $t, rc: $rc}' >> "$FXT/tg-calls.jsonl"
[ "$rc" = 0 ] || exit "$rc"
jq -nc --arg a "$1" --arg t "$2" '{akey: $a, text: $t}' >> "$FXT/tg.jsonl"
jq --arg a "$1" '.tg[$a] = "sent"' "$FXT/db.json" > "$FXT/db.tmp" && mv "$FXT/db.tmp" "$FXT/db.json"
exit 0
SH
chmod +x "$H/bin/archie-tg-send.sh"
for s in curl gh git wrangler; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' "$s" > "$T/fakebin/$s"
done
chmod +x "$T/fakebin/"*

cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" out code=200 db="$FXT/db.json" key d
  JOBS_HTTP=""; JOBS_BODY=""
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s\n' "$m" "$p" >> "$FXT/reqlog"
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  [ "$m" = GET ] || { JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2; }
  case "${p%%\?*}" in
    /api/settings/*)
      [ -f "$FXT/settings.down" ] && { JOBS_HTTP=503; return 1; }
      key=${p#/api/settings/}
      out=$(jq -c --arg k "$key" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"no such setting"}'; return 2; } ;;
    /api/archie/factory-report)
      [ -f "$FXT/report.down" ] && { JOBS_HTTP=503; printf '{"error":"archie_actions unavailable"}'; return 1; }
      d=$(qp day)
      [ -f "$FXT/report.$d.json" ] || { JOBS_HTTP=404; return 2; }
      out=$(cat "$FXT/report.$d.json") ;;
    /api/ledger)
      key=$(printf '%b' "$(qp key | sed 's/%/\\x/g')")
      out=$(jq -c --arg k "$key" '.tg[$k] // empty | {ledger: {kind: "archie_tg", key: $k, status: .}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"no ledger row"}'; return 2; } ;;
    /api/alerts)
      [ -f "$FXT/alerts.down" ] && { JOBS_HTTP=503; return 1; }
      out=$(jq -c --arg s "$(qp state)" '{alerts: [.alerts[] | select(.state == $s)], truncated: false}' "$db") ;;
    *) JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
:
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test-fixture \
  JOBS_SETTINGS_CACHE_S=0 LANE_GATE_DISABLE=1
unset ARCHIE_FMR_ENABLED ARCHIE_FMR_TIMED ARCHIE_FMR_NOW ARCHIE_FMR_FIXTURE ARCHIE_QUIET_FROM_H ARCHIE_QUIET_TO_H 2>/dev/null || true

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
T0=$(date -u -d 2026-10-23T07:05:00Z +%s)   # after the 07 send hour; yesterday is 2026-10-22
DAY=2026-10-22
# reset <mode>: settings as seeded, no alert, no ledger row, the seeded day's report.
reset() {
  local p
  for p in reqlog tg.jsonl tg-calls.jsonl tg.rc net.log out report.down alerts.down settings.down; do scratch_rm "$T/$p" || exit 1; done
  scratch_rm "$H/logs/archie-fm-report.log" || exit 1
  rm -f "$T"/report.*.json
  cp "$FIX/report.json" "$T/report.$DAY.json"
  jq -nc --arg m "${1:-on}" '{settings: {"archie.manage": $m, "archie.report.send_hour_utc": "7",
      "archie.stl.main_red_min": "60", "archie.stl.queue_stall_min": "60", "archie.stl.box_down_min": "15",
      "archie.stl.spend_spike_min": "0", "archie.stl.beats_per_tick": "3"}, tg: {}, alerts: []}' > "$T/db.json"
}
# alert <id> <first_seen-epoch> [line]: one open alert, as GET /api/alerts answers it.
alert() {
  jq --arg id "$1" --arg fs "$(iso "$2")" --arg l "${3:-[orchestrator/main-red] example-org/cromford main is RED}" \
    '.alerts += [{id: $id, family: "fixture", box: "hub", project: "cromford", state: "new", count: 1,
      first_seen: $fs, last_seen: $fs, claimed_by: null, claimed_at: null, notified_at: null, severity: "warn", line: $l}]' \
    "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
tick() {
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_NOW="${1:-$T0}" ARCHIE_FMR_FIXTURE="$T/fx.sh" \
    bash "$H/bin/${FMR_BIN:-archie-fm-report.sh}" tick > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()     { local c; c=$(wc -l 2>/dev/null < "$1"); printf '%s' "${c:-0}" | tr -d ' '; }
sends() { n "$T/tg.jsonl"; }
akeys() { jq -r .akey "$T/tg.jsonl" 2>/dev/null | tr '\n' ' '; }
report_text() { jq -r 'select(.akey | startswith("fm-report:")) | .text' "$T/tg.jsonl" 2>/dev/null; }
logl()  { cat "$H/logs/archie-fm-report.log" 2>/dev/null; }

# ═════ R: the daily report ═══════════════════════════════════════════════════
# R1: the seeded day: every section, each count equal to the fixture's rows.
reset on
tick
eq "R1 rc 0" "$(cat "$T/rc")" 0
eq "R1 exactly one send" "$(sends)" 1
eq "R1 the akey is fm-report:<yesterday>" "$(akeys)" "fm-report:$DAY "
R=$(report_text)
for h in 'Merges:' 'Queue:' 'Stuck items:' 'Tickets:' 'Spend vs caps:' 'Archie actions:' 'Mode:'; do
  check "R1 the section [$h] is there" 'grep -q "^$h" <<<"$R"'
done
eq "R1 merges count" "$(grep '^Merges:' <<<"$R")" \
  "Merges: $(jq .merges.total "$FIX/report.json") merges across $(jq '.merges.by_project | length' "$FIX/report.json") projects."
eq "R1 merges 3 across 2 projects" "$(grep '^Merges:' <<<"$R")" "Merges: 3 merges across 2 projects."
eq "R1 merges per project" "$(grep -c '^- cromford: 2\. \|^- project-4: 1\. ' <<<"$R")" 2
eq "R1 stuck 2 cleared, 1 open" "$(grep '^Stuck items:' <<<"$R")" "Stuck items: 2 cleared, 1 open, 0 failed."
eq "R1 stuck items listed: one line per fixture item" "$(sed -n '/^Stuck items:/,/^Tickets:/p' <<<"$R" | grep -c '^- ')" \
  "$(jq '.stuck.items | length' "$FIX/report.json")"
eq "R1 tickets 1 filed, 1 shipped" "$(grep '^Tickets:' <<<"$R")" "Tickets: 1 filed, 1 commented, 1 shipped, 0 verified."
check "R1 the filed ticket links its issue" 'grep -qxe "- filed: .*https://github.com/example-org/cromford/issues/9001" <<<"$R"'
eq "R1 spend cromford" "$(grep '^- cromford: \$' <<<"$R")" "- cromford: \$3.75 of a \$11323.76 day cap (partial: 1 of 3 calls unpriced)."
eq "R1 spend project-4 unknown, never \$0" "$(grep '^- project-4: unknown' <<<"$R")" "- project-4: unknown of a \$4970.21 day cap (1 call, none priced)."
eq "R1 queue health" "$(grep '^Queue:' <<<"$R")" "Queue: 3 batches finished (failed 1, merged 2). Queue actions: 2 (failed 1, done 1)."
eq "R1 action totals" "$(grep '^Archie actions:' <<<"$R")" "Archie actions: 8 (done 6, failed 1, requested 1)."
check "R1 the log says sent" 'logl | grep -q "sent fm-report:$DAY (mode on)"'

# R2: an empty day: every section says none: <reason>.
reset on
rm -f "$T/report.$DAY.json"; jq --arg d "$DAY" '.day = $d' "$FIX/empty.json" > "$T/report.$DAY.json"
tick
R=$(report_text)
for h in 'Merges' 'Queue' 'Stuck items' 'Tickets' 'Spend vs caps' 'Archie actions'; do
  check "R2 [$h] says none: <reason>" 'grep -qE "^$h: none: .+\." <<<"$R"'
done
check "R2 no heading is followed by nothing" '! grep -qE "^[A-Z][A-Za-z ]+:$" <<<"$R"'
eq "R2 the one thing" "$(sed -n 1p <<<"$R")" "Nothing needs you from 2026-10-01."

# R3: before the hour: nothing; after: one send; a second tick: no new send.
reset on
tick "$(date -u -d 2026-10-23T06:59:00Z +%s)"
eq "R3 before the send hour: 0 sends" "$(sends)" 0
check "R3 before the send hour: no report read" '! grep -q factory-report "$T/reqlog" 2>/dev/null'
tick
eq "R3 after the hour: 1 send" "$(sends)" 1
tick "$(( T0 + 900 ))"
eq "R3 a second tick: still 1 send" "$(sends)" 1
check "R3 a second tick: no second report read" '[ "$(grep -c factory-report "$T/reqlog")" = 1 ]'
jq '.settings["archie.report.send_hour_utc"] = "9"' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
jq '.tg = {}' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; : > "$T/tg.jsonl"
tick
eq "R3 the hour is the settings row (9): 0 sends at 07:05" "$(sends)" 0

# R4: archie.manage=off: the report says so, no action, no beat.
reset off
alert main-red-cromford "$(( T0 - 7200 ))"
tick
R=$(report_text)
eq "R4 one send (the report still goes out)" "$(sends)" 1
eq "R4 the first line says Archie is off" "$(sed -n 1p <<<"$R")" "Archie is off (archie.manage=off) and took no action."
check "R4 no POST at all (no archie_actions write)" '! grep -q "^POST" "$T/reqlog"'
eq "R4 no stl: beat for a 2 h main-red" "$(jq -r 'select(.akey | startswith("stl:")) | .akey' "$T/tg.jsonl" | wc -l | tr -d ' ')" 0
check "R4 no alert read when off" '! grep -q "/api/alerts" "$T/reqlog"'

# R5: voice: no em or en dash, the one thing first, a PR link on each PR line.
reset on
jq '.stuck.items[0].why = "kicked the lane — twice – today"' "$FIX/report.json" > "$T/report.$DAY.json"
tick
R=$(report_text)
check "R5 no em dash or en dash" '! grep -q "[—–]" <<<"$R"'
eq "R5 the first line is the one thing" "$(sed -n 1p <<<"$R")" "$(jq -r .one_thing.text "$FIX/report.json")"
while IFS= read -r l; do
  check "R5 [$l] carries a pull link" 'grep -qE "https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+" <<<"$l"'
done < <(grep -E '#[0-9]+,' <<<"$R")
check "R5 numbers, not adjectives" 'grep -qE "^Merges: [0-9]+ merges" <<<"$R"'

# R6: the route fails: nothing sent, one log line.
reset on
: > "$T/report.down"
tick
eq "R6 nothing sent" "$(sends)" 0
eq "R6 no tg call at all" "$(n "$T/tg-calls.jsonl")" 0
eq "R6 one log line names the failure" "$(logl | grep -c "report $DAY: GET /api/archie/factory-report failed (rc=1 http=503)")" 1
rm -f "$T/report.down"; tick "$(( T0 + 900 ))"
eq "R6 the next tick retries and sends" "$(sends)" 1

# R7: archie-tg-send not configured (rc 2): one log line, nothing recorded sent.
reset on
echo 2 > "$T/tg.rc"
tick; tick "$(( T0 + 900 ))"
eq "R7 tried each tick" "$(n "$T/tg-calls.jsonl")" 2
eq "R7 nothing sent" "$(sends)" 0
eq "R7 nothing recorded as sent" "$(jq -r '.tg | length' "$T/db.json")" 0
eq "R7 one log line for the day" "$(logl | grep -c 'not configured')" 1
check "R7 no sent line" '! logl | grep -q "^.* sent fm-report"'

# R8: the spend section failed: not measured, and no over-cap claim.
reset on
jq '.spend = {ok: false, error: "D1_ERROR: fixture cost read down"}' "$FIX/report.json" > "$T/report.$DAY.json"
tick
R=$(report_text)
eq "R8 not measured" "$(grep '^Spend vs caps:' <<<"$R")" "Spend vs caps: not measured: D1_ERROR: fixture cost read down."
check "R8 never claims over cap" '! grep -qi "over" <<<"$(grep -iE "cap" <<<"$R")"'
check "R8 the other sections still print" 'grep -q "^Merges: 3 merges" <<<"$R"'
reset on
: > "$T/settings.down"
tick
eq "R8 settings unreadable: the tick sends nothing" "$(sends)" 0
check "R8 settings unreadable: one log line" 'logl | grep -q "archie.report.send_hour_utc could not be read (rc=1); no report this tick"'
REND=$(env HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_NOW="$T0" ARCHIE_FMR_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-report.sh" render "$DAY")
check "R8 an unreadable mode prints mode unknown, never off" \
  'grep -qx "Mode: unknown (settings unreadable)." <<<"$REND" && ! grep -q "Archie is off" <<<"$REND"'

# ═════ S: stop the line ══════════════════════════════════════════════════════
# S1: the class table, read from the shipped TSV.
# shellcheck source=../bin/lib/archie-fm-report/stl.sh
. "$H/bin/lib/archie-fm-report/stl.sh" || { echo "FAIL: cannot source stl.sh"; exit 1; }
s1() {
  local id want got
  while IFS='|' read -r id want; do
    [ -n "$id" ] || continue
    got=$(HARNESS="$1" afr_stl_class "$id") || got=none
    eq "S1 [$id]" "${got%%$'\t'*}" "$want"
  done <<'EOF'
main-red-cromford|main-red
main-red-project-4|main-red
mc-window-stall-example-org_project-4|queue-stalled
pool-box-project-1|box-down
ph-costrate_hub|spend-spike
budget-stop_cromford|spend-spike
ph-overcap_project-4|spend-spike
main-red-bisect_cromford|none
main-red-prs:example-org-cromford:0123abcd|none
ph-costrollupstale_hub|none
pool-boxes-behind|none
fleet-propagate-boxes-behind|none
mc-window-stall|none
EOF
}
s1 "$H"
eq "S1 main-red reads its min-age row" "$(HARNESS="$H" afr_stl_class main-red-x | cut -f2)" archie.stl.main_red_min

# S2: 59 min, no beat; 60 min, one beat.
reset on
FS=$(( T0 - 59 * 60 )); alert main-red-cromford "$FS"
tick
eq "S2 59 min: no stl beat" "$(jq -r 'select(.akey | startswith("stl:")) | .akey' "$T/tg.jsonl" | wc -l | tr -d ' ')" 0
tick "$(( T0 + 60 ))"
eq "S2 60 min: one beat with the incident akey" "$(jq -r 'select(.akey | startswith("stl:")) | .akey' "$T/tg.jsonl")" "stl:main-red-cromford@$FS"
check "S2 the beat says what and how long" \
  'jq -r "select(.akey | startswith(\"stl:\")) | .text" "$T/tg.jsonl" | grep -q "^Stop the line: main has been red for 60 min. Alert main-red-cromford: "'
jq '.settings["archie.stl.main_red_min"] = "120"' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
alert main-red-project-4 "$(( T0 - 90 * 60 ))"
tick "$(( T0 + 120 ))"
eq "S2 the threshold is the settings row (120): a 90 min red waits" \
  "$(jq -r 'select(.akey | startswith("stl:main-red-project-4"))' "$T/tg.jsonl" | wc -l | tr -d ' ')" 0
reset on
alert main-red-cromford "$(( T0 - 7200 ))"
jq '.alerts[0].first_seen = "not-a-date"' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
check "S2 an unreadable first_seen: no beat, one log line" \
  '[ -z "$(jq -r "select(.akey | startswith(\"stl:\"))" "$T/tg.jsonl" 2>/dev/null)" ] && logl | grep -q "first_seen .not-a-date. is unreadable"'

# S3 + S4: 5 incidents: 3 beats, then 2, then 0 (the cap is the settings row).
reset on
alert main-red-cromford "$(( T0 - 7200 ))"
alert main-red-project-4 "$(( T0 - 7100 ))"
alert pool-box-project-1 "$(( T0 - 3600 ))"
alert pool-box-project-3 "$(( T0 - 3500 ))"
alert ph-costrate_hub "$(( T0 - 60 ))"
alert main-red-bisect_cromford "$(( T0 - 9000 ))"
stl_n() { jq -r 'select(.akey | startswith("stl:")) | .akey' "$T/tg.jsonl" 2>/dev/null | wc -l | tr -d ' '; }
tick "$T0"
eq "S3 tick 1: 3 beats (archie.stl.beats_per_tick)" "$(stl_n)" 3
check "S3 the oldest first" 'jq -r .akey "$T/tg.jsonl" | head -1 | grep -q "^stl:main-red-cromford@"'
check "S3 the rest wait, and the log says so" 'logl | grep -q "2 more incident(s) wait for the next tick"'
tick "$(( T0 + 900 ))"
eq "S3 tick 2: the other 2" "$(stl_n)" 5
tick "$(( T0 + 1800 ))"
eq "S4 tick 3 on the same open incidents: 0 new beats" "$(stl_n)" 5
eq "S3 the bisect near miss never beats" "$(jq -r .akey "$T/tg.jsonl" | grep -c bisect)" 0
reset on
jq '.settings["archie.stl.beats_per_tick"] = "1"' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
alert main-red-cromford "$(( T0 - 7200 ))"; alert main-red-project-4 "$(( T0 - 7100 ))"
tick "$T0"
eq "S3 the cap is the settings row (1)" "$(stl_n)" 1

# S5: alerts_list fails: no beat, one log line, never "no incidents".
reset on
alert main-red-cromford "$(( T0 - 7200 ))"
: > "$T/alerts.down"
tick "$T0"
eq "S5 0 beats" "$(stl_n)" 0
check "S5 one log line" 'logl | grep -q "stl: the open alerts (state new) could not be read (rc=1 .*); no beat this tick"'

# S6: quiet hours do not hold a stop-the-line beat.
reset on
NIGHT=$(date -u -d 2026-10-23T03:00:00Z +%s)
alert main-red-cromford "$(( NIGHT - 7200 ))"
ARCHIE_QUIET_FROM_H=22 ARCHIE_QUIET_TO_H=8 tick "$NIGHT"
eq "S6 the beat goes out at 03:00 inside a 22-08 quiet window" "$(stl_n)" 1

# S7: observe mode still beats.
reset observe
alert main-red-cromford "$(( T0 - 7200 ))"
tick "$T0"
eq "S7 observe: one beat" "$(stl_n)" 1

# The dry list: what is due, nothing sent.
reset on
alert main-red-cromford "$(( T0 - 7200 ))"
DRY=$(env HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_NOW="$T0" ARCHIE_FMR_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-report.sh" stl --dry-list)
eq "dry-list: one due incident" "$(cut -f2,3,4 <<<"$DRY")" "main-red-cromford@$(( T0 - 7200 ))"$'\t'"main-red"$'\t'"120"
eq "dry-list sends nothing" "$(sends)" 0
REND=$(env HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_NOW="$T0" ARCHIE_FMR_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-report.sh" render "$DAY")
check "render <day>: the stop-the-line incident is the first line" 'sed -n 1p <<<"$REND" | grep -q "^Stop the line: 1 open incident, first main-red (alert main-red-cromford, open 120 min)\.$"'
eq "render sends nothing" "$(sends)" 0

# The switch.
reset on
alert main-red-cromford "$(( T0 - 7200 ))"
ARCHIE_FMR_ENABLED=0 tick
eq "ARCHIE_FMR_ENABLED=0: no send" "$(sends)" 0
check "ARCHIE_FMR_ENABLED=0: no read" '[ ! -s "$T/reqlog" ]'

# ═════ K1: the backstop timeout is a knob (BH-7945) ══════════════════════════
# A fake timeout logs its argv and runs nothing. No row and no env: the
# registry defaults (600 s, kill 30 s). The env (global.env's path) wins.
mkdir -p "$T/k1bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$T/k1.log" > "$T/k1bin/timeout"
chmod +x "$T/k1bin/timeout"
reset on
env -u ARCHIE_FMR_TIMED PATH="$T/k1bin:$PATH" HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_FIXTURE="$T/fx.sh" \
  bash "$H/bin/archie-fm-report.sh" tick >/dev/null 2>&1
env -u ARCHIE_FMR_TIMED PATH="$T/k1bin:$PATH" HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_FIXTURE="$T/fx.sh" \
  ARCHIE_FMR_TICK_CEILING_S=123 ARCHIE_FMR_TICK_KILL_S=7 bash "$H/bin/archie-fm-report.sh" tick >/dev/null 2>&1
eq "K1 the default backstop" "$(sed -n 1p "$T/k1.log" 2>/dev/null | cut -d' ' -f1-3)" "-k 30 600"
eq "K1 the knob sets the backstop" "$(sed -n 2p "$T/k1.log" 2>/dev/null | cut -d' ' -f1-3)" "-k 7 123"
eq "K1 the fake timeout ran the tick twice and sent nothing" "$(sends)" 0

# ═════ X: mutations (D1) ═════════════════════════════════════════════════════
# X1: the off-mode line removed from render.sh -> R4's assertion goes red.
sed -i '/Archie is off (archie.manage=off) and took no action./d' "$H/bin/lib/archie-fm-report/render.sh"
check "X1 the mutant differs" '! cmp -s "$H/bin/lib/archie-fm-report/render.sh" "$DIR/bin/lib/archie-fm-report/render.sh"'
reset off
tick
check "X1 without the off line R4 is red" '[ "$(report_text | sed -n 1p)" != "Archie is off (archie.manage=off) and took no action." ]'
scratch_rm "$H/bin/lib/archie-fm-report/render.sh" || exit 1
scratch_install_closure bin/archie-fm-report.sh "$H" >/dev/null || exit 1
check "X1 the closure is restored" 'cmp -s "$H/bin/lib/archie-fm-report/render.sh" "$DIR/bin/lib/archie-fm-report/render.sh"'
# X2: the bisect exclusion row dropped -> S1's near miss goes red.
mkdir -p "$T/x2/catalog"
grep -v '^-	main-red-bisect_' "$H/catalog/archie-stop-the-line.tsv" > "$T/x2/catalog/archie-stop-the-line.tsv"
got=$(HARNESS="$T/x2" afr_stl_class main-red-bisect_cromford) || got=none
check "X2 without the exclusion row the bisect alert would beat (so S1 is a real guard)" '[ "${got%%$'"'"'\t'"'"'*}" = main-red ]'
# X3: no network, no git, no GitHub.
check "X3 the fakebin network log is empty" '[ ! -s "$T/net.log" ]'

echo "archie-fm-report: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
