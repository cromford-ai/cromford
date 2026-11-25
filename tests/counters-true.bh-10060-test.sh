#!/bin/bash
# tests/counters-true.bh-10060-test.sh — BH-10060 (slice C0): the fleet-status
# counters use the same filters as the detectors they summarise.
#
# remote_results_pending (bin/fleet-status-push.sh fsp_project_row) counted a
# hub json the staleremote detector (bin/pipeline-health.sh) never pages: one
# the retention rule retired, one whose own result line proves a settled PR
# older than STALEREMOTE_PR_SETTLED_DAYS, and a folderless one the detector
# cached as ledger-terminal. queue_depth and oldest_queued_min counted a key
# the pool's push-rejected terminal gate (bin/fly-pool.sh pool_terminal_check)
# never spawns. This drives the REAL script, whole-fleet mode, against a
# scratch tree: curl and beat are stubs, the jobs client is a local fake that
# answers from fixture files. No network.
#
# Cases (plan BH-10060 "Failure modes"):
#   R1-R10, P1  .remote_results_pending["<p>"]
#   Q1-Q7       .projects["<p>"].queue_depth / oldest_queued_min / terminal
#   X1          no bin/lib/remote-results-ledger.sh: today's count
#   K1          the knob fallback comment names the pipeline-health knob
# Run from anywhere: tests/counters-true.bh-10060-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin" "$T/builds" "$T/fx"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
for L in bin/lib/watchdog-url.sh bin/lib/remote-results-ledger.sh bin/lib/pool-state-rows.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$T" ) >/dev/null || { echo "closure: $L"; exit 1; }
done
printf 'HARNESS_SECRET=test-secret\nCONSOLE_URL=http://console.invalid\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
sed "s|^H=/root/harness|H=$T|" "$DIR/bin/fleet-status-push.sh" > "$T/fsp.sh"

# The fake jobs client (installed only for the DB cases). pool_state_rows is on
# when POOL_STATE_ROWS=1. GET /api/pool-state answers $T/fx/ps-<p>.json when it
# exists, else fails (an outage). queue_list answers $T/fx/q-<p>.tsv when it
# exists, else nothing (the file fallback).
cat > "$T/fx/jobs-client.sh" <<EOF
_flag_on_row() { [ "\${2:-0}" = 1 ]; }
_jobs_req() {
  case "\$2" in
    /api/pool-state\?project=*) local p=\${2#*project=}; p=\${p%%&*}
                                [ -f "$T/fx/ps-\$p.json" ] && cat "$T/fx/ps-\$p.json" && return 0; return 1 ;;
  esac
  return 1
}
queue_list() { [ -f "$T/fx/q-\$1.tsv" ] && cat "$T/fx/q-\$1.tsv"; return 0; }
EOF

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
run() { rm -f "$T/PUSH.json"; PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$T/fsp.sh" >/dev/null 2>&1; }
rrp() { jq -r --arg p "$1" '.remote_results_pending[$p] // "missing"' "$T/PUSH.json" 2>/dev/null; }
field() { jq -r --arg p "$1" ".projects[\$p].$2 // \"missing\"" "$T/PUSH.json" 2>/dev/null; }
age() { touch -d "@$((NOW - $2))" "$1"; }   # age <file> <seconds old>
mt()  { stat -c %Y "$1"; }
# rj <project> <key> <age s> [result] — a hub backup json.
rj() {
  mkdir -p "$T/state/remote-results/$1"
  if [ -n "${4:-}" ]; then jq -nc --arg r "$4" '{result:$r}'; else echo '{}'; fi \
    > "$T/state/remote-results/$1/$2.json"
  age "$T/state/remote-results/$1/$2.json" "$3"
}
cache() { mkdir -p "$T/state/remote-results-terminal"; printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$T/state/remote-results-terminal/$1.tsv"; }
D=86400
GH=https://github.com/o/r/pull

PROJECTS="r1-os r2-os r3-os r4-os r5-os r6-os r7-os r8-os r9-os p1-os q-os qdb-os qdbq-os qout-os"
: > "$T/fleet.conf"
for p in $PROJECTS; do
  printf '%s Org/%s https://a.example /api/board 2 box-x\n' "$p" "$p" >> "$T/fleet.conf"
  echo "a recent triage line" > "$T/logs/$p.log"
done

# ---------- remote_results_pending fixtures ----------
rj r1-os K1 7200                              # R1 {} at 2 h: counts
rj r2-os K2 $((8*D)) "PR_MERGED $GH/7"        # R2 settled 8 d: out
rj r3-os K3 $((8*D)) "PR_CLOSED $GH/8"        # R3 settled 8 d: out
# R4 retired: out. A build folder exists on purpose, so only the retired
# filter can exclude it (the ledger-terminal filter needs a missing folder).
rj r4-os K4 7200;  cache r4-os K4 "$(mt "$T/state/remote-results/r4-os/K4.json")" 1
mkdir -p "$T/builds/pool-r4-os-K4-1"
rj r5-os K5 7200;  cache r5-os K5 "$(mt "$T/state/remote-results/r5-os/K5.json")" 0   # R5 folderless ledger-terminal: out
rj r6-os K6 $((2*D)) "PR_MERGED $GH/9"        # R6 settled but 2 d < 7: counts
rj r7-os K7 7200;  cache r7-os K7 "$(( $(mt "$T/state/remote-results/r7-os/K7.json") - 60 ))" 0  # R7 other mtime: counts
rj r8-os K8 7200;  cache r8-os K8 "$(mt "$T/state/remote-results/r8-os/K8.json")" 0   # R8 folder present: counts
mkdir -p "$T/builds/pool-r8-os-K8-1"
rj r9-os K9 $((8*D)) "PR_CREATED https://gitlab.com/o/r/merge_requests/1"            # R9 not GitHub: counts
# P1: one json per class in one project; the pageable ones are R1, R6-R9 = 5.
rj p1-os A1 7200
rj p1-os A2 $((8*D)) "PR_MERGED $GH/7"
rj p1-os A3 $((8*D)) "PR_CLOSED $GH/8"
rj p1-os A4 7200;  cache p1-os A4 "$(mt "$T/state/remote-results/p1-os/A4.json")" 1
rj p1-os A5 7200;  cache p1-os A5 "$(mt "$T/state/remote-results/p1-os/A5.json")" 0
rj p1-os A6 $((2*D)) "PR_MERGED $GH/9"
rj p1-os A7 7200;  cache p1-os A7 "$(( $(mt "$T/state/remote-results/p1-os/A7.json") - 60 ))" 0
rj p1-os A8 7200;  cache p1-os A8 "$(mt "$T/state/remote-results/p1-os/A8.json")" 0
mkdir -p "$T/builds/p1-os-A8-1"
rj p1-os A9 $((8*D)) "PR_CREATED https://gitlab.com/o/r/merge_requests/1"
rj p1-os A10 600                              # under 30 min: never counted

# ---------- queue fixtures (file path, no jobs client) ----------
qf() { mkdir -p "$T/state/build-queue/$1"; jq -nc --arg k "$2" '{ticket_id:"1",key:$k}' > "$T/state/build-queue/$1/$2.json"; age "$T/state/build-queue/$1/$2.json" "$3"; }
tf() { mkdir -p "$T/state/pool/$1"; jq -nc --arg c "$3" '{branch:"b",head_sha:"abc",reason:"push-rejected",created_at:$c}' > "$T/state/pool/$1/$2.terminal"; }
qf q-os BH-1 600                              # Q1 plain: counts, ~10 min
qf q-os BH-2 18000; tf q-os BH-2 2026-11-20T00:00:00Z   # Q2 terminal file: out, does not age
tf q-os BH-4 2026-11-20T00:00:00Z             # Q4 marker with no queue file: nothing

STALEREMOTE_PR_SETTLED_DAYS=7 run
for c in "r1-os 1 R1" "r2-os 0 R2" "r3-os 0 R3" "r4-os 0 R4" "r5-os 0 R5" "r6-os 1 R6" "r7-os 1 R7" "r8-os 1 R8" "r9-os 1 R9" "p1-os 5 P1"; do
  set -- $c
  [ "$(rrp "$1")" = "$2" ] && ok || bad "$3 remote_results_pending[$1] want $2, got $(rrp "$1")"
done
[ "$(field q-os queue_depth)" = 1 ] && ok || bad "Q2 a pool-terminal key is out of queue_depth (want 1, got $(field q-os queue_depth))"
QA=$(field q-os oldest_queued_min)
[ "$QA" -lt 100 ] 2>/dev/null && ok || bad "Q2 a pool-terminal key does not age oldest_queued_min (got $QA)"
[ "$(field q-os terminal)" = 1 ] && ok || bad "Q2/Q4 terminal counts the one queued terminal key, not the orphan marker (want 1, got $(field q-os terminal))"
[ "$(field r1-os terminal)" = 0 ] && ok || bad "Q1 a project with no terminal keys reports terminal 0 (got $(field r1-os terminal))"

# R10: STALEREMOTE_PR_SETTLED_DAYS=0 turns the settled filter off in the counter too.
STALEREMOTE_PR_SETTLED_DAYS=0 run
[ "$(rrp r2-os)" = 1 ] && ok || bad "R10 settled-days 0 counts the settled json (want 1, got $(rrp r2-os))"
[ "$(rrp r4-os)" = 0 ] && ok || bad "R10 settled-days 0 leaves the retired filter on (want 0, got $(rrp r4-os))"

# ---------- queue, DB path (fake jobs client, pool_state_rows on) ----------
cp "$T/fx/jobs-client.sh" "$T/bin/jobs-client.sh"
# qdb-os: queue from FILES, terminal set from ROWS.
qf qdb-os BH-1 600                            # plain: counts
qf qdb-os BH-3 18000                          # Q3 a terminal row, no file: out
qf qdb-os BH-5 18000; tf qdb-os BH-5 2026-11-20T00:00:00Z   # Q5 file older than the row's clear: counts
qf qdb-os BH-7 18000; tf qdb-os BH-7 2026-11-20T00:00:00Z   # Q7 file, no row: the file decides (pool gate): out
cat > "$T/fx/ps-qdb-os.json" <<'EOF'
{"project":"qdb-os","spawns":[],"holds":[],"terminals":[
 {"key":"BH-3","branch":"b","head_sha":"abc","reason":"push-rejected","created_at":"2026-11-20T00:00:00Z"},
 {"key":"BH-5","branch":"b","head_sha":"abc","reason":"push-rejected","created_at":"2026-11-19T00:00:00Z","cleared_at":"2026-11-21T00:00:00Z"}]}
EOF
# qdbq-os: queue from DB ROWS (queue_list), terminal set from ROWS.
OLD=$(date -u -d "@$((NOW - 18000))" +%Y-%m-%dT%H:%M:%SZ); NEW=$(date -u -d "@$((NOW - 600))" +%Y-%m-%dT%H:%M:%SZ)
printf 'qdbq-os\tBH-1\t1\tqueued\tfly\t1\t-\t%s\t-\t-\nqdbq-os\tBH-3\t3\tqueued\tfly\t1\t-\t%s\t-\t-\n' "$NEW" "$OLD" > "$T/fx/q-qdbq-os.tsv"
echo '{"project":"qdbq-os","spawns":[],"holds":[],"terminals":[{"key":"BH-3","branch":"b","head_sha":"abc","reason":"push-rejected","created_at":"2026-11-20T00:00:00Z"}]}' > "$T/fx/ps-qdbq-os.json"
# qout-os: rows on, the worker does not answer (Q6): the files decide.
qf qout-os BH-1 600
qf qout-os BH-2 18000; tf qout-os BH-2 2026-11-20T00:00:00Z

POOL_STATE_ROWS=1 STALEREMOTE_PR_SETTLED_DAYS=7 run
[ "$(field qdb-os queue_depth)" = 2 ] && ok || bad "Q3/Q5/Q7 qdb-os queue_depth want 2 (BH-1, BH-5), got $(field qdb-os queue_depth)"
[ "$(field qdb-os terminal)" = 2 ] && ok || bad "Q3/Q7 qdb-os terminal want 2 (BH-3 row, BH-7 file), got $(field qdb-os terminal)"
[ "$(field qdbq-os queue_depth)" = 1 ] && ok || bad "Q3 DB queue: a terminal row is out of queue_depth (want 1, got $(field qdbq-os queue_depth))"
QA=$(field qdbq-os oldest_queued_min)
[ "$QA" -lt 100 ] 2>/dev/null && ok || bad "Q3 DB queue: the terminal row does not age oldest_queued_min (got $QA)"
[ "$(field qdbq-os terminal)" = 1 ] && ok || bad "Q3 DB queue: terminal 1 (got $(field qdbq-os terminal))"
[ "$(field qout-os queue_depth)" = 1 ] && ok || bad "Q6 no worker answer: the .terminal file decides (want 1, got $(field qout-os queue_depth))"
[ "$(field qout-os terminal)" = 1 ] && ok || bad "Q6 no worker answer: terminal 1 (got $(field qout-os terminal))"

# Rows knob OFF: the files only, even with a worker that answers.
STALEREMOTE_PR_SETTLED_DAYS=7 run
[ "$(field qdb-os queue_depth)" = 2 ] && ok || bad "rows off: qdb-os counts by files (BH-1, BH-3; want 2, got $(field qdb-os queue_depth))"
rm -f "$T/bin/jobs-client.sh"

# ---------- X1: no remote-results-ledger.sh, today's count ----------
rm -f "$T/bin/lib/remote-results-ledger.sh"
STALEREMOTE_PR_SETTLED_DAYS=7 run
[ "$(rrp p1-os)" = 9 ] && ok || bad "X1 no lib: every json older than 30 min counts (want 9, got $(rrp p1-os))"

# ---------- K1 ----------
grep -q '# fallback of the pipeline-health knob STALEREMOTE_PR_SETTLED_DAYS' "$DIR/bin/fleet-status-push.sh" \
  && ok || bad "K1 the settled-days fallback names its knob"

echo "counters-true.bh-10060: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
