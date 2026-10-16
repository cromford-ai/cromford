#!/bin/bash
# tests/project-loops.bh-5944-test.sh — BH-5944 (BH-5938.4): six project
# loops on the per-project runner (bin/lib/project-lanes.sh). Each lane's cron
# line is `<lane>.sh --dispatch`; it starts one detached run per fleet project,
# and no project's run waits on another project's lock.
#
# THE RIG. A scratch $H (symlink tree of bin/ and catalog/, a built
# lanes.json, fleet.conf p1..p50). The real lanes, runner and gate run.
# Stubbed: `curl` as the jobs worker (settings empty, everything else 404),
# `gh` (fails), bin/alert-line.sh, bin/lane-alert.sh and bin/beat.sh (record
# argv). PL_DISPATCH_SPREAD_PCT=0 starts every run at once. The barrier seam
# PL_TEST_BARRIER=$T/b:50 makes each run, once it holds BOTH its locks, wait
# until 50 runs hold theirs: a run that waited on another project's lock never
# gets there, and the run writes `<lane> <project>` to $T/b/timeouts.
#
#   L1  pl_lane_lock twice in one runner env: rc 0; a second process: rc 1
#   L2  two projects hold locks/x.lock shared; pl_lane_lock_all is busy, then free
#   L3  a hand run takes locks/x-p1.lock itself
#   L4  pl_agg_lock serialises two writers
#   L5  PL_DISPATCH_SPREAD_PCT=50 of a 600 s window = period 300s
#   L6  the barrier seam: 3 holders, n=3, no timeouts
#   D-<lane> (6) --dispatch: rc 0, `started 50 project run(s)`, returns before
#       the runs reach the barrier (fleet-status-push excepted: it waits for
#       rows by design), then 50 holders, 50 distinct projects, no timeouts. D-<lane>-busy: the fleet lock held exclusive, a project run
#       holds nothing and exits 0.
#   D-dqw2  one observe tick per dispatch, not per project
#   D-afm2  archie-fm's project run holds the fleet lock SHARED
#   D-ra2   review-autopilot's project run beats with its own project and akey
#   U       a bad argument or an unknown project exits 2 with no request
#   C1-C3   the archie-fm day cap is claimed under a lock
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/project-loops.bh-5944-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "project-loops: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "project-loops: flock is required"; exit 1; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${PROJECT_LOOPS_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

LIB="$DIR/bin/lib/project-lanes.sh"
for f in "$LIB" "$DIR/bin/project-lane-run.sh" "$DIR/bin/dequeue-watch.sh" \
         "$DIR/bin/archie-fm.sh" "$DIR/bin/lib/archie-fm.sh" "$DIR/bin/lib/archie-fm-repair.sh" \
         "$DIR/bin/review-autopilot.sh" "$DIR/bin/fleet-status-push.sh" "$DIR/bin/metrics-collect.sh" \
         "$DIR/bin/stale-owed-tickets.sh" "$DIR/catalog/lanes.d/_lib.project-lanes.json"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "project-loops: 0 passed, 1 failed"; exit 1; }
done

# ── the cron lines ───────────────────────────────────────────────────────────
# Each pattern sits in a variable and grep reads it directly, never through
# eval (merge queue batch #6301: a `>> /root/harness/...` inside an eval'd
# string reads as a write to the real harness).
cronline() { # cronline <file> <lane-script> <hub 0|1>
  local re pre='' sch
  sch=$(awk '!/^#/ && NF { print $1, $2, $3, $4, $5; exit }' "$DIR/cron/lanes/$1")
  [ "$3" = 1 ] && pre='/root/harness/bin/hub-lease.sh check && '
  re="^$(printf '%s' "$sch" | sed 's/\*/\\*/g') ${pre}/root/harness/bin/$2 --dispatch >> /root/harness/logs/${2%.sh}-cron.log 2>&1\$"
  [ "$(grep -cE "$re" "$DIR/cron/lanes/$1")" = 1 ]
}
cronline 415-dequeue-watch.cron dequeue-watch.sh 1 && ok cron-dqw || bad "cron: 415-dequeue-watch runs --dispatch into its cron log"
cronline 725-archie-fm.cron archie-fm.sh 1 && ok cron-afm || bad "cron: 725-archie-fm runs --dispatch into its cron log"
cronline 490-review-autopilot.cron review-autopilot.sh 1 && ok cron-ra || bad "cron: 490-review-autopilot runs --dispatch into its cron log"
cronline 270-fleet-status-push.cron fleet-status-push.sh 1 && ok cron-fsp || bad "cron: 270-fleet-status-push runs --dispatch into its cron log"
cronline 130-metrics-collect.cron metrics-collect.sh 0 && ok cron-mc || bad "cron: 130-metrics-collect runs --dispatch into its cron log (no hub lease)"
cronline 300-stale-owed-tickets.cron stale-owed-tickets.sh 1 && ok cron-so || bad "cron: 300-stale-owed-tickets runs --dispatch into its cron log"

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/env" "$T/fakebin" "$T/home"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
: > "$H/env/global.env"
# Stubs replace the symlink first: a write through a symlink lands in the repo.
rm -f "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh" "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/alerts"\nexit 0\n' > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/lane-alerts"\nexit 0\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$FXT/beats"\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; -w) wfmt=1 ;; esac
  prev="$a"
done
url="${!#}"
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
printf '%s %s %s\n' "${PL_PROJECT:--}" "$m" "$path" >> "$FXT/reqs"
code=404; out='{"error":"not found"}'
case "$m $path" in
  "GET /api/settings"|"GET /api/settings?"*) code=200; out='{"settings":[]}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
[ "$code" = 200 ] || [ "$wfmt" = 1 ] || exit 22
exit 0
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/gh.log"\nexit 1\n' > "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

conf50() { local i; for i in $(seq 1 50); do printf 'p%s o/p%s https://p%s.example.invalid /api/board 2 box-p%s 192.0.2.%s\n' "$i" "$i" "$i" "$i" "$i"; done; }
conf50 > "$H/fleet.conf"

export HARNESS="$H" FXT="$T" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test-fixture-secret \
  JOBS_BOX=hub PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 FLEET_CONF="$H/fleet.conf" \
  PL_DISPATCH_SPREAD_PCT=0 HOME="$T/home"
unset GH_TOKEN GITHUB_TOKEN LANE_GATE_DISABLE HARNESS_ENV_DIR WATCHDOG_URL PL_LANE PL_PROJECT PL_LOCK_FD \
  PL_SLUG PL_STATE_DIR PL_TEST_BARRIER PL_TEST_BARRIER_EXIT PL_TEST_LOCK_WAIT_S REGISTRY_SOURCE 2>/dev/null || true

held() { [ -e "$1" ] && ! flock -n "$1" true; }
# waitfor <cmd> [steps] — poll a condition (0.2 s steps, 100 = 20 s by default).
waitfor() { local i=0 n="${2:-100}"; until eval "$1"; do i=$((i + 1)); [ "$i" -ge "$n" ] && return 1; sleep 0.2; done; return 0; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
# settle <lane> — wait until no run of <lane> holds a project lock.
settle() {
  local l
  for l in "$H/locks/$1"-*.lock; do [ -e "$l" ] && waitfor "! held '$l'" 300; done
  return 0
}
# hold_ex <file> — a separate process holds <file> exclusive until unhold_ex.
hold_ex() {
  rm -f "$T/hold.ok" "$T/unhold"
  flock -n "$1" -c "touch '$T/hold.ok'; while [ ! -e '$T/unhold' ]; do sleep 0.1; done" &
  HOLD_PID=$!
  waitfor "[ -e '$T/hold.ok' ]"
}
unhold_ex() { touch "$T/unhold"; wait "$HOLD_PID" 2>/dev/null; rm -f "$T/unhold" "$T/hold.ok"; }

# ═════ L: the library ════════════════════════════════════════════════════════
LX="H='$H'; . '$H/bin/lib/project-lanes.sh'"
mkdir -p "$H/locks"
# L1
bash -c "$LX
  exec 9>\"\$H/locks/x-p1.lock\"; flock -n 9 || exit 9
  export PL_LANE=x PL_PROJECT=p1 PL_LOCK_FD=9
  pl_lane_lock x p1; a=\$?
  pl_lane_lock x p1; b=\$?
  ( unset PL_LANE PL_PROJECT PL_LOCK_FD; exec 9>&-; pl_lane_lock x p1; echo \$? > '$T/l1.second' )
  echo \"\$a \$b\"" > "$T/l1.out" 2>&1 < /dev/null
eq "L1 pl_lane_lock twice in one runner env answers rc 0 both times" "$(cat "$T/l1.out")" "0 0"
eq "L1 a second process for p1 (no runner env) is busy, rc 1" "$(cat "$T/l1.second" 2>/dev/null)" 1

# L2
rm -f "$T/l2."*
for p in p1 p2; do
  bash -c "$LX; pl_lane_lock x $p || exit 3; touch '$T/l2.$p'; while [ ! -e '$T/l2.go' ]; do sleep 0.1; done" &
done
waitfor "[ -e '$T/l2.p1' ] && [ -e '$T/l2.p2' ]"
check "L2 two projects hold locks/x.lock at once (both reached their body)" "[ -e '$T/l2.p1' ] && [ -e '$T/l2.p2' ]"
bash -c "$LX; pl_lane_lock_all x; echo \$?" > "$T/l2.all1" 2>&1
eq "L2 pl_lane_lock_all is busy while project runs hold the shared lock" "$(cat "$T/l2.all1")" 1
touch "$T/l2.go"; wait
bash -c "$LX; pl_lane_lock_all x; echo \$?" > "$T/l2.all2" 2>&1
eq "L2 pl_lane_lock_all takes the lock once they are gone" "$(cat "$T/l2.all2")" 0

# L3
rm -f "$T/l3."*
bash -c "$LX; unset PL_LANE PL_PROJECT PL_LOCK_FD; pl_lane_lock x p1 || exit 3; touch '$T/l3.in'; while [ ! -e '$T/l3.go' ]; do sleep 0.1; done" &
waitfor "[ -e '$T/l3.in' ]"
check "L3 a hand run holds locks/x-p1.lock itself" "held '$H/locks/x-p1.lock'"
check "L3 ...and locks/x.lock shared, not exclusive" "flock -n -s '$H/locks/x.lock' true && ! flock -n '$H/locks/x.lock' true"
touch "$T/l3.go"; wait

# L4
rm -f "$T/l4.out"
for w in A B; do
  bash -c "$LX; pl_agg_lock x || exit 3; for i in \$(seq 1 100); do echo $w >> '$T/l4.out'; [ \$((i % 10)) = 0 ] && sleep 0.02; done; pl_agg_unlock" &
done
wait
eq "L4 two agg-locked writers wrote 200 lines" "$(lines "$T/l4.out")" 200
eq "L4 ...in two unbroken runs (no interleave)" "$(uniq "$T/l4.out" | wc -l | tr -d ' ')" 2

# L5 — the period, read off what pl_dispatch was called with.
bash -c "$LX; pl_dispatch() { echo \"period \$2s cmd \$3\"; }; PL_DISPATCH_SPREAD_PCT=50 pl_lane_dispatch x 600 /bin/true" > "$T/l5.out" 2>&1
eq "L5 PL_DISPATCH_SPREAD_PCT=50 of a 600 s window" "$(cat "$T/l5.out")" "period 300s cmd /bin/true"
bash -c "$LX; pl_dispatch() { echo \"period \$2s\"; }; PL_DISPATCH_SPREAD_PCT=abc pl_lane_dispatch x 600 /bin/true 2>/dev/null" > "$T/l5b.out"
eq "L5 a non-number spread is 100" "$(cat "$T/l5b.out")" "period 600s"

# L6
scratch_rm "$T/b6"; mkdir -p "$T/b6"
for p in p1 p2 p3; do
  bash -c "$LX; PL_TEST_BARRIER='$T/b6:3' pl_lane_lock y $p" &
done
wait
eq "L6 three holders wrote three lines" "$(lines "$T/b6/holders")" 3
check "L6 ...and none timed out" "[ ! -e '$T/b6/timeouts' ]"

# ═════ D: every lane, 50 projects, one dispatch ══════════════════════════════
# dcase <tag> <lane> <script> [VAR=value ...] — the cron line's command with the
# barrier armed; asserts the dispatch line, its return order, and the holders.
dcase() {
  local tag="$1" lane="$2" script="$3" s0 rc n0 n
  shift 3
  scratch_rm "$T/b" || exit 1
  mkdir -p "$T/b"
  s0=$SECONDS
  env PL_TEST_BARRIER="$T/b:50" PL_TEST_BARRIER_EXIT=1 "$@" bash "$H/bin/$script" --dispatch > "$T/d.out" 2>&1
  rc=$?
  n0=$(lines "$T/b/holders")
  eq "D-$tag --dispatch rc" "$rc" 0
  check "D-$tag the dispatch line says started 50 project run(s): $(head -c 300 "$T/d.out")" \
    "grep -q 'started 50 project run(s)' '$T/d.out'"
  # The dispatch never waits on a run (#6528 order): it is back while runs are
  # still short of the barrier. fleet-status-push is the one dispatch that
  # waits, for the rows, by design (F2-F4); its row wait is 0 here and it
  # computes all 50 rows itself, so it is checked for the runs, not the order.
  # The wall bound is loose on purpose (BH-5913's dispatch reads 50 cold hold
  # flags on a box the 50 starting runs load): it catches a dispatch that
  # waited out the 60 s barrier, not a slow box. 55 s, not 30 s: a loaded box
  # took 47 s with no code change (lead review of #7000); a wait on the
  # barrier is 60 s or more.
  if [ "$tag" != fsp ]; then
    check "D-$tag --dispatch returned before every run held its locks (holders at return: $n0)" "[ '$n0' -lt 50 ]"
    check "D-$tag --dispatch returns in under 55 s ($((SECONDS - s0)) s)" "[ \$((SECONDS - s0)) -lt 55 ]"
  fi
  waitfor "[ \$(lines '$T/b/holders') -ge 50 ]" 350
  n=$(lines "$T/b/holders")
  eq "D-$tag 50 runs held both their locks at once" "$n" 50
  eq "D-$tag ...50 distinct projects" "$(awk '{print $2}' "$T/b/holders" 2>/dev/null | sort -u | wc -l | tr -d ' ')" 50
  eq "D-$tag ...all of lane $lane" "$(awk -v l="$lane" '$1 != l' "$T/b/holders" 2>/dev/null | wc -l | tr -d ' ')" 0
  check "D-$tag ...and no run waited out the barrier (no timeouts)" "[ ! -e '$T/b/timeouts' ]"
  settle "$lane"
}
# bcase <tag> <lane> <state-path> <script> [args...] — the fleet lock held
# exclusive: the project run holds nothing (no barrier line) and writes no
# state. The same run with the lock free reaches the barrier (not vacuous).
bcase() {
  local tag="$1" lane="$2" st="$3" rc
  shift 3
  scratch_rm "$T/b" || exit 1
  mkdir -p "$T/b" "$H/locks"
  hold_ex "$H/locks/$lane.lock"
  PL_TEST_BARRIER="$T/b:1" PL_TEST_BARRIER_EXIT=1 bash "$@" > "$T/busy.out" 2>&1; rc=$?
  unhold_ex
  eq "D-$tag-busy rc with locks/$lane.lock held exclusive" "$rc" 0
  eq "D-$tag-busy ...the run took no lock (no barrier line)" "$(lines "$T/b/holders")" 0
  check "D-$tag-busy ...and wrote no state ($st)" "[ ! -e '$st' ]"
  PL_TEST_BARRIER="$T/b:1" PL_TEST_BARRIER_EXIT=1 bash "$@" > "$T/busy2.out" 2>&1
  eq "D-$tag-busy ...the same run with the lock free reaches the barrier" "$(lines "$T/b/holders")" 1
}

dcase dqw dequeue-watch dequeue-watch.sh
scratch_rm "$H/state/observe-report" || exit 1
bcase dqw dequeue-watch "$H/state/observe-report/dequeue-watch.json" "$H/bin/dequeue-watch.sh" p1
check "D-dqw-busy the busy run wrote its summary 'locked'" "grep -q ' locked project=p1$' '$H/logs/dequeue-watch.log'"


dcase afm archie-fm archie-fm.sh
bcase afm archie-fm "$H/logs/archie-fm.log" "$H/bin/archie-fm.sh" tick --project p1

dcase ra review-autopilot review-autopilot.sh
bcase ra review-autopilot "$H/state/review-autopilot/count-p1-x" "$H/bin/review-autopilot.sh" p1

dcase fsp fleet-status-push fleet-status-push.sh FLEET_STATUS_PUSH_ROW_WAIT_S=0
scratch_rm "$H/state/fleet-status-push" || exit 1
bcase fsp fleet-status-push "$H/state/fleet-status-push/p1/row.json" "$H/bin/fleet-status-push.sh" p1

dcase mc metrics-collect metrics-collect.sh
scratch_rm "$H/state/metrics-collect" || exit 1
bcase mc metrics-collect "$H/state/metrics-collect/p1/rows.csv" "$H/bin/metrics-collect.sh" p1

dcase so stale-owed-tickets stale-owed-tickets.sh
scratch_rm "$H/state/stale-owed-tickets" || exit 1
bcase so stale-owed-tickets "$H/state/stale-owed-tickets/p1/entry.json" "$H/bin/stale-owed-tickets.sh" p1

# ═════ D-dqw2: one observe tick per dispatch ═════════════════════════════════
cp "$H/fleet.conf" "$T/fleet50.conf"
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\np2 o/p2 - - 2 box-p2 192.0.2.2\np3 o/p3 - - 2 box-p3 192.0.2.3\n' > "$H/fleet.conf"
scratch_rm "$H/state/observe-report" || exit 1
: > "$H/logs/dequeue-watch.log"
bash "$H/bin/dequeue-watch.sh" --dispatch > "$T/dqw2.out" 2>&1
check "D-dqw2 the dispatch started 3 runs: $(cat "$T/dqw2.out")" "grep -q 'started 3 project run(s)' '$T/dqw2.out'"
waitfor "[ \$(grep -c ' tick .*project=' '$H/logs/dequeue-watch.log') -ge 3 ]" 300
settle dequeue-watch
eq "D-dqw2 three project summaries, each naming its project" \
  "$(grep -oE ' project=p[0-9]+$' "$H/logs/dequeue-watch.log" | sort -u | tr -d ' ' | paste -sd, -)" "project=p1,project=p2,project=p3"
eq "D-dqw2 the observe counter is 1 after one dispatch of 3 projects" \
  "$(jq -r '.ticks' "$H/state/observe-report/dequeue-watch.json" 2>/dev/null)" 1

cp "$T/fleet50.conf" "$H/fleet.conf"

# ═════ D-afm2: archie-fm holds the fleet lock SHARED ═════════════════════════
scratch_rm "$T/b" || exit 1
mkdir -p "$T/b"
PL_TEST_BARRIER="$T/b:2" PL_TEST_BARRIER_EXIT=1 bash "$H/bin/archie-fm.sh" tick --project p1 > "$T/afm2.out" 2>&1 &
AFM_PID=$!
waitfor "[ \$(lines '$T/b/holders') -ge 1 ]"
check "D-afm2 the run waits at the barrier" "[ \$(lines '$T/b/holders') = 1 ]"
check "D-afm2 locks/archie-fm-p1.lock is held" "held '$H/locks/archie-fm-p1.lock'"
check "D-afm2 a shared flock on locks/archie-fm.lock succeeds" "flock -n -s '$H/locks/archie-fm.lock' true"
check "D-afm2 an exclusive flock on locks/archie-fm.lock fails" "! flock -n '$H/locks/archie-fm.lock' true"
echo "release - 0" >> "$T/b/holders"
wait "$AFM_PID"

# ═════ D-ra2: the end beat carries the project ═══════════════════════════════
SHA=0123456789abcdef0123456789abcdef01234567
# ONE clock read: review-autopilot judges age on the real clock (12 h cutoff).
NOW=$(date -u +%s)
CREATED=$(date -u -d "@$((NOW - 46800))" '+%Y-%m-%dT%H:%M:%SZ')
printf '{"resources":{"core":{"limit":5000,"remaining":4999,"reset":%s},"graphql":{"limit":5000,"remaining":4999,"reset":%s}}}\n' \
  "$((NOW + 3600))" "$((NOW + 3600))" > "$T/rate.json"
jq -n --arg sha "$SHA" --arg c "$CREATED" \
  '[{number:7,html_url:"https://github.com/o/p1/pull/7",title:"BH-1: a thing",
     body:"Closes #7",head:{sha:$sha,ref:"ticket/bh-1"},base:{ref:"main"},
     draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
     merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$T/pulls.json"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gh.log"
[ "${1:-}" = pr ] && [ "${2:-}" = comment ] && exit 0
case "$*" in
  "api rate_limit"*) cat "$FXT/rate.json" ;;
  *repos/o/p1/pulls*) case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac; cat "$FXT/pulls.json" ;;
  *"pr diff"*--name-only*) printf 'bin/x.sh\n' ;;
  *"pr diff"*) printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*) printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
  *repos/o/p1*) printf '{"full_name":"o/p1","permissions":{"pull":true}}\n' ;;
esac
exit 0
SH
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf 'Nothing deferred.\n\nVERDICT: MERGE — reads fine\n' > "$5"
exit 0
SH
chmod +x "$T/fakebin/gh" "$H/bin/agent-call.sh"
mrs_cache_1523 "$H" p1
# The earlier runs cached an unreadable GitHub budget under a failing gh.
scratch_rm "$H/state/gh-budget" || exit 1
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
: > "$T/beats"
REVIEW_DEDUPE=0 bash "$H/bin/review-autopilot.sh" p1 > "$T/ra2.out" 2>&1
BEAT=$(grep '"kind":"pr_review"' "$T/beats" | tail -1)
eq "D-ra2 the end beat's project is p1 ($(tail -3 "$H/logs/review-autopilot.log" 2>/dev/null | tr '\n' ' '))" \
  "$(jq -r '.project' <<<"${BEAT:-null}" 2>/dev/null)" p1
check "D-ra2 ...and its akey starts review-autopilot:p1:" \
  "jq -e '.akey | startswith(\"review-autopilot:p1:\")' <<<'${BEAT:-null}' >/dev/null 2>&1"
cp "$T/fleet50.conf" "$H/fleet.conf"

# ═════ U: a bad argument or an unknown project exits 2 before any request ════
for u in "dequeue-watch.sh" "review-autopilot.sh" "fleet-status-push.sh" \
         "metrics-collect.sh" "stale-owed-tickets.sh"; do
  : > "$T/reqs"
  bash "$H/bin/$u" nosuch > "$T/u.out" 2>&1; rc=$?
  eq "U $u nosuch (not in fleet.conf) exits 2" "$rc" 2
  eq "U $u nosuch made no worker request" "$(lines "$T/reqs")" 0
  bash "$H/bin/$u" p1 p2 > "$T/u.out" 2>&1; rc=$?
  eq "U $u with two arguments exits 2" "$rc" 2
done
: > "$T/reqs"
bash "$H/bin/archie-fm.sh" tick --project nosuch > "$T/u.out" 2>&1; rc=$?
eq "U archie-fm.sh tick --project nosuch exits 2" "$rc" 2
eq "U archie-fm.sh --project nosuch made no worker request" "$(lines "$T/reqs")" 0
# The operator's half of an unposted-terminal alert (BH-4156) takes 4 arguments;
# the mode parser takes 0 or 1. --print-body must reach the ledger read, never
# the mode usage (lead review of #7000: rc 2 on c06b76aa5).
bash "$H/bin/review-autopilot.sh" --print-body o/r 7 0123456789ab > "$T/pb.out" 2>&1; rc=$?
check "U review-autopilot.sh --print-body o/r 7 <head12> does not exit 2 (rc $rc: $(head -c 200 "$T/pb.out"))" "[ '$rc' != 2 ]"
check "U ...it reached the ledger read" "grep -q 'no cached review body for o/r#7@0123456789ab' '$T/pb.out'"
check "U ...and did not print the mode usage" "! grep -q 'dispatch | <project>' '$T/pb.out'"
bash "$H/bin/review-autopilot.sh" --print-body o/r 7 > "$T/pb.out" 2>&1; rc=$?
eq "U review-autopilot.sh --print-body with a missing head12 exits 2" "$rc" 2
check "U ...with the --print-body usage" "grep -q 'print-body <owner/repo> <num> <head12>' '$T/pb.out'"

# ═════ C: the archie-fm day cap, claimed under a lock ═════════════════════════
# A worker stub in-process: GET counts answer from the POSTs made so far (after
# 0.5 s, the window a read-then-claim race needs); POST appends one line.
cat > "$T/afm-cap.sh" <<'SH'
H="$CAP_H"; AFM_H="$CAP_H"; AFM_LOG="$CAP_T/afm-cap.log"; NOW=1791184500; DAY=2026-10-05
AFM_RETRY_S=1800; AFM_MAX_ATT=3
. "$CAP_H/bin/lib/archie-fm.sh" || exit 9
setting_get() { [ "$1" = "archie.cap.$AFM_PLAYBOOK" ] || return 2; cat "$CAP_T/cap"; }
_jobs_req() {
  local n
  case "$1 $2" in
    "GET /api/archie/actions"*)
      sleep 0.5
      n=$(wc -l < "$CAP_T/posts" | tr -d ' ')
      JOBS_HTTP=200
      printf '{"count_by":"action","counts":{"stacked-parent-merged":{"on":{"restack":%s}}}}' "$n"; return 0 ;;
    "POST /api/archie/actions")
      echo "$3" >> "$CAP_T/posts"; JOBS_HTTP=201
      jq -c '{ok: true, created: true, action: (. + {id: 1, attempts: 1})}' <<<"$3"; return 0 ;;
  esac
  JOBS_HTTP=404; return 2
}
afm_cap_claim p1 afm_claim "k-$1" p1 o/p1 "$1" on restack "stacked on #1, which merged" '{}'
echo "rc=$?" >> "$CAP_T/afm-cap.rc"
SH
capcase() { # capcase <cap> — two concurrent claimers
  : > "$T/posts"; : > "$T/afm-cap.rc"; : > "$T/afm-cap.log"; printf '%s' "$1" > "$T/cap"
  CAP_H="$H" CAP_T="$T" bash "$T/afm-cap.sh" 11 &
  CAP_H="$H" CAP_T="$T" bash "$T/afm-cap.sh" 12 &
  wait
}
capcase 1
eq "C1 cap 1, used 0, two concurrent claimers: exactly 1 claim POST" "$(lines "$T/posts")" 1
eq "C1 ...one claimer rc 0, the other rc 100" "$(sort "$T/afm-cap.rc" | paste -sd' ' -)" "rc=0 rc=100"
check "C1 ...and the refused one logged the cap" "grep -q 'cap reached (1 of 1' '$T/afm-cap.log'"
capcase 3
eq "C2 cap 3, used 0, two concurrent claimers: 2 claim POSTs" "$(lines "$T/posts")" 2
: > "$T/posts"; : > "$T/afm-cap.rc"; : > "$T/afm-cap.log"; printf 1 > "$T/cap"
hold_ex "$H/locks/archie-fm-cap-stacked-parent-merged.lock"
CAP_H="$H" CAP_T="$T" PL_TEST_LOCK_WAIT_S=1 bash "$T/afm-cap.sh" 13
unhold_ex
eq "C3 the cap lock held past the wait: rc 100" "$(cat "$T/afm-cap.rc")" "rc=100"
eq "C3 ...one 'cap lock' log line" "$(grep -c 'cap lock' "$T/afm-cap.log")" 1
eq "C3 ...and no claim POST" "$(lines "$T/posts")" 0

echo "project-loops: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
