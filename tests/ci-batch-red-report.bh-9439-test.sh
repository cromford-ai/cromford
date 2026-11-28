#!/bin/bash
# tests/ci-batch-red-report.bh-9439-test.sh — bin/ci-batch-red-report.sh reads
# the member gate of a pre-queue GROUP run (BH-9439). Since BH-8327 the gate is
# prequeue-group-gate.yml, titled `prequeue group=<gid> main=<sha>`, with one
# job `gate (<pr>, <head40>) / gate` per member, and its log is the ledger shape
# (tests/fixtures/bh-9439/gate-job-log.txt): the verdict is
# `##[notice]green main=<40> head=<40> suites=`, and the only
# `prequeue-verdict::` text is the echoed script source line.
#
# Seam shape as bh-8048: stub lane-gate, gh-budget and gh-repo-token libs; the
# REAL bin/lib/gh-ci-read.sh; a fake `gh` on PATH that serves fixture JSON and
# job logs, appends each argv to calls.txt and exits 1 on any path it does not
# know (0 network calls). Time is injected with NOW. Each case resets its own
# fixture tree.
#
# WHAT IT PINS (plan "Acceptance tests"):
#   G1  a group run before the batch: the gate line is green, case=A
#   G1b two members in one group run: the group run's jobs are read once
#   G2  near miss: job `gate (91480, <40>) / gate`: gate ?, case=C
#   G3  the group run is created AFTER the batch: not used, gate ?
#   G4  a per-PR run (older) and a group run (newer): the group job log is read
#   G4b a per-PR run newer than the group run: the per-PR job log is read
#   G5  the group list fails: the per-PR shape still works
#   G6  verdict parse: echoed source line = read; selected= notice = read;
#       `##[notice]red main=.. head=..` = red
#   G7  CI_BATCH_RED_GROUP_SCAN=2, the member in the 3rd-newest group run: ?
#   G8  a failed group jobs read: gate ?
#   U1  the ci-batch-red-gate: line in logs/ci-batch-red-gate.log; the tick
#       log keeps one line; stdout is the rate line only (dry run: after the TSV)
#   U2  0 red runs: gate_unread=0 gate_unread_pct=-
#   B   the fake gh saw only repos/... paths, no URL
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=1791000000
REPO=example-org/cromford
iso() { jq -rn --argjson t "$(( NOW - $1 ))" '$t | todate'; }
TAB=$(printf '\t')
FIX="$DIR/tests/fixtures/bh-9439/gate-job-log.txt"
[ -s "$FIX" ] || { echo "FAIL: fixture missing: $FIX"; echo "ci-batch-red-report.bh-9439: 0 passed, 1 failed"; exit 1; }

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx" "$T/path"
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
SH
cat > "$T/path/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls.txt"
FX="$HARNESS/fx"; path=""; pg=1; esc=0
for a in "$@"; do
  case "$a" in
    repos/*) path="$a" ;;
    page=*) pg="${a#page=}" ;;
    --allow-escape-sequences) esc=1 ;;
  esac
done
case "$path" in *page=*) pg="${path##*page=}"; pg="${pg%%&*}" ;; esac
p="${path%%\?*}"
case "$p" in
  repos/*/actions/workflows/harness-ci.yml/runs) f="$FX/runs.$pg.json" ;;
  repos/*/actions/workflows/prequeue-gate.yml/runs) f="$FX/gates.$pg.json" ;;
  repos/*/actions/workflows/prequeue-group-gate.yml/runs) f="$FX/ggates.$pg.json" ;;
  repos/*/actions/runs/*/jobs) id="${p#*/actions/runs/}"; id="${id%/jobs}"; f="$FX/jobs.$id.json" ;;
  repos/*/actions/jobs/*/logs)
    id="${p#*/actions/jobs/}"; id="${id%/logs}"
    [ "$esc" = 1 ] || exit 0
    f="$FX/log.$id.txt" ;;
  *) exit 1 ;;
esac
[ -r "$f" ] || exit 1
cat "$f"
SH
chmod +x "$T/path/gh"
scratch_install_closure bin/ci-batch-red-report.sh "$HH" >/dev/null \
  || { echo "FAIL: cannot install the lane closure (bin/ci-batch-red-report.sh)"; echo "ci-batch-red-report.bh-9439: 0 passed, 1 failed"; exit 1; }

H40=1f7f14b3c2d9e8a7b6c5d4e3f2a1b0c9d8e7f6a5
M40=8e1c0d2a9b7f4c6e3a5d1b0f9c8e7a6d5b4c3a21
RUNS=""; GATES=""; GGATES=""
run() { # run <id> <conclusion> <age-s> <tree> <first msg line>
  RUNS="$RUNS${RUNS:+,}$(jq -nc --argjson id "$1" --arg c "$2" --arg t "$(iso "$3")" --arg tr "$4" --arg m "$5" \
    '{id: $id, head_branch: "mergify/merge-queue/main/pr-x", conclusion: $c, status: "completed", created_at: $t, run_attempt: 1, head_commit: {tree_id: $tr, message: $m}}')"
  jq -n --argjson r "[$RUNS]" '{total_count: ($r | length), workflow_runs: $r}' > "$HH/fx/runs.1.json"
}
jobs() { # jobs <run_id> <jid>:<conclusion>:<name>...
  local id="$1" a js=""; shift
  for a in "$@"; do
    js="$js${js:+,}$(jq -nc --arg i "${a%%:*}" --arg r "${a#*:}" '{id: ($i | tonumber), conclusion: ($r | split(":")[0]), name: ($r | split(":")[1:] | join(":"))}')"
  done
  jq -n --argjson j "[$js]" '{total_count: ($j | length), jobs: $j}' > "$HH/fx/jobs.$id.json"
}
logf() { local id="$1"; shift; printf '%s\n' "$@" > "$HH/fx/log.$id.txt"; }
# ggate <run_id> <age-s> <title> <jid>:<job name>... — a group run, every gate job's log the fixture
ggate() {
  local gid="$1" age="$2" title="$3" a specs=(); shift 3
  GGATES="$GGATES${GGATES:+,}$(jq -nc --argjson id "$gid" --arg t "$(iso "$age")" --arg d "$title" \
    '{id: $id, display_title: $d, created_at: $t, conclusion: "success"}')"
  jq -n --argjson r "[$GGATES]" '{total_count: ($r | length), workflow_runs: $r}' > "$HH/fx/ggates.1.json"
  for a in "$@"; do specs+=("${a%%:*}:success:${a#*:}"); cp "$FIX" "$HH/fx/log.${a%%:*}.txt"; done
  jobs "$gid" "${specs[@]}"
}
gjob() { printf 'gate (%s, %s) / gate' "$1" "${2:-$H40}"; }
# pgate <run_id> <pr> <age-s> <jid> <suite ran> — a per-PR (old shape) gate run
pgate() {
  GATES="$GATES${GATES:+,}$(jq -nc --argjson id "$1" --arg t "$(iso "$3")" --arg d "prequeue pr=$2 head=$H40 main=$M40" \
    '{id: $id, display_title: $d, created_at: $t, conclusion: "success"}')"
  jq -n --argjson r "[$GATES]" '{total_count: ($r | length), workflow_runs: $r}' > "$HH/fx/gates.1.json"
  jobs "$1" "$4:success:gate"
  logf "$4" "2026-10-22T15:00:00.1Z impact-gate: done $5 rc=0 (3s)" \
            "2026-10-22T15:00:01.1Z ::notice title=prequeue-verdict::green main=$M40 head=$H40 suites="
}
reset() { RUNS=""; GATES=""; GGATES=""; local p; for p in fx state logs calls.txt; do scratch_rm "$HH/$p"; done; mkdir -p "$HH/fx" "$HH/logs"; }
drive() { # drive [ENV=val...] [-- args...] — one tick
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$HH/calls.txt"
  ( export HARNESS="$HH" NOW PATH="$T/path:$PATH" CI_BATCH_RED_REPO="$REPO"
    unset CI_BATCH_RED_GROUP_SCAN CI_BATCH_RED_DAYS
    [ ${#envs[@]} -gt 0 ] && export "${envs[@]}"
    bash "$HH/bin/ci-batch-red-report.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
REC="$HH/state/ci-batch-red/runs"
LOG="$HH/logs/ci-batch-red.log"
GLOG="$HH/logs/ci-batch-red-gate.log"
lastlog() { tail -1 "$LOG" 2>/dev/null; }
gl() { grep "^gate${TAB}$2${TAB}" "$REC/$1" 2>/dev/null; }
r() { local IFS="$TAB"; echo "$*"; }
ncalls() { if [ -f "$HH/calls.txt" ]; then grep -c -- "$1" "$HH/calls.txt"; else echo 0; fi; }
SH0='Tests, traced (shard 0/2)'
GT="prequeue group=g17890abc main=$M40"

# One red batch for #9148 (2 h old), its failing shard names tests/a-test.sh.
batch() { # batch [first msg line]
  run 101 failure 7200 tree1 "${1:-Merge of #9148}"
  jobs 101 "9001:failure:$SH0"
  logf 9001 "2026-11-10T22:31:36.1Z --- tests/a-test.sh rc=1 3s"
}

# ── G1: a group run 3 h old (before the batch) holds the member's gate job
reset; batch
# A newer run whose title is not a group title holds a RED gate for #9148: never used.
ggate 602 9000 "prequeue grp=g1 main=$M40" "7602:$(gjob 9148)"
printf '%s\n' "2026-11-10T21:41:31.2Z ##[notice]red main=$M40 head=$H40 suites=tests/a-test.sh" > "$HH/fx/log.7602.txt"
ggate 601 10800 "$GT" "7600:plan" "7601:$(gjob 9148)"
drive
[ "$RC" = 0 ] && ok || bad "G1: rc 0, got $RC ($(cat "$T/err.txt"))"
[ "$(gl 101 9148)" = "$(r gate 9148 green -)" ] && ok || bad "G1: the record gate line is 'gate 9148 green -': '$(gl 101 9148)' $(cat "$REC/101" 2>/dev/null)"
lastlog | grep -q 'case=A share_a=100 ' && ok || bad "G1: the tick line has case=A share_a=100: $(lastlog)"
[ "$(ncalls 'jobs/7601/logs')" = 1 ] && [ "$(ncalls 'jobs/7602/logs')" = 0 ] && [ "$(ncalls 'actions/runs/602/jobs')" = 0 ] && ok \
  || bad "G1: only the matching group run's gate job log is read: $(grep -E 'runs/60|jobs/76' "$HH/calls.txt")"
[ "$(ncalls 'prequeue-group-gate.yml/runs')" -ge 1 ] && grep 'prequeue-group-gate.yml/runs' "$HH/calls.txt" | grep -q 'event=workflow_dispatch' && ok \
  || bad "G1: the group run list is read with event=workflow_dispatch"

# ── G1b: two members in one group run: its jobs are read once this tick
reset; batch "Merge of #9148 and #9149"
ggate 601 10800 "$GT" "7600:plan" "7601:$(gjob 9148)" "7603:$(gjob 9149)"
drive
[ "$(gl 101 9148)" = "$(r gate 9148 green -)" ] && [ "$(gl 101 9149)" = "$(r gate 9149 green -)" ] && ok \
  || bad "G1b: both members read green: $(grep gate "$REC/101" 2>/dev/null)"
[ "$(ncalls 'actions/runs/601/jobs')" = 1 ] && ok || bad "G1b: the group jobs read once a tick, got $(ncalls 'actions/runs/601/jobs')"

# ── G2: near misses on the job name
for nm in "$(gjob 91480)" "$(gjob 148)" "$(gjob 9148 abc)" "gate" "plan"; do
  reset; batch
  ggate 601 10800 "$GT" "7601:$nm"
  drive
  [ "$(gl 101 9148)" = "$(r gate 9148 '?' -)" ] && lastlog | grep -q 'case=C ' && ok \
    || bad "G2: job '$nm' is not the member's gate: '$(gl 101 9148)' $(lastlog)"
done

# ── G3: the group run is created AFTER the batch
reset; batch
ggate 601 3600 "$GT" "7601:$(gjob 9148)"
drive
[ "$(gl 101 9148)" = "$(r gate 9148 '?' -)" ] && [ "$(ncalls 'actions/runs/601/jobs')" = 0 ] && ok \
  || bad "G3: a group run after the batch is not a candidate: '$(gl 101 9148)'"

# ── G4: a per-PR run (5 h, older) and a group run (3 h, newer): the group wins
reset; batch
pgate 501 9148 18000 7001 tests/a-test.sh
ggate 601 10800 "$GT" "7601:$(gjob 9148)"
drive
[ "$(gl 101 9148)" = "$(r gate 9148 green -)" ] && [ "$(ncalls 'jobs/7601/logs')" = 1 ] && [ "$(ncalls 'jobs/7001/logs')" = 0 ] && ok \
  || bad "G4: the newer group job log is read, the per-PR log is not: '$(gl 101 9148)' $(grep -E 'jobs/7' "$HH/calls.txt")"
# G4b: the per-PR run is the newer one
reset; batch
pgate 501 9148 9000 7001 tests/a-test.sh
ggate 601 10800 "$GT" "7601:$(gjob 9148)"
drive
[ "$(gl 101 9148)" = "$(r gate 9148 green tests/a-test.sh)" ] && [ "$(ncalls 'jobs/7001/logs')" = 1 ] && [ "$(ncalls 'jobs/7601/logs')" = 0 ] && ok \
  || bad "G4b: the newer per-PR job log is read: '$(gl 101 9148)'"

# ── G5: the group list fails; the per-PR shape still works
reset; batch
pgate 501 9148 9000 7001 tests/a-test.sh
drive
[ "$(gl 101 9148)" = "$(r gate 9148 green tests/a-test.sh)" ] && [ "$RC" = 0 ] && ok \
  || bad "G5: with no group list the per-PR gate is read: '$(gl 101 9148)'"

# ── G6: the verdict parse in both shapes
g6() { # g6 <name> <want verdict> <log line>...
  local name="$1" want="$2"; shift 2
  reset; batch
  ggate 601 10800 "$GT" "7601:$(gjob 9148)"
  printf '%s\n' "$@" > "$HH/fx/log.7601.txt"
  drive
  [ "$(gl 101 9148)" = "$(r gate 9148 "$want" -)" ] && ok || bad "G6 $name: want verdict '$want': '$(gl 101 9148)'"
}
g6 "echoed source line" read "$(grep -F 'prequeue-verdict::$V' "$FIX")"
g6 "selected= notice" read "$(grep -F '##[notice]selected=' "$FIX")"
g6 "invariants notice" read "$(grep -F '##[notice]prequeue-invariants:' "$FIX")"
g6 "red notice" red "2026-11-10T21:41:31.2Z ##[notice]red main=$M40 head=$H40 suites=tests/a-test.sh"
g6 "old shape" could-not-run "2026-11-10T21:41:31.2Z ::notice title=prequeue-verdict::could-not-run main=$M40 head=$H40 suites= why=rc-3"
g6 "short head" read "2026-11-10T21:41:31.2Z ##[notice]green main=$M40 head=abc suites="
g6 "the whole fixture" green "$(cat "$FIX")"

# ── G7: the scan bound
reset; batch
ggate 603 9000 "$GT" "7603:$(gjob 7)"
ggate 602 10000 "$GT" "7602:$(gjob 8)"
ggate 601 10800 "$GT" "7601:$(gjob 9148)"
drive CI_BATCH_RED_GROUP_SCAN=2
[ "$(gl 101 9148)" = "$(r gate 9148 '?' -)" ] && ok || bad "G7: the 3rd-newest run is past a scan of 2: '$(gl 101 9148)'"
[ "$(grep -cE 'actions/runs/60[0-9]/jobs' "$HH/calls.txt")" = 2 ] && [ "$(ncalls 'actions/runs/601/jobs')" = 0 ] && ok \
  || bad "G7: 2 group jobs reads: $(grep -E 'actions/runs/60' "$HH/calls.txt")"
reset; batch
ggate 603 9000 "$GT" "7603:$(gjob 7)"
ggate 602 10000 "$GT" "7602:$(gjob 8)"
ggate 601 10800 "$GT" "7601:$(gjob 9148)"
drive CI_BATCH_RED_GROUP_SCAN=3
[ "$(gl 101 9148)" = "$(r gate 9148 green -)" ] && ok || bad "G7: a scan of 3 reaches the 3rd-newest run: '$(gl 101 9148)'"

# ── G8: a group jobs read that fails during the scan: ?
reset; batch
ggate 602 9000 "$GT" "7602:$(gjob 8)"
ggate 601 10800 "$GT" "7601:$(gjob 9148)"
rm -f "$HH/fx/jobs.602.json"
drive
[ "$(gl 101 9148)" = "$(r gate 9148 '?' -)" ] && [ "$RC" = 0 ] && ok || bad "G8: a failed jobs read is ?: '$(gl 101 9148)'"
[ ! -f "$REC/101.strikes" ] && ok || bad "G8: a gate read failure is no strike"

# ── U1: the ci-batch-red-gate: line, over records
mkdir -p "$REC"
recw() { # recw <id> <age-s> <red|green> <prs> [unread] — body lines on stdin
  mkdir -p "$REC"
  { echo "run $1 attempt 1 created $(( NOW - $2 )) concl $3 tree t$1 prs $4${5:+ $5}"; cat; } > "$REC/$1"
}
u_seed() {
  reset; echo '{"total_count":0,"workflow_runs":[]}' > "$HH/fx/runs.1.json"
  printf 'fail\ttests/a.sh\t1\ngate\t1\tgreen\t-\n' | recw 1 100 red 1
  printf 'fail\ttests/b.sh\t1\ngate\t2\tgreen\t-\ngate\t3\t?\t-\n' | recw 2 100 red 2,3
  : | recw 3 100 red 4 unread
  printf 'ran\ttests/a.sh\n' | recw 4 100 green 5
  # Outside the window: not counted.
  printf 'fail\ttests/a.sh\t1\ngate\t6\t?\t-\n' | recw 5 $(( 8 * 86400 )) red 6
}
u_seed
drive
[ "$RC" = 0 ] && ok || bad "U1: rc 0, got $RC"
[ "$(grep -c . "$GLOG" 2>/dev/null)" = 1 ] && grep -q "^.*Z ci-batch-red-gate: repo=$REPO days=7 red=3 gate_unread=2 gate_unread_pct=66$" "$GLOG" && ok \
  || bad "U1: the gate log line: $(cat "$GLOG" 2>/dev/null)"
[ "$(grep -c . "$LOG" 2>/dev/null)" = 1 ] && lastlog | grep -q 'ci-batch-red: repo=.* red=3 green=1 ' && ! grep -q 'ci-batch-red-gate' "$LOG" && ok \
  || bad "U1: the tick log keeps one tick line: $(cat "$LOG" 2>/dev/null)"
[ "$(grep -c . "$T/out.txt")" = 1 ] && grep -q '^ci-batch-red: red-batch rate, last 7 days: 75 percent (3 red of 4 batches)$' "$T/out.txt" && ok \
  || bad "U1: stdout is the rate line only: $(cat "$T/out.txt")"
u_seed
drive -- --dry-run
gn=$(grep -n '^ci-batch-red-gate: ' "$T/out.txt" | cut -d: -f1); tn=$(grep -n '^suite	kind	' "$T/out.txt" | cut -d: -f1)
[ -n "$gn" ] && [ -n "$tn" ] && [ "$gn" -gt "$tn" ] && grep -q '^ci-batch-red-gate: .* gate_unread=2 gate_unread_pct=66$' "$T/out.txt" \
  && [ "$(sed -n 1p "$T/out.txt" | cut -c1-30)" = "ci-batch-red: red-batch rate, " ] && [ ! -s "$GLOG" ] && ok \
  || bad "U1: --dry-run prints the gate line after the TSV and writes no gate log: $(cat "$T/out.txt")"

# ── U2: 0 red runs
reset; echo '{"total_count":0,"workflow_runs":[]}' > "$HH/fx/runs.1.json"
printf 'ran\ttests/a.sh\n' | recw 4 100 green 5
drive
grep -q "ci-batch-red-gate: repo=$REPO days=7 red=0 gate_unread=0 gate_unread_pct=-$" "$GLOG" 2>/dev/null && ok \
  || bad "U2: no red run: $(cat "$GLOG" 2>/dev/null)"

# ── B: no URL; every call names a repos/ path
reset; batch
pgate 501 9148 18000 7001 tests/a-test.sh
ggate 601 10800 "$GT" "7601:$(gjob 9148)"
drive
[ -s "$HH/calls.txt" ] && ! grep -qiE 'https?://' "$HH/calls.txt" && [ "$(grep -vc ' repos/' "$HH/calls.txt")" = 0 ] && ok \
  || bad "B: the fake gh saw only repos/ paths: $(cat "$HH/calls.txt")"

# ── the knob fragment
KF="$DIR/catalog/lanes.d/ci-batch-red-report.knobs.d/CI_BATCH_RED_GROUP_SCAN.json"
[ "$(jq -r '[.env, .read_in, .type, .default, .min, .max] | map(tostring) | join(" ")' "$KF" 2>/dev/null)" \
  = "CI_BATCH_RED_GROUP_SCAN bin/ci-batch-red-report.sh int 20 1 100" ] && ok \
  || bad "K: the knob fragment CI_BATCH_RED_GROUP_SCAN (default 20, 1..100)"

echo "ci-batch-red-report.bh-9439: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
