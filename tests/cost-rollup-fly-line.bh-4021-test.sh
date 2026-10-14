#!/bin/bash
# tests/cost-rollup-fly-line.bh-4021-test.sh — FLY MACHINE TIME IS ITS OWN LINE
# IN THE PER-PR COST (BH-4021, slice 4 of BH-3989).
#
# A cost row with runner=fly is Fly machine time (the reap writes it with
# stage=infra). bin/cost-rollup.sh keeps it in the PR's total, but shows it
# apart from the AI tokens: a trailing fly_usd column in cost-per-pr.csv and a
# "Fly machine time" clause in the merged-PR comment. This suite runs the REAL
# script (STAMP_DRY=1, WINDOWS_ONLY unset so the stamp loop runs) in a scratch
# $HARNESS with hand-written fixture rows.
#
#   D1 claude + fly rows -> fly_usd 0.45, total 4.95, AI tokens $4.50, the Fly
#      row out of the payer split and out of the comment's Stages
#   D2 no fly rows -> fly_usd empty (absent, not 0.00), comment says not recorded
#   D3 the worker's pr_costs JSON keys are unchanged (no fly_usd)
#   D4 an unpriced fly row -> fly_usd empty, comment says "not priced"
#   D4b one priced + one unpriced fly row -> fly_usd is the priced sum, the
#      comment names the unpriced segment
#   D5 stamped.json still gates the comment to once per PR
#   D6 the runner match is what makes D1 green (mutated copy -> fly_usd empty)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cost-rollup-fly-line.bh-4021-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,run_id"
# crow <stage> <cost> — a claude token row; frow <duration_s> <cost> — a fly row.
crow() { printf '2026-10-03T10:00:00Z,box,cromford,%s,claude,claude-opus-5,0,60,1000,2000,0,0,%s,subscription,fp1,acct1,\n' "$1" "$2"; }
frow() { printf '2026-10-03T10:00:00Z,box,cromford,infra,fly,performance-8x,0,%s,0,0,0,0,%s,metered,,,\n' "$1" "$2"; }

mkdir -p "$T/fakebin"
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_LOG"
exit 0
STUB
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
[ "$1 $2" = "pr view" ] && { echo MERGED; exit 0; }
exit 1
STUB
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/ssh" "$T/fakebin/gh" "$T/fakebin/curl"

# setup <name> [script] — a fresh scratch harness with the three fixture builds.
setup() {
  H="$T/$1/h"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/builds" "$H/state/cost" "$H/env"
  cp "${2:-$DIR/bin/cost-rollup.sh}" "$H/bin/cost-rollup.sh"
  cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
  cp "$DIR/bin/lib/builds-of-record.sh" "$H/bin/lib/builds-of-record.sh"
  cp "$DIR/bin/lib/cost-rows-read.sh" "$H/bin/lib/cost-rows-read.sh"
  cat > "$H/bin/jobs-client.sh" <<'JC'
job_artifact_feed() { return 0; }
ledger_page() { echo '{"ledgers":[]}'; }  # TEST-CHANGE: merge into BH-4158 — the stamp loop bills only off a readable cost-final-bill ledger (empty here; D5 still gates on the legacy stamped.json)
_jobs_req() {
  case "$2" in /api/metrics/cost-rows*) echo '{"cost_rows":[]}' ;; *) return 1 ;; esac
}
JC
  printf '#!/bin/bash\nexit 1\n' > "$H/bin/fleet-conf.sh"
  chmod +x "$H/bin/fleet-conf.sh"
  printf '# project slug\ncromford -\n' > "$H/fleet.conf"

  local b="$H/builds"
  mkdir -p "$b/bp-BH-1-x" "$b/bp-BH-2-x" "$b/bp-BH-3-x" "$b/bp-BH-4-x"
  echo "PR_CREATED https://github.com/o/r/pull/41" > "$b/bp-BH-1-x/RESULT"
  { echo "$HDR"; crow execute 3.00; crow review 1.50; frow 3600 0.45; } > "$b/bp-BH-1-x/cost.csv"
  echo "PR_CREATED https://github.com/o/r/pull/42" > "$b/bp-BH-2-x/RESULT"
  { echo "$HDR"; crow execute 2.00; } > "$b/bp-BH-2-x/cost.csv"
  echo "PR_CREATED https://github.com/o/r/pull/43" > "$b/bp-BH-3-x/RESULT"
  { echo "$HDR"; crow execute 1.00; frow 1800 ''; } > "$b/bp-BH-3-x/cost.csv"
  echo "PR_CREATED https://github.com/o/r/pull/44" > "$b/bp-BH-4-x/RESULT"
  { echo "$HDR"; crow execute 1.00; frow 600 0.10; frow 600 ''; } > "$b/bp-BH-4-x/cost.csv"
}

run() {
  env PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" SSH_LOG="$H/ssh.log" \
      COST_ROLLUP_TIMEBOXED=1 LANE_GATE_DISABLE=1 STAMP_DRY=1 HARNESS_SECRET= \
      bash "$H/bin/cost-rollup.sh" > "$H/run.out" 2>&1
  echo $? > "$H/run.rc"
}
CSV() { printf '%s\n' "$H/state/cost/cost-per-pr.csv"; }
col() { # col <pr-no> <column> -> that PR's value, "<no row>" when absent
  python3 -c 'import csv,sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["pr_url"] == "https://github.com/o/r/pull/" + sys.argv[2]:
        print(r.get(sys.argv[3], "<no column>")); break
else: print("<no row>")' "$(CSV)" "$1" "$2" 2>/dev/null
}
stamp() { grep "^DRY-STAMP https://github.com/o/r/pull/$1:" "$H/run.out" | head -1; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# ===========================================================================
# D1-D4
# ===========================================================================
setup s1
run
[ "$(cat "$H/run.rc")" = 0 ] && ok || bad "s1: rollup exited $(cat "$H/run.rc"): $(tail -5 "$H/run.out")"
[ "$(head -1 "$(CSV)" | tr -d '\r' | awk -F, '{print $NF}')" = fly_usd ] && ok \
  || bad "D1: cost-per-pr.csv header's last column is not fly_usd: $(head -1 "$(CSV)")"
[ "$(head -1 "$(CSV)" | tr -d '\r' | cut -d, -f1-10)" = "pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs,auth_account,account_breakdown" ] \
  && ok || bad "D1: the first ten columns moved: $(head -1 "$(CSV)")"

# D1
[ "$(col 41 cost_usd)" = 4.95 ] && ok || bad "D1: pull/41 cost_usd should stay the whole bill 4.95, got '$(col 41 cost_usd)'"
[ "$(col 41 fly_usd)" = 0.45 ] && ok || bad "D1: pull/41 fly_usd should be 0.45, got '$(col 41 fly_usd)'"
has "$(col 41 stage_breakdown)" "infra:0.45" && ok || bad "D1: stage_breakdown keeps infra: '$(col 41 stage_breakdown)'"
has "$(col 41 account_breakdown)" unknown && bad "D1: the Fly row leaked into account_breakdown: '$(col 41 account_breakdown)'" || ok
[ "$(col 41 auth_account)" = acct1 ] && ok || bad "D1: auth_account should be acct1, got '$(col 41 auth_account)'"
S1=$(stamp 41)
[ -n "$S1" ] && ok || bad "D1: no DRY-STAMP line for pull/41: $(grep DRY-STAMP "$H/run.out")"
has "$S1" 'Final bill: **$4.95**' && ok || bad "D1: stamp lacks 'Final bill: **\$4.95**': $S1"
has "$S1" 'AI tokens: $4.50' && ok || bad "D1: stamp lacks 'AI tokens: \$4.50': $S1"
has "$S1" 'Fly machine time: $0.45 (60 min)' && ok || bad "D1: stamp lacks the Fly line: $S1"
has "$S1" 'Final AI bill' && bad "D1: stamp still says 'Final AI bill': $S1" || ok
has "$S1" 'Fly at catalog/fly-prices.json list price' && ok || bad "D1: stamp does not name the Fly price source: $S1"
STG=${S1#*Stages:}; STG=${STG%%. Fly machine time*}
{ has "$STG" execute && has "$STG" review; } && ok || bad "D1: Stages lacks execute/review: '$STG'"
has "$STG" infra && bad "D1: Stages still lists infra: '$STG'" || ok

# D2
[ "$(col 42 fly_usd)" = "" ] && ok || bad "D2: pull/42 (no fly rows) fly_usd should be empty, got '$(col 42 fly_usd)'"
[ "$(col 42 cost_usd)" = 2.00 ] && ok || bad "D2: pull/42 cost_usd should be 2.00, got '$(col 42 cost_usd)'"
tr -d '\r' < "$(CSV)" | grep -q '^https://github.com/o/r/pull/42,.*,$' && ok || bad "D2: pull/42's csv line should end in ',': $(grep pull/42 "$(CSV)")"
S2=$(stamp 42)
has "$S2" 'Fly machine time: not recorded for this PR' && ok || bad "D2: stamp lacks 'not recorded': $S2"
has "$S2" '$0.00' && bad "D2: stamp shows \$0.00 for an absent Fly line: $S2" || ok
{ has "$S2" 'Final bill: **$2.00**' && has "$S2" 'AI tokens: $2.00'; } && ok || bad "D2: AI tokens should equal the total \$2.00: $S2"

# D3
J=$( ( . "$DIR/bin/lib/jobs/cost.sh"; _metric_pr_costs_json "$(CSV)" ) 2>&1)
[ "$(printf '%s' "$J" | jq -r '.rows[0] | keys_unsorted | join(",")')" = \
  "pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs,auth_account,account_breakdown" ] \
  && ok || bad "D3: the pr_costs JSON keys changed: $(head -c 300 <<<"$J")"
[ "$(printf '%s' "$J" | grep -c fly_usd)" = 0 ] && ok || bad "D3: fly_usd reached the worker contract"

# D4
[ "$(col 43 fly_usd)" = "" ] && ok || bad "D4: an all-unpriced Fly line should leave fly_usd empty, got '$(col 43 fly_usd)'"
[ "$(col 43 cost_usd)" = 1.00 ] && ok || bad "D4: pull/43 cost_usd should be 1.00, got '$(col 43 cost_usd)'"
S3=$(stamp 43)
has "$S3" 'Fly machine time: 30 min, not priced' && ok || bad "D4: stamp lacks '30 min, not priced': $S3"
has "$S3" 'Fly machine time: $0.00' && bad "D4: an unpriced Fly line reads as free: $S3" || ok

# D4b
[ "$(col 44 fly_usd)" = 0.10 ] && ok || bad "D4b: a partly unpriced Fly line should carry the priced 0.10, got '$(col 44 fly_usd)'"
has "$(stamp 44)" 'Fly machine time: $0.10 (20 min) (+1 unpriced segment(s))' && ok \
  || bad "D4b: stamp should name the unpriced segment: $(stamp 44)"

[ "$(cat "$H/ssh.log" 2>/dev/null | grep -c .)" = 0 ] && ok || bad "no box is reached over ssh: $(head -2 "$H/ssh.log")"

# ===========================================================================
# D5 — stamped once
# ===========================================================================
setup s5
echo '{"https://github.com/o/r/pull/41":"x"}' > "$H/state/cost/stamped.json"
run
[ "$(cat "$H/run.rc")" = 0 ] && ok || bad "s5: rollup exited $(cat "$H/run.rc")"
[ -z "$(stamp 41)" ] && ok || bad "D5: an already-stamped PR stamped again: $(stamp 41)"
[ -n "$(stamp 42)" ] && ok || bad "D5: pull/42 should still stamp"

# ===========================================================================
# D6 — mutation sanity: the runner match is what puts 0.45 in fly_usd
# ===========================================================================
sed 's/== "fly"/== "flyX"/' "$DIR/bin/cost-rollup.sh" > "$T/mutant.sh"
if grep -q '== "flyX"' "$T/mutant.sh"; then
  ok
  setup s6 "$T/mutant.sh"
  run
  [ "$(col 41 fly_usd)" = "" ] && ok || bad "D6: with the runner match broken fly_usd should be empty, got '$(col 41 fly_usd)'"
else
  bad "D6: no '== \"fly\"' runner match in bin/cost-rollup.sh to mutate"
fi

printf 'cost-rollup-fly-line: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
