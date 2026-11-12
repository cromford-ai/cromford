#!/bin/bash
# tests/ci-minutes-watch.k1-test.sh — bin/ci-minutes-watch.sh driven against a
# scratch harness with a fake `gh` that serves fixture run lists and job lists.
#
# WHAT IT PINS (K1, 2026-09-24 — MonkCI billing ~120K job-minutes/day, nothing
# in the harness measuring it):
#   1  the estimate: wall minutes x the sampled billed/wall ratio, only jobs
#      whose runner labels match, each job rounded UP to a whole minute
#   2  over CI_MINUTES_DAY_MAX: ONE critical page on the deterministic path
#      (a triaged critical beat), deduped for a day
#   3  under the line: no page, and the log line + state/ci-minutes/latest.json
#      are written anyway
#   4  the GitHub budget: exactly pages + sample reads + one closed-PR read
#      (BH-9411) per readable repo, and a repo whose
#      run list fills every page is named a floor
#   5  a repo nobody can read is named, not counted as zero, and does not stop
#      the others
#   6  a low GitHub bucket skips the tick with no read at all
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx" "$T/stub"
cp "$DIR/bin/ci-minutes-watch.sh" "$DIR/bin/fleet-conf.sh" "$HH/bin/"
cp "$DIR/bin/lib/gh-ci-read.sh" "$DIR/bin/lib/page-critical.sh" "$HH/bin/lib/"
cat > "$HH/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$HARNESS/beats.txt"
SH
chmod +x "$HH/bin/beat.sh"
cat > "$HH/fleet.conf" <<'CONF'
a     Acme/a   - - 1 box-a 10.0.0.1
b     Acme/b   - - 2 box-a 10.0.0.1
b2    Acme/b   - - 3 box-a 10.0.0.1
c     Acme/c   - - 4 box-a 10.0.0.1
none  -        - - 5 box-a 10.0.0.1
CONF

# The fake gh: `api [flags] <path> [-f k=v]... [-q filter]`. It serves
# fx/<owner>_<repo>.runs.<page>.json and fx/<owner>_<repo>.jobs.<id>.json,
# applies -q with jq exactly as gh does, and records every call.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
shift   # "api"
P=""; Q=""; PG=1
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    -q|--jq) Q="$2"; shift 2 ;;
    -f) case "$2" in page=*) PG="${2#page=}" ;; esac; shift 2 ;;
    *) P="$1"; shift ;;
  esac
done
echo "$P page=$PG" >> "$HARNESS/gh-calls.txt"
R=$(sed -E 's#^repos/([^/]+)/([^/]+)/.*#\1_\2#' <<<"$P")
case "$P" in
  */actions/runs/*/jobs*) ID=$(sed -E 's#.*/runs/([0-9]+)/jobs.*#\1#' <<<"$P"); F="$HARNESS/fx/$R.jobs.$ID.json" ;;
  */actions/runs) F="$HARNESS/fx/$R.runs.$PG.json" ;;
  */pulls) F="$HARNESS/fx/$R.pulls.json"; [ -r "$F" ] || echo '[]' > "$F" ;;
  *) exit 1 ;;
esac
[ -r "$F" ] || exit 1
if [ -n "$Q" ]; then jq -c "$Q" "$F"; else cat "$F"; fi
SH
chmod +x "$T/stub/gh"

runs() { # runs <repo_key> <page> <count> <first-id> <wall-seconds> [workflow_id] [total_count] [append]
  local i out="" id f="$HH/fx/$1.runs.$2.json" prev="[]"
  for (( i = 0; i < $3; i++ )); do
    id=$(( $4 + i ))
    out="$out${out:+,}{\"id\":$id,\"workflow_id\":${6:-1},\"run_started_at\":\"$(iso $(( 7200 + $5 )))\",\"updated_at\":\"$(iso 7200)\"}"
  done
  [ -n "${8:-}" ] && [ -r "$f" ] && prev=$(jq -c '.workflow_runs' "$f")
  jq -n --argjson p "$prev" --argjson n "[$out]" --argjson t "${7:-0}" \
    '{total_count: (if $t > 0 then $t else ($p + $n | length) end), workflow_runs: ($p + $n)}' > "$f"
}
jobs() { # jobs <repo_key> <id> <label> <n-jobs> <secs-each>
  local i out=""
  for (( i = 0; i < $4; i++ )); do
    out="$out${out:+,}{\"labels\":[\"$3\"],\"runner_name\":\"r$i\",\"started_at\":\"$(iso $(( 7200 + $5 )))\",\"completed_at\":\"$(iso 7200)\"}"
  done
  # plus one job on a runner that does not match, which must never be billed
  out="$out,{\"labels\":[\"ubuntu-latest\"],\"started_at\":\"$(iso 9000)\",\"completed_at\":\"$(iso 7200)\"}"
  echo "{\"jobs\":[$out]}" > "$HH/fx/$1.jobs.$2.json"
}
drive() { # drive [env assignments...]
  rm -f "$HH/gh-calls.txt" "$HH/beats.txt"
  ( export HARNESS="$HH" FLEET_CONF="$HH/fleet.conf" NOW PATH="$T/stub:$PATH" CI_MINUTES_DAY_MAX=100 CI_MINUTES_BILL_MULT=1
    [ $# -gt 0 ] && export "${@?}"
    bash "$HH/bin/ci-minutes-watch.sh" ) >"$T/out.txt" 2>&1
}
calls() { if [ -f "$HH/gh-calls.txt" ]; then wc -l < "$HH/gh-calls.txt" | tr -d ' '; else echo 0; fi; }

# Acme/a: 10 runs of 10 wall-minutes each; every run's jobs are 3 MonkCI jobs of
# 5m30s (billed 6 each = 18) and one ubuntu-latest job. Ratio 18/10 -> est 180.
runs Acme_a 1 10 100 600
for id in $(seq 100 109); do jobs Acme_a "$id" monkci-ubuntu-24.04-4 3 330; done
# Acme/b: 4 runs, only GitHub-hosted jobs -> 0 billed.
runs Acme_b 1 4 200 600
for id in $(seq 200 203); do jobs Acme_b "$id" ubuntu-latest 2 600; done
# Acme/c: no fixture at all -> the read fails.

# 1-2. over the line: the estimate, one critical page on the triaged path
drive
L=$(grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1)
grep -q '10 run(s) in 24h, 100 wall min' <<<"$L" && grep -q 'sample 10 run(s) billed 180 job-min over 100 wall min' <<<"$L" \
  && grep -q 'est 180 billed job-min/24h' <<<"$L" && ok || bad "1: Acme/a's estimate must be 100 x 180/100 = 180: $L"
grep -q 'Acme/b: .*est 0 billed' "$HH/logs/ci-minutes-watch.log" && ok || bad "1: a repo with no matching runner bills 0"
B=$(cat "$HH/beats.txt" 2>/dev/null)
[ "$(jq -r '.triaged' <<<"$B")" = true ] && [ "$(jq -r '.severity' <<<"$B")" = critical ] \
  && [ "$(jq -r '.alertid' <<<"$B")" = "ci-minutes:fleet" ] && grep -q 'estimated 180 job-minutes' <<<"$(jq -r .line <<<"$B")" \
  && grep -q 'Top: Acme/a 180 min' <<<"$(jq -r .line <<<"$B")" && ok \
  || bad "2: over the line pages ONE triaged critical beat with the total and the top repo: $B"
grep -q 'CRITICAL \[ci-minutes-watch\] ci-minutes:fleet' "$HH/logs/ALERTS.log" && ok || bad "2: the ALERTS line names the lane"
drive
[ ! -s "$HH/beats.txt" ] && ok || bad "2: the page is once a day, not once a tick"

# 3. under the line: no page, the record still written
rm -f "$HH/state/page-critical.json"
drive CI_MINUTES_DAY_MAX=1000
[ ! -s "$HH/beats.txt" ] && ok || bad "3: under the line must not page"
[ "$(jq -r '.est_billed_job_minutes_24h' "$HH/state/ci-minutes/latest.json")" = 180 ] \
  && [ "$(jq -r '.repos[] | select(.repo == "Acme/a") | .est' "$HH/state/ci-minutes/latest.json")" = 180 ] && ok \
  || bad "3: state/ci-minutes/latest.json must carry the total and the per-repo split: $(cat "$HH/state/ci-minutes/latest.json")"
drive CI_MINUTES_DAY_MAX=0
[ ! -s "$HH/beats.txt" ] && ok || bad "3: CI_MINUTES_DAY_MAX=0 turns the page off"
# the vendor's per-minute multiplier (MonkCI bills a 4-vCPU minute as 2)
drive CI_MINUTES_DAY_MAX=0 CI_MINUTES_BILL_MULT=2
grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1 | grep -q 'est 360 billed' && ok \
  || bad "3: CI_MINUTES_BILL_MULT=2 doubles the billed figure ($(grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1))"
drive CI_MINUTES_DAY_MAX=0 CI_MINUTES_BILL_MULT=1.5
grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1 | grep -q 'est 270 billed' && ok \
  || bad "3: a decimal multiplier (1.5) is a number, not a reason to fall back to the default ($(grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1))"

# 4. the budget: a: 1 page + 10 sampled jobs + 1 closed-PR read, b: 1 page + 4
# (it only has 4) + 1 closed-PR read, c: 1 failed page and no PR read = 19.
# TEST-CHANGE (BH-9411): was 17; each readable repo now reads its closed PRs once.
drive CI_MINUTES_DAY_MAX=1000
[ "$(calls)" = 19 ] && ok || bad "4: exactly pages + sample + 1 pulls reads per readable repo, and Acme/b listed once though two projects use it (got $(calls): $(cat "$HH/gh-calls.txt"))"
grep -q '19 GitHub read(s)' "$HH/logs/ci-minutes-watch.log" && ok || bad "4: the fleet line reports the reads it spent"
# a busy repo: 100 runs read of total_count 250 -> the wall minutes are
# EXTRAPOLATED to 250 runs, not capped at what the pages held
runs Acme_a 1 100 1000 600 1 250
for id in $(seq 1000 1099); do jobs Acme_a "$id" monkci-ubuntu-24.04-4 3 330; done
drive CI_MINUTES_DAY_MAX=1000 CI_MINUTES_MAX_PAGES=1 CI_MINUTES_SAMPLE_RUNS=2
L=$(grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1)
[ "$(grep -c 'Acme/a/actions/runs page' "$HH/gh-calls.txt")" = 1 ] && grep -q '100 of 250 run(s)' <<<"$L" \
  && grep -q 'extrapolated' <<<"$L" && grep -q 'est 4500 billed' <<<"$L" \
  && ok || bad "4: 1000 wall min over 100 of 250 runs -> 2500 x 1.8 = 4500, extrapolated from total_count: $L"
# overlapping pages (a run that moved between reads) are counted once
runs Acme_a 1 100 1000 600 1 150; runs Acme_a 2 100 1050 600 1 150
drive CI_MINUTES_DAY_MAX=1000 CI_MINUTES_MAX_PAGES=2 CI_MINUTES_SAMPLE_RUNS=2
grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1 | grep -q '150 run(s) in 24h, 1500 wall min' && ok \
  || bad "4: runs are unique by id across pages ($(grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1))"
rm -f "$HH/fx/Acme_a.runs.2.json"
# the ratio is per WORKFLOW: 2 MonkCI runs of workflow 1, 18 GitHub-hosted runs
# of workflow 2, a sample of 4. One pooled ratio would read 200 x 18/40 = 90;
# per workflow it is 20 x 1.8 + 180 x 0 = 36.
runs Acme_a 1 2 300 600 1
runs Acme_a 1 18 400 600 2 0 append
for id in 300 301; do jobs Acme_a "$id" monkci-ubuntu-24.04-4 3 330; done
for id in $(seq 400 417); do jobs Acme_a "$id" ubuntu-latest 2 600; done
drive CI_MINUTES_DAY_MAX=1000 CI_MINUTES_SAMPLE_RUNS=4
grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1 | grep -q 'est 36 billed' && ok \
  || bad "4: the billed/wall ratio is taken per workflow_id ($(grep 'Acme/a:' "$HH/logs/ci-minutes-watch.log" | tail -1))"
runs Acme_a 1 10 100 600

# 5. a repo nobody can read
grep -q 'could not read: Acme/c' "$HH/logs/ci-minutes-watch.log" && ok || bad "5: an unreadable repo is named"
grep -q 'Acme/c:' "$HH/logs/ci-minutes-watch.log" && bad "5: an unreadable repo must not get an estimate line" || ok

# 6. a low bucket: no read at all
printf 'gh_budget_low() { return 0; }\n' > "$HH/bin/lib/gh-budget.sh"
drive
[ "$(calls)" = 0 ] && grep -q 'skipped: the GitHub API budget is low' "$HH/logs/ci-minutes-watch.log" \
  && ok || bad "6: a low GitHub bucket must skip the tick with no read ($(calls) calls)"
rm -f "$HH/bin/lib/gh-budget.sh"

echo "ci-minutes-watch.k1-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
