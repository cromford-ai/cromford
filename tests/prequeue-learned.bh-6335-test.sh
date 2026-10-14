#!/bin/bash
# tests/prequeue-learned.bh-6335-test.sh — bin/prequeue-learned.sh (BH-6335)
# driven against a scratch harness. The lane closure is installed with
# scratch_install_closure; the GitHub reads are stub libs written FIRST (the
# install never clobbers them): gh_ci_api serves fixture run pages, and
# flaky_run_tests_strict serves a fixture tagged test list and rc per run.
# Time is injected with NOW. Records are written by the real --refresh.
#
# WHAT IT PINS (plan "Acceptance tests", L1-L8, plus K1b and the exit paths):
#   L1 only failed mergify/merge-queue/ runs are recorded, in the record format
#   L2 a recorded run is never read again
#   L3 a log read rc 2 is a strike, not a record; 3 strikes = `unreadable` record
#   L4 budget low, or a runs page unreadable: rc 0, no record, one log line
#   L5 PREQUEUE_LEARNED_MAX caps a tick, oldest first, the rest are deferred
#   L6 round trip: --refresh writes, --list and --why read; MIN moves the cut
#   L7 the decision table: 20 in, 19 out, all-old out, 20-of-21 in, TOP and
#      ties by name, a bad head line skipped, an unreadable record counts nothing
#   L8 only P-tagged tests/*.sh names reach a record
#   L9 a record that cannot be written is logged and read again next tick
#   L10 prune: records and strike files created over 30 days ago go
#   L11 --list with no records dir: rc 0, no output; a bad argument: rc 2
#   K1b the lane fragment's knobs and defaults; the cron fragment's gate
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=1791000000
DAY=86400
iso() { jq -rn --argjson t "$(( NOW - $1 ))" '$t | todate'; }

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx"
# Stubs first: scratch_install_closure never clobbers a file already there.
cat > "$HH/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_knob() { printf '%s' "${!2:-}"; }
SH
cat > "$HH/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return "${FAKE_BUDGET_LOW:-1}"; }
SH
cat > "$HH/bin/lib/gh-repo-token.sh" <<'SH'
gh_repo_use_token() { return 0; }
gh_repo_token_reset() { :; }
SH
cat > "$HH/bin/lib/gh-ci-read.sh" <<'SH'
gh_ci_api() { # gh_ci_api <repo> -X GET <path> -f k=v ... — every call to calls.txt
  echo "$*" >> "$HARNESS/calls.txt"
  local pg=1 a
  for a in "$@"; do case "$a" in page=*) pg="${a#page=}" ;; esac; done
  [ -r "$HARNESS/fx/runs.$pg.json" ] || return 1
  cat "$HARNESS/fx/runs.$pg.json"
}
SH
cat > "$HH/bin/lib/flaky.sh" <<'SH'
flaky_run_tests_strict() { # <slug> <id> — fx/t.<id> lines, rc from fx/rc.<id>
  echo "$2" >> "$HARNESS/flaky-calls.txt"
  local rc=0
  [ -r "$HARNESS/fx/rc.$2" ] && rc=$(cat "$HARNESS/fx/rc.$2")
  [ "$rc" = 0 ] || return "$rc"
  [ -r "$HARNESS/fx/t.$2" ] && cat "$HARNESS/fx/t.$2"
  return 0
}
SH
scratch_install_closure bin/prequeue-learned.sh "$HH" >/dev/null \
  || { echo "FAIL: cannot install the lane closure (bin/prequeue-learned.sh)"; echo "prequeue-learned: 0 passed, 1 failed"; exit 1; }

RUNS=""
run() { # run <id> <head_branch> <conclusion> <age-seconds> [attempt]
  RUNS="$RUNS${RUNS:+,}{\"id\":$1,\"head_branch\":\"$2\",\"conclusion\":\"$3\",\"status\":\"completed\",\"event\":\"pull_request\",\"created_at\":\"$(iso "$4")\",\"run_attempt\":${5:-1}}"
  jq -n --argjson r "[$RUNS]" '{total_count: ($r | length), workflow_runs: $r}' > "$HH/fx/runs.1.json"
}
fails() { # fails <id> <path>... — the run's log names these harness suites (P tag)
  local id="$1"; shift
  : > "$HH/fx/t.$id"
  for p in "$@"; do printf 'P\t%s\n' "$p" >> "$HH/fx/t.$id"; done
}
MQ=mergify/merge-queue/main/pr-1
batch() { # batch <first-id> <n> <age-seconds> <path>... — n failed batches naming the paths
  local i
  for (( i = $1; i < $1 + $2; i++ )); do run "$i" "$MQ-$i" failure "$3"; fails "$i" "${@:4}"; done
}
reset() { RUNS=""; local p; for p in fx state logs calls.txt flaky-calls.txt; do scratch_rm "$HH/$p"; done; mkdir -p "$HH/fx" "$HH/logs"; }
drive() { # drive [ENV=val...] — one --refresh tick
  rm -f "$HH/calls.txt"
  ( export HARNESS="$HH" NOW
    [ $# -gt 0 ] && export "${@?}"
    bash "$HH/bin/prequeue-learned.sh" --refresh ) >"$T/out.txt" 2>&1
  RC=$?
}
list() { # list [ENV=val...] -- [args...] — stdout to $T/list.txt, stderr to $T/list.err
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$HH/calls.txt"
  ( export NOW
    unset HARNESS
    [ ${#envs[@]} -gt 0 ] && export "${envs[@]}"
    bash "$HH/bin/prequeue-learned.sh" --list "$@" --harness "$HH" ) >"$T/list.txt" 2>"$T/list.err"
  LRC=$?
}
REC="$HH/state/prequeue-learned/runs"
LOG="$HH/logs/prequeue-learned.log"
lastlog() { tail -1 "$LOG" 2>/dev/null; }
nlog() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi; }
fcalls() { if [ -f "$HH/flaky-calls.txt" ]; then grep -cx -- "$1" "$HH/flaky-calls.txt"; else echo 0; fi; }
gcalls() { if [ -f "$HH/calls.txt" ]; then wc -l < "$HH/calls.txt" | tr -d ' '; else echo 0; fi; }
nrec() { find "$REC" -maxdepth 1 -type f ! -name '*.strikes' ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

# ── L1: one merge-queue failure, one merge-queue success, three failures on
#    other branches (a PR branch, another mergify/ prefix, the prefix not at the start)
reset
run 101 "$MQ" failure 3600 2
fails 101 tests/a.sh tests/mc/b.sh
run 102 mergify/merge-queue/main/pr-2 success 3500
fails 102 tests/a.sh
run 103 ticket/bh-1 failure 3400
fails 103 tests/a.sh
run 104 mergify/other/x failure 3300
fails 104 tests/a.sh
run 105 feature/mergify/merge-queue/y failure 3200
fails 105 tests/a.sh
drive
[ "$RC" = 0 ] && ok || bad "L1: rc must be 0, got $RC ($(cat "$T/out.txt"))"
[ "$(nrec)" = 1 ] && [ -f "$REC/101" ] && ok || bad "L1: exactly one record, for run 101: $(ls "$REC" 2>&1)"
[ "$(head -1 "$REC/101" 2>/dev/null)" = "run 101 created $(( NOW - 3600 )) attempt 2" ] && ok \
  || bad "L1: the head line is 'run <id> created <epoch> attempt <n>': $(head -1 "$REC/101" 2>/dev/null)"
[ "$(tail -n +2 "$REC/101" 2>/dev/null | sort | tr '\n' ' ')" = "tests/a.sh tests/mc/b.sh " ] && ok \
  || bad "L1: the record holds the run's suites, one per line: $(cat "$REC/101" 2>/dev/null)"
[ "$(fcalls 102)" = 0 ] && [ "$(fcalls 103)" = 0 ] && [ "$(fcalls 104)" = 0 ] && [ "$(fcalls 105)" = 0 ] && ok \
  || bad "L1: a success or a run off mergify/merge-queue/ is never read"
grep -q -- '-f created=>=' "$HH/calls.txt" && grep -q 'actions/workflows/harness-ci.yml/runs' "$HH/calls.txt" && ok \
  || bad "L1: the runs read asks harness-ci.yml with a created>= window: $(cat "$HH/calls.txt" 2>/dev/null)"
lastlog | grep -q 'prequeue-learned: failed-batches=1 recorded=1 unread=0 deferred=0 pages=1' && ok \
  || bad "L1: one log line with the tick's counts: $(lastlog)"

# ── L2: a second tick does not read run 101 again
drive
[ "$(fcalls 101)" = 1 ] && ok || bad "L2: a recorded run is never read again (calls=$(fcalls 101))"
lastlog | grep -q 'failed-batches=1 recorded=0 unread=0 deferred=0' && ok || bad "L2: nothing new recorded: $(lastlog)"

# ── L3: rc 2 three times = an unreadable record, then never read again
reset
run 201 "$MQ" failure 3600
fails 201 tests/a.sh
echo 2 > "$HH/fx/rc.201"
drive
[ "$RC" = 0 ] && [ ! -f "$REC/201" ] && [ "$(cat "$REC/201.strikes" 2>/dev/null | awk '{print $2}')" = 1 ] && ok \
  || bad "L3: rc 2 writes no record and one strike: rc=$RC $(ls "$REC" 2>&1) $(cat "$REC/201.strikes" 2>/dev/null)"
lastlog | grep -q 'recorded=0 unread=1' && ok || bad "L3: the tick logs unread=1: $(lastlog)"
drive
[ ! -f "$REC/201" ] && [ "$(awk '{print $2}' "$REC/201.strikes" 2>/dev/null)" = 2 ] && ok || bad "L3: second strike, still no record"
drive
[ "$(head -1 "$REC/201" 2>/dev/null)" = "run 201 created $(( NOW - 3600 )) attempt 1 unreadable" ] && ok \
  || bad "L3: the third strike writes an unreadable record: $(cat "$REC/201" 2>/dev/null)"
[ "$(wc -l < "$REC/201" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "L3: an unreadable record has no suite line"
[ ! -e "$REC/201.strikes" ] && ok || bad "L3: the strike file goes once the record is written"
drive
[ "$(fcalls 201)" = 3 ] && ok || bad "L3: an unreadable record is never read again (calls=$(fcalls 201))"

# ── L4: budget low, page unreadable, page not JSON — rc 0, no record, one log line
reset
run 301 "$MQ" failure 3600
fails 301 tests/a.sh
drive FAKE_BUDGET_LOW=0
[ "$RC" = 0 ] && [ "$(gcalls)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(nlog)" = 1 ] && ok \
  || bad "L4: budget low: rc 0, no read, no record, one log line (rc=$RC reads=$(gcalls) recs=$(nrec) log=$(nlog))"
lastlog | grep -q 'budget' && ok || bad "L4: the budget line names the budget: $(lastlog)"
rm -f "$HH/fx/runs.1.json"
drive
[ "$RC" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(nlog)" = 2 ] && lastlog | grep -q 'page 1 unreadable' && ok \
  || bad "L4: page unreadable: rc 0, no record, one log line (rc=$RC $(lastlog))"
echo 'not json' > "$HH/fx/runs.1.json"
drive
[ "$RC" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(nlog)" = 3 ] && ok || bad "L4: a page that is not JSON is unreadable (rc=$RC $(lastlog))"
[ "$(fcalls 301)" = 0 ] && ok || bad "L4: no log read on any of these paths"

# ── L5: MAX=1 and three new runs: the oldest is recorded, two deferred
reset
run 503 "$MQ-3" failure 1000; fails 503 tests/a.sh
run 501 "$MQ-1" failure 3000; fails 501 tests/a.sh
run 502 "$MQ-2" failure 2000; fails 502 tests/a.sh
drive PREQUEUE_LEARNED_MAX=1
[ "$(nrec)" = 1 ] && [ -f "$REC/501" ] && ok || bad "L5: one record, the oldest run (501): $(ls "$REC" 2>&1)"
lastlog | grep -q 'failed-batches=3 recorded=1 unread=0 deferred=2' && ok || bad "L5: deferred=2: $(lastlog)"

# ── L6: round trip — 21 runs name tests/a.sh, 5 of them also tests/mc/b.sh
reset
batch 600 5 7200 tests/a.sh tests/mc/b.sh
batch 605 16 3600 tests/a.sh
drive
lastlog | grep -q 'failed-batches=21 recorded=20 unread=0 deferred=1' && ok || bad "L6: MAX 20 per tick, one deferred: $(lastlog)"
drive
lastlog | grep -q 'recorded=1 unread=0 deferred=0' && ok || bad "L6: the deferred run drains next tick: $(lastlog)"
[ "$(nrec)" = 21 ] && ok || bad "L6: 21 records on disk (got $(nrec))"
list
[ "$LRC" = 0 ] && [ "$(cat "$T/list.txt")" = "tests/a.sh" ] && ok || bad "L6: --list prints tests/a.sh (rc=$LRC '$(cat "$T/list.txt")')"
[ "$(gcalls)" = 0 ] && ok || bad "L6: --list never reads GitHub"
list -- --why
grep -qx "21$(printf '\t')tests/a.sh" "$T/list.txt" && grep -qx "5$(printf '\t')tests/mc/b.sh" "$T/list.txt" && ok \
  || bad "L6: --why prints count<TAB>suite rows: $(cat "$T/list.txt")"
list PREQUEUE_LEARNED_MIN=5 --
[ "$(cat "$T/list.txt")" = "tests/a.sh,tests/mc/b.sh" ] && ok || bad "L6: MIN=5 lists both, count desc: '$(cat "$T/list.txt")'"

# ── L7: the decision table
reset
batch 700 19 3600 tests/in20.sh tests/out19.sh   # 19 name both
batch 719 1 3600 tests/in20.sh                   # the 20th names only in20
batch 720 25 $(( 8 * DAY )) tests/old.sh         # all older than 7 days
batch 750 20 3600 tests/edge.sh                  # 20 inside the window ...
batch 770 1 $(( 8 * DAY )) tests/edge.sh         # ... and one outside: 20 of 21
drive PREQUEUE_LEARNED_MAX=100
[ "$(nrec)" = 66 ] && ok || bad "L7: setup: 66 records (got $(nrec))"
list
[ "$(cat "$T/list.txt")" = "tests/edge.sh,tests/in20.sh" ] && ok \
  || bad "L7: 20 in (tie by name), 19 out, 25-all-old out, 20-of-21 in: '$(cat "$T/list.txt")'"
list -- --why
grep -qx "19$(printf '\t')tests/out19.sh" "$T/list.txt" && ! grep -q 'tests/old.sh' "$T/list.txt" && ok \
  || bad "L7: --why counts out19 at 19 and nothing for the old runs: $(cat "$T/list.txt")"
printf 'garbage head\ntests/in20.sh\n' > "$REC/799"
printf 'run 798 created %s attempt 1 unreadable\ntests/u.sh\n' "$(( NOW - 3600 ))" > "$REC/798"
list PREQUEUE_LEARNED_MIN=1 -- --why
grep -qx "20$(printf '\t')tests/in20.sh" "$T/list.txt" && ok || bad "L7: a bad head line is skipped: $(grep in20 "$T/list.txt")"
grep -q '1 record' "$T/list.err" && [ "$(wc -l < "$T/list.err" | tr -d ' ')" = 1 ] && ok \
  || bad "L7: one stderr line counts the skipped record: $(cat "$T/list.err")"
! grep -q 'tests/u.sh' "$T/list.txt" && ok || bad "L7: an unreadable record counts no suite"
reset
batch 800 1 3600 tests/s01.sh tests/s02.sh tests/s03.sh tests/s04.sh tests/s05.sh tests/s06.sh \
  tests/s07.sh tests/s08.sh tests/s09.sh tests/s10.sh tests/s11.sh tests/s12.sh
batch 801 1 3600 tests/s12.sh tests/s11.sh
drive
list PREQUEUE_LEARNED_MIN=1 --
[ "$(cat "$T/list.txt")" = "tests/s11.sh,tests/s12.sh,tests/s01.sh,tests/s02.sh,tests/s03.sh,tests/s04.sh,tests/s05.sh,tests/s06.sh,tests/s07.sh,tests/s08.sh" ] \
  && ok || bad "L7: TOP=10 of 12: count desc, then name asc: '$(cat "$T/list.txt")'"
list PREQUEUE_LEARNED_MIN=1 PREQUEUE_LEARNED_TOP=2 --
[ "$(cat "$T/list.txt")" = "tests/s11.sh,tests/s12.sh" ] && ok || bad "L7: TOP=2 takes the first two: '$(cat "$T/list.txt")'"
list PREQUEUE_LEARNED_MIN=1 PREQUEUE_LEARNED_DAYS=0 --
[ "$(tr ',' '\n' < "$T/list.txt" | wc -l | tr -d ' ')" = 10 ] && ok || bad "L7: a bad DAYS falls to the default 7: '$(cat "$T/list.txt")'"

# ── L8: only P-tagged tests/*.sh names reach a record
reset
run 901 "$MQ" failure 3600
printf 'J\tjob:Pure-logic gate fixtures\nP\tsrc/x.test.ts\nT\ttests/title.sh\nP\ttests/ok.sh\nP\ttests/sub/deep.sh\nP\ttests/mc/m.sh\nP\ttests/ok.sh\n' > "$HH/fx/t.901"
drive
[ "$(tail -n +2 "$REC/901" 2>/dev/null | sort | tr '\n' ' ')" = "tests/mc/m.sh tests/ok.sh " ] && ok \
  || bad "L8: only tests/*.sh and tests/mc/*.sh paths, deduped: $(cat "$REC/901" 2>/dev/null)"
run 902 "$MQ-2" failure 3000
printf 'J\tjob:Pure-logic gate fixtures\n' > "$HH/fx/t.902"
drive
[ "$(cat "$REC/902" 2>/dev/null)" = "run 902 created $(( NOW - 3000 )) attempt 1" ] && ok \
  || bad "L8: a read log with no suite is a record with no suite line: $(cat "$REC/902" 2>/dev/null)"

# ── L9: a record that cannot be written is logged and read again
reset
run 951 "$MQ" failure 3600
fails 951 tests/a.sh
mkdir -p "$REC/.951.tmp/x"
drive
[ "$RC" = 0 ] && [ ! -f "$REC/951" ] && grep -q 'run 951: record write failed' "$LOG" && ok \
  || bad "L9: a write failure is one log line and no record: rc=$RC $(cat "$LOG" 2>/dev/null)"
scratch_rm "$REC/.951.tmp"
drive
[ -f "$REC/951" ] && [ "$(fcalls 951)" = 2 ] && ok || bad "L9: the run is read again next tick and recorded"

# ── L10: prune at 30 days, records and strike files
reset
run 961 "$MQ-1" failure $(( 29 * DAY )); fails 961 tests/a.sh
run 962 "$MQ-2" failure "$DAY";          fails 962 tests/a.sh
run 963 "$MQ-3" failure $(( 29 * DAY )); echo 2 > "$HH/fx/rc.963"
drive
[ -f "$REC/961" ] && [ -f "$REC/962" ] && [ -f "$REC/963.strikes" ] && ok || bad "L10: setup: two records and a strike file"
echo '{"total_count":0,"workflow_runs":[]}' > "$HH/fx/runs.1.json"
drive NOW=$(( NOW + 2 * DAY ))
[ ! -e "$REC/961" ] && [ -f "$REC/962" ] && [ ! -e "$REC/963.strikes" ] && ok \
  || bad "L10: 31 days old is pruned, 3 days old is kept: $(ls "$REC" 2>&1)"

# ── L11: --list with nothing on disk; a bad argument
reset
list
[ "$LRC" = 0 ] && [ ! -s "$T/list.txt" ] && ok || bad "L11: no records dir: rc 0, no output (rc=$LRC)"
( export HARNESS="$HH" NOW; bash "$HH/bin/prequeue-learned.sh" --bogus ) >/dev/null 2>&1; BRC=$?
[ "$BRC" = 2 ] && ok || bad "L11: an unknown argument is rc 2 (got $BRC)"

# ── K1b: the lane fragment and the cron fragment
LANE="$DIR/catalog/lanes.d/prequeue-learned.json"
[ "$(jq -r '[.id, .scope, .script, (.wired|tostring)] | join(" ")' "$LANE" 2>/dev/null)" = "prequeue-learned hub bin/prequeue-learned.sh true" ] \
  && ok || bad "K1b: the lane is hub-scoped, wired, and runs bin/prequeue-learned.sh"
for kv in PREQUEUE_LEARNED_MIN=20 PREQUEUE_LEARNED_DAYS=7 PREQUEUE_LEARNED_TOP=10 PREQUEUE_LEARNED_PAGES=5 PREQUEUE_LEARNED_MAX=20 \
          PREQUEUE_LEARNED_REPO=example-org/cromford; do
  [ "$(jq -r --arg e "${kv%%=*}" '.knobs[] | select(.env == $e) | .default | tostring' "$LANE" 2>/dev/null)" = "${kv#*=}" ] \
    && ok || bad "K1b: the lane declares ${kv%%=*} with default ${kv#*=}"
done
CRON="$DIR/cron/lanes/729-prequeue-learned.cron"
grep -qx '# @hub-lanes' "$CRON" 2>/dev/null && ok || bad "K1b: the cron fragment is a # @hub-lanes section"
grep -qE '^23,53 \* \* \* \* /root/harness/bin/hub-lease\.sh check && /root/harness/bin/prequeue-learned\.sh --refresh ' "$CRON" 2>/dev/null \
  && ok || bad "K1b: the cron line runs --refresh behind hub-lease.sh check &&"
grep -q 'Tests: tests/prequeue-learned.bh-6335-test.sh' "$DIR/bin/prequeue-learned.sh" 2>/dev/null && ok \
  || bad "K1b: the script header names this suite"

echo "prequeue-learned: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
