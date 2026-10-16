#!/bin/bash
# tests/fleet-totals.bh-5944-test.sh — BH-5944 (BH-5938.4): the three lanes
# that report a fleet total write ONE ROW PER PROJECT from each project's own
# run, and one aggregate reads the rows. The fleet total must equal the sum of
# the rows.
#
# THE RIG. A scratch $H (symlink tree of bin/ and catalog/), fleet.conf p1..p5
# (box `local`, a board at https://p<i>.example.invalid/api/board). Seeded per
# project: p<i> has i queued build-queue files, i-1 remote results older than
# 30 min, a triage log, i stale owed tickets on its board, and builds. The
# real lanes and runner run. Stubbed: `curl` (the watchdog POST lands in
# $T/PUSH.json; the boards answer from their seeds; the jobs worker answers the
# artifact feed and 404 for the rest), bin/alert-line.sh, bin/lane-alert.sh,
# bin/beat.sh (records argv).
#
#   F1-F6  fleet-status-push: rows, THE FLEET TOTAL, v2/missing rows computed
#          by the dispatch, no wait, empty fleet, the no-arg push is the same
#   M1-M6  metrics-collect: per-project rows, THE FLEET TOTAL, the one-time
#          legacy cutover, idempotent, the agg lock held, two runs at once
#   S1-S6  stale-owed-tickets: entries, THE FLEET TOTAL, a skipped project (and
#          one with no board),
#          orphan alerts once per dir and per ledger key, no lost queue write,
#          the legacy queued map
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fleet-totals.bh-5944-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "fleet-totals: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "fleet-totals: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${FLEET_TOTALS_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

for f in "$DIR/bin/fleet-status-push.sh" "$DIR/bin/metrics-collect.sh" "$DIR/bin/stale-owed-tickets.sh" \
         "$DIR/bin/lib/project-lanes.sh" "$DIR/catalog/lanes.d/fleet-status-push.knobs.d/FLEET_STATUS_PUSH_ROW_WAIT_S.json"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "fleet-totals: 0 passed, 1 failed"; exit 1; }
done

# ONE clock read for the whole file.
NOW=$(date -u +%s)
H="$T/h"
mkdir -p "$H/env" "$H/logs" "$H/state" "$H/builds" "$T/fakebin" "$T/boards" "$T/home"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
printf 'HARNESS_SECRET=test-fixture-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$H/env/global.env"
rm -f "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/alerts"\nexit 0\n' > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/lane-alerts"\nexit 0\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$FXT/beats"\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
url=""
for a in "$@"; do case "$a" in http://*|https://*) url="$a" ;; esac; done
case "$url" in
  http://watchdog.invalid/api/status*) cat > "$FXT/PUSH.json"; echo push >> "$FXT/pushes"; exit 0 ;;
  https://p*.example.invalid/api/board/boards/*/tickets)
    p=${url#https://}; p=${p%%.*}; cat "$FXT/boards/$p.tickets.json"; exit 0 ;;
  https://p*.example.invalid/api/board/boards)
    p=${url#https://}; p=${p%%.*}; printf '[{"id":"b-%s","keyPrefix":"P"}]' "$p"; exit 0 ;;
  "$JOBS_URL"/api/artifacts\?kind=result\&project=*)
    p=${url#*project=}; p=${p%%&*}
    if [ -f "$FXT/feed-$p.json" ]; then printf '%s\n200\n' "$(cat "$FXT/feed-$p.json")"; else printf '{"artifacts":[]}\n200\n'; fi
    exit 0 ;;
  "$JOBS_URL"/api/artifacts\?*|"$JOBS_URL"/api/jobs/*/artifacts*) printf '{"artifacts":[]}\n200\n'; exit 0 ;;
  "$JOBS_URL"*) printf '{"error":"not found"}\n404\n'; exit 0 ;;
esac
exit 7
SH
chmod +x "$T/fakebin/curl"

conf5() { local i; for i in 1 2 3 4 5; do printf 'p%s o/p%s https://p%s.example.invalid /api/board 2 local\n' "$i" "$i" "$i"; done; }
conf5 > "$H/fleet.conf"
for i in 1 2 3 4 5; do
  printf 'P%s_INTERNAL_API_TOKEN=tok-fixture-%s\n' "$i" "$i" > "$H/env/p$i.env"
  echo "triage ran for p$i" > "$H/logs/p$i.log"
  mkdir -p "$H/state/build-queue/p$i" "$H/state/remote-results/p$i"
  for j in $(seq 1 "$i"); do
    jq -nc --arg k "BH-$i$j" '{ticket_id:"1",key:$k,attempt:1}' > "$H/state/build-queue/p$i/BH-$i$j.json"
    touch -d "@$((NOW - 1800))" "$H/state/build-queue/p$i/BH-$i$j.json"
  done
  for j in $(seq 2 "$i"); do
    echo '{}' > "$H/state/remote-results/p$i/BH-$i$j.json"
    touch -d "@$((NOW - 7200))" "$H/state/remote-results/p$i/BH-$i$j.json"
  done
  # i stale tickets owed by us (waitingOn team, 10h quiet) + one fresh one.
  OLD=$(date -u -d "@$((NOW - 36000))" +%Y-%m-%dT%H:%M:%SZ)
  jq -n --argjson n "$i" --arg old "$OLD" --arg new "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" \
    '[range(1; $n + 1) | {key: "P-\(.)", title: "ticket \(.)", status: "todo", waitingOn: "team", lastActivityAt: $old}]
     + [{key: "P-99", title: "fresh", status: "todo", waitingOn: "team", lastActivityAt: $new}]' > "$T/boards/p$i.tickets.json"
done

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 FLEET_CONF="$H/fleet.conf" \
  PL_DISPATCH_SPREAD_PCT=0 HOME="$T/home" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 JOBS_BOX=hub
unset GH_TOKEN GITHUB_TOKEN LANE_GATE_DISABLE HARNESS_ENV_DIR PL_LANE PL_PROJECT PL_LOCK_FD PL_SLUG \
  PL_STATE_DIR PL_TEST_BARRIER PL_TEST_BARRIER_EXIT PL_TEST_LOCK_WAIT_S REGISTRY_SOURCE STALE_H 2>/dev/null || true

held() { [ -e "$1" ] && ! flock -n "$1" true; }
waitfor() { local i=0 n="${2:-100}"; until eval "$1"; do i=$((i + 1)); [ "$i" -ge "$n" ] && return 1; sleep 0.2; done; return 0; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
settle() {
  local l
  for l in "$H/locks/$1"-*.lock; do [ -e "$l" ] && waitfor "! held '$l'" 300; done
  return 0
}
hold_ex() {
  rm -f "$T/hold.ok" "$T/unhold"
  mkdir -p "$(dirname "$1")"
  flock -n "$1" -c "touch '$T/hold.ok'; while [ ! -e '$T/unhold' ]; do sleep 0.1; done" &
  HOLD_PID=$!
  waitfor "[ -e '$T/hold.ok' ]"
}
unhold_ex() { touch "$T/unhold"; wait "$HOLD_PID" 2>/dev/null; rm -f "$T/unhold" "$T/hold.ok"; }

# ═════ F: fleet-status-push ══════════════════════════════════════════════════
FSP="$H/bin/fleet-status-push.sh"
ROWS="$H/state/fleet-status-push"
row() { jq -r "$2" "$ROWS/$1/row.json" 2>/dev/null; }
# F1
for i in 1 2 3 4 5; do bash "$FSP" "p$i" > "$T/f1.out" 2>&1; done
for i in 1 2 3 4 5; do
  eq "F1 p$i row.json is v1 for p$i with queue_depth $i" "$(row "p$i" '"\(.v) \(.project) \(.row.queue_depth)"')" "1 p$i $i"
done
eq "F1 p3's row carries its remote results pending" "$(row p3 .rrp)" 2
eq "F1 p3's row carries its expected lane" "$(row p3 '.lane | "\(.project) \(.cadence_min)"')" "p3 10"
check "F1 a project run pushes nothing" "[ ! -e '$T/PUSH.json' ]"

# F2 — THE FLEET TOTAL
scratch_rm "$ROWS" || exit 1
rm -f "$T/PUSH.json"; : > "$H/logs/fleet-status-push.log"
bash "$FSP" --dispatch > "$T/f2.out" 2>&1
settle fleet-status-push
eq "F2 the push has exactly the 5 projects" "$(jq -r '.projects | keys | join(",")' "$T/PUSH.json" 2>/dev/null)" "p1,p2,p3,p4,p5"
SUMROWS=$(cat "$ROWS"/p*/row.json 2>/dev/null | jq -s '[.[].row.queue_depth] | add')
eq "F2 the row files sum to 15 queued" "$SUMROWS" 15
eq "F2 the pushed fleet total equals the sum of the rows" "$(jq '[.projects[].queue_depth] | add' "$T/PUSH.json" 2>/dev/null)" "$SUMROWS"
eq "F2 remote_results_pending sums the same way" \
  "$(jq '[.remote_results_pending[]] | add' "$T/PUSH.json" 2>/dev/null)" "$(cat "$ROWS"/p*/row.json | jq -s '[.[].rrp] | add')"
check "F2 every row came from its project's own run: $(grep 'dispatch:' "$H/logs/fleet-status-push.log" | tail -1)" \
  "grep -q 'dispatch: 5 project row(s) from their runs, 0 computed here' '$H/logs/fleet-status-push.log'"
cp "$T/PUSH.json" "$T/push-dispatch.json"

# F3 — a v2 row and a missing row are computed by the dispatch
mkdir -p "$H/flags"
touch "$H/flags/lane-off-fleet-status-push-p1" "$H/flags/lane-off-fleet-status-push-p2"
jq -nc --argjson at $((NOW + 99999)) '{v: 2, project: "p1", at: $at, row: {queue_depth: 99}}' > "$ROWS/p1/row.json"
rm -f "$ROWS/p2/row.json"
rm -f "$T/PUSH.json"; : > "$H/logs/fleet-status-push.log"
FLEET_STATUS_PUSH_ROW_WAIT_S=3 bash "$FSP" --dispatch > "$T/f3.out" 2>&1
settle fleet-status-push
eq "F3 the push still has 5 projects" "$(jq -r '.projects | keys | length' "$T/PUSH.json" 2>/dev/null)" 5
eq "F3 the v2 row is not believed: p1 queue_depth is its real 1" "$(jq -r '.projects.p1.queue_depth' "$T/PUSH.json" 2>/dev/null)" 1
eq "F3 the missing row is computed: p2 queue_depth 2" "$(jq -r '.projects.p2.queue_depth' "$T/PUSH.json" 2>/dev/null)" 2
check "F3 3 rows from runs, 2 computed here: $(grep 'dispatch:' "$H/logs/fleet-status-push.log" | tail -1)" \
  "grep -q 'dispatch: 3 project row(s) from their runs, 2 computed here' '$H/logs/fleet-status-push.log'"
rm -f "$H/flags/lane-off-fleet-status-push-p1" "$H/flags/lane-off-fleet-status-push-p2"

# F4 — no wait
rm -f "$T/PUSH.json"; : > "$H/logs/fleet-status-push.log"
FLEET_STATUS_PUSH_ROW_WAIT_S=0 bash "$FSP" --dispatch > "$T/f4.out" 2>&1
settle fleet-status-push
eq "F4 FLEET_STATUS_PUSH_ROW_WAIT_S=0 still pushes 5 projects" "$(jq -r '.projects | keys | length' "$T/PUSH.json" 2>/dev/null)" 5
check "F4 ...after a 0 s wait: $(grep 'dispatch:' "$H/logs/fleet-status-push.log" | tail -1)" \
  "grep -q 'dispatch: .* after 0s' '$H/logs/fleet-status-push.log'"

# F4b — a row wait that is not a number is 60, with one log line
rm -f "$T/PUSH.json"; : > "$H/logs/fleet-status-push.log"
FLEET_STATUS_PUSH_ROW_WAIT_S=abc bash "$FSP" --dispatch > "$T/f4b.out" 2>&1
settle fleet-status-push
check "F4b FLEET_STATUS_PUSH_ROW_WAIT_S=abc is one log line" \
  "grep -q \"FLEET_STATUS_PUSH_ROW_WAIT_S='abc' is not a number of seconds; using 60\" '$H/logs/fleet-status-push.log'"
eq "F4b ...and the push still carries 5 projects" "$(jq -r '.projects | keys | length' "$T/PUSH.json" 2>/dev/null)" 5

# F5 — empty fleet
cp "$H/fleet.conf" "$T/fleet5.conf"; : > "$H/fleet.conf"
rm -f "$T/PUSH.json"; : > "$T/beats"
bash "$FSP" --dispatch > "$T/f5.out" 2>&1
check "F5 an empty fleet.conf posts nothing" "[ ! -e '$T/PUSH.json' ]"
eq "F5 ...and writes no beat" "$(lines "$T/beats")" 0
cp "$T/fleet5.conf" "$H/fleet.conf"

# F6 — the no-arg push is the dispatch push, on the fields the rows own
rm -f "$T/PUSH.json"
bash "$FSP" > "$T/f6.out" 2>&1
PF='.projects | map_values({queue_depth, held, failed, pool, last_line})'
eq "F6 the no-arg run pushed the 5 projects" "$(jq -r '.projects | keys | join(",")' "$T/PUSH.json" 2>/dev/null)" "p1,p2,p3,p4,p5"
eq "F6 the no-arg push equals the dispatch push on .projects" \
  "$(jq -c "$PF" "$T/PUSH.json" 2>/dev/null)" "$(jq -c "$PF" "$T/push-dispatch.json" 2>/dev/null)"
eq "F6 ...and on remote_results_pending" \
  "$(jq -c .remote_results_pending "$T/PUSH.json" 2>/dev/null)" "$(jq -c .remote_results_pending "$T/push-dispatch.json" 2>/dev/null)"

# ═════ M: metrics-collect ════════════════════════════════════════════════════
MC="$H/bin/metrics-collect.sh"
CSV="$H/logs/metrics.csv"
MS="$H/state/metrics-collect"
HDR="build_dir,project,key,started,pr_at,merged_at,result_kind,size,fix_rounds,conflict_defers,duration_min"
mkbuild() { # mkbuild <dir> — a build with a RESULT and a pipeline.log
  mkdir -p "$H/builds/$1"
  printf 'PR_CREATED https://github.com/o/x/pull/1\n' > "$H/builds/$1/RESULT"
  printf '2026-10-13 01:00:00Z start\n2026-10-13 01:20:00Z [x] PR created\n2026-10-13 01:30:00Z end\n' > "$H/builds/$1/pipeline.log"
}
{ conf5; printf 'p1-os o/p1-os - - 2 local\n'; } > "$H/fleet.conf"
for i in 1 2 3 4 5; do mkbuild "p$i-BH-$i-202610130001"; mkbuild "p$i-BH-${i}0-202610130002"; done
mkbuild p1-os-BH-1-202610130009
mkbuild pool-p2-BH-9-202610130011
mkbuild zz-BH-1-202610130010
# The legacy world: a metrics.csv with 4 rows and a seen file that names one
# of the builds above, written by the pre-BH-5944 lane.
{ echo "$HDR"
  echo "p1-BH-1-202610130001,p1,BH-1,2026-10-13 01:00:00Z,,,PR_CREATED,,0,0,30"
  echo "old-1,p1,BH-0,2026-10-01 01:00:00Z,,,PR_MERGED,,0,0,10"
  echo "old-2,p2,BH-0,2026-10-01 01:00:00Z,,,PR_CREATED,,0,0,10"
  echo "old-3,,old-3,,,,PR_CREATED,,0,0,"
} > "$CSV"
printf 'p1-BH-1-202610130001\nold-1\nold-2\nold-3\n' > "$H/state/metrics-seen.txt"
# reopen-metrics.sh's own count of a project's PR rows in metrics.csv.
reopen_count() { awk -F, -v p="$1" 'NR>1 && $2==p && ($7=="PR_MERGED" || $7=="PR_CREATED") { n++ } END { print n+0 }' "$CSV"; }
P1_BEFORE=$(reopen_count p1)

# M1 + M3
bash "$MC" p1 > "$T/m1.out" 2>&1
eq "M1 p1's run wrote rows only for p1's builds (p1-BH-10; p1-BH-1 is legacy-seen)" \
  "$(cut -d, -f1,2 "$MS/p1/rows.csv" 2>/dev/null | paste -sd' ' -)" "p1-BH-10-202610130002,p1"
eq "M1 ...the nested p1-os build is not p1's" "$(grep -c 'p1-os' "$MS/p1/rows.csv" 2>/dev/null)" 0
eq "M3 the cutover kept the 4 legacy rows" "$(lines "$MS/legacy.csv")" 4
eq "M3 the legacy-seen build is in the aggregate once" "$(grep -c '^p1-BH-1-202610130001,' "$CSV")" 1
eq "M3 reopen-metrics' p1 count grew by exactly p1's one new row ($(grep -c ',p1,' "$CSV") p1 lines)" "$(reopen_count p1)" $((P1_BEFORE + 1))
eq "M3 the header is line 1" "$(head -1 "$CSV")" "$HDR"

# M2 — THE FLEET TOTAL
bash "$MC" --dispatch > "$T/m2.out" 2>&1
check "M2 the dispatch started 6 runs: $(cat "$T/m2.out")" "grep -q 'started 6 project run(s)' '$T/m2.out'"
waitfor "[ -s '$MS/p5/rows.csv' ] && [ -s '$MS/p2/rows.csv' ]" 300
settle metrics-collect
SUMR=0; for f in "$MS"/*/rows.csv; do SUMR=$((SUMR + $(lines "$f"))); done
eq "M2 the project rows: 9 new builds (p1-BH-1 is legacy-seen) + p2's pool build + p1-os = 11" "$SUMR" 11
eq "M2 the unresolved bucket holds the build no project owns" "$(cut -d, -f1 "$MS/unresolved.csv" 2>/dev/null)" zz-BH-1-202610130010
eq "M2 THE FLEET TOTAL: data lines = legacy + rows + unresolved" \
  "$(( $(lines "$CSV") - 1 ))" "$(( $(lines "$MS/legacy.csv") + SUMR + $(lines "$MS/unresolved.csv") ))"
eq "M2 the pool build is p2's" "$(grep -c '^pool-p2-BH-9-202610130011,p2,' "$MS/p2/rows.csv" 2>/dev/null)" 1
eq "M2 the header is line 1" "$(head -1 "$CSV")" "$HDR"

# M4 — idempotent
C1=$(cksum < "$CSV")
bash "$MC" --dispatch > "$T/m4.out" 2>&1
sleep 0.5; settle metrics-collect
eq "M4 a second dispatch adds 0 rows" "$(cksum < "$CSV")" "$C1"

# M5 — the agg lock held
mkbuild p3-BH-7-202610130020
C1=$(cksum < "$CSV")
hold_ex "$H/locks/metrics-collect-agg.lock"
PL_TEST_LOCK_WAIT_S=1 bash "$MC" p3 > "$T/m5.out" 2>&1
unhold_ex
eq "M5 p3's own rows grew" "$(grep -c '^p3-BH-7-' "$MS/p3/rows.csv")" 1
eq "M5 logs/metrics.csv is unchanged while the agg lock is held" "$(cksum < "$CSV")" "$C1"
eq "M5 one log line says why" "$(grep -c 'agg lock' "$H/logs/metrics-collect.log")" 1
bash "$MC" p3 > "$T/m5b.out" 2>&1
eq "M5 the next run rebuilds the aggregate" "$(grep -c '^p3-BH-7-' "$CSV")" 1

# M6 — two runs at once
mkbuild p4-BH-8-202610130030; mkbuild p5-BH-8-202610130031
bash "$MC" p4 > "$T/m6a.out" 2>&1 &
bash "$MC" p5 > "$T/m6b.out" 2>&1 &
wait
eq "M6 both projects' rows are in the aggregate" "$(grep -cE '^p[45]-BH-8-' "$CSV")" 2
conf5 > "$H/fleet.conf"

# ═════ S: stale-owed-tickets ═════════════════════════════════════════════════
SO="$H/bin/stale-owed-tickets.sh"
SE="$H/state/stale-owed-tickets"
# S1
for i in 1 2 3 4 5; do bash "$SO" "p$i" > "$T/s1.out" 2>&1; done
for i in 1 2 3 4 5; do
  eq "S1 p$i entry.json counts its $i stale tickets" "$(jq -r '"\(.v) \(.entry.count)"' "$SE/p$i/entry.json" 2>/dev/null)" "1 $i"
done
# S2 — THE FLEET TOTAL
SUME=$(cat "$SE"/p*/entry.json | jq -s '[.[].entry.count] | add')
eq "S2 the entries sum to 15" "$SUME" 15
eq "S2 THE FLEET TOTAL: state/stale-owed.json sums to the entries" "$(jq '[.[].count] | add' "$H/state/stale-owed.json")" "$SUME"
for i in 1 3 5; do
  eq "S2 progress-push's .[\$p].count read answers p$i" "$(jq -r --arg p "p$i" '.[$p].count // 0' "$H/state/stale-owed.json")" "$i"
done
eq "S2 each project's keys were queued once" "$(jq -r 'keys | length' "$H/state/stale-owed-queued.json")" 15

# S3 — a skipped project (no token) is absent from the map
{ conf5; printf 'p6 o/p6 https://p6.example.invalid /api/board 2 local\n'; } > "$H/fleet.conf"
jq -c '. + {p6: {count: 9, tickets: []}}' "$H/state/stale-owed.json" > "$T/so.tmp" && cp "$T/so.tmp" "$H/state/stale-owed.json"
bash "$SO" p6 > "$T/s3.out" 2>&1
eq "S3 the skipped project's entry is null" "$(jq -c '.entry' "$SE/p6/entry.json" 2>/dev/null)" null
eq "S3 ...and its key is gone from the map" "$(jq -r 'has("p6")' "$H/state/stale-owed.json")" false
eq "S3 ...the other five stay" "$(jq -r 'keys | join(",")' "$H/state/stale-owed.json")" "p1,p2,p3,p4,p5"
# S3b — a fleet project with no board: one log line, no row
{ conf5; printf 'p7 o/p7 - - 2 local\n'; } > "$H/fleet.conf"
bash "$SO" p7 > "$T/s3b.out" 2>&1; rc=$?
eq "S3b a project with no board exits 0" "$rc" 0
check "S3b ...writes one log line" "grep -q 'p7: no board in fleet.conf' '$H/logs/stale-owed.log'"
check "S3b ...and no row" "[ ! -e '$SE/p7/entry.json' ]"
conf5 > "$H/fleet.conf"

# S4 — orphan alerts: once per dir (the find) and once per ledger key
mkdir -p "$H/builds/p1-BH-50-202610130050"
printf 'REVIEW_BLOCKED tier 3\n' > "$H/builds/p1-BH-50-202610130050/RESULT"
printf 'the review died\n' > "$H/builds/p1-BH-50-202610130050/review.md"
touch -d "@$((NOW - 7200))" "$H/builds/p1-BH-50-202610130050/RESULT"
UPD=$(date -u -d "@$((NOW - 7200))" +%Y-%m-%dT%H:%M:%S.000Z)
jq -cn --arg u "$UPD" '{artifacts: [{job_id: "J1", artifact_ref: "REVIEW_BLOCKED tier 3", box: "w2", ticket_id: "BH-51",
  updated_at: $u, detail: ({build_dir: "p2-BH-51-20260925", job_status: "done", key: "BH-51"} | tojson)}]}' > "$T/feed-p2.json"
: > "$T/alerts"
bash "$SO" --dispatch > "$T/s4a.out" 2>&1
settle stale-owed-tickets
bash "$SO" --dispatch > "$T/s4b.out" 2>&1
settle stale-owed-tickets
eq "S4 two dispatches: one ORPHANED BUILD line for the dir" "$(grep -c 'ORPHANED BUILD: p1-BH-50-202610130050 ' "$T/alerts")" 1
eq "S4 ...and one for the ledger key" "$(grep -c 'ORPHANED BUILD: p2-BH-51-20260925 (p2 BH-51' "$T/alerts")" 1
eq "S4 ...the ledger key is stamped p2:<dir>" "$(jq -r 'has("p2:p2-BH-51-20260925")' "$H/state/stale-owed-orphans.json")" true

# S5 — two runs at once each queue a key: no lost write
for i in 1 2; do
  jq -c --arg old "$(date -u -d "@$((NOW - 36000))" +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{key: "P-77", title: "new", status: "todo", waitingOn: "team", lastActivityAt: $old}]' \
    "$T/boards/p$i.tickets.json" > "$T/tk.tmp" && cp "$T/tk.tmp" "$T/boards/p$i.tickets.json"
done
bash "$SO" p1 > "$T/s5a.out" 2>&1 &
bash "$SO" p2 > "$T/s5b.out" 2>&1 &
wait
eq "S5 both runs' new keys are in the queued map" \
  "$(jq -r '[has("p1:P-77"), has("p2:P-77")] | map(tostring) | join(",")' "$H/state/stale-owed-queued.json")" "true,true"
eq "S5 ...and no earlier key was lost" "$(jq -r 'keys | length' "$H/state/stale-owed-queued.json")" 17

# S6 — a legacy queued map entry stamped now stops a re-queue
jq -c --argjson now "$NOW" '. + {"p3:P-88": $now}' "$H/state/stale-owed-queued.json" > "$T/q.tmp" && cp "$T/q.tmp" "$H/state/stale-owed-queued.json"
jq -c --arg old "$(date -u -d "@$((NOW - 36000))" +%Y-%m-%dT%H:%M:%SZ)" \
  '. + [{key: "P-88", title: "legacy", status: "todo", waitingOn: "team", lastActivityAt: $old}]' \
  "$T/boards/p3.tickets.json" > "$T/tk.tmp" && cp "$T/tk.tmp" "$T/boards/p3.tickets.json"
bash "$SO" p3 > "$T/s6.out" 2>&1
eq "S6 the legacy-stamped key is counted" "$(jq -r '.entry.count' "$SE/p3/entry.json")" 4
eq "S6 ...and not queued again" "$(grep -c '^P-88 OWED-STALE' "$H/logs/READY-QUEUE.log")" 0

echo "fleet-totals: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
