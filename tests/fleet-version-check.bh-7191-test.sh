#!/bin/bash
# tests/fleet-version-check.bh-7191-test.sh — BH-7191 (tracer BH-7302): the hub
# lane bin/fleet-version-check.sh, its pure half bin/lib/fleet-version-decide.sh,
# the lag rule bin/lib/fleet-version-rules.d/20-lag.sh, the empty seams
# (10-role.sh, 30-beat.sh, 40-nosync.sh, bin/lib/fleet-version-sink.sh) and the
# settings seed worker/jobs/schema.d/202610171941-bh-7191-harness-version-settings.sql.
#
# The lane runs over real curl against the REAL jobs worker
# (tests/lib/fleet-version-worker.bh-7191.mjs, clock pinned to FVC_NOW), and a
# scratch bare origin whose first-parent main has merges at fixed committer
# dates, one of them docs-only:
#   C0    NOW-3d      bin/a           (base)
#   M40   NOW-40m     merge of a branch (bin/b) whose own commit B1 is NOW-3d+1h
#   M31   NOW-31m     bin/c
#   M30   NOW-30m     bin/d
#   MDOC  NOW-20m     docs/x only     (the tip)
#
#   L1-L5  fvc_main_log columns and F; fvc_lag_min tip/prefix/>=n/notmain/report time
#   D1-D13 fvc_decide on hand TSV rows (the lag rule's decide table)
#   M1     mutation: `>` -> `>=` in fvc_rule_lag turns the 30-min row red
#   S1-S3  FVC_RULES order and empty seams; decide makes no git/curl call; rc 2 stops
#   E1-E13 the lane end to end (siblings extend this file)
#
# Run from anywhere: tests/fleet-version-check.bh-7191-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/fleet-version-worker.bh-7191.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qE -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no /$3/ in [$2]"; fi; }
hasnt() { if grep -qE -- "$3" <<<"$2"; then bad "$1: unexpected /$3/ in [$2]"; else ok "$1"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v git >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or git missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/flags" "$H/catalog"
for L in bin/fleet-version-check.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
# A stub beat.sh records the payload alert-line.sh sends (its akey carries --id).
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beat.payloads"\nexit 0\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/"*.sh 2>/dev/null
[ -x "$H/bin/fleet-version-check.sh" ] && ok "closure installs bin/fleet-version-check.sh" || bad "closure lacks bin/fleet-version-check.sh"
[ -f "$H/bin/lib/fleet-version-rules.d/20-lag.sh" ] && ok "closure installs fleet-version-rules.d/" || bad "closure lacks fleet-version-rules.d/20-lag.sh"

NOW=1792000000   # 2026-10-14T06:13:20Z
export FVC_NOW=$NOW LANE_GATE_NOW=$NOW

# ── the scratch main ──────────────────────────────────────────────────────────
G="$T/work"; ORIGIN="$T/origin.git"; HCO="$T/hco"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$G"
gc() { local at=$1; shift; GIT_AUTHOR_DATE="@$at +0000" GIT_COMMITTER_DATE="@$at +0000" git -C "$G" "$@"; }
git -C "$G" config user.email fixture@example.invalid; git -C "$G" config user.name fixture
mkdir -p "$G/bin" "$G/docs"
echo a > "$G/bin/a"; git -C "$G" add -A; gc $((NOW - 259200)) commit -qm C0
git -C "$G" checkout -qb feat
echo b > "$G/bin/b"; git -C "$G" add -A; gc $((NOW - 259200 + 3600)) commit -qm B1
git -C "$G" checkout -q main
gc $((NOW - 2400)) merge -q --no-ff feat -m M40
echo c > "$G/bin/c"; git -C "$G" add -A; gc $((NOW - 1860)) commit -qm M31
echo d > "$G/bin/d"; git -C "$G" add -A; gc $((NOW - 1800)) commit -qm M30
echo x > "$G/docs/x"; git -C "$G" add -A; gc $((NOW - 1200)) commit -qm MDOC
git -C "$G" push -q "$ORIGIN" main
git clone -q "$ORIGIN" "$HCO"
sha() { git -C "$G" log --all --format='%H %s' | awk -v s="$1" '$2 == s { print $1; exit }'; }
C0=$(sha C0); B1=$(sha B1); M40=$(sha M40); M31=$(sha M31); M30=$(sha M30); MDOC=$(sha MDOC)
[ -n "$C0" ] && [ -n "$MDOC" ] && [ -n "$B1" ] && ok "scratch main built" || bad "scratch main not built"

# shellcheck source=bin/lib/fleet-version-decide.sh
. "$H/bin/lib/fleet-version-decide.sh" || { bad "decide lib did not load"; exit 1; }
unset FLEET_PATHS
# shellcheck source=bin/lib/fleet-paths.sh
. "$H/bin/lib/fleet-paths.sh" || bad "fleet-paths lib did not load"

echo "L: fvc_main_log / fvc_lag_min"
ML="$T/main.log"
fvc_main_log "$HCO" > "$ML"; rc=$?
eq "L1 fvc_main_log rc 0" "$rc" 0
eq "L1 first-parent lines, newest first" "$(awk '{print $1}' "$ML" | tr '\n' ' ')" "$MDOC $M30 $M31 $M40 $C0 "
eq "L1 commit epochs" "$(awk '{print $2}' "$ML" | tr '\n' ' ')" "$((NOW-1200)) $((NOW-1800)) $((NOW-1860)) $((NOW-2400)) $((NOW-259200)) "
eq "L1 F flag: the docs-only merge is 0, the rest 1" "$(awk '{print $3}' "$ML" | tr '\n' ' ')" "0 1 1 1 1 "
eq "L1b no FLEET_PATHS: every line F=1" "$(FLEET_PATHS='' fvc_main_log "$HCO" | awk '{print $3}' | tr '\n' ' ')" "1 1 1 1 1 "
eq "L1c an empty checkout is rc 1" "$(fvc_main_log "$T/nowhere" >/dev/null 2>&1; echo $?)" 1
eq "L2 the tip is 0" "$(fvc_lag_min "$MDOC" "$ML")" 0
eq "L2 behind only on the docs-only merge is 0" "$(fvc_lag_min "$M30" "$ML")" 0
eq "L2 C0 lags 40 (oldest missing fleet commit M40)" "$(fvc_lag_min "$C0" "$ML")" 40
eq "L2 a 7-char prefix of C0 matches" "$(fvc_lag_min "${C0:0:7}" "$ML")" 40
eq "L2 an upper-case sha matches" "$(fvc_lag_min "$(tr a-f A-F <<<"$M40")" "$ML")" 31
eq "L2 M31 lags 30" "$(fvc_lag_min "$M31" "$ML")" 30
fvc_main_log "$HCO" 3 > "$T/main3.log"
eq "L3 a sha older than the fetched window is >=n" "$(FVC_CHECKOUT="$HCO" fvc_lag_min "$C0" "$T/main3.log")" ">=31"
eq "L3 a non-first-parent commit main contains is >=n, never 0" "$(FVC_CHECKOUT="$HCO" fvc_lag_min "$B1" "$ML")" ">=4320"
eq "L3 without FVC_CHECKOUT it is notmain" "$(fvc_lag_min "$C0" "$T/main3.log")" notmain
eq "L4 an unknown sha is notmain" "$(FVC_CHECKOUT="$HCO" fvc_lag_min deadbeefdeadbeef "$ML")" notmain
eq "L4 a non-hex sha is notmain" "$(fvc_lag_min 'zz12345' "$ML")" notmain
eq "L4 a 6-char sha is notmain" "$(fvc_lag_min "${C0:0:6}" "$ML")" notmain
eq "L5 a merge newer than the report does not count (as_of before M40)" "$(fvc_lag_min "$C0" "$ML" $((NOW - 2500)))" 0
eq "L5 as_of between M40 and M31: lag from M40" "$(fvc_lag_min "$C0" "$ML" $((NOW - 1900)))" 8

echo "D: fvc_decide"
R=$((NOW - 60))
row() { printf '%s\tbuild\t%s\t%s\t%s\t\t\t\n' "$@"; }
dec() { FVC_MAX_LAG_MIN="${MAXL:-30}" fvc_decide; }
eq "D1 lag 40 alerts" "$(row b1 "$C0" "$R" 40 | dec)" "ALERT b1 lag lag=40m sha=${C0:0:8}"
eq "D2 lag 30 is OK" "$(row b2 "$M31" "$R" 30 | dec)" "OK b2 lag=30m"
eq "D3 lag 31 alerts" "$(row b3 "$M40" "$R" 31 | dec)" "ALERT b3 lag lag=31m sha=${M40:0:8}"
TIPOLD="$T/tipold.log"; printf '%s %s 1\n' "$C0" $((NOW - 259200)) > "$TIPOLD"
eq "D4 sha == tip with a 3-day-old tip is OK" "$(row b4 "$C0" "$R" "$(fvc_lag_min "$C0" "$TIPOLD")" | dec)" "OK b4 lag=0m"
eq "D5 notmain alerts" "$(row b5 deadbeefcafe "$R" notmain | dec)" "ALERT b5 lag sha not on main sha=deadbeef"
eq "D6 no sha alerts nosha" "$(row b6 "" "$R" "" | dec)" "ALERT b6 nosha no sha reported"
eq "D7 a report 91 min old is stale" "$(row b7 "$MDOC" $((NOW - 91*60 - 1)) 0 | dec)" \
  "ALERT b7 nosha report stale ($(date -u -d "@$((NOW - 91*60 - 1))" +%Y-%m-%dT%H:%M:%SZ))"
eq "D7b a report exactly 90 min old is not stale" "$(row b7 "$MDOC" $((NOW - 90*60)) 0 | dec)" "OK b7 lag=0m"
eq "D7c no report time is stale (never)" "$(row b7 "$MDOC" "" 0 | dec)" "ALERT b7 nosha report stale (never)"
eq "D8 >=n alerts" "$(row b8 "$C0" "$R" '>=500' | dec)" "ALERT b8 lag lag>=500m sha=${C0:0:8}"
eq "D9 behind only on docs (lag 0) is OK" "$(row b9 "$M30" "$R" "$(fvc_lag_min "$M30" "$ML")" | dec)" "OK b9 lag=0m"
eq "D10 a merge after the report is OK" "$(row b10 "$C0" $((NOW - 2500)) "$(fvc_lag_min "$C0" "$ML" $((NOW - 2500)))" | dec)" "OK b10 lag=0m"
OUT=$(printf '%s\n%s\n' "$(row b11 "$M40" "$R" 31)" "$(row b12 "$M31" "$R" 30)" | MAXL=abc dec)
has "D11 threshold abc prints a WARN" "$OUT" '^WARN FVC_MAX_LAG_MIN=abc is not a whole number; using 30$'
has "D11 and uses 30: 31 alerts" "$OUT" '^ALERT b11 lag lag=31m'
has "D11 and uses 30: 30 is OK" "$OUT" '^OK b12 lag=30m$'
eq "D12 a 45 threshold: lag 40 is OK" "$(row b1 "$C0" "$R" 40 | MAXL=45 dec)" "OK b1 lag=40m"
eq "D13 an unreadable lag alerts, never OK" "$(row b13 "$C0" "$R" 'x9' | dec)" "ALERT b13 lag lag unreadable (x9) sha=${C0:0:8}"

echo "M: mutation"
( cd "$REPO" && scratch_install_closure bin/fleet-version-check.sh "$T/mut" ) >/dev/null 2>&1 || bad "setup: could not install the mutation tree"
MUT="$T/mut/bin/lib/fleet-version-rules.d"
sed -i 's/n > max/n >= max/' "$MUT/20-lag.sh"
if grep -q 'n >= max' "$MUT/20-lag.sh"; then ok "M1 the mutation applied"; else bad "M1 the mutation did not apply"; fi
eq "M1 with >= the 30-min row goes red (ALERT)" "$(row b2 "$M31" "$R" 30 | FVC_RULES_DIR="$MUT" dec)" "ALERT b2 lag lag=30m sha=${M31:0:8}"
eq "M1 the real rule keeps it OK" "$(row b2 "$M31" "$R" 30 | dec)" "OK b2 lag=30m"

echo "S: seams"
for f in "$REPO/bin/lib/fleet-version-rules.d/10-role.sh" "$REPO/bin/lib/fleet-version-rules.d/20-lag.sh" \
         "$REPO/bin/lib/fleet-version-rules.d/30-beat.sh" "$REPO/bin/lib/fleet-version-rules.d/40-nosync.sh"; do
  cmp -s "$f" "$H/bin/lib/fleet-version-rules.d/${f##*/}" && ok "S0 ${f##*/} is installed as shipped" || bad "S0 ${f##*/} not installed"
done
fvc_decide </dev/null >/dev/null
eq "S1 FVC_RULES order" "${FVC_RULES[*]}" "fvc_rule_role fvc_rule_lag fvc_rule_beat fvc_rule_nosync"
for s in 10-role:fvc_rule_role 30-beat:fvc_rule_beat 40-nosync:fvc_rule_nosync; do
  o=$( FVC_RULES=(); . "$H/bin/lib/fleet-version-rules.d/${s%%:*}.sh"; FVC_BOX=x "${s##*:}"; echo "rc=$?" )
  eq "S1 ${s##*:} alone prints nothing, rc 0" "$o" "rc=0"
done
o=$( . "$H/bin/lib/fleet-version-sink.sh"; echo "ALERT x lag lag=40m" | fvc_sink; echo "rc=$?" )
eq "S1 fvc_sink prints nothing, rc 0" "$o" "rc=0"
STUB="$T/stub"; mkdir -p "$STUB"
for c in git curl; do printf '#!/bin/sh\necho "%s called" >> "%s/called"\nexit 99\n' "$c" "$T" > "$STUB/$c"; chmod +x "$STUB/$c"; done
rm -f "$T/called"
OUT=$(printf 'b20\tbuild\t%s\t%s\t40\t\t\t\nb21\t\t%s\t%s\t0\t\t\t\nb22\tbuild\t\t\t\t\t\t\n' "$C0" "$R" "$MDOC" "$R" | PATH="$STUB:$PATH" dec)
eq "S2 decide makes no git or curl call" "$(cat "$T/called" 2>/dev/null)" ""
eq "S2 every line parses back to word, box and kind" \
  "$(awk '{ print $1, $2, ($1 == "OK" ? "-" : $3) }' <<<"$OUT" | tr '\n' ';')" "ALERT b20 lag;OK b21 -;ALERT b22 nosha;"

( cd "$REPO" && scratch_install_closure bin/fleet-version-check.sh "$T/stop" ) >/dev/null 2>&1 || bad "setup: could not install the stop-rule tree"
STOPR="$T/stop/bin/lib/fleet-version-rules.d"
printf 'FVC_RULES+=(fvc_rule_stop)\nfvc_rule_stop() { echo "SKIP $FVC_BOX role=$FVC_ROLE"; return 2; }\n' > "$STOPR/15-stop.sh"
eq "S3 a rule that returns 2 stops the later rules for that box" \
  "$(printf 'b30\tbuild\t%s\t%s\t40\t\t\t\n' "$C0" "$R" | FVC_RULES_DIR="$STOPR" dec)" "SKIP b30 role=build"

echo "E: the lane"
PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub JOBS_BOX=fixture-hub
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 HARNESS_CHECKOUT="$HCO"
unset HARNESS_VERSION_MAX_LAG_MIN HARNESS_VERSION_MAX_BEAT_GAP_MIN
fresh() {
  local n=$((${#PIDS[@]} + 1)) i pid
  : > "$T/w$n.log"; : > "$T/w$n.port"
  node "$SRV" "$T/w$n.log" "$NOW" > "$T/w$n.port" 2> "$T/w$n.err" &
  pid=$!; PIDS+=("$pid"); WPID=$pid
  for i in $(seq 1 200); do [ -s "$T/w$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$n.port")
  [ -n "$PORT" ] || { echo "SKIP: the fixture worker did not start ($(head -3 "$T/w$n.err"))"; exit 0; }
  export JOBS_URL="http://127.0.0.1:$PORT"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/fleet-version-check.log"
  scratch_rm "$H/state/fleet-version-check"; scratch_rm "$H/flags"; mkdir -p "$H/flags"
}
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
reg() {
  sql "INSERT INTO registry_boxes (box, box_id, updated_at) VALUES (?,?,'2026-10-14T00:00:00Z')" "$1" "$2" \
    | jq -e '.rows' >/dev/null 2>&1 || bad "setup: registry_boxes row $1 not written"
}
status() {
  sql "INSERT INTO box_status (box, harness_commit, harness_reported_at, updated_at) VALUES (?,?,?,?) ON CONFLICT(box) DO UPDATE SET harness_commit=excluded.harness_commit, harness_reported_at=excluded.harness_reported_at" "$1" "$2" "$3" "$3" \
    | jq -e '.rows' >/dev/null 2>&1 || bad "setup: box_status row $1 not written"
}
tick() { "$H/bin/fleet-version-check.sh" > "$T/tick.out" 2>&1; echo $?; }
alerts() { grep -c . "$H/logs/ALERTS.log" 2>/dev/null || true; }
# The lane-gate liveness post adds a box_status row for this box (fixture-hub);
# it is not in the registry, so it is a SKIP line, never an alert.
seed() {
  reg box-stale stale; reg box-current current; reg box-gen gen; reg box-norow norow
  status box-stale "$C0" "$(iso "$NOW")"
  status box-current "$MDOC" "$(iso "$NOW")"
  status box-gen-2 "$MDOC" "$(iso "$NOW")"
  status box-gen "$C0" "$(iso $((NOW - 7200)))"
  status pool-x "$MDOC" "$(iso $((NOW - 60)))"
}

fresh; seed
eq "E1 the lane exits 0" "$(tick)" 0
A=$(cat "$H/logs/ALERTS.log"); LG=$(cat "$H/logs/fleet-version-check.log")
eq "E1 exactly one ALERTS line" "$(alerts)" 1
has "E1 it names the stale box and lag=40m" "$A" "fleet-version box-stale lag lag=40m sha=${C0:0:8} \\(reported $(iso "$NOW"), main ${MDOC:0:8}\\)"
hasnt "E1 no line names box-current" "$A" "box-current"
has "E1 box-current is OK in the log" "$LG" "OK box-current lag=0m"
has "E1 the -2 generation row answers for box-gen (newest report)" "$LG" "OK box-gen lag=0m"
hasnt "E1 the older generation row is not 'not in registry'" "$LG" "SKIP box-gen not in registry"
has "E1 a registry box with no row is SKIP" "$LG" "SKIP box-norow no box_status row"
[ -e "$H/state/fleet-version-check/open/lag.box-stale" ] && ok "E1 the open marker is written" || bad "E1 no open marker"
eq "E1 alert-line got --id fleet-version:lag:box-stale (akey folded as alert-line folds it)" "$(jq -r 'select(.line | test("fleet-version box-stale lag")) | .akey' "$T/beat.payloads" 2>/dev/null)" "alert:fleet-version_lag_box-stale"
has "E5 a box_status row not in the registry is SKIP" "$LG" "SKIP pool-x not in registry"

eq "E2 a second tick exits 0" "$(tick)" 0
eq "E2 the second tick adds no ALERTS line" "$(alerts)" 1
has "E2 the log says still open" "$(cat "$H/logs/fleet-version-check.log")" "still open: ALERT box-stale lag lag=40m"

eq "E3 the lane writes no flag" "$(find "$H/flags" -type f -name 'lane-off-*' -o -type f -name '*pause*' | wc -l | tr -d ' ')" 0
eq "E3 no pause_flags row" "$(sql "SELECT COUNT(*) AS n FROM pause_flags" | jq -r '.rows[0].n')" 0

status box-stale "$MDOC" "$(iso $((NOW - 30)))"
tick >/dev/null
has "E6 a box back at the tip clears its marker" "$(cat "$H/logs/fleet-version-check.log")" "cleared lag box-stale"
[ -e "$H/state/fleet-version-check/open/lag.box-stale" ] && bad "E6 the marker is still there" || ok "E6 the marker is gone"
eq "E6 clearing adds no ALERTS line" "$(alerts)" 1
status box-stale "$C0" "$(iso $((NOW - 20)))"
tick >/dev/null
eq "E6 a regress alerts once more" "$(alerts)" 2

echo "E7: no settings rows -> 30/30"
fresh
sql "DELETE FROM settings WHERE key LIKE 'harness_version.%'" >/dev/null
reg box-31 b31; reg box-30 b30
status box-31 "$M40" "$(iso "$NOW")"; status box-30 "$M31" "$(iso "$NOW")"
eq "E7 exit 0" "$(tick)" 0
eq "E7 one ALERTS line" "$(alerts)" 1
has "E7 the 31-min box alerts" "$(cat "$H/logs/ALERTS.log")" "fleet-version box-31 lag lag=31m"
has "E7 the 30-min box is OK" "$(cat "$H/logs/fleet-version-check.log")" "OK box-30 lag=30m"

echo "E13: the lag is measured at the report time"
fresh
reg box-early early
status box-early "$C0" "$(iso $((NOW - 1500)))"
tick >/dev/null
eq "E13 a C0 report 25 min old: no ALERTS line" "$(alerts)" 0
has "E13 lag 15 as of the report (40 as of now)" "$(cat "$H/logs/fleet-version-check.log")" "OK box-early lag=15m"

echo "E8-E12: the settings row, the env, suppression, the lock, the gate"
fresh; seed
sql "UPDATE settings SET value='45' WHERE key='harness_version.max_lag_min'" >/dev/null
tick >/dev/null
eq "E8a the settings row (45) moves the threshold: no alert" "$(alerts)" 0
has "E8a box-stale is OK under 45" "$(cat "$H/logs/fleet-version-check.log")" "OK box-stale lag=40m"
HARNESS_VERSION_MAX_LAG_MIN=35 tick >/dev/null
eq "E8b the env value (35) wins over the row" "$(alerts)" 1
fresh; seed
touch -d "@$((NOW - 600))" "$H/flags/orchestrator-sync-in-progress"
eq "E9 exit 0 under a fresh orchestrator sync" "$(tick)" 0
eq "E9 a fresh orchestrator sync sends no ALERTS line" "$(alerts)" 0
has "E9 it logs suppressed" "$(cat "$H/logs/fleet-version-check.log")" "suppressed \\(orchestrator sync in progress\\): ALERT box-stale lag"
touch -d "@$((NOW - 2800))" "$H/flags/orchestrator-sync-in-progress"
tick >/dev/null
eq "E9 an old orchestrator flag does not suppress" "$(alerts)" 1
rm -f "$H/flags/orchestrator-sync-in-progress"
fresh; seed
exec 7>"$H/locks/fleet-version-check.lock"; flock -n 7
eq "E10 a held lock: exit 0" "$(tick)" 0
eq "E10 a held lock: no ALERTS line" "$(alerts)" 0
has "E10 a held lock: skip line" "$(cat "$H/logs/fleet-version-check.log")" "skip: already running"
exec 7>&-
touch "$H/flags/lane-off-fleet-version-check"
eq "E11 gate off: exit 0" "$(tick)" 0
eq "E11 gate off: no ALERTS line" "$(alerts)" 0
hasnt "E11 gate off: no decide line" "$(cat "$H/logs/fleet-version-check.log")" "ALERT|OK |SKIP"
rm -f "$H/flags/lane-off-fleet-version-check"
HARNESS_CHECKOUT="$T/nowhere" tick >/dev/null
eq "E12 main unreadable: no ALERTS line" "$(alerts)" 0
eq "E12 main unreadable: one log line" "$(grep -c 'fleet-version-check: main unreadable' "$H/logs/fleet-version-check.log")" 1

echo "E4: worker down"
: > "$H/logs/ALERTS.log"; : > "$H/logs/fleet-version-check.log"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
eq "E4 worker down: exit 0" "$(tick)" 0
eq "E4 worker down: one registry unreadable line" "$(grep -c '^[^ ]* fleet-version-check: registry unreadable (registry,boxes)$' "$H/logs/fleet-version-check.log")" 1
eq "E4 worker down: no fleet-version ALERTS line" "$(grep -c 'fleet-version' "$H/logs/ALERTS.log")" 0
hasnt "E4 worker down: no per-box line" "$(cat "$H/logs/fleet-version-check.log")" "ALERT|OK |SKIP"

echo
echo "fleet-version-check.bh-7191: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
