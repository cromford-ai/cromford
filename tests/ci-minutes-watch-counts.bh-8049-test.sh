#!/bin/bash
# tests/ci-minutes-watch-counts.bh-8049-test.sh — BH-8049: the 24h CI-cost lane
# (bin/ci-minutes-watch.sh) records two counts per repo from the runs it already
# reads: workflow_dispatch runs per day (per workflow), and pushes per PR
# (distinct head SHAs of the pull_request runs on each branch).
#
#   C1  dispatches_24h and the per-workflow split, in the log and latest.json
#   C2  pushes_per_pr {prs, median, max, max_branch, total}
#   C3  the ci-counts line comes BEFORE the repo's estimate line, and the
#       estimate is still the last `<slug>:` line (tests/ci-minutes-watch.k1-test.sh greps it)
#   C4  the ci_health payload carries both counts
#   C5  0 new GitHub reads: pages + sample reads only
#
# A scratch harness, a fake `gh` that serves fixture files and applies -q with
# jq (the k1 suite's shape), and a fixture jobs client whose ci_health_put
# writes the payload to a file. No network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ci-minutes-watch-counts.bh-8049-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=2000000000
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx" "$T/stub"
printf 'mk  Acme/mk  - - 1 box-a 192.0.2.1\n' > "$HH/fleet.conf"
# The fixture jobs client: one line per ci_health_put, `<repo>\t<kind>\t<body>`.
# Written BEFORE the closure, which never overwrites a file the suite wrote.
cat > "$HH/bin/jobs-client.sh" <<'SH'
ci_health_put() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$HARNESS/payload.tsv"; }
SH
scratch_install_closure bin/ci-minutes-watch.sh "$HH" >/dev/null || exit 1
cp "$DIR/bin/fleet-conf.sh" "$HH/bin/" || exit 1
# The budget and the per-repo token read the box's GitHub identity: out of
# this suite, which is about the counts.
for f in gh-budget.sh gh-repo-token.sh page-critical.sh; do scratch_rm "$HH/bin/lib/$f"; done

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
  *) exit 1 ;;
esac
[ -r "$F" ] || exit 1
if [ -n "$Q" ]; then jq -c "$Q" "$F"; else cat "$F"; fi
SH
chmod +x "$T/stub/gh"

# r <id> <event> <name> <branch> <sha> — one completed 10-minute run
RS=""
r() {
  RS="$RS${RS:+,}$(jq -nc --argjson i "$1" --arg e "$2" --arg n "$3" --arg b "$4" --arg h "$5" \
    --arg s "$(iso 7800)" --arg u "$(iso 7200)" \
    '{id:$i, workflow_id:($n|length), event:$e, name:$n, head_branch:$b, head_sha:$h, run_started_at:$s, updated_at:$u}')"
}
ID=1000
# C1: 3 workflow_dispatch runs: 2 of `ci`, 1 of `e2e`
r $((ID+=1)) workflow_dispatch ci main dddd1; r $((ID+=1)) workflow_dispatch ci main dddd2; r $((ID+=1)) workflow_dispatch e2e main dddd3
# C2: ticket/a has 6 pushes (each starts ci + e2e: 12 runs), ticket/b has 2
for i in 1 2 3 4 5 6; do r $((ID+=1)) pull_request ci ticket/a "aaaa$i"; r $((ID+=1)) pull_request e2e ticket/a "aaaa$i"; done
for i in 1 2; do r $((ID+=1)) pull_request ci ticket/b "bbbb$i"; done
# a push to main and a merge-group run count as neither
r $((ID+=1)) push ci main mmmm1; r $((ID+=1)) merge_group ci gh-readonly-queue/main/x qqqq1
NR=$((ID - 1000))
printf '{"total_count":%s,"workflow_runs":[%s]}\n' "$NR" "$RS" > "$HH/fx/Acme_mk.runs.1.json"
for (( i = 1001; i <= ID; i++ )); do echo '{"jobs":[]}' > "$HH/fx/Acme_mk.jobs.$i.json"; done

rm -f "$HH/gh-calls.txt" "$HH/payload.tsv"
( export HARNESS="$HH" FLEET_CONF="$HH/fleet.conf" NOW PATH="$T/stub:$PATH" CI_MINUTES_DAY_MAX=0 CI_MINUTES_SAMPLE_RUNS=4
  bash "$HH/bin/ci-minutes-watch.sh" ) >"$T/out.txt" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "setup: the lane exits 0 (rc $RC): $(cat "$T/out.txt")"
LOG="$HH/logs/ci-minutes-watch.log"; J="$HH/state/ci-minutes/latest.json"

# C1
grep -q "ci-counts repo=Acme/mk dispatches_24h=3 (ci=2,e2e=1) pushes_per_pr prs=2 median=4 max=6 (ticket/a) of $NR run(s) read" "$LOG" \
  && ok || bad "C1: the ci-counts line: $(grep ci-counts "$LOG")"
[ "$(jq -r '.repos[] | select(.repo == "Acme/mk") | .dispatches_24h' "$J" 2>/dev/null)" = 3 ] \
  && [ "$(jq -c '.repos[] | select(.repo == "Acme/mk") | .dispatches_by_workflow' "$J" 2>/dev/null)" = '{"ci":2,"e2e":1}' ] \
  && ok || bad "C1: latest.json carries dispatches_24h and the split: $(cat "$J" 2>/dev/null)"

# C2
PP=$(jq -c '.repos[] | select(.repo == "Acme/mk") | .pushes_per_pr' "$J" 2>/dev/null)
[ "$(jq -r '.prs' <<<"$PP")" = 2 ] && [ "$(jq -r '.max' <<<"$PP")" = 6 ] && [ "$(jq -r '.max_branch' <<<"$PP")" = ticket/a ] \
  && [ "$(jq -r '.total' <<<"$PP")" = 8 ] && [ "$(jq -r '.median' <<<"$PP")" = 4 ] \
  && ok || bad "C2: pushes_per_pr {prs 2, median 4, max 6, max_branch ticket/a, total 8}: $PP"
# the estimate keys are unchanged
[ "$(jq -r '.repos[] | select(.repo == "Acme/mk") | .est | type' "$J" 2>/dev/null)" = number ] && ok || bad "C2: .est stays a number"

# C3
CL=$(grep -n 'ci-counts repo=Acme/mk' "$LOG" | head -1 | cut -d: -f1)
EL=$(grep -n 'Acme/mk:' "$LOG" | head -1 | cut -d: -f1)
[ -n "$CL" ] && [ -n "$EL" ] && [ "$CL" -lt "$EL" ] && ok || bad "C3: ci-counts (line ${CL:-none}) comes before the estimate (line ${EL:-none})"
grep 'Acme/mk:' "$LOG" | tail -1 | grep -q 'billed job-min/24h' && ok || bad "C3: the last 'Acme/mk:' line is still the estimate"

# C4
PB=$(awk -F'\t' '$1 == "Acme/mk" && $2 == "minutes" {print $3}' "$HH/payload.tsv" 2>/dev/null | tail -1)
[ "$(jq -r '.dispatches_24h' <<<"$PB" 2>/dev/null)" = 3 ] && [ "$(jq -r '.pushes_per_pr.max' <<<"$PB" 2>/dev/null)" = 6 ] \
  && [ "$(jq -r '.est_24h | type' <<<"$PB" 2>/dev/null)" = number ] \
  && ok || bad "C4: the ci_health payload carries dispatches_24h and pushes_per_pr: $PB"

# C5: one runs page + 4 sampled jobs reads, nothing more
[ "$(grep -c '' "$HH/gh-calls.txt")" = 5 ] && ok || bad "C5: 0 new reads (want 1 page + 4 samples = 5): $(cat "$HH/gh-calls.txt")"

# A repo with no dispatch and no PR run: zeros, never a missing key
printf '{"total_count":1,"workflow_runs":[%s]}\n' "$(jq -nc --arg s "$(iso 7800)" --arg u "$(iso 7200)" '{id:5000,workflow_id:1,event:"push",name:"ci",head_branch:"main",head_sha:"z",run_started_at:$s,updated_at:$u}')" > "$HH/fx/Acme_mk.runs.1.json"
( export HARNESS="$HH" FLEET_CONF="$HH/fleet.conf" NOW PATH="$T/stub:$PATH" CI_MINUTES_DAY_MAX=0
  bash "$HH/bin/ci-minutes-watch.sh" --dry-run ) >"$T/out2.txt" 2>&1
grep -q 'ci-counts repo=Acme/mk dispatches_24h=0 pushes_per_pr prs=0 of 1 run(s) read' "$T/out2.txt" \
  && [ "$(jq -c '.repos[0] | [.dispatches_24h, .pushes_per_pr.prs, .pushes_per_pr.total]' "$J")" = '[0,0,0]' ] \
  && ok || bad "C6: zero counts are written as zeros: $(grep ci-counts "$T/out2.txt") $(jq -c '.repos[0]' "$J")"

echo "ci-minutes-watch-counts.bh-8049: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
