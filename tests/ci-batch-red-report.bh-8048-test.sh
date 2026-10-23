#!/bin/bash
# tests/ci-batch-red-report.bh-8048-test.sh — bin/ci-batch-red-report.sh
# (BH-8048) driven against a scratch harness. The GitHub reads go through the
# REAL bin/lib/gh-ci-read.sh seam into a fake `gh` on PATH that serves fixture
# JSON and job logs, appends each argv to calls.txt, and exits 1 on any path it
# does not know (0 network calls). gh-budget, lane-gate and gh-repo-token are
# stub libs. Time is injected with NOW. Each case resets its own fixture tree.
#
# WHAT IT PINS (plan "Acceptance tests"):
#   T-rows  2 red batches + 1 green: the TSV rows and counts
#   T-log   one log line with red/green/red_rate/unread/deferred/case
#   E1      budget low: rc 0, 0 gh calls, latest.tsv untouched
#   E2      a run whose jobs cannot be read: strikes, then an `unread` row; rc 0
#   E3      CI_BATCH_RED_MAX=1: the rest deferred, drained on later ticks
#   E4      every job log read passes --allow-escape-sequences
#   E5      a runs page unreadable: rc 0, nothing written
#   R1      a second tick reads no run again and writes the same TSV
#   S1      only mergify/merge-queue/ failure|success runs are read
#   G1      the gate's RAN suites come from its job log, not the verdict's suites=
#   D1-D11  the case decision table
#   P1-P8   the log parser
#   K1      prune after CI_BATCH_RED_KEEP_DAYS; dry run writes nothing; lane file
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

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx" "$T/path"
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
SH
# The REAL gh-ci-read.sh comes in with the closure (scratch_install_closure).
# The fake gh: `gh api [flags] <path> [-f k=v]...`; argv to calls.txt.
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
  repos/*/actions/runs/*/jobs) id="${p#*/actions/runs/}"; id="${id%/jobs}"; f="$FX/jobs.$id.json" ;;
  repos/*/actions/jobs/*/logs)
    id="${p#*/actions/jobs/}"; id="${id%/logs}"
    # gh 2.100: without the flag a log with escape codes prints NOTHING, rc 0.
    [ "$esc" = 1 ] || exit 0
    f="$FX/log.$id.txt" ;;
  *) exit 1 ;;
esac
[ -r "$f" ] || exit 1
cat "$f"
SH
chmod +x "$T/path/gh"
scratch_install_closure bin/ci-batch-red-report.sh "$HH" >/dev/null \
  || { echo "FAIL: cannot install the lane closure (bin/ci-batch-red-report.sh)"; echo "ci-batch-red-report: 0 passed, 1 failed"; exit 1; }

H40=0123456789abcdef0123456789abcdef01234567
RUNS=""; GATES=""
run() { # run <id> <branch> <conclusion> <age-s> <tree> <first msg line> [attempt]
  RUNS="$RUNS${RUNS:+,}$(jq -nc --argjson id "$1" --arg b "$2" --arg c "$3" --arg t "$(iso "$4")" --arg tr "$5" --arg m "$6" --argjson a "${7:-1}" \
    '{id: $id, head_branch: $b, conclusion: $c, status: "completed", created_at: $t, run_attempt: $a, head_commit: {tree_id: $tr, message: ($m + "\n\nbody #999")}}')"
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
gate() { # gate <gate_run_id> <pr> <age-s> <gate job id> <suite ran>... — a gate run whose log ran these suites
  local gid="$1" pr="$2" age="$3" jid="$4" s; shift 4
  GATES="$GATES${GATES:+,}$(jq -nc --argjson id "$gid" --arg t "$(iso "$age")" --arg d "prequeue pr=$pr head=$H40 main=$H40" \
    '{id: $id, display_title: $d, created_at: $t, conclusion: "success"}')"
  jq -n --argjson r "[$GATES]" '{total_count: ($r | length), workflow_runs: $r}' > "$HH/fx/gates.1.json"
  jobs "$gid" "$jid:success:gate"
  : > "$HH/fx/log.$jid.txt"
  for s in "$@"; do echo "2026-10-22T15:00:00.1Z impact-gate: done $s rc=0 (3s)" >> "$HH/fx/log.$jid.txt"; done
  # The verdict's suites= is the FAILED list, empty on green: it must not be read as "ran".
  echo "2026-10-22T15:00:01.1Z ::notice title=prequeue-verdict::green main=$H40 head=$H40 suites=" >> "$HH/fx/log.$jid.txt"
}
reset() { RUNS=""; GATES=""; local p; for p in fx state logs calls.txt; do scratch_rm "$HH/$p"; done; mkdir -p "$HH/fx" "$HH/logs"; }
drive() { # drive [ENV=val...] [-- args...] — one tick
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$HH/calls.txt"
  ( export HARNESS="$HH" NOW PATH="$T/path:$PATH" CI_BATCH_RED_REPO="$REPO"
    [ ${#envs[@]} -gt 0 ] && export "${envs[@]}"
    bash "$HH/bin/ci-batch-red-report.sh" "$@" ) >"$T/out.txt" 2>&1
  RC=$?
}
TSV="$HH/state/ci-batch-red/latest.tsv"
REC="$HH/state/ci-batch-red/runs"
LOG="$HH/logs/ci-batch-red.log"
lastlog() { tail -1 "$LOG" 2>/dev/null; }
row() { awk -F'\t' -v s="$1" '$1 == s' "$TSV" 2>/dev/null; }
r() { local IFS="$TAB"; echo "$*"; }
ncalls() { if [ -f "$HH/calls.txt" ]; then grep -c -- "$1" "$HH/calls.txt"; else echo 0; fi; }
SH0='Tests, traced (shard 0/2)'; SH1='Tests, traced (shard 1/2)'
MQ=mergify/merge-queue/main/pr

# The ticket fixture: two red batches, one green; plus a cancelled batch and a
# red run off the merge queue, which are never read.
base_fixture() {
  reset
  run 101 "$MQ-11" failure 7200 tree1 "Merge of #11"
  jobs 101 "9001:failure:$SH0" "9002:success:$SH1" "9003:failure:Pure-logic gate fixtures"
  logf 9001 "2026-10-22T15:31:36.1234567Z --- tests/a-test.sh rc=1 3s" \
            "2026-10-22T15:31:37.1234567Z --- tests/b-test.sh rc=0 2s" \
            "2026-10-22T15:31:38.1234567Z GATE: pure-logic fail (1 of 65 failed)"
  run 102 "$MQ-12" failure 5400 tree2 "Merge of #12"
  jobs 102 "9011:failure:$SH0" "9012:success:$SH1" "9013:failure:Tests cannot touch a real harness"
  logf 9011 "2026-10-22T15:31:36.1Z --- tests/c-test.sh rc=0 1s" \
            "2026-10-22T15:31:36.2Z HIT c-test.sh rm /root/harness/x (tests/c-test.sh:3, cwd /w)  rm -f /root/harness/x" \
            "2026-10-22T15:31:36.3Z GATE: pure-logic pass (0 of 69 failed)"
  run 103 "$MQ-13" success 3600 tree1 "Merge of #13"
  jobs 103 "9021:success:$SH0" "9022:success:$SH1"
  logf 9021 "--- tests/a-test.sh rc=0 3s"
  logf 9022 "--- tests/z-test.sh rc=0 3s"
  run 104 "$MQ-14" cancelled 3000 tree4 "Merge of #14"
  run 105 ticket/bh-1 failure 2900 tree5 "Merge of #15"
  # PR 11's gate ran b-test and tests/mc/a-test.sh (same basename, not a-test.sh); PR 12's ran c-test.
  gate 501 11 8000 7001 tests/b-test.sh tests/mc/a-test.sh
  gate 502 12 6000 7002 tests/c-test.sh
}

# ── T-rows, T-log, S1, G1, E4
base_fixture
drive
[ "$RC" = 0 ] && ok || bad "T-rows: rc must be 0, got $RC ($(cat "$T/out.txt"))"
[ "$(head -1 "$TSV" 2>/dev/null)" = "$(r suite kind red_batches green_batches_since gate_missed retry_green prs)" ] && ok \
  || bad "T-rows: the TSV header: $(head -1 "$TSV" 2>/dev/null)"
[ "$(row tests/a-test.sh)" = "$(r tests/a-test.sh rc 1 1 1 1 11)" ] && ok \
  || bad "T-rows: a-test row (red 1, green since 1, gate missed 1, retry green 1, prs 11): '$(row tests/a-test.sh)'"
[ "$(row tests/c-test.sh)" = "$(r tests/c-test.sh trace 1 0 0 0 12)" ] && ok \
  || bad "T-rows: c-test row (trace, gate ran it, tree differs): '$(row tests/c-test.sh)'"
[ -z "$(row tests/b-test.sh)" ] && [ -z "$(row tests/z-test.sh)" ] && ok || bad "T-rows: an rc=0 suite has no row: $(cat "$TSV")"
[ "$(grep -c . "$TSV")" = 3 ] && ok || bad "T-rows: header + 2 rows (no fan-in job row): $(cat "$TSV")"
[ "$(grep -c . "$LOG" 2>/dev/null)" = 1 ] && ok || bad "T-log: one log line per tick: $(cat "$LOG" 2>/dev/null)"
lastlog | grep -q "ci-batch-red: repo=$REPO days=7 red=2 green=1 red_rate=66 unread=0 deferred=0 case=C share_a=50 share_b=50 pruned=0 ignored=1$" && ok \
  || bad "T-log: the summary line: $(lastlog)"
[ "$(ncalls 'actions/runs/104/')" = 0 ] && [ "$(ncalls 'actions/runs/105/')" = 0 ] && ok \
  || bad "S1: a cancelled batch and a non-queue run are never read"
[ "$(ncalls 'jobs/9002/logs')" = 0 ] && [ "$(ncalls 'jobs/9021/logs')" = 1 ] && [ "$(ncalls 'jobs/9022/logs')" = 1 ] && ok \
  || bad "T-rows: a red run reads only its failed shards, a green run every shard"
[ "$(ncalls '/logs')" -ge 1 ] && [ "$(grep '/logs' "$HH/calls.txt" | grep -vc -- '--allow-escape-sequences')" = 0 ] && ok \
  || bad "E4: every log read passes --allow-escape-sequences: $(grep '/logs' "$HH/calls.txt")"
[ "$(sed -n 1p "$REC/101")" = "run 101 attempt 1 created $(( NOW - 7200 )) concl red tree tree1 prs 11" ] && ok \
  || bad "T-rows: the record head line: $(sed -n 1p "$REC/101")"
grep -qxF "$(r gate 11 green 'tests/b-test.sh,tests/mc/a-test.sh')" "$REC/101" && ok \
  || bad "G1: the gate line holds the suites from 'impact-gate: done' lines: $(grep gate "$REC/101")"
cp "$TSV" "$T/tsv1"

# ── R1: the second tick reads no run again and writes the same TSV
drive
[ "$RC" = 0 ] && [ "$(ncalls 'actions/runs/')" = 0 ] && [ "$(ncalls prequeue-gate.yml)" = 0 ] && ok \
  || bad "R1: no jobs, log or gate read on the second tick: $(cat "$HH/calls.txt")"
cmp -s "$T/tsv1" "$TSV" && ok || bad "R1: the TSV is byte-identical: $(diff "$T/tsv1" "$TSV")"

# ── a re-run batch (attempt 2) is read again
jq '.workflow_runs |= map(if .id == 101 then .run_attempt = 2 else . end)' "$HH/fx/runs.1.json" > "$T/r.json" && mv "$T/r.json" "$HH/fx/runs.1.json"
drive
[ "$(ncalls 'actions/runs/101/jobs')" = 1 ] && [ "$(awk 'NR==1{print $4}' "$REC/101")" = 2 ] && ok \
  || bad "R1b: a new run_attempt is read again: $(head -1 "$REC/101")"

# ── E1: budget low
base_fixture
mkdir -p "$(dirname "$TSV")"; echo "keep" > "$TSV"
drive FAKE_BUDGET_LOW=0
[ "$RC" = 0 ] && [ ! -s "$HH/calls.txt" ] && ok || bad "E1: budget low = rc 0 and 0 gh calls: rc=$RC $(cat "$HH/calls.txt" 2>/dev/null)"
[ "$(cat "$TSV")" = keep ] && ok || bad "E1: latest.tsv untouched"
lastlog | grep -q 'skipped: GitHub budget low' && ok || bad "E1: one log line: $(lastlog)"

# ── E2: run 102's jobs cannot be read: 2 strikes, then `unread`; rc 0 each tick
base_fixture
rm -f "$HH/fx/jobs.102.json"
for i in 1 2 3; do
  drive
  [ "$RC" = 0 ] && ok || bad "E2: tick $i rc must be 0, got $RC"
  case $i in
    1|2) [ ! -f "$REC/102" ] && grep -q "^strikes $i " "$REC/102.strikes" && ok || bad "E2: tick $i is strike $i, no record" ;;
    3) head -1 "$REC/102" | grep -q ' unread$' && [ ! -f "$REC/102.strikes" ] && ok || bad "E2: the third strike writes the record unread: $(cat "$REC/102" 2>/dev/null)" ;;
  esac
done
[ "$(row unread)" = "$(r unread - 1 - - - 12)" ] && ok || bad "E2: the unread row: '$(row unread)'"
lastlog | grep -q 'red=2 green=1 red_rate=66 unread=1 deferred=0 case=A+B share_a=100 share_b=100' && ok \
  || bad "E2: an unread run is out of the case decision (run 101 alone is A and B): $(lastlog)"
drive
[ "$(ncalls 'actions/runs/102/')" = 0 ] && ok || bad "E2: an unread record is not read again"

# ── E3: CI_BATCH_RED_MAX=1
base_fixture
drive CI_BATCH_RED_MAX=1
lastlog | grep -q 'deferred=2 ' && [ -f "$REC/101" ] && [ ! -f "$REC/102" ] && ok || bad "E3: tick 1 reads the oldest, defers 2: $(lastlog)"
drive CI_BATCH_RED_MAX=1
lastlog | grep -q 'deferred=1 ' && ok || bad "E3: tick 2 defers 1: $(lastlog)"
drive CI_BATCH_RED_MAX=1
lastlog | grep -q 'red=2 green=1 .*deferred=0 ' && ok || bad "E3: tick 3 drained: $(lastlog)"

# ── E5: the runs page unreadable
base_fixture
rm -f "$HH/fx/runs.1.json"
drive
[ "$RC" = 0 ] && [ ! -f "$TSV" ] && [ -z "$(ls "$REC" 2>/dev/null)" ] && ok || bad "E5: rc 0 and nothing written"
lastlog | grep -q 'runs page unreadable' && ok || bad "E5: one log line: $(lastlog)"

# ── E6: the gate list unreadable: gate `?`, the rest proceeds
base_fixture
rm -f "$HH/fx/gates.1.json"
drive
[ "$(row tests/a-test.sh)" = "$(r tests/a-test.sh rc 1 1 '?' 1 11)" ] && ok || bad "E6: gate_missed is ? with no gate read: '$(row tests/a-test.sh)'"

# ── P1-P8: the log parser, one red run
reset
run 201 "$MQ-21" failure 3600 treeP "Merge of #21 and #22"
jobs 201 "9101:failure:$SH0" "9102:failure:Lint shell"
logf 9101 "2026-10-22T15:31:36.1234567Z --- tests/x-test.sh rc=1 3s" \
          "--- tests/mc/y.sh rc=137 9s" \
          "2026-10-22T15:31:36.1Z --- tests/w-test.sh rc=0 3s" \
          "2026-10-22T15:31:36.1Z --- tests/v-test.sh rc=10 1s" \
          "2026-10-22T15:31:36.1Z HIT closeout-retry.bh-781-test.sh rm /root/harness/state/x (a:1, cwd /w)  rm x" \
          "2026-10-22T15:31:36.1Z GATE: pure-logic pass (0 of 69 failed)" \
          "2026-10-22T15:31:36.1Z   --- tests/q-test.sh rc=1 1s"
drive
for want in "fail${TAB}tests/x-test.sh${TAB}1" "fail${TAB}tests/mc/y.sh${TAB}137" "ran${TAB}tests/w-test.sh" \
            "fail${TAB}tests/v-test.sh${TAB}10" "fail${TAB}tests/closeout-retry.bh-781-test.sh${TAB}trace" \
            "fail${TAB}job:Lint shell${TAB}other" "gate${TAB}21${TAB}?${TAB}-" "gate${TAB}22${TAB}?${TAB}-"; do
  grep -qxF "$want" "$REC/201" && ok || bad "P: the record holds '$want': $(cat "$REC/201")"
done
grep -q "^fail${TAB}tests/w-test.sh" "$REC/201" && bad "P3: rc=0 is never a failure" || ok
grep -q 'q-test' "$REC/201" && bad "P8: an indented echo of the marker is not a suite line" || ok
[ "$(grep -c '^fail' "$REC/201")" = 5 ] && ok || bad "P6: the GATE success line adds no row: $(grep '^fail' "$REC/201")"
[ "$(row tests/x-test.sh | cut -f7)" = "21,22" ] && ok || bad "P: prs are every #n of the first message line: '$(row tests/x-test.sh)'"
[ "$(row 'job:Lint shell')" = "$(r 'job:Lint shell' other 1 0 - 0 21,22)" ] && ok || bad "P: a failed non-shard job row: '$(row 'job:Lint shell')'"

# ── D1-D11: the decision table, over records the producer writes
recw() { # recw <id> <age-s> <red|green> <tree> <prs> [unread] — body lines on stdin
  mkdir -p "$REC"
  { echo "run $1 attempt 1 created $(( NOW - $2 )) concl $3 tree $4 prs $5${6:+ $6}"; cat; } > "$REC/$1"
}
dcase() { # dcase <name> <want case> <want share_a> <want share_b>
  echo '{"total_count":0,"workflow_runs":[]}' > "$HH/fx/runs.1.json"
  drive
  lastlog | grep -q "case=$2 share_a=$3 share_b=$4 " && ok || bad "$1: want case=$2 share_a=$3 share_b=$4: $(lastlog)"
}
F() { printf 'fail\t%s\t%s\n' "$1" "$2"; }
G() { printf 'gate\t%s\tgreen\t%s\n' "$1" "$2"; }
reset; { F tests/a.sh 1; G 1 tests/z.sh; } | recw 1 100 red t1 1
{ F tests/b.sh 1; G 2 tests/z.sh; } | recw 2 100 red t2 2
dcase D1 A 100 0
reset; { F tests/a.sh 1; G 1 tests/z.sh; } | recw 1 100 red t1 1
{ F tests/b.sh 1; G 2 tests/b.sh; } | recw 2 100 red t2 2
dcase "D2 (50 % is not most)" C 50 0
reset; { F tests/a-test.sh 1; G 1 tests/a-test.sh.bak; } | recw 1 100 red t1 1
dcase "D3 (a prefix is not a match)" A 100 0
reset; { F tests/a-test.sh 1; G 1 tests/a-test.sh; } | recw 1 100 red t1 1
dcase "D3b (the exact name is a match)" C 0 0
reset; { F tests/a.sh 1; F tests/b.sh 1; G 1 tests/b.sh; } | recw 1 100 red t1 1
dcase "D4 (one missed, one ran)" C 0 0
reset; { F tests/a.sh 1; G 1 tests/z.sh; printf 'gate\t2\t?\t-\n'; } | recw 1 100 red t1 1,2
dcase "D5 (a member gate unreadable)" C 0 0
reset; { F tests/a.sh 1; printf 'gate\t1\t?\t-\n'; } | recw 1 100 red t1 1
dcase "D5b" C 0 0
[ "$(row tests/a.sh | cut -f5)" = "?" ] && ok || bad "D5b: gate_missed is ? with no readable gate: '$(row tests/a.sh)'"
reset; { F tests/a.sh 1; G 1 tests/a.sh; } | recw 1 100 red t1 1
printf 'ran\ttests/a.sh\n' | recw 2 50 green t1 3
dcase "D6 (same tree green)" B 0 100
reset; { F tests/a.sh 1; G 1 tests/a.sh; } | recw 1 100 red t1 1
printf 'ran\ttests/a.sh\n' | recw 2 50 green t9 3
dcase "D7 (code changed)" C 0 0
reset; { F tests/a.sh 1; G 1 tests/z.sh; } | recw 1 100 red t1 1
printf 'ran\ttests/a.sh\n' | recw 2 200 green t8 3
printf 'ran\ttests/a.sh\n' | recw 3 50 green t9 4
dcase "D7b" A 100 0
[ "$(row tests/a.sh | cut -f4)" = 1 ] && ok || bad "D7b: green_batches_since counts only greens after the first red: '$(row tests/a.sh)'"
reset; { F "job:Lint" other; G 1 tests/z.sh; } | recw 1 100 red t1 1
: | recw 2 50 green t1 3
dcase "D8 (a job failure only)" C 0 0
reset; { F tests/a.sh 1; G 1 tests/z.sh; } | recw 1 100 red t1 1
: | recw 2 100 red t2 2 unread
dcase "D9 (unread is out)" A 100 0
reset; : | recw 2 50 green t1 3
dcase "D10 (no red)" C 0 0
reset; { F tests/a.sh 1; G 1 tests/z.sh; } | recw 1 100 red t1 1
{ F tests/b.sh trace; G 2 tests/z.sh; } | recw 2 100 red t2 2
{ F tests/c.sh 1; G 3 tests/c.sh; } | recw 3 100 red t3 3
: | recw 4 50 green t1 4
: | recw 5 50 green t2 5
dcase "D11 (2 of 3 both)" "A+B" 66 66
reset; { F tests/a.sh 1; G 1 tests/z.sh; } | recw 1 $(( 8 * 86400 )) red t1 1
dcase "D12 (a record outside the window counts nothing)" C 0 0

# ── K1: prune, --days, --dry-run, the lane file
reset; { F tests/a.sh 1; } | recw 1 $(( 31 * 86400 )) red t1 1
{ F tests/b.sh 1; } | recw 2 100 red t2 2
dcase K1 C 0 0
[ ! -f "$REC/1" ] && [ -f "$REC/2" ] && lastlog | grep -q 'pruned=1 ' && ok || bad "K1: a record over 30 days old is pruned: $(lastlog)"
base_fixture
drive -- --dry-run --days 3
[ "$RC" = 0 ] && [ ! -e "$TSV" ] && [ -z "$(ls "$REC" 2>/dev/null)" ] && [ ! -s "$LOG" ] && ok || bad "K1: --dry-run writes no record, TSV or log"
grep -q "^ci-batch-red: repo=$REPO days=3 red=2 green=1 .* case=C " "$T/out.txt" && grep -q "^tests/a-test.sh${TAB}rc${TAB}1" "$T/out.txt" && ok \
  || bad "K1: --dry-run prints the TSV and the line: $(cat "$T/out.txt")"
drive -- --days 99
[ "$RC" = 2 ] && ok || bad "K1: --days out of range is rc 2, got $RC"
L="$DIR/catalog/lanes.d/ci-batch-red-report.json"
[ "$(jq -r '[.id, .scope, .script, .switch.name, .stats.log, .wired] | join(" ")' "$L" 2>/dev/null)" \
  = "ci-batch-red-report hub bin/ci-batch-red-report.sh lane-off-ci-batch-red-report logs/ci-batch-red.log true" ] && ok \
  || bad "K1: the lane file's id, scope, script, switch and log"
[ "$(jq -r '[.knobs[] | "\(.env)=\(.default)"] | sort | join(" ")' "$L" 2>/dev/null)" \
  = "CI_BATCH_RED_DAYS=7 CI_BATCH_RED_KEEP_DAYS=30 CI_BATCH_RED_MAX=40 CI_BATCH_RED_PAGES=5 CI_BATCH_RED_REPO=example-org/cromford" ] && ok \
  || bad "K1: the lane knobs and defaults: $(jq -c '[.knobs[] | {(.env): .default}]' "$L" 2>/dev/null)"

echo "ci-batch-red-report: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
