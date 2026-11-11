#!/bin/bash
# tests/staff-clerk-lever.bh-9420-test.sh — BH-9420 (C2 of #9187): the clerk
# staff agent owns the NEEDS count and pulls the #9117 NEEDS sweep as its one
# lever. bin/staff/clerk-lever.sh is driven over real curl against one local
# server (tests/lib/needs-sweep-world.bh-9117.mjs, unchanged) that hosts the
# REAL Pages function console-ui/functions/api/needs-sweep/[[path]].js (with
# the new GET /count) on a seeded console D1, and the REAL jobs worker (the C0
# lever routes, the settings rows of this PR's seed, the ledger). No call
# leaves the box: the clerk makes no GitHub call, and the C11 sweep run reads
# no GitHub (aged rows only).
#
#   C0  sources, the cron line, the lane row
#   U1  the action-answer decision (CLERK_LIB_ONLY=1); the sweep tag check
#       (NS_LIB_ONLY=1 ns_tag_ok)
#   C1  level act, NEEDS 900, dry row 1: one action (dry), one sample, one
#       sweep call with --dry-run and NS_TAG=clerk:<12 hex>
#   C2  the same window again: window-taken, no second sweep, a second sample
#   C3  level observe / no row / `act;rm`: a sample, no action, no sweep
#   C4  level file: no action, no sweep
#   C5  target 300: 299 no action; 300 and 301 one action each
#   C6  dry row 0: the sweep runs without --dry-run; a sample 25 h later
#       settles the action (moved=1, scorecard precision 1)
#   C7  NEEDS unreadable (dead port, a 404 path, a 502): no sample, no action
#   C8  a conflicting row for the window key: the real route answers 409,
#       window-taken, no sweep
#   C9  kill flags, STAFF_ENABLED=0 and the lane-off flag: no request
#   C10 the sweep exits 3: the action stays, sweep_rc=3, the clerk exits 0
#   C11 the REAL bin/needs-sweep.sh applies: /count drops by 3 and the
#       needs_sweep ledger row ends with tag=clerk:<12 hex>
#   C12 staff.clerk.lever_every_hours: 1 = two windows in 61 min; abc/0 = 6
#
# Run from anywhere: tests/staff-clerk-lever.bh-9420-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The jobs worker imports the git-ignored catalogs (BH-6452, BH-6540).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/needs-sweep-world.bh-9117.mjs"
CLERK_REL=bin/staff/clerk-lever.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2' want '$3'"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v sha256sum >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or sha256sum missing"; exit 0; }

# --- C0 sources -----------------------------------------------------------------
for f in "$DIR/$CLERK_REL" "$DIR/bin/needs-sweep.sh" "$DIR/console-ui/functions/_lib/needs-count.js" \
         "$DIR/console-ui/functions/api/needs-sweep/[[path]].js" "$DIR/catalog/lanes.d/staff-clerk-lever.json" \
         "$DIR/cron/lanes/780-staff-clerk-lever.cron" "$DIR/console-ui/tests/needs-sweep-count.bh-9420.test.js"; do
  [ -s "$f" ] && ok "C0 source exists: ${f#"$DIR"/}" || bad "C0 missing source ${f#"$DIR"/}"
done
ls "$DIR"/worker/jobs/schema.d/*-bh-9420-clerk-lever.sql >/dev/null 2>&1 && ok "C0 settings seed fragment" || bad "C0 no schema.d/*-bh-9420-clerk-lever.sql"
grep -q '^47 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/staff/clerk-lever.sh ' \
  "$DIR/cron/lanes/780-staff-clerk-lever.cron" 2>/dev/null && ok "C0 cron: hourly :47 behind the hub lease" || bad "C0 cron line"
eq "C0 lane row" "$(jq -r '.script + " " + .switch.name + " " + .scope' "$DIR/catalog/lanes.d/staff-clerk-lever.json" 2>/dev/null)" \
  "bin/staff/clerk-lever.sh lane-off-staff-clerk-lever hub"

# --- U1 the action answer, and the sweep tag --------------------------------------
(
  CLERK_LIB_ONLY=1 . "$DIR/$CLERK_REL" || { echo "  FAIL U1 source"; exit 1; }
  f=0
  chk() { local b="$T/u1.json"; printf '%s' "$2" > "$b"
          local got; got=$(clerk_action_verdict "$1" "$b" "$3")
          [ "$got" = "$4" ] && echo "  ok   U1 $5" || { echo "  FAIL U1 $5: got '$got' want '$4'"; f=1; }; }
  chk 200 '{"ok":true,"action":{"action_key":"ab"}}' 0 run "a new row is run"
  chk 200 '{"ok":true,"existing":true,"action":{}}' 0 window-taken "existing is window-taken"
  chk 409 '{"error":"key_mismatch","action":{}}' 9 window-taken "409 is window-taken"
  chk "" '' 1 failed "rc 1, empty body is failed"
  chk 500 '{"error":"x"}' 1 failed "500 is failed"
  chk 200 '{"ok":false}' 0 failed "ok:false is failed"
  chk 200 'not json' 0 failed "a non-JSON 200 is failed"
  chk 404 '' 2 failed "404 (not on roster) is failed"
  exit "$f"
) && ok "U1 action verdicts" || bad "U1 action verdicts"
(
  NS_LIB_ONLY=1 . "$DIR/bin/needs-sweep.sh" || { echo "  FAIL U1 needs-sweep source"; exit 1; }
  f=0
  ns_tag_ok clerk:abc123def456 && echo "  ok   U1 tag clerk:abc123def456 kept" || { echo "  FAIL U1 good tag dropped"; f=1; }
  for b in 'a b' '$(x)' "$(printf 'a%.0s' $(seq 1 65))" '' 'Clerk:x' ';rm'; do
    ns_tag_ok "$b" && { echo "  FAIL U1 bad tag kept: '$b'"; f=1; } || echo "  ok   U1 tag dropped: '${b:0:20}'"
  done
  exit "$f"
) && ok "U1 tag check" || bad "U1 tag check"

# --- the scratch harness --------------------------------------------------------
H="$T/h"
mkdir -p "$H/bin/staff" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in "$CLERK_REL" bin/jobs-client.sh bin/lib/staff-contract.sh bin/lib/console-pages.sh bin/lib/lane-gate.sh \
         bin/needs-sweep.sh bin/builds-merged-sweep.sh bin/alert-line.sh bin/fleet-conf.sh bin/lib/tracker.sh \
         bin/lib/tracker/github-issues.sh bin/lib/tracker/board.sh bin/lib/gh-rest.sh bin/lib/mc/settle.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh "$H/bin/staff/"*.sh 2>/dev/null
cp "$H/bin/needs-sweep.sh" "$T/needs-sweep.real.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf 'demo-board o/board https://board.example /api/board 2 hub\n' > "$H/fleet.conf"
# The sweep stub (C1-C10, C12): one line per call, argv and NS_TAG; exit STUB_RC.
stub_sweep() {
  cat > "$H/bin/needs-sweep.sh" <<EOF
#!/bin/bash
printf 'args=[%s] tag=%s\n' "\$*" "\${NS_TAG:-}" >> "$T/sweep-calls.txt"
echo "mode=stub candidates=0 would=0"
exit \${STUB_RC:-0}
EOF
  chmod +x "$H/bin/needs-sweep.sh"
}
stub_sweep

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_TEST_SANDBOX=1
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 BOX_NAME=hub
export LANE_GATE_DISABLE=1 GH_ETAG=0
unset CONSOLE_URL STAFF_ENABLED NS_TAG NS_NOW CLERK_LIB_ONLY

# The console tables needCounts reads that the world does not create.
SEED="$T/seed.sql"
cat > "$SEED" <<'EOF'
CREATE TABLE IF NOT EXISTS alerts (id INTEGER PRIMARY KEY, akey TEXT, ts TEXT, project TEXT, line TEXT, resolved INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS proposals (pkey TEXT PRIMARY KEY, project TEXT, slug TEXT, title TEXT, summary TEXT, score INTEGER, status TEXT, updated_at TEXT);
EOF

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all; __scratch_exit_trap' EXIT
: > "$T/w.log"; : > "$T/w.port"; : > "$T/w.bodies"
node "$SRV" "$T/w.log" "$SEED" "$T/w.bodies" > "$T/w.port" 2> "$T/w.err" &
SPID=$!; PIDS+=("$SPID")
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: server did not start: $(cat "$T/w.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT" CONSOLE_PAGES_URL="http://127.0.0.1:$PORT"

jsql() { curl -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
jget() { curl -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
csql() { curl -sS -X POST "$JOBS_URL/__csql" --data-binary "$1" >/dev/null; }
setk() { jsql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('$1','$2','t','test','2026-11-10T00:00:00Z')"; }
delk() { jsql "DELETE FROM settings WHERE key='$1'"; }
# cseed <alerts> [aged builds] — the console NEEDS state: <alerts> unresolved
# alerts and <aged> parked build rows from 2026-01-01 (each its own ticket).
cseed() {
  csql "DELETE FROM alerts; DELETE FROM builds; DELETE FROM commands; DELETE FROM proposals;
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < $1)
      INSERT INTO alerts (id, akey, project, line, resolved) SELECT i, 'a' || i, 'demo-board', 'x', 0 FROM n WHERE $1 > 0;"
  local i
  for i in $(seq 1 "${2:-0}"); do
    csql "INSERT INTO builds (id,bkey,project,ticket_key,stage,pr_url,merged,updated_at)
      VALUES ($i,'k$i','demo-board','TK-$i','plan_blocked','',0,'2026-01-01T00:00:00Z')"
  done
}
count_total() { curl -sS -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_PAGES_URL/api/needs-sweep/count" | jq -r '.needs.total'; }
# RESET: no clerk rows, the seed's clerk settings, a clean log and stub file.
RESET() {
  jsql "DELETE FROM staff_lever_actions WHERE agent='clerk'; DELETE FROM staff_metric_samples WHERE agent='clerk'"
  setk staff.clerk.level observe; setk staff.clerk.target 300; delk staff.clerk.lever_every_hours
  setk staff.clerk.lever_every_hours 6; setk console.needs.sweep_dry_run 1
  rm -f "$H"/flags/* 2>/dev/null
  : > "$H/logs/staff-clerk-lever.log"; : > "$H/logs/ALERTS.log"; : > "$T/sweep-calls.txt"; : > "$T/w.log"
  stub_sweep
}
run() { CLERK_NOW="$1" "$H/$CLERK_REL" > "$T/run.out" 2>&1; RC=$?; }
last() { tail -1 "$H/logs/staff-clerk-lever.log"; }
nactions() { grep -c '^POST /api/staff/levers/actions ' "$T/w.log"; }
nsamples() { grep -c '^POST /api/staff/levers/metric ' "$T/w.log"; }
nsweeps() { grep -c . "$T/sweep-calls.txt"; }
rows() { jget "SELECT dry_run, metric_before, lever, target, detail, metric_after, moved, settled_at FROM staff_lever_actions WHERE agent='clerk' ORDER BY id"; }
samples() { jget "SELECT value, detail FROM staff_metric_samples WHERE agent='clerk' ORDER BY id"; }
iso() { date -u -d "@$1" +%FT%TZ; }
# 2026-11-10T00:30:00Z: inside the 00:00 window for W=6 and for W=1.
NOW0=$(date -u -d 2026-11-10T00:30:00Z +%s)
DAY=86400

eq "seed: staff.clerk.level is observe" "$(jget "SELECT value FROM settings WHERE key='staff.clerk.level'" | jq -r '.[0].value')" observe
eq "seed: staff.clerk.lever_every_hours is 6" "$(jget "SELECT value FROM settings WHERE key='staff.clerk.lever_every_hours'" | jq -r '.[0].value')" 6

# --- C1 act, NEEDS 900, dry row 1 -----------------------------------------------
RESET; cseed 900; setk staff.clerk.level act
run "$NOW0"
eq "C1 rc" "$RC" 0
eq "C1 one action POST" "$(nactions)" 1
eq "C1 one sample POST" "$(nsamples)" 1
R=$(rows)
eq "C1 one row" "$(jq length <<<"$R")" 1
eq "C1 row dry_run/metric_before/lever/target" "$(jq -r '.[0] | "\(.dry_run) \(.metric_before) \(.lever) \(.target)"' <<<"$R")" "1 900 needs-sweep console NEEDS"
eq "C1 row detail names the window" "$(jq -r '.[0].detail' <<<"$R")" "needs-sweep dry window $(iso "$NOW0" | sed 's/T00:30:00Z/T00:00:00Z/')"
eq "C1 sample value" "$(samples | jq -r '.[0].value')" 900
eq "C1 sample detail" "$(samples | jq -r '.[0].detail')" "alerts=900 builds=0 commands=0 proposals=0"
eq "C1 one sweep call" "$(nsweeps)" 1
grep -qE '^args=\[--dry-run\] tag=clerk:[0-9a-f]{12}$' "$T/sweep-calls.txt" && ok "C1 sweep --dry-run with NS_TAG=clerk:<12 hex>" || bad "C1 sweep call: $(cat "$T/sweep-calls.txt")"
AK=$(jget "SELECT action_key FROM staff_lever_actions WHERE agent='clerk'" | jq -r '.[0].action_key')
grep -qF "tag=clerk:${AK:0:12}" "$T/sweep-calls.txt" && ok "C1 the tag is the action key" || bad "C1 tag vs action key $AK"
grep -qE ' level=act needs=900 target=300 sample=ok action=recorded dry=1 sweep_rc=0 sweep=mode=stub ' <<<"$(last)" && ok "C1 summary line" || bad "C1 summary: $(last)"

# --- C2 the same window, again --------------------------------------------------
cseed 880; : > "$T/w.log"
run "$((NOW0 + 1200))"
eq "C2 rc" "$RC" 0
grep -q ' action=window-taken ' <<<"$(last)" && ok "C2 window-taken" || bad "C2 summary: $(last)"
eq "C2 still one sweep call" "$(nsweeps)" 1
eq "C2 still one action row" "$(rows | jq length)" 1
eq "C2 two samples" "$(samples | jq length)" 2

# --- C3 observe, no row, act;rm --------------------------------------------------
for lv in observe NOROW 'act;rm'; do
  RESET; cseed 900
  if [ "$lv" = NOROW ]; then delk staff.clerk.level; else setk staff.clerk.level "$lv"; fi
  run "$NOW0"
  eq "C3 [$lv] rc" "$RC" 0
  eq "C3 [$lv] 0 action POSTs" "$(nactions)" 0
  eq "C3 [$lv] 0 sweep calls" "$(nsweeps)" 0
  eq "C3 [$lv] 1 sample" "$(samples | jq length)" 1
  grep -q ' level=observe needs=900 .* action=none ' <<<"$(last)" && ok "C3 [$lv] summary" || bad "C3 [$lv] summary: $(last)"
done

# --- C4 file ---------------------------------------------------------------------
RESET; cseed 900; setk staff.clerk.level file; run "$NOW0"
eq "C4 0 action POSTs" "$(nactions)" 0
eq "C4 0 sweep calls" "$(nsweeps)" 0

# --- C5 the target boundary ------------------------------------------------------
for pair in 299:0 300:1 301:1; do
  n=${pair%%:*}; want=${pair#*:}
  RESET; cseed "$n"; setk staff.clerk.level act; run "$NOW0"
  eq "C5 NEEDS $n vs target 300: actions" "$(rows | jq length)" "$want"
  eq "C5 NEEDS $n vs target 300: sweeps" "$(nsweeps)" "$want"
done

# --- C6 apply mode, then the settle --------------------------------------------
RESET; cseed 900; setk staff.clerk.level act; setk console.needs.sweep_dry_run 0
run "$NOW0"
grep -qE '^args=\[\] tag=clerk:[0-9a-f]{12}$' "$T/sweep-calls.txt" && ok "C6 dry row 0: the sweep runs without --dry-run" || bad "C6 sweep call: $(cat "$T/sweep-calls.txt")"
eq "C6 row dry_run 0" "$(rows | jq -r '.[0].dry_run')" 0
grep -q ' action=recorded dry=0 ' <<<"$(last)" && ok "C6 summary dry=0" || bad "C6 summary: $(last)"
# The action ran 25 h ago, the NEEDS count fell to 400: the next sample settles it.
jsql "UPDATE staff_lever_actions SET acted_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-25 hours') WHERE agent='clerk'"
cseed 400
run "$((NOW0 + DAY + 3600))"
R=$(rows)
eq "C6 the first action settled: metric_after 400, moved 1" "$(jq -r '.[0] | "\(.metric_after) \(.moved)"' <<<"$R")" "400 1"
SC=$(curl -sS -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/staff/levers/scorecard?agent=clerk")
eq "C6 scorecard settled/moved/precision" "$(jq -r '"\(.settled) \(.moved) \(.precision)"' <<<"$SC")" "1 1 1"
eq "C6 scorecard metric_now" "$(jq -r '.metric_now.value' <<<"$SC")" 400

# --- C7 NEEDS unreadable ----------------------------------------------------------
RESET; cseed 900; setk staff.clerk.level act
for url in "http://127.0.0.1:9" "http://127.0.0.1:$PORT/no-such-prefix" BROKEN; do
  : > "$T/w.log"; : > "$H/logs/staff-clerk-lever.log"
  if [ "$url" = BROKEN ]; then
    csql "ALTER TABLE alerts RENAME TO alerts_off"   # needCounts throws: the route answers 502
    run "$NOW0"
    csql "ALTER TABLE alerts_off RENAME TO alerts"
    grep -q '^GET /api/needs-sweep/count 502' "$T/w.log" && ok "C7 [502] the route answered 502" || bad "C7 [502] log: $(cat "$T/w.log")"
  else
    CONSOLE_PAGES_URL="$url" run "$NOW0"
  fi
  eq "C7 [$url] rc" "$RC" 0
  eq "C7 [$url] 0 samples" "$(nsamples)" 0
  eq "C7 [$url] 0 actions" "$(nactions)" 0
  eq "C7 [$url] 0 sweep calls" "$(nsweeps)" 0
  grep -q ' needs=unreadable ' <<<"$(last)" && ok "C7 [$url] needs=unreadable" || bad "C7 [$url] summary: $(last)"
done

# --- C8 a conflicting row for the window key -------------------------------------
RESET; cseed 900; setk staff.clerk.level act
WS=$(iso "$((NOW0 - NOW0 % (6 * 3600)))")
KEY=$(printf '%s' "clerk|needs-sweep|needs-sweep:$WS" | sha256sum | cut -d' ' -f1)
jsql "INSERT INTO staff_lever_actions (action_key, agent, lever, target, dry_run, metric, metric_before, acted_at)
  VALUES ('$KEY','clerk','needs-sweep','console NEEDS',0,'needs_count',900,'2026-11-10T00:01:00Z')"
run "$NOW0"
grep -q '^POST /api/staff/levers/actions 409' "$T/w.log" && ok "C8 the real route answered 409" || bad "C8 log: $(grep actions "$T/w.log")"
grep -q ' action=window-taken ' <<<"$(last)" && ok "C8 window-taken" || bad "C8 summary: $(last)"
eq "C8 0 sweep calls" "$(nsweeps)" 0

# --- C9 the kill switches ---------------------------------------------------------
for k in flag:staff-off-clerk flag:staff-kill-clerk flag:staff-off-all flag:staff-kill-all env:STAFF_ENABLED=0 lane:lane-off-staff-clerk-lever; do
  RESET; cseed 900; setk staff.clerk.level act; : > "$T/w.log"
  case "$k" in
    flag:*) : > "$H/flags/${k#flag:}"; run "$NOW0" ;;
    env:*) STAFF_ENABLED=0 run "$NOW0" ;;
    lane:*) : > "$H/flags/${k#lane:}"; LANE_GATE_DISABLE=0 run "$NOW0" ;;
  esac
  eq "C9 [$k] rc" "$RC" 0
  # The kill check itself reads the flag rows (flag_active, as bin/staff.sh
  # does), and the lane gate reports flag-seen and liveness. Nothing of the
  # clerk's own (roster, settings, /count, sample, action) may follow.
  OWN=$(grep -vE '^(GET /api/flags/|POST /api/lanes/(flag-seen|liveness) )' "$T/w.log")
  eq "C9 [$k] 0 clerk requests" "$(grep -c . <<<"$OWN")" 0
  eq "C9 [$k] 0 sweep calls" "$(nsweeps)" 0
  [ ! -s "$H/logs/ALERTS.log" ] && ok "C9 [$k] no alert" || bad "C9 [$k] alerted: $(cat "$H/logs/ALERTS.log")"
done
RESET; cseed 900; setk staff.clerk.level act; : > "$H/flags/staff-off-clerk"; run "$NOW0"
grep -q 'killed by staff-off-clerk' "$H/logs/staff-clerk-lever.log" && ok "C9 one 'killed by' line" || bad "C9 log: $(cat "$H/logs/staff-clerk-lever.log")"

# --- C10 the sweep fails ----------------------------------------------------------
RESET; cseed 900; setk staff.clerk.level act
STUB_RC=3 run "$NOW0"
eq "C10 rc" "$RC" 0
eq "C10 the action row stays" "$(rows | jq length)" 1
grep -q ' action=recorded dry=1 sweep_rc=3 ' <<<"$(last)" && ok "C10 sweep_rc=3" || bad "C10 summary: $(last)"
[ ! -s "$H/logs/ALERTS.log" ] && ok "C10 no alert from the clerk" || bad "C10 alerted: $(cat "$H/logs/ALERTS.log")"

# --- C11 the REAL sweep, applied, tagged -----------------------------------------
RESET; cp "$T/needs-sweep.real.sh" "$H/bin/needs-sweep.sh"; chmod +x "$H/bin/needs-sweep.sh"
cseed 900 3; setk staff.clerk.level act; setk console.needs.sweep_dry_run 0
B=$(count_total)
eq "C11 NEEDS before" "$B" 903
# The sweep's clock too (NS_NOW): the 2026-01-01 rows are aged against NOW0.
NS_NOW="$NOW0" run "$NOW0"
eq "C11 rc" "$RC" 0
eq "C11 NEEDS after: 3 lower" "$(count_total)" 900
LD=$(jget "SELECT status, detail FROM ledgers WHERE kind='needs_sweep' ORDER BY rowid DESC LIMIT 1")
eq "C11 ledger row applied" "$(jq -r '.[0].status' <<<"$LD")" applied
AK=$(jget "SELECT action_key FROM staff_lever_actions WHERE agent='clerk'" | jq -r '.[0].action_key')
grep -qE " tag=clerk:${AK:0:12}\$" <<<"$(jq -r '.[0].detail' <<<"$LD")" && ok "C11 ledger detail ends with tag=clerk:<action key 12>" || bad "C11 ledger: $LD"
grep -qE "sweep=mode=apply .* changed=3 .* tag=clerk:${AK:0:12}\$" <<<"$(last)" && ok "C11 clerk summary carries the sweep summary" || bad "C11 summary: $(last)"
grep -q '^GET /api/needs-sweep/candidates' "$T/w.log" && ok "C11 the real sweep read the candidates" || bad "C11 no candidates read"

# --- C12 the lever window row ----------------------------------------------------
RESET; cseed 900; setk staff.clerk.level act; setk staff.clerk.lever_every_hours 1
run "$NOW0"; run "$((NOW0 + 3660))"
eq "C12 lever_every_hours=1: 2 actions in 61 min" "$(rows | jq length)" 2
eq "C12 lever_every_hours=1: 2 sweeps" "$(nsweeps)" 2
for v in abc 0; do
  RESET; cseed 900; setk staff.clerk.level act; setk staff.clerk.lever_every_hours "$v"
  run "$NOW0"; run "$((NOW0 + 3660))"
  eq "C12 lever_every_hours=$v: fallback 6, 1 action" "$(rows | jq length)" 1
  eq "C12 lever_every_hours=$v: 1 sweep" "$(nsweeps)" 1
done

echo "staff-clerk-lever.bh-9420: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
