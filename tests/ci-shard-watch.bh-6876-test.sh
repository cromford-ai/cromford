#!/bin/bash
# tests/ci-shard-watch.bh-6876-test.sh — bin/ci-shard-watch.sh (BH-6876) run as
# its own entry point against a scratch harness: a fake `gh` that serves fixture
# in-progress run lists and job lists, a fixed clock (CI_SHARD_WATCH_NOW), and a
# fake bin/lane-alert.sh that records its argv.
#
# WHAT IT PINS:
#   A1  a shard job in progress 36 min raises ONE critical ci-shard-slow:<slug>
#       alert naming the run, the shard, the minutes and the runner
#   A2  the edge: exactly CI_SHARD_ALERT_MIN x 60 s is slow, one second less is not
#   A3  no slow job and every run read: one --resolve
#   A4  a failed jobs read is an unknown: no resolve
#   A5  more in-progress runs than CI_SHARD_WATCH_MAX_RUNS: deferred, no resolve
#   A6  jobs that are not an in-progress shard never raise (plan, console-ui and
#       worker jobs, a queued shard, a completed shard)
#   A7  the runs list read fails: a log line, rc 0, no lane-alert call
#   A8  --dry-run prints `would: alert` and calls nothing
#   A9  7 slow shards: 5 named, `+2 more`, one call
#   A10 CI_SHARD_ALERT_MIN=abc falls back to 35
#   A11 the GitHub budget is low: no read, no call
#   A12 no repo token can read the repo: no read, no call
#   A13 no repo configured at all: no read, no call
# The shard job name prefix comes from .github/workflows/harness-ci.yml's own
# tests-shard `name:`, so a rename of that job goes red here.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LANE="$DIR/bin/ci-shard-watch.sh"
[ -f "$LANE" ] || { echo "FAIL: no bin/ci-shard-watch.sh"; echo "ci-shard-watch: 0 passed, 1 failed"; exit 1; }
WF="$DIR/.github/workflows/harness-ci.yml"
NOW=$(date -u -d '2026-10-15T12:00:00Z' +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# The job names, read off the workflow itself.
SHARD_NAME=$(sed -n '/^  tests-shard:$/,/^  [a-z]/{s/^    name: //p}' "$WF" | head -1)
CONSOLE_NAME=$(sed -n '/^  console-ui:$/,/^  [a-z]/{s/^    name: //p}' "$WF" | head -1)
WORKER_NAME=$(sed -n '/^  worker-jobs:$/,/^  [a-z]/{s/^    name: //p}' "$WF" | head -1)
PLAN_NAME=$(sed -n '/^  plan:$/,/^  [a-z]/{s/^    name: //p}' "$WF" | head -1)
case "$SHARD_NAME" in 'Tests, traced (shard ${{ matrix.shard }}/'*) ok ;;
  *) bad "the workflow's tests-shard job name moved off 'Tests, traced (shard <s>/...': '$SHARD_NAME'" ;; esac
[ -n "$CONSOLE_NAME" ] && [ -n "$WORKER_NAME" ] && [ -n "$PLAN_NAME" ] && ok \
  || bad "the workflow's plan/console-ui/worker-jobs names: '$PLAN_NAME' '$CONSOLE_NAME' '$WORKER_NAME'"
shard_name() { # shard_name <s> — the job name GitHub shows for shard <s> of 8
  local n="${SHARD_NAME//'${{ matrix.shard }}'/$1}"
  printf '%s' "${n//'${{ needs.plan.outputs.n }}'/8}"
}

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx" "$T/stub"
# Stubs first: scratch_install_closure never clobbers a file already there.
cat > "$HH/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
SH
cat > "$HH/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return "${FAKE_BUDGET_LOW:-1}"; }
SH
cat > "$HH/bin/lib/gh-repo-token.sh" <<'SH'
gh_repo_use_token() { return "${FAKE_NO_TOKEN:-0}"; }
gh_repo_token_reset() { :; }
SH
cat > "$HH/bin/lane-alert.sh" <<'SH'
#!/bin/bash
{ printf 'CALL'; printf ' [%s]' "$@"; printf '\n'; } >> "$HARNESS/alerts.txt"
SH
chmod +x "$HH/bin/lane-alert.sh"
scratch_install_closure bin/ci-shard-watch.sh "$HH" >/dev/null || { echo "FAIL: cannot install the lane closure"; exit 1; }

# The fake gh: `api [-X M] <path>`. Every call's arguments go to calls.txt.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls.txt"
shift   # "api"
P=""
while [ $# -gt 0 ]; do
  case "$1" in -X|-q|--jq|-f) shift 2 ;; *) P="$1"; shift ;; esac
done
case "$P" in
  */actions/workflows/harness-ci.yml/runs\?*) F="$HARNESS/fx/runs.json" ;;
  */actions/runs/*/jobs\?*) ID=$(sed -E 's#.*/runs/([0-9]+)/jobs.*#\1#' <<<"$P"); F="$HARNESS/fx/jobs.$ID.json" ;;
  *) exit 1 ;;
esac
[ -r "$F" ] || exit 1
cat "$F"
SH
chmod +x "$T/stub/gh"

RUNS=""
run() { # run <id> <age-seconds> — one in-progress run, listed newest first like GitHub
  RUNS="{\"id\":$1,\"status\":\"in_progress\",\"run_started_at\":\"$(iso "$2")\"}${RUNS:+,}$RUNS"
  jq -n --argjson r "[$RUNS]" '{total_count: ($r | length), workflow_runs: $r}' > "$HH/fx/runs.json"
}
job() { # job <name> <status> <age-seconds|-> [runner]
  local st=null
  [ "$3" = - ] || st="\"$(iso "$3")\""
  jq -nc --arg n "$1" --arg s "$2" --argjson st "$st" --arg r "${4-monkci-fixture-1}" \
    '{name: $n, status: $s, started_at: $st, runner_name: $r}'
}
jobs() { # jobs <run-id> <job-json>...
  local id="$1"; shift
  local IFS=,; echo "{\"total_count\":$#,\"jobs\":[$*]}" > "$HH/fx/jobs.$id.json"
}
drive() { # drive [args to the lane] — env through DRIVE_ENV
  rm -f "$HH/calls.txt" "$HH/alerts.txt"
  ( unset GH_TOKEN GITHUB_TOKEN
    export HARNESS="$HH" CI_SHARD_WATCH_NOW="$NOW" PATH="$T/stub:$PATH" CI_SHARD_WATCH_REPO=example-org/cromford
    for kv in ${DRIVE_ENV:-}; do export "${kv?}"; done
    bash "$HH/bin/ci-shard-watch.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
reset() { RUNS=""; DRIVE_ENV=""; rm -f "$HH/fx/"* "$HH/logs/ci-shard-watch.log"; }
ncalls() { if [ -f "$HH/alerts.txt" ]; then grep -c '^CALL' "$HH/alerts.txt"; else echo 0; fi; }
nraise() { if [ -f "$HH/alerts.txt" ]; then grep -c '\[--severity\] \[critical\]' "$HH/alerts.txt"; else echo 0; fi; }
nresolve() { if [ -f "$HH/alerts.txt" ]; then grep -c '\[--resolve\]' "$HH/alerts.txt"; else echo 0; fi; }
ghcalls() { if [ -f "$HH/calls.txt" ]; then grep -c . "$HH/calls.txt"; else echo 0; fi; }
LOG="$HH/logs/ci-shard-watch.log"
lastlog() { tail -1 "$LOG" 2>/dev/null; }
ID='[--id] [ci-shard-slow:example-org/cromford]'

# ── A1: one slow shard ────────────────────────────────────────────────────────
reset
run 7001 3000
jobs 7001 "$(job "$(shard_name 3)" in_progress 2160)" "$(job "$(shard_name 1)" in_progress 600)"
drive
[ "$RC" = 0 ] && ok || bad "A1: rc must be 0, got $RC ($(cat "$T/err.txt"))"
[ "$(ncalls)" = 1 ] && [ "$(nraise)" = 1 ] && ok || bad "A1: exactly one critical raise: $(cat "$HH/alerts.txt" 2>/dev/null)"
grep -qF "$ID" "$HH/alerts.txt" 2>/dev/null && ok || bad "A1: the id is ci-shard-slow:<repo slug>: $(cat "$HH/alerts.txt" 2>/dev/null)"
grep -qF '[ci-shard-watch] [1 CI shard job(s) past 35 min (limit 45): run 7001 shard 3 36 min [monkci-fixture-1]]' "$HH/alerts.txt" 2>/dev/null \
  && ok || bad "A1: the text names run, shard, minutes and runner: $(cat "$HH/alerts.txt" 2>/dev/null)"
lastlog | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z .*runs=1 read=1 deferred=0 slow=1 action=raise$' && ok \
  || bad "A1: one stamped summary line: $(lastlog)"
[ "$(grep -c . "$LOG")" = 1 ] && ok || bad "A1: one log line per tick: $(cat "$LOG")"
grep -q 'repos/example-org/cromford/actions/workflows/harness-ci.yml/runs?status=in_progress&per_page=50' "$HH/calls.txt" \
  && grep -q 'repos/example-org/cromford/actions/runs/7001/jobs?filter=latest&per_page=100' "$HH/calls.txt" \
  && [ "$(ghcalls)" = 2 ] && ok || bad "A1: 1 runs read + 1 jobs read: $(cat "$HH/calls.txt")"

# ── A2: the edge ──────────────────────────────────────────────────────────────
reset
run 7002 3000
jobs 7002 "$(job "$(shard_name 2)" in_progress 2100)"
drive
[ "$(nraise)" = 1 ] && grep -qF 'run 7002 shard 2 35 min' "$HH/alerts.txt" 2>/dev/null && ok \
  || bad "A2: exactly 35:00 is slow: $(cat "$HH/alerts.txt" 2>/dev/null)"
jobs 7002 "$(job "$(shard_name 2)" in_progress 2099)"
drive
[ "$(nraise)" = 0 ] && [ "$(nresolve)" = 1 ] && ok || bad "A2: 34:59 is not slow (resolve, no raise): $(cat "$HH/alerts.txt" 2>/dev/null)"

# ── A3: nothing slow, everything read: one resolve ───────────────────────────
reset
run 7003 3000; run 7004 1000
jobs 7003 "$(job "$(shard_name 1)" in_progress 1200)"
jobs 7004 "$(job "$(shard_name 1)" in_progress 300)"
drive
[ "$RC" = 0 ] && [ "$(ncalls)" = 1 ] && [ "$(nresolve)" = 1 ] && grep -qF "$ID" "$HH/alerts.txt" && ok \
  || bad "A3: one resolve of the id: $(cat "$HH/alerts.txt" 2>/dev/null)"
grep -qF '[ci-shard-watch]' "$HH/alerts.txt" 2>/dev/null && ok || bad "A3: the resolve names the lane: $(cat "$HH/alerts.txt" 2>/dev/null)"
lastlog | grep -q 'runs=2 read=2 deferred=0 slow=0 action=resolve$' && ok || bad "A3: summary: $(lastlog)"

# ── A4: one jobs read fails: no resolve, the others still raise when slow ────
reset
run 7005 3000; run 7006 2000
jobs 7006 "$(job "$(shard_name 1)" in_progress 300)"
drive
[ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "A4: an unread run is unknown, never a resolve: $(cat "$HH/alerts.txt" 2>/dev/null)"
lastlog | grep -q 'runs=2 read=1 deferred=0 slow=0 action=none$' && ok || bad "A4: summary: $(lastlog)"
jobs 7006 "$(job "$(shard_name 4)" in_progress 2400)"
drive
[ "$(nraise)" = 1 ] && [ "$(nresolve)" = 0 ] && grep -qF 'run 7006 shard 4 40 min' "$HH/alerts.txt" && ok \
  || bad "A4: a slow job on a read run still raises: $(cat "$HH/alerts.txt" 2>/dev/null)"

# ── A5: the cap ───────────────────────────────────────────────────────────────
reset
for i in $(seq 1 12); do run $(( 7100 + i )) $(( 5000 - i * 100 )); jobs $(( 7100 + i )) "$(job "$(shard_name 1)" in_progress 60)"; done
DRIVE_ENV="CI_SHARD_WATCH_MAX_RUNS=10" drive
[ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "A5: deferred runs are unknown: no resolve: $(cat "$HH/alerts.txt" 2>/dev/null)"
lastlog | grep -q 'runs=12 read=10 deferred=2 slow=0 action=none$' && ok || bad "A5: summary: $(lastlog)"
[ "$(ghcalls)" = 11 ] && ok || bad "A5: bounded to 1 + MAX_RUNS reads: $(ghcalls)"
grep -q 'runs/7101/jobs' "$HH/calls.txt" && ! grep -q 'runs/7112/jobs' "$HH/calls.txt" && ok \
  || bad "A5: oldest first, the newest are deferred: $(cat "$HH/calls.txt")"

# ── A6: negatives ─────────────────────────────────────────────────────────────
reset
run 7200 4000
jobs 7200 "$(job "$PLAN_NAME" in_progress 3000)" \
  "$(job "$(shard_name 5)" queued -)" \
  "$(job "$(shard_name 6)" completed 2640)" \
  "$(job "$WORKER_NAME" in_progress 2400)" \
  "$(job "$CONSOLE_NAME" in_progress 3000)"
drive
[ "$RC" = 0 ] && [ "$(nraise)" = 0 ] && [ "$(nresolve)" = 1 ] && ok \
  || bad "A6: no shard in progress past the line: resolve, no raise: $(cat "$HH/alerts.txt" 2>/dev/null)"

# ── A7: the runs read fails ───────────────────────────────────────────────────
reset
drive
[ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "A7: rc 0 and no lane-alert call: rc=$RC $(cat "$HH/alerts.txt" 2>/dev/null)"
[ "$(grep -c . "$LOG" 2>/dev/null)" = 1 ] && grep -q 'unreadable' "$LOG" && ok || bad "A7: one log line: $(cat "$LOG" 2>/dev/null)"

# ── A8: --dry-run ─────────────────────────────────────────────────────────────
reset
run 7300 3000
jobs 7300 "$(job "$(shard_name 2)" in_progress 2700)"
drive --dry-run
[ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "A8: dry-run calls nothing: $(cat "$HH/alerts.txt" 2>/dev/null)"
grep -q '^would: alert .*run 7300 shard 2 45 min' "$T/out.txt" && ok || bad "A8: prints would: alert: $(cat "$T/out.txt")"
jobs 7300 "$(job "$(shard_name 2)" in_progress 60)"
drive --dry-run
[ "$(ncalls)" = 0 ] && grep -q '^would: resolve ' "$T/out.txt" && ok || bad "A8: prints would: resolve: $(cat "$T/out.txt")"

# ── A9: 7 slow shards ─────────────────────────────────────────────────────────
reset
run 7400 4000
J=()
for s in 1 2 3 4 5 6 7; do J+=("$(job "$(shard_name "$s")" in_progress $(( 2400 + s * 60 )) "")"); done
jobs 7400 "${J[@]}"
drive
[ "$(ncalls)" = 1 ] && [ "$(nraise)" = 1 ] && ok || bad "A9: one call: $(cat "$HH/alerts.txt" 2>/dev/null)"
grep -qF '[7 CI shard job(s) past 35 min (limit 45): ' "$HH/alerts.txt" 2>/dev/null && grep -qF '; +2 more]' "$HH/alerts.txt" \
  && [ "$(grep -o 'run 7400 shard' "$HH/alerts.txt" | grep -c .)" = 5 ] && ok \
  || bad "A9: 5 named, then +2 more: $(cat "$HH/alerts.txt" 2>/dev/null)"
grep -qF 'run 7400 shard 1 41 min [-]' "$HH/alerts.txt" 2>/dev/null && ok || bad "A9: an empty runner reads '-': $(cat "$HH/alerts.txt" 2>/dev/null)"

# ── A10: a bad knob falls back to 35 ─────────────────────────────────────────
reset
run 7500 3000
jobs 7500 "$(job "$(shard_name 1)" in_progress 2100)"
DRIVE_ENV="CI_SHARD_ALERT_MIN=abc" drive
[ "$RC" = 0 ] && [ "$(nraise)" = 1 ] && grep -qF 'past 35 min' "$HH/alerts.txt" && ok \
  || bad "A10: abc falls back to 35: $(cat "$HH/alerts.txt" 2>/dev/null)"
grep -q 'CI_SHARD_ALERT_MIN' "$T/err.txt" && ok || bad "A10: the fallback is said on stderr: $(cat "$T/err.txt")"
DRIVE_ENV="CI_SHARD_ALERT_MIN=40" drive
[ "$(nraise)" = 0 ] && [ "$(nresolve)" = 1 ] && ok || bad "A10: a valid knob moves the line: $(cat "$HH/alerts.txt" 2>/dev/null)"

# ── A11: budget low; A12: no token ───────────────────────────────────────────
reset
run 7600 3000
jobs 7600 "$(job "$(shard_name 1)" in_progress 2400)"
DRIVE_ENV="FAKE_BUDGET_LOW=0" drive
[ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok || bad "A11: budget low: no read, no call ($(ghcalls) reads)"
[ "$(grep -c . "$LOG")" = 1 ] && grep -q 'budget' "$LOG" && ok || bad "A11: one log line: $(cat "$LOG" 2>/dev/null)"
rm -f "$LOG"
DRIVE_ENV="FAKE_NO_TOKEN=1" drive
[ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok || bad "A12: no token: no read, no call ($(ghcalls) reads)"
[ "$(grep -c . "$LOG")" = 1 ] && grep -q 'token' "$LOG" && ok || bad "A12: one log line: $(cat "$LOG" 2>/dev/null)"

# ── A13: no repo at all (no CI_SHARD_WATCH_REPO, no HARNESS_REPO) ────────────
rm -f "$LOG"
: > "$T/no-deployment.sh"
DRIVE_ENV="CI_SHARD_WATCH_REPO= HARNESS_REPO= HARNESS_DEPLOYMENT_FILE=$T/no-deployment.sh" drive
[ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok || bad "A13: no repo: no read, no call ($(ghcalls) reads)"
[ "$(grep -c . "$LOG")" = 1 ] && grep -q 'not configured' "$LOG" && ok || bad "A13: one log line: $(cat "$LOG" 2>/dev/null)"

echo "ci-shard-watch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
