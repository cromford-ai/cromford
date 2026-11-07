#!/bin/bash
# tests/lane-wake-calendar.bh-9074-test.sh — BH-9074 (BH-9067.2, parent T5):
# the calendar scheduler. The REAL bin/lane-wake-calendar.sh reads the SHIPPED
# catalog/lane-calendar.d/*.tsv and catalog/lane-wakes.d/*.json and rings
# through lwg_ring. C1-C13 use a stub bin/lib/lane-wake-gate.sh in the scratch
# tree: lwg_ring appends `<lane>|<scope>|<dedupe>` to $T/rings.<n> and keeps a
# dedupe set ($T/dd.<n>/, one file per ring, made with noclobber); lwg_mode
# answers $T/mode.<n>.<lane>, else shadow; a lane named in $T/ringfail.<n>
# rings rc 1. C-real runs the contract's REAL lib against the REAL worker
# routes (tests/lib/wakes-worker.bh-9074.mjs) and the SHIPPED bin/pm-groom.sh,
# and only when the contract (#9122) is in this tree. Clocks are pinned
# (LANE_WAKE_CALENDAR_NOW, LANE_GATE_NOW, PM_GROOM_NOW). Any host but the fake
# worker is logged to $T/net.log and fails (C14: 0 vendor calls).
#
#   C1  Monday 10:59Z, lead 2: pm-groom once per project (cal:w2026-46),
#       archie and orc-monitor once each (cal:20261109t1100); inserted=1 lines
#   C2  the same minute again: 0 new dedupe rows, inserted=0 lines
#   C3  Tuesday 10:59Z: no pm-groom, rule-miner or lookback ring; C3b a
#       minute no calendar matches rings nothing
#   C4  the wake gate lib missing: exit 0, no ring, one line at minute 00 only
#   C5  mode off for archie: archie not rung, the others are
#   C6  catalog/lane-wakes.d/pm-groom.json missing: pm-groom skipped, one line
#   C7  the cal_match table (bin/lane-wake-calendar.sh --match)
#   C8  a key format that yields a bad dedupe: bad-key, no ring; a malformed
#       expr: bad-expr, no ring, the next line still rings
#   C9  a ring that fails with mode on: ring-failed, one ALERTS line for two runs
#   C10 every shipped tsv line parses; its lane exists; the 7 registry files
#   C11 lead 0 rings the matching minute itself; lead x falls to 2 with a line
#   C12 the cadence of the 7 calendar lanes is unchanged (A-3)
#   C13 flags/lane-off-lane-wake-calendar: no ring; the cron line and the knob
#   C-real  the contract's lwg_ring over the real routes, then pm-groom's take
#   C14 0 calls to any host but the fake worker
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-wake-calendar.bh-9074-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The worker imports the git-ignored catalogs (lanes.json, llm-sites.json).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/wakes-worker.bh-9074.mjs"
SCRIPT_REL=bin/lane-wake-calendar.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

export LANE_REGISTRY
LANE_REGISTRY=$(cd "$DIR" && . bin/lib/lanes-registry.sh && lanes_json_path "$DIR") \
  || { echo "setup: the lane registry did not compose"; exit 1; }
PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT

REAL_CURL=$(command -v curl)
mkdir -p "$T/netbin"
cat > "$T/netbin/curl" <<SH
#!/bin/bash
for a in "\$@"; do
  case "\$a" in http://127.0.0.1:*) exec "$REAL_CURL" "\$@" ;; http://*|https://*) printf 'curl %s\n' "\$a" >> "$T/net.log"; exit 7 ;; esac
done
exec "$REAL_CURL" "\$@"
SH
cat > "$T/netbin/gh" <<SH
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$T/net.log"
exit 7
SH
chmod +x "$T/netbin/curl" "$T/netbin/gh"
: > "$T/net.log"

at() { date -u -d "$1" +%s; }
MON1059=$(at 2026-11-09T10:59:00Z)
MON1100=$(at 2026-11-09T11:00:00Z)
MON1101=$(at 2026-11-09T11:01:00Z)
TUE1059=$(at 2026-11-10T10:59:00Z)
TUE1002=$(at 2026-11-10T10:02:00Z)

# The stub wake gate lib (C1-C13).
STUBLIB=$(cat <<'SH'
# shellcheck shell=bash
# stub of bin/lib/lane-wake-gate.sh for tests/lane-wake-calendar.bh-9074-test.sh
lwg_mode() { cat "$LWG_STUB/mode.$1" 2>/dev/null || echo shadow; }
lwg_ring() {
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$LWG_STUB/rings"
  grep -qx -- "$1" "$LWG_STUB/ringfail" 2>/dev/null && return 1
  mkdir -p "$LWG_STUB/dd"
  if ( set -C; : > "$LWG_STUB/dd/$1.$2.$3" ) 2>/dev/null; then echo inserted=1; else echo inserted=0; fi
  return 0
}
SH
)

N=0
# fresh [real] — a new scratch harness H (the stub lib unless `real`) and a new worker.
fresh() {
  N=$((N+1))
  H="$T/h$N"; S="$T/s$N"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/env" "$H/catalog" "$S"
  [ "${1:-}" = real ] || printf '%s\n' "$STUBLIB" > "$H/bin/lib/lane-wake-gate.sh"
  ( cd "$DIR" && scratch_install_closure "$SCRIPT_REL" "$H" && scratch_install_closure bin/jobs-client.sh "$H" \
    && scratch_install_closure bin/fleet-conf.sh "$H" ) >/dev/null 2>&1 || bad "setup: closure install of $SCRIPT_REL"
  chmod +x "$H/bin/"*.sh 2>/dev/null
  cp -r "$DIR/catalog/lane-calendar.d" "$H/catalog/" 2>/dev/null
  mkdir -p "$H/catalog/lane-wakes.d"
  cp "$DIR"/catalog/lane-wakes.d/*.json "$H/catalog/lane-wakes.d/" 2>/dev/null
  # pm-groom's registry file is the contract's (#9122). Without it in this
  # tree, the suite writes the contract's shape so pm-groom has one.
  [ -f "$H/catalog/lane-wakes.d/pm-groom.json" ] \
    || printf '%s\n' '{"lane": "pm-groom", "scope": "project", "kinds": ["issue", "issue_comment"], "mode_knob": "MODE_PM_GROOM"}' > "$H/catalog/lane-wakes.d/pm-groom.json"
  printf 'project-3 example-org/project-3-fixture https://project-3.example.com /api/feature-board 0 local\nacme example-org/acme-fixture https://acme.example.com - 0 local\n' > "$H/fleet.conf"
  : > "$T/w$N.log"; : > "$T/w$N.port"
  export HARNESS="$H" LWG_STUB="$S" FLEET_CONF="$H/fleet.conf" HARNESS_SECRET=fixture-harness-secret \
    JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_GATE_CACHE_S=0 BOX_NAME=hub \
    PATH="$T/netbin:$PATH" HARNESS_TEST_SANDBOX=1 NODE_NO_WARNINGS=1
  unset LANE_WAKE_CALENDAR_LEAD_MIN LANE_SINGLE_RUN LANE_GATE_RUN
  node "$SRV" "$T/w$N.log" > "$T/w$N.port" 2> "$T/w$N.err" &
  WPID=$!; PIDS+=("$WPID")
  for _ in $(seq 1 200); do [ -s "$T/w$N.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$N.port")
  if [ -z "$PORT" ]; then wait "$WPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
    echo "setup: worker did not start: $(cat "$T/w$N.err")"; exit 1; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
}
# run <epoch> — one scheduler tick at that minute.
run() { LANE_WAKE_CALENDAR_NOW="$1" LANE_GATE_NOW="$1" "$H/$SCRIPT_REL" > "$T/run.out" 2>&1; RC=$?; }
rings() { sort "$S/rings" 2>/dev/null | tr '\n' ' '; }
nrings() { local c; c=$(grep -c . "$S/rings" 2>/dev/null); printf '%s' "${c:-0}"; }
ndd() { find "$S/dd" -type f 2>/dev/null | grep -c .; }
cnt() { local c; c=$(grep -cF -- "$1" "$H/logs/lane-wake-calendar.log" 2>/dev/null); printf '%s' "${c:-0}"; }
has_lane() { grep -q "^$1|" "$S/rings" 2>/dev/null && echo yes || echo no; }

C1_WANT="archie|fleet|cal:20261109t1100 orc-monitor|fleet|cal:20261109t1100 pm-groom|acme|cal:w2026-46 pm-groom|project-3|cal:w2026-46 "

echo "C1 Monday 10:59Z, lead 2"
fresh
run "$MON1059"
eq "C1 exit 0 ($(head -2 "$T/run.out"))" "$RC" 0
eq "C1 the rings" "$(rings)" "$C1_WANT"
eq "C1 four inserted=1 lines" "$(cnt ' inserted=1')" 4
eq "C1 the pm-groom line" "$(cnt 'lane-wake-calendar ring pm-groom project-3 cal:w2026-46 inserted=1')" 1

echo "C2 the same minute again adds 0 rows"
run "$MON1059"
eq "C2 exit 0" "$RC" 0
eq "C2 dedupe set unchanged" "$(ndd)" 4
eq "C2 four inserted=0 lines" "$(cnt ' inserted=0')" 4

echo "C3 a Tuesday: the weekly lanes do not ring"
fresh
run "$TUE1059"
eq "C3 no pm-groom" "$(has_lane pm-groom)" no
eq "C3 no rule-miner" "$(has_lane rule-miner)" no
eq "C3 no lookback" "$(has_lane lookback)" no
eq "C3 archie still rings for 11:00" "$(has_lane archie)" yes
fresh
run "$TUE1002"
eq "C3b a minute no calendar matches: no ring" "$(nrings)" 0
eq "C3b exit 0" "$RC" 0

echo "C4 the wake gate lib missing"
fresh real; rm -f "$H/bin/lib/lane-wake-gate.sh"
run "$MON1100"; R1=$RC
run "$MON1101"
eq "C4 exit 0 both" "$R1/$RC" 0/0
eq "C4 one off line (minute 00 only)" "$(cnt 'lane-wake-calendar off (no lane wake gate lib)')" 1
eq "C4 no ring" "$(nrings)" 0

echo "C5 mode off for archie"
fresh; echo off > "$S/mode.archie"
run "$MON1059"
eq "C5 archie not rung" "$(has_lane archie)" no
eq "C5 orc-monitor rung" "$(has_lane orc-monitor)" yes
eq "C5 pm-groom rung" "$(has_lane pm-groom)" yes

echo "C6 pm-groom has no registry file"
fresh; rm -f "$H/catalog/lane-wakes.d/pm-groom.json"
run "$MON1059"
eq "C6 pm-groom skipped" "$(has_lane pm-groom)" no
eq "C6 one skip line" "$(cnt 'lane-wake-calendar skip pm-groom (no catalog/lane-wakes.d/pm-groom.json)')" 1
eq "C6 archie rung" "$(has_lane archie)" yes

echo "C7 the cal_match table"
fresh
m() { "$H/$SCRIPT_REL" --match "$1" "$(at "$2")" >/dev/null 2>&1; echo $?; }
# match (rc 0)
eq "C7 */15 at :00"            "$(m '*/15 * * * *' 2026-11-10T13:00:00Z)" 0
eq "C7 */15 at :15"            "$(m '*/15 * * * *' 2026-11-10T13:15:00Z)" 0
eq "C7 */15 at :45"            "$(m '*/15 * * * *' 2026-11-10T13:45:00Z)" 0
eq "C7 7-57/10 at :07"         "$(m '7-57/10 * * * *' 2026-11-10T13:07:00Z)" 0
eq "C7 7-57/10 at :57"         "$(m '7-57/10 * * * *' 2026-11-10T13:57:00Z)" 0
eq "C7 51 * at 13:51"          "$(m '51 * * * *' 2026-11-10T13:51:00Z)" 0
eq "C7 1 11 * * 1 Mon 11:01"   "$(m '1 11 * * 1' 2026-11-09T11:01:00Z)" 0
eq "C7 OR rule: the 1st, not a Monday" "$(m '0 0 1 * 1' 2026-12-01T00:00:00Z)" 0
eq "C7 OR rule: a Monday, not the 1st" "$(m '0 0 1 * 1' 2026-11-09T00:00:00Z)" 0
eq "C7 dow 7 is Sunday"        "$(m '0 9 * * 7' 2026-11-08T09:00:00Z)" 0
eq "C7 a comma list"           "$(m '5,35 6 * * *' 2026-11-08T06:35:00Z)" 0
eq "C7 a month range"          "$(m '0 0 * 10-12 *' 2026-11-08T00:00:00Z)" 0
# near misses (rc 1)
eq "C7 */15 at :14"            "$(m '*/15 * * * *' 2026-11-10T13:14:00Z)" 1
eq "C7 7-57/10 at :08"         "$(m '7-57/10 * * * *' 2026-11-10T13:08:00Z)" 1
eq "C7 7-57/10 at :58"         "$(m '7-57/10 * * * *' 2026-11-10T13:58:00Z)" 1
eq "C7 51 * at 13:50"          "$(m '51 * * * *' 2026-11-10T13:50:00Z)" 1
eq "C7 1 11 * * 1 Tue 11:01"   "$(m '1 11 * * 1' 2026-11-10T11:01:00Z)" 1
eq "C7 1 11 * * 1 Mon 11:02"   "$(m '1 11 * * 1' 2026-11-09T11:02:00Z)" 1
eq "C7 1 11 * * 1 Mon 10:01"   "$(m '1 11 * * 1' 2026-11-09T10:01:00Z)" 1
eq "C7 OR rule: neither"       "$(m '0 0 1 * 1' 2026-11-10T00:00:00Z)" 1
eq "C7 a month out of range"   "$(m '0 0 * 1-6 *' 2026-11-08T00:00:00Z)" 1
# malformed (rc 2)
eq "C7 61 is malformed"        "$(m '61 * * * *' 2026-11-10T13:00:00Z)" 2
eq "C7 four fields"            "$(m '* * * *' 2026-11-10T13:00:00Z)" 2
eq "C7 */0"                    "$(m '*/0 * * * *' 2026-11-10T13:00:00Z)" 2
eq "C7 a letter"               "$(m 'a * * * *' 2026-11-10T13:00:00Z)" 2
eq "C7 a reversed range"       "$(m '30-10 * * * *' 2026-11-10T13:00:00Z)" 2
eq "C7 dom 0"                  "$(m '0 0 0 * *' 2026-11-10T13:00:00Z)" 2

echo "C8 a bad key format and a malformed expr"
fresh
printf '# fixture\n*/15 * * * *\tbad key %%H\n' > "$H/catalog/lane-calendar.d/archie.tsv"
printf '61 * * * *\t%%Y%%m%%dt%%H%%M\n*/5 * * * *\t%%Y%%m%%dt%%H%%M\n' > "$H/catalog/lane-calendar.d/orc-monitor.tsv"
run "$MON1059"
eq "C8 bad-key line" "$(cnt 'lane-wake-calendar bad-key archie')" 1
eq "C8 archie not rung" "$(has_lane archie)" no
eq "C8 bad-expr line" "$(cnt 'lane-wake-calendar bad-expr orc-monitor 61 * * * *')" 1
eq "C8 the next orc-monitor line still rings" "$(has_lane orc-monitor)" yes
eq "C8 exit 0" "$RC" 0

echo "C9 a ring that fails with mode on"
fresh; echo on > "$S/mode.archie"; echo archie > "$S/ringfail"; echo orc-monitor >> "$S/ringfail"
run "$MON1059"; R1=$RC
run "$MON1059"
eq "C9 exit 0 both" "$R1/$RC" 0/0
eq "C9 ring-failed lines (two runs)" "$(cnt 'lane-wake-calendar ring-failed archie fleet cal:20261109t1100')" 2
eq "C9 one ALERTS line for archie, none for the shadow lane" "$(grep -c . "$H/logs/ALERTS.log" 2>/dev/null)/$(grep -c 'archie' "$H/logs/ALERTS.log" 2>/dev/null)" 1/1
eq "C9 pm-groom still rung" "$(has_lane pm-groom)" yes

echo "C10 the shipped calendar and registry files"
fresh
LANES="claude-auth-check archie archie-fm-watch archie-research rule-miner lookback pm-groom orc-monitor"
for L in $LANES; do
  F="$DIR/catalog/lane-calendar.d/$L.tsv"
  [ -f "$F" ] && ok "C10 $L.tsv exists" || { bad "C10 $L.tsv missing"; continue; }
  [ -f "$DIR/catalog/lanes.d/$L.json" ] && ok "C10 $L is a lane id" || bad "C10 $L is not in catalog/lanes.d"
  n=0
  while IFS=$'\t' read -r ex fm rest; do
    case "$ex" in ''|'#'*) continue ;; esac
    n=$((n+1))
    rc=$(m "$ex" 2026-11-09T11:00:00Z)
    [ "$rc" != 2 ] && ok "C10 $L '$ex' parses" || bad "C10 $L '$ex' is malformed"
    [ -z "$rest" ] && [ -n "$fm" ] && ok "C10 $L two columns" || bad "C10 $L line is not <expr>\\t<fmt>"
    k="cal:$(date -u -d @"$MON1100" +"$fm" | tr '[:upper:]' '[:lower:]')"
    [[ $k =~ ^[a-z0-9:#@._-]{1,64}$ ]] && ok "C10 $L key $k" || bad "C10 $L key '$k' fails the dedupe charset"
  done < "$F"
  [ "$n" -ge 1 ] && ok "C10 $L has a line" || bad "C10 $L.tsv has no line"
done
for L in claude-auth-check archie archie-fm-watch archie-research rule-miner lookback orc-monitor; do
  eq "C10 lane-wakes.d/$L.json" "$(jq -c '[.lane, .scope, .kinds]' "$DIR/catalog/lane-wakes.d/$L.json" 2>/dev/null)" "[\"$L\",\"fleet\",[]]"
done
eq "C10 claude-auth-check carries the per-box hazard note" \
  "$(jq -r '.note // ""' "$DIR/catalog/lane-wakes.d/claude-auth-check.json" 2>/dev/null | grep -c 'every box')" 1
eq "C10 archie-research rings scan and digest" "$(grep -c . "$DIR/catalog/lane-calendar.d/archie-research.tsv" 2>/dev/null)" 2

echo "C11 the lead knob"
fresh
LANE_WAKE_CALENDAR_LEAD_MIN=0 run "$MON1100"
eq "C11 lead 0 rings 11:00 itself" "$(rings)" "archie|fleet|cal:20261109t1100 orc-monitor|fleet|cal:20261109t1100 "
fresh
LANE_WAKE_CALENDAR_LEAD_MIN=x run "$MON1059"
eq "C11 lead x falls to 2" "$(rings)" "$C1_WANT"
eq "C11 one line for it" "$(cnt "lane-wake-calendar LANE_WAKE_CALENDAR_LEAD_MIN='x' is not a whole number 0..4 — using 2")" 1

echo "C12 the cadence of the calendar lanes is unchanged"
cad() { jq -r .cadence "$DIR/catalog/lanes.d/$1.json"; }
eq "C12 claude-auth-check" "$(cad claude-auth-check)" '51 * * * *'
eq "C12 archie" "$(cad archie)" '*/15 * * * *'
eq "C12 archie-fm-watch" "$(cad archie-fm-watch)" '7-57/10 * * * *'
eq "C12 archie-research" "$(cad archie-research)" '40 6 * * *'
eq "C12 rule-miner" "$(cad rule-miner)" '30 5 * * 1'
eq "C12 lookback" "$(cad lookback)" '45 6 * * 1'
eq "C12 pm-groom" "$(cad pm-groom)" '1 11 * * 1; 2 11 * * 1; 4 11 * * 1; 5 11 * * 1; 6 11 * * 1; 8 11 * * 1; 9 11 * * 1'

echo "C13 the switch, the cron line, the knob"
fresh; touch "$H/flags/lane-off-lane-wake-calendar"
run "$MON1059"
eq "C13 switch off: exit 0, no ring" "$RC/$(nrings)" 0/0
F738="$DIR/cron/lanes/738-lane-wake-calendar.cron"
eq "C13 738 one active line, lease-gated under flock -n" \
  "$(grep -v '^#' "$F738" 2>/dev/null | grep -c .)/$(grep -cxF '* * * * * /root/harness/bin/hub-lease.sh check && flock -n /root/harness/locks/lane-wake-calendar.lock /root/harness/bin/lane-wake-calendar.sh >/dev/null 2>&1' "$F738" 2>/dev/null)" 1/1
eq "C13 738 is a hub lane" "$(grep -cx '# @hub-lanes' "$F738" 2>/dev/null)" 1
eq "C13 the lead knob, default 2" \
  "$(jq -c '[.lanes[] | select(.id=="lane-wake-calendar") | .knobs[] | select(.env=="LANE_WAKE_CALENDAR_LEAD_MIN") | .default]' "$LANE_REGISTRY")" '[2]'

echo "C-real the contract's lib over the real routes"
if [ -f "$DIR/bin/lib/lane-wake-gate.sh" ] && [ -f "$DIR/worker/jobs/src/routes/lane-wakes.js" ]; then
  fresh real
  ( cd "$DIR" && scratch_install_closure bin/lib/lane-wake-gate.sh "$H" && scratch_install_closure bin/pm-groom.sh "$H" ) >/dev/null 2>&1
  mkdir -p "$H/prompts/product-stages"; cp "$DIR/prompts/product-stages/pm-groom.md" "$H/prompts/product-stages/" 2>/dev/null
  cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s\n' '{"summary":"Nothing to move.","moves":[]}' > "$5"
SH
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/archie-tg-send.sh"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/alert-line.sh"
  chmod +x "$H/bin/"*.sh
  setting() { curl -s -X PUT "$JOBS_URL/__setting" -d "{\"key\":\"$1\",\"value\":\"$2\"}" >/dev/null; }
  lanerows() { curl -s "$JOBS_URL/__wakes?repo=harness/lanes" | jq -r .n; }
  setting lib.lane-wake-gate.mode_default shadow
  run "$MON1059"
  eq "C-real exit 0 ($(head -2 "$T/run.out"))" "$RC" 0
  eq "C-real one harness/lanes row per matching lane and scope" "$(lanerows)" 4
  eq "C-real the rows" "$(curl -s "$JOBS_URL/__wakes?repo=harness/lanes" | jq -r '[.rows[] | .key + "|" + .minute] | sort | join(" ")')" \
    "archie:fleet|lw:cal:20261109t1100 orc-monitor:fleet|lw:cal:20261109t1100 pm-groom:acme|lw:cal:w2026-46 pm-groom:project-3|lw:cal:w2026-46"
  run "$MON1059"
  eq "C-real a second run adds 0 rows" "$(lanerows)" 4
  run "$TUE1002"
  eq "C-real a non-matching minute adds 0 rows" "$(lanerows)" 4
  RID=$(curl -s "$JOBS_URL/__wakes?repo=harness/lanes" | jq -r '.rows[] | select(.key=="pm-groom:project-3") | .id')
  setting lib.lane-wake-gate.mode_pm_groom on
  LANE_SINGLE_RUN=1 LANE_GATE_NOW="$MON1101" PM_GROOM_NOW="$MON1101" bash "$H/bin/pm-groom.sh" project-3 > "$T/pm.out" 2>&1
  eq "C-real Monday 11:01Z: pm-groom takes the ring (lwg pm-groom project-3 run wake=$RID)" \
    "$(grep -c "lwg pm-groom project-3 run wake=$RID\$" "$H/logs/lane-wake-gate.log" 2>/dev/null)" 1
else
  echo "  SKIPPED: contract #9122 not in this tree (no bin/lib/lane-wake-gate.sh)"
fi

echo "C14 budget: 0 vendor calls"
eq "C14 net.log is empty ($(head -3 "$T/net.log"))" "$(grep -c . "$T/net.log")" 0

echo "lane-wake-calendar: $PASS passed, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
