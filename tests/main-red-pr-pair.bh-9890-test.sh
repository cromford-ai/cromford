#!/bin/bash
# tests/main-red-pr-pair.bh-9890-test.sh — the PR-pair lane does not freeze a
# repo on an operator-wait job, re-reads a named head that got a newer run
# attempt, and ages out its own freeze.
#
#   THE INCIDENT: on 2026-11-20 10:00:52Z bin/main-red-pr-pair.sh raised
#   flags/main-red-example-org-project-6 on two PRs (#3912, #3913) that failed
#   the migration-ledger job "gate". That job fails until an operator applies
#   the PR's SQL to prod, so it is no evidence of a red main. The operator ran
#   "gate" again at 01:21Z on 2026-11-22 (attempt 2, green on both heads), and
#   the lane still logged "still fail "gate" the same way": a head's verdict
#   row was write-once, so the freeze held itself for 2,240 minutes.
#
# Cases (the plan's acceptance tests A1-A13, plus A14-A15):
#   A1  operator-wait "gate" on example-org/project-6: no pair, no flag
#   A2  the exclusion is per repo: another repo's row excludes nothing
#   A3  both heads get a green newer attempt: re-read, flag cleared, pair resolved
#   A4  one head goes green: a group of 1 is not a pair, flag cleared
#   A5  the tick after A3 is quiet: no re-read, no GitHub read for those heads
#   A6  a detector-owned or hand-written flag is never changed
#   A7  a newer attempt still in flight: the old row stands, the flag stands
#   A8  an own freeze older than the limit with main not red: forced re-read and
#       a warn alert with the age, under one id, on each tick
#   A9  not stale (5h59m), decision=red, limit 0: no forced re-read, no alert
#   A10 --explain stays read-only on the A3 and A8 setups
#   A11 near misses: integration-gate, Gate, a number value, bad JSON pair
#   A12 a named head with no newer attempt costs 1 check-runs read, nothing more
#   A13 code fallbacks: no exclusion, and 21600 s as the age limit
#   A14 row mode through the real worker: the re-read verdict replaces the row
#       (replace:true), and the next tick does not pair the green heads again
#   A15 the stale alert closes even when main turned red after it opened; a
#       young freeze's clear never touches the stale id
#
# Every case drives the real script in file mode (no jobs-client, so no
# network) against a gh shim that applies the caller's -q filter with jq, a
# scratch $HARNESS and a recording lane-alert.sh. Timestamps are literals, or
# computed from `date -u` where the lane compares against its own clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$DIR/bin/main-red-pr-pair.sh" ] || {
  echo "FAIL: bin/main-red-pr-pair.sh does not exist"
  echo "main-red-pr-pair.bh-9890: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-pr-pair.bh-9890: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
scratch_install_closure bin/main-red-pr-pair.sh "$T" >/dev/null \
  || { echo "FAIL: cannot install the closure of bin/main-red-pr-pair.sh"
       echo "main-red-pr-pair.bh-9890: 0 passed, 1 failed"; exit 1; }
rm -f "$T/bin/jobs-client.sh"   # file mode: no coordination DB, no network
: > "$T/env/global.env"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# gh shim. The open PR list from $T/pulls.json; a head's runs from
# $T/runs-<sha>.json; a run's failing job from $T/jobs-<runid>.txt; one job's
# log from $T/joblog-<jobid>.txt; a commit's check runs from
# $T/checks-<sha>.json (absent = no check runs), filtered by check_name= as
# the real API does. The runs and check-runs reads apply the caller's own -q
# filter, so every field the lane asks for reaches it. Every call is recorded.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
Q=""; CN=""; prev=""
for a in "$@"; do
  [ "$prev" = "-q" ] && Q="$a"
  case "$a" in check_name=*) CN="${a#check_name=}" ;; esac
  prev="$a"
done
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 echo "[]" ;;
  *"/check-runs"*)            [ -f "$T/checks-fail" ] && exit 1
                              sha=${A##*/commits/}; sha=${sha%%/check-runs*}
                              f="$T/checks-$sha.json"
                              { [ -s "$f" ] && cat "$f" || echo '{"check_runs":[]}'; } \
                                | jq -c --arg n "$CN" '{check_runs:[.check_runs[]? | select($n == "" or .name == $n)]}' \
                                | jq -rc "${Q:-.}" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              case "$A" in *--allow-escape-sequences*) ;; *) exit 1 ;; esac
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           sha=${A##*head_sha=}; sha=${sha%% *}
                              [ -s "$T/runs-$sha.json" ] || exit 1
                              jq -rc "${Q:-.}" "$T/runs-$sha.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
LEDGERR="ledger-check: refuse. 1 of 1 file(s) are not in the prod ledger with the same checksum"
LOG="$T/logs/main-red-pr-pair.log"

set_slug() { # set_slug <owner/repo>
  SLUG="$1"; D=$(tr '/' '-' <<<"$1")
  MARKS="$T/state/main-red/pairs/$D"
  LEDGER="$T/state/main-red/pr-errors/$D"
  FLAG="$T/flags/main-red-$D"
  VERDICT="$T/state/main-red/$D.verdict"
}
pulls() { # pulls <number:head-sha:updatedAt>...
  local out='[' first=1 spec num sha upd
  for spec in "$@"; do
    IFS=':' read -r num sha upd <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$num" --arg sha "$sha" --arg u "$upd" \
      '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)),
        title:"t", body:"", head:{sha:$sha, ref:("b"+($n|tostring))},
        base:{ref:"main"}, draft:false, user:{login:"operator", type:"User"},
        created_at:$u, updated_at:$u, merged_at:null, closed_at:null,
        labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$T/pulls.json"
}
head_run() { # head_run <sha> <conclusion|null> <created_at> <run-id> [status] [attempt] [run_started_at]
  jq -nc --arg p "$CI" --arg c "$2" --arg t "$3" --argjson id "$4" \
    --arg s "${5:-completed}" --argjson a "${6:-1}" --arg st "${7:-$3}" \
    '{workflow_runs:[{name:"Harness CI", path:$p, status:$s,
       conclusion:(if $c=="null" then null else $c end), created_at:$t,
       run_started_at:$st, run_attempt:$a,
       html_url:("https://github.com/o/r/actions/runs/"+($id|tostring)), id:$id}]}' > "$T/runs-$1.json"
}
job_of() { printf '%s\t%s\n' "$2" "$3" > "$T/jobs-$1.txt"; }  # job_of <run-id> <job name> <job id>
joblog() { printf '%s\n' "$2" > "$T/joblog-$1.txt"; }          # joblog <job id> <text>
checks() { # checks <sha> <name|status|conclusion|started_at>...
  local sha="$1" out='{"check_runs":[' first=1 spec n s c st; shift
  for spec in "$@"; do
    IFS='|' read -r n s c st <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg s "$s" --arg c "$c" --arg st "$st" \
      '{name:$n, status:$s, conclusion:(if $c=="null" then null else $c end), started_at:$st}')
  done
  printf '%s]}' "$out" > "$T/checks-$sha.json"
}
verdict_file() { # verdict_file <decision>
  mkdir -p "$T/state/main-red"
  { echo "decision=$1"; echo "reason=fixture"; echo "sha="; echo "at=2026-11-22 01:00:00Z"; } > "$VERDICT"
}
owait_env() { # owait_env <json> | owait_env — the operator-wait row as the box env
  if [ $# -gt 0 ]; then printf "MAIN_RED_PAIR_OPERATOR_WAIT_JOBS='%s'\n" "$1" > "$T/env/global.env"
  else : > "$T/env/global.env"; fi
}
drive() { # drive [args...] — one tick
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt"
    unset GH_TOKEN HARNESS_SECRET JOBS_URL MAIN_RED_PAIR_OPERATOR_WAIT_JOBS MAIN_RED_PAIR_FREEZE_MAX_AGE_S
    [ -n "${AGE_KNOB:-}" ] && export MAIN_RED_PAIR_FREEZE_MAX_AGE_S="$AGE_KNOB"
    bash "$T/bin/main-red-pr-pair.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
iso_ago() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
stamp_ago() { date -u -d "@$(( $(date -u +%s) - $1 ))" '+%Y-%m-%d %H:%M:%SZ'; }
crit()     { grep -c -- '--severity critical' "$T/alerts.txt" 2>/dev/null; }
stale()    { grep -c -- "--id main-red-pair-stale:$D" "$T/alerts.txt" 2>/dev/null; }
markers()  { ls -A "$MARKS" 2>/dev/null | awk 'END{print NR+0}'; }
col1()     { cut -f1 "$LEDGER/$1.tsv" 2>/dev/null; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$LOG"
  scratch_rm "$T/state/main-red"; rm -f "$T"/flags/main-red-*
  rm -f "$T"/runs-*.json "$T"/jobs-*.txt "$T"/joblog-*.txt "$T"/checks-*.json "$T/checks-fail"
  AGE_KNOB=""; owait_env
}
quiet() { : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$LOG"; }
# gate_pair <job> — #1 (aaaa111) and #2 (bbbb222) fail <job> with the same
# first error, runs 35 s apart, and the detector has no decision.
gate_pair() {
  local job="${1:-gate}"
  pulls "1:aaaa111:2026-11-20T09:55:00Z" "2:bbbb222:2026-11-20T09:56:00Z"
  head_run aaaa111 failure 2026-11-20T09:50:00Z 9001; job_of 9001 "$job" 8001
  head_run bbbb222 failure 2026-11-20T09:50:35Z 9002; job_of 9002 "$job" 8002
  joblog 8001 "$(printf '2026-11-20T09:51:02.1234567Z %s\n2026-11-20T09:51:02.2234567Z ##[error]Process completed with exit code 1.' "$LEDGERR")"
  joblog 8002 "$(printf '2026-11-20T09:51:40.7654321Z %s\n2026-11-20T09:51:40.8654321Z ##[error]Process completed with exit code 1.' "$LEDGERR")"
  verdict_file none
}
age_ledger() { touch -d "@$(( $(date -u +%s) - 3600 ))" "$LEDGER"/*.tsv; }  # rows written 1 h ago
green_attempt() { # green_attempt <sha> <run-id> — attempt 2 of "gate" ran green 10 min ago
  head_run "$1" success 2026-11-20T09:50:00Z "$2" completed 2 "$(iso_ago 600)"
  checks "$1" "gate|completed|failure|$(iso_ago 90000)" "gate|completed|success|$(iso_ago 600)"
}
# pair_raised — tick 1 of A3/A4/A7/A8: a gate pair on o/r raises the own flag.
pair_raised() {
  reset_case; set_slug o/r; gate_pair gate; drive o/r
  [ -f "$FLAG" ] && grep -q '^owner=main-red-pr-pair$' "$FLAG" \
    || bad "setup: tick 1 did not raise the own flag: $(cat "$LOG")"
  age_ledger; quiet
}

# ── A1: operator-wait gate on project-6 forms no pair (red first) ─────────
reset_case; set_slug example-org/project-6; owait_env '{"example-org/project-6":"gate"}'
gate_pair gate; drive example-org/project-6
[ "$(crit)" = 0 ] && ok || bad "A1: an operator-wait job paged: $(cat "$T/alerts.txt")"
[ ! -e "$FLAG" ] && ok || bad "A1: an operator-wait job raised the freeze: $(cat "$FLAG")"
[ "$(markers)" = 0 ] && ok || bad "A1: a pair marker was written: $(ls -A "$MARKS")"
grep -q 'job "gate" is an operator-wait job' "$LOG" && ok \
  || bad "A1: no operator-wait log line: $(cat "$LOG")"
[ "$(col1 aaaa111)" = gate ] && ok || bad "A1: the verdict row must still record the job: '$(col1 aaaa111)'"

# ── A2: the exclusion is per repo ──────────────────────────────────────────
reset_case; set_slug example-org/project-6; owait_env '{"other/repo":"gate"}'
gate_pair gate; drive example-org/project-6
[ "$(crit)" = 1 ] && ok || bad "A2: another repo's row must not exclude here: $(cat "$T/alerts.txt")"
[ -f "$FLAG" ] && ok || bad "A2: the pair must raise the freeze: $(cat "$LOG")"

# ── A3: both heads get a green newer attempt (red first) ──────────────────
pair_raised
green_attempt aaaa111 9001; green_attempt bbbb222 9002
drive o/r
grep -q 're-read (newer run attempt)' "$LOG" && ok || bad "A3: no re-read log line: $(cat "$LOG")"
[ "$(col1 aaaa111)" = - ] && [ "$(col1 bbbb222)" = - ] && ok \
  || bad "A3: the re-read verdicts were not recorded: '$(col1 aaaa111)' '$(col1 bbbb222)'"
[ ! -e "$FLAG" ] && ok || bad "A3: the own flag stands after both heads went green: $(cat "$LOG")"
[ "$(grep -c -- '--resolve --id main-red-prs:o-r:' "$T/alerts.txt")" = 1 ] && ok \
  || bad "A3: want one pair resolve: $(cat "$T/alerts.txt")"
grep -q 'no pair fires after re-reading 2 head(s)' "$LOG" && ok \
  || bad "A3: no 'no pair fires after re-reading' line: $(cat "$LOG")"

# ── A5: the next tick is quiet ─────────────────────────────────────────────
quiet; drive o/r
grep -q 're-read' "$LOG" && bad "A5: a quiet tick re-read a head: $(cat "$LOG")" || ok
[ ! -s "$T/alerts.txt" ] && ok || bad "A5: a quiet tick sent: $(cat "$T/alerts.txt")"
[ "$(grep -c 'check-runs\|actions/runs' "$T/gh.txt")" = 0 ] && ok \
  || bad "A5: heads no longer named were read again: $(cat "$T/gh.txt")"

# ── A4: only head 1 goes green ─────────────────────────────────────────────
pair_raised
green_attempt aaaa111 9001
drive o/r
[ "$(col1 aaaa111)" = - ] && [ "$(col1 bbbb222)" = gate ] && ok \
  || bad "A4: rows: '$(col1 aaaa111)' '$(col1 bbbb222)'"
[ ! -e "$FLAG" ] && ok || bad "A4: a group of 1 is not a pair, the flag must clear: $(cat "$LOG")"
[ "$(grep -c -- '--resolve --id main-red-prs:o-r:' "$T/alerts.txt")" = 1 ] && ok \
  || bad "A4: want one pair resolve: $(cat "$T/alerts.txt")"

# ── A6: a detector-owned or hand-written flag is never changed ─────────────
for body in "reason=streak|job=Tests|since=2026-11-20 10:00:00Z" "reason=manual|by=operator"; do
  pair_raised
  tr '|' '\n' <<<"$body" > "$FLAG"; before=$(sha1sum < "$FLAG")
  green_attempt aaaa111 9001; green_attempt bbbb222 9002
  drive o/r
  [ -f "$FLAG" ] && [ "$(sha1sum < "$FLAG")" = "$before" ] && ok \
    || bad "A6: a flag this lane did not raise changed (${body%%|*}): $(cat "$FLAG" 2>/dev/null)"
  [ "$(stale)" = 0 ] && ok || bad "A6: a stale alert on a flag this lane did not raise: $(cat "$T/alerts.txt")"
done
# and an old one: a detector-owned flag 7 h old forces nothing.
pair_raised
printf 'reason=streak\nsince=%s\n' "$(stamp_ago 25200)" > "$FLAG"; before=$(sha1sum < "$FLAG")
drive o/r
[ "$(sha1sum < "$FLAG")" = "$before" ] && [ "$(stale)" = 0 ] && ok \
  || bad "A6: an old detector-owned flag was touched or alerted on: $(cat "$T/alerts.txt")"
grep -q '/actions/runs/900[12]/jobs' "$T/gh.txt" && bad "A6: an old detector-owned flag forced a re-read" || ok

# ── A7: a newer attempt still in flight ────────────────────────────────────
pair_raised
row_before=$(cat "$LEDGER/aaaa111.tsv")
head_run aaaa111 null 2026-11-20T09:50:00Z 9001 in_progress 2 "$(iso_ago 60)"
checks aaaa111 "gate|completed|failure|$(iso_ago 90000)" "gate|in_progress|null|$(iso_ago 60)"
drive o/r
[ "$(cat "$LEDGER/aaaa111.tsv")" = "$row_before" ] && ok || bad "A7: an in-flight re-read changed the row"
[ -f "$FLAG" ] && ok || bad "A7: an in-flight re-read cleared the flag: $(cat "$LOG")"
grep -q 'aaaa111.*no verdict yet' "$LOG" && ok || bad "A7: the in-flight re-read is not logged: $(cat "$LOG")"

# ── A12: a named head with no newer attempt costs one check-runs read ──────
pair_raised
drive o/r
[ "$(grep -c '/commits/aaaa111/check-runs' "$T/gh.txt")" = 1 ] && ok \
  || bad "A12: want 1 check-runs read for head 1: $(cat "$T/gh.txt")"
[ "$(grep -c 'head_sha=\|/jobs\|/logs' "$T/gh.txt")" = 0 ] && ok \
  || bad "A12: a head with no newer attempt was read in full: $(cat "$T/gh.txt")"
[ -f "$FLAG" ] && ok || bad "A12: the flag must stand: $(cat "$LOG")"
grep -q 're-read' "$LOG" && bad "A12: a re-read without a newer attempt: $(cat "$LOG")" || ok

# ── A8: an own freeze 7 h old, main not red ────────────────────────────────
pair_raised
sed -i "s/^since=.*/since=$(stamp_ago 25200)/" "$FLAG"
for tick in 1 2; do
  : > "$T/gh.txt"; : > "$LOG"
  drive o/r
  grep -q '/actions/runs/9001/jobs' "$T/gh.txt" && grep -q '/actions/runs/9002/jobs' "$T/gh.txt" && ok \
    || bad "A8 tick $tick: a stale freeze did not re-read both heads: $(cat "$T/gh.txt")"
  grep -q 'freeze main-red-o-r is 7h0m old' "$LOG" && ok || bad "A8 tick $tick: no stale log line: $(cat "$LOG")"
  [ -f "$FLAG" ] && ok || bad "A8 tick $tick: the flag must stand (both heads still fail)"
done
[ "$(grep -c -- '--severity warn --id main-red-pair-stale:o-r main-red' "$T/alerts.txt")" = 2 ] && ok \
  || bad "A8: want the warn alert under one id on each of 2 ticks: $(cat "$T/alerts.txt")"
grep -q 'is 7h0m old' "$T/alerts.txt" && ok || bad "A8: the alert must carry the age: $(cat "$T/alerts.txt")"
# and when the heads go green, the clear resolves the stale alert.
green_attempt aaaa111 9001; green_attempt bbbb222 9002; quiet; drive o/r
[ ! -e "$FLAG" ] && ok || bad "A8: the stale freeze did not clear once the heads went green"
grep -q -- '--resolve --id main-red-pair-stale:o-r' "$T/alerts.txt" && ok \
  || bad "A8: the stale alert was not resolved with the clear: $(cat "$T/alerts.txt")"

# ── A9: not stale ──────────────────────────────────────────────────────────
a9() { # a9 <label> <age-s> <decision> [knob]
  pair_raised
  sed -i "s/^since=.*/since=$(stamp_ago "$2")/" "$FLAG"; verdict_file "$3"; AGE_KNOB="${4:-}"
  drive o/r
  grep -q '/actions/runs/900[12]/jobs' "$T/gh.txt" && bad "A9 $1: a forced re-read: $(cat "$LOG")" || ok
  [ "$(stale)" = 0 ] && ok || bad "A9 $1: a stale alert: $(cat "$T/alerts.txt")"
  AGE_KNOB=""
}
a9 "5h59m" 21540 none
a9 "decision=red" 25200 red
a9 "limit 0" 25200 none 0

# ── A10: --explain is read-only ────────────────────────────────────────────
# state/gh-rest-ledger/ is bin/lib/gh-rest.sh's own count of GitHub calls,
# written on every read in every mode; it is not this lane's state.
tree_sum() { find "$T/state" "$T/flags" "$T/locks" -path "$T/state/gh-rest-ledger" -prune -o -type f \
               -printf '%p %T@\n' -exec sha1sum {} \; 2>/dev/null | sort | sha1sum; }
pair_raised
green_attempt aaaa111 9001; green_attempt bbbb222 9002
before=$(tree_sum); drive --explain o/r
[ "$(tree_sum)" = "$before" ] && ok || bad "A10: --explain changed state, flags or locks"
[ ! -s "$T/alerts.txt" ] && ok || bad "A10: --explain sent: $(cat "$T/alerts.txt")"
grep -q 'WOULD RECORD o/r aaaa111 :: -' "$T/out.txt" && ok || bad "A10: no WOULD RECORD for the re-read head: $(cat "$T/out.txt")"
pair_raised
sed -i "s/^since=.*/since=$(stamp_ago 25200)/" "$FLAG"
before=$(tree_sum); drive --explain o/r
[ "$(tree_sum)" = "$before" ] && ok || bad "A10: --explain (stale) changed state, flags or locks"
[ ! -s "$T/alerts.txt" ] && ok || bad "A10: --explain (stale) sent: $(cat "$T/alerts.txt")"
grep -q 'WOULD ALERT main-red-pair-stale:o-r' "$T/out.txt" && ok || bad "A10: no WOULD ALERT for the stale freeze: $(cat "$T/out.txt")"

# ── A11: near misses still pair; a list still excludes ─────────────────────
a11() { # a11 <label> <owait-json> <job> <want-crit>
  reset_case; set_slug example-org/project-6; owait_env "$2"; gate_pair "$3"; drive example-org/project-6
  [ "$(crit)" = "$4" ] && ok || bad "A11 $1: want $4 pair alert(s): $(cat "$T/alerts.txt") / $(cat "$LOG")"
}
a11 "integration-gate" '{"example-org/project-6":"gate"}' integration-gate 1
a11 "Gate (case)"      '{"example-org/project-6":"gate"}' Gate 1
a11 "number value"     '{"example-org/project-6":5}' gate 1
a11 "list lint, gate"  '{"example-org/project-6":"lint, gate"}' gate 0
a11 "bad JSON"         '{gate' gate 1
[ "$(grep -c 'main_red_pair_operator_wait_jobs is not a JSON object' "$LOG")" = 1 ] && ok \
  || bad "A11: bad JSON must be logged once: $(cat "$LOG")"

# ── A13: code fallbacks ────────────────────────────────────────────────────
reset_case; set_slug example-org/project-6; gate_pair gate; drive example-org/project-6
[ "$(crit)" = 1 ] && [ -f "$FLAG" ] && ok || bad "A13: with no row, gate must pair as before: $(cat "$LOG")"
pair_raised
sed -i "s/^since=.*/since=$(stamp_ago 21660)/" "$FLAG"; drive o/r
[ "$(stale)" = 1 ] && ok || bad "A13: 6h1m with no knob set must be stale (21600 s): $(cat "$LOG")"

# ── A14: row mode — the re-read verdict REPLACES the worker row ────────────
# The cases above run in file mode. Here the lane runs with the REAL
# bin/jobs-client.sh against the REAL worker router over one node:sqlite file
# (the tests/main-red-state-rows.bh-4156-test.sh pattern: a fake curl hands
# each request to worker.fetch). Without replace:true the PUT is write-once,
# the "gate" rows would stand, and the next tick would pair them again.
a14() {
  if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
    echo "A14: SKIPPED, this node has no node:sqlite"; return 0; fi
  jobs_schema_render || { bad "A14: worker/jobs/schema.sql could not be composed"; return 0; }
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/a14-lb.out" 2>&1 \
    || { bad "A14: catalog/lanes.json could not be composed: $(cat "$T/a14-lb.out")"; return 0; }
  "$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null 2>&1 \
    || { bad "A14: catalog/llm-sites.json could not be composed"; return 0; }
  local RH="$T/rh" SECRET=tok-fixture-bh9890 DB="$T/a14.sqlite"
  mkdir -p "$RH/bin" "$RH/logs" "$RH/flags" "$RH/locks" "$RH/state" "$RH/env" "$T/rowbin"
  : > "$RH/env/global.env"
  for s in bin/main-red-pr-pair.sh bin/jobs-client.sh; do
    scratch_install_closure "$s" "$RH" >/dev/null || { bad "A14: closure of $s"; return 0; }
  done
  cp "$T/bin/lane-alert.sh" "$RH/bin/lane-alert.sh"
  cat >"$T/a14-init.mjs" <<EOF
import { readFileSync, rmSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
rmSync('$DB', { force: true });
new DatabaseSync('$DB').exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
EOF
  cat >"$T/a14-drv.mjs" <<EOF
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync('$DB');
const [method, url, body] = process.argv.slice(2);
const res = await worker.fetch(new Request(url, {
  method, headers: { authorization: 'Bearer $SECRET', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: '$SECRET' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
  cat >"$T/rowbin/curl" <<STUB
#!/bin/bash
URL=""; BODY=""; M=GET
while [ \$# -gt 0 ]; do
  case "\$1" in --data-binary|-d|--data) BODY="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;; http*://*) URL="\$1"; shift ;; *) shift ;; esac
done
case "\$URL" in https://jobs.test*) ;; *) exit 22 ;; esac
case "\$BODY" in @*) BODY=\$(cat "\${BODY#@}") ;; esac
printf '%s %s %s\n' "\$M" "\${URL#https://jobs.test}" "\$BODY" >> "$T/a14-req.log"
exec flock "$DB.lock" node "$T/a14-drv.mjs" "\$M" "\$URL" "\$BODY"
STUB
  chmod +x "$T/rowbin/curl"
  sqlq() { NODE_OPTIONS=--no-warnings node -e '
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(process.argv[2]);
    if (process.argv[3] === "x") { db.exec(process.argv[1]); process.exit(0); }
    for (const r of db.prepare(process.argv[1]).all()) console.log(Object.values(r).join("\t"));' "$1" "$DB" "${2:-}"; }
  rdrive() {
    ( export PATH="$T/rowbin:$T/fakebin:$PATH" GH_SINK="$T/gh.txt" ALERT_SINK="$T/alerts.txt" T="$T" NODE_OPTIONS=--no-warnings
      unset GH_TOKEN MAIN_RED_PAIR_OPERATOR_WAIT_JOBS MAIN_RED_PAIR_FREEZE_MAX_AGE_S
      env HARNESS="$RH" HARNESS_ENV_DIR="$RH/env" HARNESS_SECRET="$SECRET" JOBS_URL=https://jobs.test \
        JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=60 JOBS_ALERT=0 JOBS_BOX=box-fixture \
        LANE_GATE_CACHE_S=0 bash "$RH/bin/main-red-pr-pair.sh" o/r >"$T/a14-out.txt" 2>"$T/a14-err.txt" )
  }
  NODE_OPTIONS=--no-warnings node "$T/a14-init.mjs" || { bad "A14: schema.sql did not apply"; return 0; }
  reset_case; set_slug o/r; : > "$T/a14-req.log"
  gate_pair gate
  rm -f "$VERDICT"   # the detector verdict lives in the row here; none = not red
  ( export PATH="$T/rowbin:$PATH" NODE_OPTIONS=--no-warnings
    curl -X PUT https://jobs.test/api/main-red-state/verdict \
      --data-binary '{"repo":"o/r","decision":"none","reason":"fixture","sha":""}' >/dev/null ) \
    || { bad "A14: the verdict row could not be seeded"; return 0; }
  rdrive
  local rflag="$RH/flags/main-red-o-r"
  [ -f "$rflag" ] && grep -q '^owner=main-red-pr-pair$' "$rflag" && ok \
    || { bad "A14: row-mode tick 1 did not raise the own flag: $(cat "$RH/logs/main-red-pr-pair.log" 2>/dev/null | tail -5)"; return 0; }
  [ "$(sqlq "SELECT job FROM main_red_pr_errors WHERE repo='o/r' ORDER BY head" | tr '\n' ' ')" = "gate gate " ] && ok \
    || bad "A14: tick 1 rows: $(sqlq "SELECT head, job, at FROM main_red_pr_errors")"
  # the rows were written an hour ago; then both heads get a green attempt 2.
  sqlq "UPDATE main_red_pr_errors SET at='$(iso_ago 3600)' WHERE repo='o/r'" x
  green_attempt aaaa111 9001; green_attempt bbbb222 9002
  : > "$T/a14-req.log"; : > "$RH/logs/main-red-pr-pair.log"
  rdrive
  [ "$(sqlq "SELECT job FROM main_red_pr_errors WHERE repo='o/r' ORDER BY head" | tr '\n' ' ')" = "- - " ] && ok \
    || bad "A14: the re-read verdicts did not replace the worker rows: $(sqlq "SELECT head, job, at FROM main_red_pr_errors") / $(grep 'pr-errors' "$T/a14-req.log")"
  [ "$(grep -c '^PUT /api/main-red-state/pr-errors .*"replace":true' "$T/a14-req.log")" = 2 ] && ok \
    || bad "A14: want 2 replace PUTs: $(grep 'pr-errors' "$T/a14-req.log")"
  [ ! -e "$rflag" ] && ok || bad "A14: the own flag stands in row mode: $(tail -5 "$RH/logs/main-red-pr-pair.log")"
  # tick 3: the rows say green, so nothing is paired and nothing is re-read.
  : > "$T/a14-req.log"; : > "$RH/logs/main-red-pr-pair.log"; : > "$T/alerts.txt"
  rdrive
  grep -q 're-read' "$RH/logs/main-red-pr-pair.log" && bad "A14: tick 3 re-read a head" || ok
  [ "$(crit)" = 0 ] && [ ! -e "$rflag" ] && ok || bad "A14: tick 3 paired the green heads again: $(cat "$T/alerts.txt")"
}
a14

# ── A15: the stale alert closes even when main turned red after it opened ──
# A young freeze never sends the resolve (tests/main-red-pair-suspected.bh-1451
# P5 counts one resolve line on a clear); an old one always does.
pair_raised
sed -i "s/^since=.*/since=$(stamp_ago 25200)/" "$FLAG"; drive o/r
[ "$(stale)" = 1 ] && ok || bad "A15: setup: no stale alert: $(cat "$T/alerts.txt")"
age_ledger   # the stale tick re-read both heads and rewrote their rows
verdict_file red; green_attempt aaaa111 9001; green_attempt bbbb222 9002; quiet; drive o/r
[ ! -e "$FLAG" ] && ok || bad "A15: the freeze did not clear once the heads went green: $(cat "$LOG")"
grep -q -- '--resolve --id main-red-pair-stale:o-r' "$T/alerts.txt" && ok \
  || bad "A15: decision=red on the clear tick left the stale alert open: $(cat "$T/alerts.txt")"
pair_raised
green_attempt aaaa111 9001; green_attempt bbbb222 9002; drive o/r
[ ! -e "$FLAG" ] && ! grep -q -- 'main-red-pair-stale' "$T/alerts.txt" && ok \
  || bad "A15: a young freeze's clear touched the stale id: $(cat "$T/alerts.txt")"

echo "main-red-pr-pair.bh-9890: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
