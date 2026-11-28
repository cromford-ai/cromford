#!/bin/bash
# tests/staff-quartermaster-lever.bh-10123-test.sh — BH-10123 (C2 of #9423):
# the quartermaster staff agent owns orphan_usd_day (the $/day of Fly machines
# with no job row, plus idle Orgo capacity) and pulls one lever: a stop of an
# orphan pool machine through bin/fly-idle-reaper.sh act, dry run first, one
# staff_lever_actions row before each stop.
#
# bin/staff/quartermaster-lever.sh is driven over real curl against
# tests/lib/needs-sweep-world.bh-9117.mjs (unchanged), which serves the REAL
# jobs worker on the jobs schema composed from worker/jobs/schema.d/ (so the
# settings rows read are the seed this PR ships). The fly-idle snapshot and the
# Orgo rows are seeded with POST /__sql. The REAL bin/fly-idle-reaper.sh act
# runs in the scratch tree; flyctl is a PATH stub that logs its args. Each case
# starts its own world (a fresh DB), so no case depends on another.
#
#   C0  sources, the cron line, the lane row
#   U1  the action-answer decision (QM_LEVER_LIB_ONLY=1)
#   Q1  level observe (seed): one sample, 0 action rows, 0 reaper calls
#   Q2  the metric math: orphans of every source, unpriced, unsettled
#   Q3  idle_min edge: pool idle 3600 no action, 3601 one action
#   Q4  dry row 1 / absent / false: dry rows, act probe, 0 machine stop
#   Q5  dry row 0: one row, one machine stop, the reaper's act stop row; the
#       same hour again is taken. Q5b the probe sees work: refused. Q5c a
#       sample 25 h later settles the action (moved 1), target 0
#   Q6  stale, no pass row, 503: no sample, no action; the 1800 s edge is fresh
#   Q7  Orgo: not-recorded (no read), idle capacity, over pool, unreadable
#   Q8  adversarial negatives: no act stop on any of them
#   Q9  level file / `ACT;rm`: sample only
#   Q10 idle_min row 30 / abc; stops_max_run 3 with 4 candidates
#   Q11 the action POST fails: action=failed, 0 reaper calls
#   Q12 kill flags, STAFF_ENABLED=0, the lane-off flag: no lane request
#   V   0 vendor calls (gh, curl to a non-local host)
#
# D1 mutations (checked by hand, each turns a case red): `>=` for idle_min ->
# Q3; drop the source == pool filter -> Q8; call act before the action POST ->
# Q11; a missing dry row as apply -> Q4; drop the level gate -> Q1; a stale
# snapshot as fresh -> Q6.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-quartermaster-lever.bh-10123-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The jobs worker imports the git-ignored catalogs (BH-6452, BH-6540).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
. "$DIR/tests/lib/rendered.sh" || exit 1
SRV="$DIR/tests/lib/needs-sweep-world.bh-9117.mjs"
QM_REL=bin/staff/quartermaster-lever.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2' want '$3'"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
REAL_CURL=$(command -v curl)

# --- C0 sources -----------------------------------------------------------------
for f in "$DIR/$QM_REL" "$DIR/catalog/lanes.d/staff-quartermaster-lever.json" \
         "$DIR/cron/lanes/787-staff-quartermaster-lever.cron" \
         "$DIR/worker/jobs/schema.d/202611252040-bh-10123-quartermaster-lever.sql"; do
  [ -s "$f" ] && ok "C0 source exists: ${f#"$DIR"/}" || bad "C0 missing source ${f#"$DIR"/}"
done
bash -n "$DIR/$QM_REL" && ok "C0 bash -n" || bad "C0 bash -n"
grep -q '^49 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/staff/quartermaster-lever.sh ' \
  "$DIR/cron/lanes/787-staff-quartermaster-lever.cron" 2>/dev/null && ok "C0 cron: hourly :49 behind the hub lease" || bad "C0 cron line"
eq "C0 lane row" "$(jq -r '.script + " " + .switch.name + " " + .scope + " " + .cadence' "$DIR/catalog/lanes.d/staff-quartermaster-lever.json" 2>/dev/null)" \
  "bin/staff/quartermaster-lever.sh lane-off-staff-quartermaster-lever hub 49 * * * *"

# --- U1 the action answer -------------------------------------------------------
(
  QM_LEVER_LIB_ONLY=1 . "$DIR/$QM_REL" || { echo "  FAIL U1 source"; exit 1; }
  f=0
  chk() { local b="$T/u1.json"; printf '%s' "$2" > "$b"
          local got; got=$(qm_action_verdict "$1" "$b" "$3")
          [ "$got" = "$4" ] && echo "  ok   U1 $5" || { echo "  FAIL U1 $5: got '$got' want '$4'"; f=1; }; }
  chk 200 '{"ok":true,"action":{"action_key":"ab"}}' 0 run "a new row is run"
  chk 200 '{"ok":true,"existing":true,"action":{}}' 0 taken "existing is taken"
  chk 409 '{"error":"key_mismatch","action":{}}' 22 taken "409 is taken"
  chk 500 '{"error":"x"}' 22 failed "500 is failed"
  chk "" '' 7 failed "rc 7 (no connection) is failed"
  chk 200 '' 0 failed "a 200 with an empty body is failed"
  chk 200 '{"ok":false}' 0 failed "ok:false is failed"
  exit "$f"
) && ok "U1 action verdicts" || bad "U1 action verdicts"

# --- the scratch harness --------------------------------------------------------
H="$T/h"; FIX="$T/fix"
mkdir -p "$H/bin/staff" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$FIX" "$T/fakebin" "$T/home"
for L in "$QM_REL" bin/jobs-client.sh bin/lib/staff-contract.sh bin/lib/lane-gate.sh bin/fly-idle-reaper.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh "$H/bin/staff/"*.sh 2>/dev/null
cp "$(rendered_registry)" "$H/catalog/lanes.json"
cp "$DIR/catalog/fly-idle-signals.json" "$DIR/catalog/fly-prices.json" "$DIR/catalog/fly-work-procs.json" \
   "$DIR/catalog/orgo-plans.json" "$H/catalog/"
cp "$DIR/catalog/orgo-plans.json" "$T/orgo-plans.repo.json"
printf 'FLY_API_TOKEN="FlyV1 fm2_fixture"\n' > "$H/env/fly.env"; : > "$H/env/global.env"
cat > "$H/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/beats"
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/alerts"
EOF
# flyctl: one line per call. machine list answers $FIX/m-<app>.json; machine
# exec answers $FIX/exec-out (default: an idle ps).
cat > "$T/fakebin/flyctl" <<EOF
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$1 \$2" in
  "machine list") cat "$FIX/m-\$4.json" 2>/dev/null || exit 1 ;;
  "machine exec") cat "$FIX/exec-out" 2>/dev/null || printf '  0.0 /.fly/init\n  0.0 sleep infinity\n' ;;
  "machine stop") exit 0 ;;
esac
exit 0
EOF
# The vendor budget: gh is never called; curl reaches 127.0.0.1 only.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$T/vendor.log"; exit 1
EOF
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in http://127.0.0.1:*) ;; http://*|https://*) echo "curl \$a" >> "$T/vendor.log"; exit 7 ;; esac
done
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$H/bin/beat.sh" "$H/bin/lane-alert.sh" "$T/fakebin/"*
: > "$T/vendor.log"

export HARNESS="$H" HARNESS_TEST_SANDBOX=1 HOME="$T/home" PATH="$T/fakebin:$PATH"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 BOX_NAME=hub
export LANE_GATE_DISABLE=1 GH_ETAG=0
unset STAFF_ENABLED QM_LEVER_LIB_ONLY FLY_IDLE_REAPER_NOW

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all; __scratch_exit_trap' EXIT
: > "$T/seed.sql"
# world_up: a fresh world (fresh jobs DB from the schema.d seed), clean logs,
# the repo Orgo catalog, the default ps.
world_up() {
  stop_all; PIDS=()
  : > "$T/w.log"; : > "$T/w.port"; : > "$T/w.bodies"
  node "$SRV" "$T/w.log" "$T/seed.sql" "$T/w.bodies" > "$T/w.port" 2> "$T/w.err" &
  local spid=$!; PIDS+=("$spid")
  local _
  for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$spid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w.port")
  if [ -z "$PORT" ]; then
    wait "$spid"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
    echo "setup: server did not start: $(cat "$T/w.err")"; exit 1
  fi
  export JOBS_URL="http://127.0.0.1:$PORT"
  rm -f "$H"/flags/* "$FIX/exec-out" 2>/dev/null
  [ -e "$H/state/fly-idle-reaper" ] && { scratch_rm "$H/state/fly-idle-reaper" || exit 1; }
  : > "$H/logs/staff-quartermaster-lever.log"; : > "$H/logs/fly-idle-reaper.log"
  : > "$T/fly-calls"; : > "$T/beats"; : > "$T/alerts"; : > "$T/w.log"
  cp "$T/orgo-plans.repo.json" "$H/catalog/orgo-plans.json"
}
jsql() { "$REAL_CURL" -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
jget() { "$REAL_CURL" -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
setk() { jsql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('$1','$2','t','test','2026-11-10T00:00:00Z')"; }
delk() { jsql "DELETE FROM settings WHERE key='$1'"; }
iso() { date -u -d "@$1" +%FT%TZ; }
# 2026-11-10T00:30:00Z, pinned (D60). November has 30 days.
NOW0=$(date -u -d 2026-11-10T00:30:00Z +%s)
# pass_at <age seconds> — the reaper's pass row, that many seconds before NOW0.
pass_at() { jsql "INSERT OR REPLACE INTO fly_idle_pass (id, pass_at, apps_total, apps_failed, partial, box) VALUES (1, '$(iso "$((NOW0 - $1))")', 9, 0, 0, 'hub')"; }
# mach <app> <mid> <source> <state> <idle_s|NULL> <usd|NULL> — one snapshot row.
mach() {
  jsql "INSERT INTO fly_idle_machines (app, machine_id, size, source, idle_s, idle_state, threshold_s, usd_per_hour)
    VALUES ('$1','$2','performance-2x','$3',$5,'$4',900,$6)"
}
# flylist <app> <mid> — the machine list flyctl answers for the app: one
# started machine, started 2 h before now.
flylist() {
  jq -nc --arg id "$2" --argjson s "$(( $(date -u +%s) - 7200 ))" '[{id:$id, state:"started",
    config:{guest:{cpu_kind:"performance", cpus:2, memory_mb:4096}},
    events:[{type:"start", status:"started", timestamp:($s*1000)}]}]' > "$FIX/m-$1.json"
}
run() { QM_LEVER_NOW="${1:-$NOW0}" "$H/$QM_REL" > "$T/run.out" 2>&1; RC=$?; }
last() { tail -1 "$H/logs/staff-quartermaster-lever.log"; }
nactions() { grep -c '^POST /api/staff/levers/actions ' "$T/w.log"; }
nsamples() { grep -c '^POST /api/staff/levers/metric ' "$T/w.log"; }
nfly() { grep -c -- "$1" "$T/fly-calls"; }
nreaper() { grep -c ' act \(probe\|stop\) ' "$H/logs/fly-idle-reaper.log"; }
rows() { jget "SELECT dry_run, metric_before, lever, target, metric, detail, metric_after, moved FROM staff_lever_actions WHERE agent='quartermaster' ORDER BY id"; }
samples() { jget "SELECT value, detail FROM staff_metric_samples WHERE agent='quartermaster' ORDER BY id"; }
PA=pool-qa-fixture; MA=1f1dc0000a01; MB=1f1dc0000a02; MC=1f1dc0000a03; MD=1f1dc0000a04

world_up
eq "seed: staff.quartermaster.level is observe" "$(jget "SELECT value FROM settings WHERE key='staff.quartermaster.level'" | jq -r '.[0].value')" observe
eq "seed: the five BH-10123 rows" "$(jget "SELECT key || '=' || value AS kv FROM settings WHERE key IN ('staff.quartermaster.idle_min','staff.quartermaster.lever_dry_run','staff.quartermaster.stops_max_run','staff.quartermaster.snapshot_max_age_min','staff.quartermaster.act_timeout_s') ORDER BY key" | jq -r '[.[].kv] | join(" ")')" \
  "staff.quartermaster.act_timeout_s=180 staff.quartermaster.idle_min=60 staff.quartermaster.lever_dry_run=1 staff.quartermaster.snapshot_max_age_min=30 staff.quartermaster.stops_max_run=3"

# --- Q1 level observe (the seed) --------------------------------------------------
world_up; pass_at 60; mach "$PA" "$MA" pool idle 7200 0.5; flylist "$PA" "$MA"
run
eq "Q1 rc" "$RC" 0
eq "Q1 one sample" "$(samples | jq length)" 1
eq "Q1 sample value (0.5 * 24)" "$(samples | jq -r '.[0].value')" 12
eq "Q1 0 action POSTs" "$(nactions)" 0
eq "Q1 0 reaper calls" "$(nreaper)" 0
eq "Q1 0 flyctl calls" "$(grep -c . "$T/fly-calls")" 0
eq "Q1 0 beats" "$(grep -c . "$T/beats")" 0
grep -qE ' level=observe orphan_usd_day=12 fly=ok orgo=not-recorded sample=ok dry=- candidates=0 ' <<<"$(last)" && ok "Q1 summary" || bad "Q1 summary: $(last)"

# --- Q2 the metric math -----------------------------------------------------------
world_up; pass_at 60
mach "$PA" "$MA" pool idle 3601 0.1             # counts
mach bld-fixture 1f1dc0000b01 builder over 7200 0.2  # counts (any source)
mach met-fixture 1f1dc0000b02 metrics idle 4000 0.05 # counts
mach "$PA" "$MB" pool idle 3600 0.4             # exactly idle_min: not more
mach "$PA" "$MC" pool busy 0 0.4
mach unk-fixture 1f1dc0000b03 metrics unknown NULL 0.4
mach nos-fixture 1f1dc0000b04 metrics nosignal NULL 0.4
mach harness-hub 1f1dc0000b05 exempt exempt 90000 0.4
mach stp-fixture 1f1dc0000b06 pool stopping 9000 0.4
mach unp-fixture 1f1dc0000b07 metrics idle 3700 NULL # counts, unpriced
run
eq "Q2 rc" "$RC" 0
eq "Q2 value ((0.1 + 0.2 + 0.05) * 24)" "$(samples | jq -r '.[0].value')" 8.4
eq "Q2 detail" "$(samples | jq -r '.[0].detail')" "fly_usd_day=8.4 orphans=4 unpriced=1 unsettled=2 orgo_usd_day=not-recorded idle_min=60"

# --- Q3 the idle_min edge (act, dry 0) -------------------------------------------
world_up; pass_at 60; setk staff.quartermaster.level act; setk staff.quartermaster.lever_dry_run 0
mach "$PA" "$MA" pool idle 3600 0.1; mach "$PA" "$MB" pool idle 3601 0.1
flylist "$PA" "$MB"
run
eq "Q3 one action row" "$(rows | jq length)" 1
eq "Q3 the row is the 3601 s machine" "$(rows | jq -r '.[0].target')" "$PA/$MB"
eq "Q3 one machine stop, of $MB" "$(nfly "^machine stop $MB -a $PA")" 1
eq "Q3 no stop of the 3600 s machine" "$(nfly "^machine stop $MA")" 0

# --- Q4 dry: row 1 / absent / false ----------------------------------------------
for dr in 1 ABSENT false; do
  world_up; pass_at 60; setk staff.quartermaster.level act
  if [ "$dr" = ABSENT ]; then delk staff.quartermaster.lever_dry_run; else setk staff.quartermaster.lever_dry_run "$dr"; fi
  mach "$PA" "$MA" pool idle 7200 0.5; flylist "$PA" "$MA"
  run
  eq "Q4 [$dr] rc" "$RC" 0
  eq "Q4 [$dr] one dry-run row" "$(rows | jq -r '[length, .[0].dry_run] | join(" ")')" "1 1"
  eq "Q4 [$dr] one act probe" "$(grep -c " act probe $PA/$MA: idle" "$H/logs/fly-idle-reaper.log")" 1
  eq "Q4 [$dr] 0 machine stop" "$(nfly '^machine stop')" 0
  grep -q " $PA/$MA idle_s=7200 action=recorded act=probe:idle\$" "$H/logs/staff-quartermaster-lever.log" \
    && ok "Q4 [$dr] candidate line" || bad "Q4 [$dr] log: $(cat "$H/logs/staff-quartermaster-lever.log")"
  grep -qE ' dry=1 candidates=1 recorded=1 taken=0 failed=0 stopped=0 refused=0 over_cap=0$' <<<"$(last)" \
    && ok "Q4 [$dr] summary" || bad "Q4 [$dr] summary: $(last)"
done

# --- Q5 apply: one row, one stop; the same hour again is taken -------------------
world_up; pass_at 60; setk staff.quartermaster.level act; setk staff.quartermaster.lever_dry_run 0
mach "$PA" "$MA" pool idle 7200 0.5; flylist "$PA" "$MA"
run
eq "Q5 rc" "$RC" 0
R=$(rows)
eq "Q5 one row: dry_run lever target metric metric_before" \
  "$(jq -r '.[0] | "\(.dry_run) \(.lever) \(.target) \(.metric) \(.metric_before)"' <<<"$R")" "0 fly-stop $PA/$MA orphan_usd_day 12"
eq "Q5 row count" "$(jq length <<<"$R")" 1
eq "Q5 exactly one machine stop" "$(nfly "^machine stop $MA -a $PA")" 1
eq "Q5 the reaper's stop row (source act)" "$(jget "SELECT app || '/' || machine_id || ' ' || source AS r FROM fly_idle_stops" | jq -r '[.[].r] | join(",")')" "$PA/$MA act"
eq "Q5 one fly_idle_action beat" "$(jq -r .kind "$T/beats" 2>/dev/null)" fly_idle_action
grep -q " $PA/$MA idle_s=7200 action=recorded act=stopped\$" "$H/logs/staff-quartermaster-lever.log" && ok "Q5 candidate line" \
  || bad "Q5 log: $(cat "$H/logs/staff-quartermaster-lever.log")"
grep -qE ' level=act orphan_usd_day=12 .* dry=0 candidates=1 recorded=1 taken=0 failed=0 stopped=1 refused=0 over_cap=0$' <<<"$(last)" \
  && ok "Q5 summary" || bad "Q5 summary: $(last)"
# The action row is written before the stop: the world logs the action POST
# before the reaper's stop-row POST.
A_LN=$(grep -n '^POST /api/staff/levers/actions ' "$T/w.log" | head -1 | cut -d: -f1)
S_LN=$(grep -n '^POST /api/fly-idle/stops ' "$T/w.log" | head -1 | cut -d: -f1)
[ -n "$A_LN" ] && [ -n "$S_LN" ] && [ "$A_LN" -lt "$S_LN" ] && ok "Q5 the action row is recorded before the stop row" \
  || bad "Q5 order: action line ${A_LN:-none}, stop line ${S_LN:-none}"
run "$((NOW0 + 1200))"
grep -q " $PA/$MA idle_s=7200 action=taken act=-\$" "$H/logs/staff-quartermaster-lever.log" && ok "Q5 the same hour again: taken" \
  || bad "Q5 rerun log: $(tail -2 "$H/logs/staff-quartermaster-lever.log")"
eq "Q5 still one machine stop" "$(nfly '^machine stop')" 1
eq "Q5 still one action row" "$(rows | jq length)" 1
# Q5c: the action ran 25 h ago, the orphan is gone: the next sample settles it.
jsql "UPDATE staff_lever_actions SET acted_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-25 hours') WHERE agent='quartermaster'"
jsql "DELETE FROM fly_idle_machines"; mach "$PA" "$MA" pool busy 0 0.5
pass_at "$((-(25 * 3600) + 60))"
run "$((NOW0 + 25 * 3600))"
eq "Q5c the action settled: metric_after 0, moved 1" "$(rows | jq -r '.[0] | "\(.metric_after) \(.moved)"')" "0 1"
SC=$("$REAL_CURL" -sS -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/staff/levers/scorecard?agent=quartermaster")
eq "Q5c scorecard settled/moved/target/metric" "$(jq -r '"\(.settled) \(.moved) \(.target) \(.metric)"' <<<"$SC")" "1 1 0 orphan_usd_day"

# Q5b: the reaper's probe sees work: refused, no stop, the row stays.
world_up; pass_at 60; setk staff.quartermaster.level act; setk staff.quartermaster.lever_dry_run 0
mach "$PA" "$MA" pool idle 7200 0.5; flylist "$PA" "$MA"
printf '  0.0 /.fly/init\n 12.0 /bin/bash /root/harness/bin/run-build.sh fixture\n' > "$FIX/exec-out"
run
eq "Q5b rc" "$RC" 0
eq "Q5b 0 machine stop" "$(nfly '^machine stop')" 0
eq "Q5b the action row stays" "$(rows | jq length)" 1
grep -q " $PA/$MA idle_s=7200 action=recorded act=refused\$" "$H/logs/staff-quartermaster-lever.log" && ok "Q5b refused" \
  || bad "Q5b log: $(cat "$H/logs/staff-quartermaster-lever.log")"

# --- Q6 the snapshot freshness ----------------------------------------------------
for c in stale:1801 edge:1800 nopass:- table:-; do
  world_up; setk staff.quartermaster.level act; setk staff.quartermaster.lever_dry_run 0
  mach "$PA" "$MA" pool idle 7200 0.5; flylist "$PA" "$MA"
  case "$c" in
    stale:*|edge:*) pass_at "${c#*:}" ;;
    table:*) pass_at 60; jsql "ALTER TABLE fly_idle_machines RENAME TO fly_idle_machines_off" ;;
  esac
  run
  eq "Q6 [$c] rc" "$RC" 0
  if [ "$c" = edge:1800 ]; then
    eq "Q6 [$c] fresh: one sample" "$(samples | jq length)" 1
    eq "Q6 [$c] fresh: one stop" "$(nfly '^machine stop')" 1
    continue
  fi
  eq "Q6 [$c] 0 samples" "$(nsamples)" 0
  eq "Q6 [$c] 0 actions" "$(nactions)" 0
  eq "Q6 [$c] 0 flyctl calls" "$(grep -c . "$T/fly-calls")" 0
  want=unreadable; [ "$c" = stale:1801 ] && want=stale
  grep -q " fly=$want " <<<"$(last)" && ok "Q6 [$c] fly=$want" || bad "Q6 [$c] summary: $(last)"
done
grep -q '^GET /api/fly-idle 503' "$T/w.log" && ok "Q6 [table] the route answered 503" || bad "Q6 [table] log: $(cat "$T/w.log")"

# --- Q7 Orgo ----------------------------------------------------------------------
orgo_pool() { # orgo_pool <vcpus> — the fixture account with only a vCPU pool
  jq --argjson v "$1" '.accounts = {"fixture-acct": {pool: {computers: null, vcpus: $v, ram_gb: null, disk_gb: null},
    prices_usd_mo: {computer: 1, vcpu: 10, ram_gb: 4, disk_gb: null}}}' "$T/orgo-plans.repo.json" > "$H/catalog/orgo-plans.json"
}
orgo_box() { # orgo_box <id> <cpu|NULL> [gone_at]
  jsql "INSERT INTO orgo_computers (orgo_id, account, status, cpu, ram_gb, seen_at, gone_at)
    VALUES ('$1','fixture-acct','running',$2,8,'2026-11-10T00:00:00Z',${3:-NULL})"
}
world_up; pass_at 60
run
grep -q '^GET /api/orgo-computers' "$T/w.log" && bad "Q7 not-recorded: the route was read" || ok "Q7 not-recorded: no /api/orgo-computers read"
grep -q 'orgo_usd_day=not-recorded' <<<"$(samples | jq -r '.[0].detail')" && ok "Q7 detail not-recorded" || bad "Q7 detail: $(samples)"
world_up; pass_at 60; orgo_pool 16; orgo_box o1 6; orgo_box o2 6; orgo_box o3 8 "'2026-11-01T00:00:00Z'"
run
eq "Q7 pool 16, used 12 (a gone box not used): 4 * 10 / 30" "$(samples | jq -r '.[0].value')" 1.33
grep -q ' orgo=ok ' <<<"$(last)" && ok "Q7 orgo=ok" || bad "Q7 summary: $(last)"
world_up; pass_at 60; orgo_pool 16; orgo_box o1 12; orgo_box o2 8
run
eq "Q7 used 20 over pool 16: 0, never negative" "$(samples | jq -r '.[0].value')" 0
for c in table truncated nullcpu badcatalog; do
  world_up; pass_at 60; orgo_pool 16; orgo_box o1 6
  case "$c" in
    table) jsql "ALTER TABLE orgo_computers RENAME TO orgo_computers_off" ;;
    nullcpu) orgo_box o2 NULL ;;
    badcatalog) printf '{"accounts": ' > "$H/catalog/orgo-plans.json" ;;
    truncated) jsql "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 2001)
      INSERT INTO orgo_computers (orgo_id, account, status, cpu, seen_at) SELECT 'x' || i, 'other-acct', 'running', 1, '2026-11-10T00:00:00Z' FROM n" ;;
  esac
  run
  eq "Q7 [$c] 0 samples" "$(nsamples)" 0
  grep -q ' orgo=unreadable ' <<<"$(last)" && ok "Q7 [$c] orgo=unreadable" || bad "Q7 [$c] summary: $(last)"
done

# --- Q8 adversarial negatives (act, dry 0) ----------------------------------------
world_up; pass_at 60; setk staff.quartermaster.level act; setk staff.quartermaster.lever_dry_run 0
mach bld-fixture 1f1dc0000c01 builder idle 9000 0.2
mach lane-run 1f1dc0000c02 lane-run idle 9000 0.2
mach harness-hub 1f1dc0000c03 exempt exempt 9000 0.2
mach pool-x 1f1dc0000c04 metrics idle 9000 0.2
mach "$PA" "$MA" pool idle 3600 0.2
mach "$PA" "$MB" pool busy 0 0.2
mach "$PA" "$MC" pool unknown NULL 0.2
run
eq "Q8 rc" "$RC" 0
eq "Q8 0 action POSTs" "$(nactions)" 0
eq "Q8 0 act stop / probe" "$(nreaper)" 0
eq "Q8 0 machine stop" "$(nfly '^machine stop')" 0
grep -qE ' candidates=0 ' <<<"$(last)" && ok "Q8 candidates=0" || bad "Q8 summary: $(last)"

# --- Q9 level file / ACT;rm -------------------------------------------------------
for lv in file ' ACT;rm'; do
  world_up; pass_at 60; setk staff.quartermaster.level "$lv"; setk staff.quartermaster.lever_dry_run 0
  mach "$PA" "$MA" pool idle 7200 0.5; flylist "$PA" "$MA"
  run
  eq "Q9 [$lv] one sample" "$(samples | jq length)" 1
  eq "Q9 [$lv] 0 action POSTs" "$(nactions)" 0
  eq "Q9 [$lv] 0 reaper calls" "$(nreaper)" 0
done

# --- Q10 the idle_min row and the per-run cap ------------------------------------
for c in 30:1 abc:0; do
  world_up; pass_at 60; setk staff.quartermaster.level act; setk staff.quartermaster.idle_min "${c%%:*}"
  mach "$PA" "$MA" pool idle 1801 0.5; flylist "$PA" "$MA"
  run
  eq "Q10 idle_min=${c%%:*}: 1801 s is a candidate? rows" "$(rows | jq length)" "${c#*:}"
done
world_up; pass_at 60; setk staff.quartermaster.level act
for m in "$MA" "$MB" "$MC" "$MD"; do mach "$PA" "$m" pool idle "$(( 7000 + ${m: -1} * 100 ))" 0.5; done
flylist "$PA" "$MA"
run
eq "Q10 4 candidates, cap 3: 3 action rows" "$(rows | jq length)" 3
eq "Q10 the 3 most idle" "$(rows | jq -r '[.[].target] | join(",")')" "$PA/$MD,$PA/$MC,$PA/$MB"
grep -qE ' candidates=3 recorded=3 .* over_cap=1$' <<<"$(last)" && ok "Q10 over_cap=1" || bad "Q10 summary: $(last)"

# --- Q11 the action POST fails ----------------------------------------------------
world_up; pass_at 60; setk staff.quartermaster.level act; setk staff.quartermaster.lever_dry_run 0
mach "$PA" "$MA" pool idle 7200 0.5; flylist "$PA" "$MA"
jsql "ALTER TABLE staff_lever_actions RENAME TO staff_lever_actions_off"
run
eq "Q11 rc" "$RC" 0
grep -q '^POST /api/staff/levers/actions 5' "$T/w.log" && ok "Q11 the real route answered 5xx" || bad "Q11 log: $(grep actions "$T/w.log")"
grep -q " $PA/$MA idle_s=7200 action=failed act=-\$" "$H/logs/staff-quartermaster-lever.log" && ok "Q11 action=failed" \
  || bad "Q11 log: $(cat "$H/logs/staff-quartermaster-lever.log")"
eq "Q11 0 reaper calls" "$(nreaper)" 0
eq "Q11 0 flyctl calls" "$(grep -c . "$T/fly-calls")" 0

# --- Q12 the kill switches --------------------------------------------------------
for k in flag:staff-off-quartermaster flag:staff-kill-quartermaster flag:staff-off-all flag:staff-kill-all \
         env:STAFF_ENABLED=0 lane:lane-off-staff-quartermaster-lever; do
  world_up; pass_at 60; setk staff.quartermaster.level act; setk staff.quartermaster.lever_dry_run 0
  mach "$PA" "$MA" pool idle 7200 0.5; flylist "$PA" "$MA"; : > "$T/w.log"
  case "$k" in
    flag:*) : > "$H/flags/${k#flag:}"; run ;;
    env:*) STAFF_ENABLED=0 run ;;
    lane:*) : > "$H/flags/${k#lane:}"; LANE_GATE_DISABLE=0 run ;;
  esac
  eq "Q12 [$k] rc" "$RC" 0
  # The kill check reads the flag rows, and the lane gate reports flag-seen
  # and liveness. Nothing of the lane's own may follow.
  OWN=$(grep -vE '^(GET /api/flags/|POST /api/lanes/(flag-seen|liveness) )' "$T/w.log")
  eq "Q12 [$k] 0 lane requests" "$(grep -c . <<<"$OWN")" 0
  eq "Q12 [$k] 0 flyctl calls" "$(grep -c . "$T/fly-calls")" 0
done

# --- V the vendor budget ----------------------------------------------------------
eq "V 0 vendor calls (gh, non-local curl)" "$(grep -c . "$T/vendor.log")" 0

echo "staff-quartermaster-lever.bh-10123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
