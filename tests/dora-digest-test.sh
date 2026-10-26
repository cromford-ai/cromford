#!/bin/bash
# tests/dora-digest-test.sh — the daily DORA + unit-economics digest, driven on
# fixture slices of the six real sources so every number has a hand-checkable
# expected value.
#
# WHAT IS UNDER TEST — the properties whose failure is SILENT, i.e. produces a
# plausible number rather than an error:
#   * the WINDOW actually filters. Every fixture carries a row 5 days old and a
#     row 10 days old; a 24h run must see neither, a 7d run must see the first
#     and not the second. A digest that quietly reports all time reads as a
#     record-breaking day.
#   * counts are DISTINCT where they are claimed to be. The conductor log holds
#     the same merge line twice and the same PR entering NEEDS_REBASE twice;
#     four merges and one conflict is the answer, not five and two.
#   * a rate divides by the denominator it NAMES. Conflict and rebuild rates are
#     counted off the conductor log, so they divide by the conductor log's merge
#     count (4) even though the ledger's headline merge count (5) is higher.
#   * the ledger WINS for merges and lead time when it answers, and the conductor
#     log's own count survives beside it.
#   * the cost csv is read BY COLUMN NAME: the fixture's columns are in a
#     different order from production's, and an unpriced row costs $0 without
#     dropping out of the row count.
#   * a MISSING source is n/a, not zero — and both merge sources missing at once
#     writes exactly one ALERTS line, because a fleet nobody can measure must
#     not look like a quiet day.
#   * box test minutes count the STAGE-TIMING lines the suite phases write and
#     nothing else: a `gates` line, a line outside the window and a build dir
#     belonging to no project must not move a repo's number, and an absent
#     builds/ is n/a rather than a project that suddenly ran no tests.
#   * --no-send posts nothing; a send posts the exact text of latest.txt through
#     the fleet-topic beat.
# Run from anywhere: tests/dora-digest-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
# Numeric equality, because json.dump writes a rounded float and jq renders it
# as 120.0 — a dollar figure asserted as a STRING would pin the formatter, not
# the arithmetic. An empty left side never passes: a missing key is a failure.
neq() { if awk -v a="$2" -v b="$3" 'BEGIN{exit !(a != "" && a+0 == b+0)}'; then ok
        else bad "$1: expected $3, got '$2'"; fi; }
# grep -c prints nothing (rc=2) when the file does not exist, which is exactly
# the state "no alert was written" — count it as the zero it is.
alerts() { [ -f "$1" ] && grep -c 'dora-digest' "$1" || echo 0; }

command -v jq >/dev/null 2>&1 || { echo "dora-digest: jq required, skipping"; exit 0; }

# Stamps: IN is inside every window, MID only inside 7d, OUT inside neither.
IN_LOG=$(date -u -d '2 hours ago'  '+%Y-%m-%d %H:%M:%SZ')
MID_LOG=$(date -u -d '5 days ago'  '+%Y-%m-%d %H:%M:%SZ')
OUT_LOG=$(date -u -d '10 days ago' '+%Y-%m-%d %H:%M:%SZ')
IN_TS=$(date -u -d '2 hours ago'   '+%Y-%m-%dT%H:%M:%SZ')
MID_TS=$(date -u -d '5 days ago'   '+%Y-%m-%dT%H:%M:%SZ')
OUT_TS=$(date -u -d '10 days ago'  '+%Y-%m-%dT%H:%M:%SZ')
BEFORE_TS=$(date -u -d '30 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
TODAY=$(date -u +%F)

mkdir -p "$T/bin" "$T/logs" "$T/env" "$T/flags" "$T/state/cost" "$T/state/quota" "$T/calls"
export HARNESS="$T"
# TEST-CHANGE BH-6965: the alpha fixture (2 rebuilds / 4 merges) is over the
# conflicts alert's default of 40 per 100. That alert and its beat are pinned in
# tests/dora-conflicts-block.bh-6965-test.sh; its day flag keeps them out of here.
touch "$T/flags/alerted-dora-conflicts-$(date -u +%Y%m%d)"

# The registry the digest maps repos to projects with. Pinned to a fixture so the
# test answers the same on the hub (where /root/harness/fleet.conf exists) and in
# CI (where it does not).
cat > "$T/fleet.conf" <<'CONF'
alpha  Org/alpha  https://alpha.test  /api/board  1 box-a 10.0.0.1
beta   Org/beta   https://beta.test   -           2 box-b 10.0.0.2
gamma  Org/gamma  https://gamma.test  -           3 box-c 10.0.0.3
CONF
export FLEET_CONF="$T/fleet.conf"

# ---- source: logs/merge-conductor.log ---------------------------------------
# alpha in-window: 101,102,103,104 merged (101 logged TWICE), 105 entering
# NEEDS_REBASE twice. beta: 7 merged. 150 is 5 days old, 1 is 10 days old.
{
  echo "$IN_LOG MERGED Org/alpha#101 by conductor (record $T/builds/pool-alpha-A-1-x)"
  echo "$IN_LOG Org/alpha#101 QUEUED -> MERGED head=aaaaaaa1 reviewed=aaaaaaa1 merge=CLEAN reason=by:conductor"
  echo "$IN_LOG MERGED Org/alpha#101 by conductor (record $T/builds/pool-alpha-A-1-x)"
  echo "$IN_LOG MERGED Org/alpha#102 by conductor (record $T/builds/pool-alpha-A-2-x)"
  echo "$IN_LOG MERGED Org/alpha#103 by conductor (record $T/builds/pool-alpha-A-3-x)"
  echo "$IN_LOG MERGED Org/alpha#104 by conductor (record $T/builds/pool-alpha-A-4-x)"
  echo "$IN_LOG Org/alpha#105 WAIT_CI -> NEEDS_REBASE head=bbbbbbb1 reviewed=bbbbbbb1 merge=DIRTY reason=mergeState DIRTY"
  echo "$IN_LOG Org/alpha#105 NEEDS_REBASE -> REBASING head=bbbbbbb1 reviewed=bbbbbbb1 merge=DIRTY reason=merging origin/main into ticket/a-9"
  echo "$IN_LOG Org/alpha#105 BLOCKED_HUMAN -> NEEDS_REBASE head=bbbbbbb1 reviewed=bbbbbbb1 merge=DIRTY reason=mergeState DIRTY"
  echo "$IN_LOG MERGED Org/beta#7 by conductor (record $T/builds/pool-beta-B-1-x)"
  # gamma merged, the ledger has never heard of it and it spent nothing: it must
  # still row, off the log, with $0 measured rather than n/a.
  echo "$IN_LOG MERGED Org/gamma#3 by conductor (record $T/builds/pool-gamma-G-1-x)"
  echo "$MID_LOG MERGED Org/alpha#150 by conductor (record $T/builds/pool-alpha-A-50-x)"
  echo "$OUT_LOG MERGED Org/alpha#1 by conductor (record $T/builds/pool-alpha-A-0-x)"
  echo "$OUT_LOG Org/alpha#2 - -> NEEDS_REBASE head=ccccccc1 reviewed=ccccccc1 merge=DIRTY reason=mergeState DIRTY"
  echo "a line with no stamp at all, which the parser must skip"
} > "$T/logs/merge-conductor.log"

# ---- source: logs/blocked-resolver.log --------------------------------------
# alpha: two REBUILD FRESH events, one of them a red-twice park, one FIX ROUND.
# beta: a dead pool lane that ran out of ladder.
{
  echo "$IN_LOG alpha/alpha-A-9 [conductor/rebase-gate-red] -> rebuild-fresh (rebuilds=0 fix=0 adj=0 rereview=0)"
  echo "$IN_LOG alpha/alpha-A-9 [rebase-gate-red]: REBUILD FRESH 1 of 3"
  echo "$IN_LOG alpha/alpha-A-11 [conductor/red-twice] -> rebuild-fresh (rebuilds=0 fix=0 adj=0 rereview=0)"
  echo "$IN_LOG alpha/alpha-A-11 [red-twice]: REBUILD FRESH 1 of 3"
  echo "$IN_LOG alpha/alpha-A-12 [head-not-reapproved]: FIX ROUND pushed deadbeef to ticket/a-12 — the conductor judges it next"
  echo "$IN_LOG beta/beta-B-3 [queue/pool-died-twice] -> rebuild-fresh (rebuilds=3 fix=0 adj=1 rereview=0)"
  echo "$IN_LOG beta/beta-B-3 [pool-died-twice]: ABANDONED — rebuilt fresh 3 times and the ladder is exhausted"
  echo "$OUT_LOG alpha/alpha-A-1 [red-twice]: REBUILD FRESH 1 of 3"
} > "$T/logs/blocked-resolver.log"

# ---- source: state/cost/fleet-cost.csv --------------------------------------
# Column order DELIBERATELY unlike production's: the digest reads by name.
{
  echo "project,ts,stage,cost_usd,billing_mode,auth_account"
  echo "alpha,$IN_TS,execute,100.00,subscription,acct:max1"
  echo "alpha,$IN_TS,triage,20.00,metered,xai-key:k"
  echo "alpha,$IN_TS,review,,subscription,acct:max1"
  echo "beta,$IN_TS,execute,10.00,,acct:max1"
  echo "alert-triage,$IN_TS,triage,5.00,subscription,acct:max1"
  echo "alpha,$MID_TS,execute,60.00,subscription,acct:max1"
  echo "alpha,$OUT_TS,execute,999.00,subscription,acct:max1"
} > "$T/state/cost/fleet-cost.csv"

# ---- source: state/cost/cost-per-pr.csv -------------------------------------
# No timestamp column exists, so the window comes from the merge log: #999 never
# merged in it and must not be counted.
{
  echo "pr_url,cost_usd,auth_account"
  echo "https://github.com/Org/alpha/pull/101,30.00,acct:max1"
  echo "https://github.com/Org/alpha/pull/102,10.00,acct:max1"
  echo "https://github.com/Org/alpha/pull/999,500.00,acct:max1"
  echo "https://github.com/Org/beta/pull/7,7.00,acct:max1"
} > "$T/state/cost/cost-per-pr.csv"

# ---- source: state/quota/<account>.json -------------------------------------
cat > "$T/state/quota/max1.json" <<'Q'
{"account":"max1","vendor":"claude","status":"ok","source":"oauth-usage",
 "polled_at":"2026-09-15T16:10:01Z",
 "five_hour":{"pct":100.0,"resets_at":"2026-09-15T16:49:59.851643+00:00"},
 "seven_day":{"pct":55.0,"resets_at":"2026-09-16T08:59:59.851666+00:00"},"per_model":{}}
Q
cat > "$T/state/quota/max2.json" <<'Q'
{"account":"max2","vendor":"claude","status":"error","source":"none",
 "polled_at":"2026-09-15T16:10:01Z","five_hour":null,"seven_day":null,
 "per_model":{},"error":"usage endpoint answered 429"}
Q
# quota-poll.sh leaves 0600 .lasterr-<account> files beside the json; a dotfile
# is not an account and must never become a row.
echo "not json" > "$T/state/quota/.lasterr-max1"

# ---- source: logs/extra-usage-<account>.csv ---------------------------------
{
  echo "ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage,extra_limit_usd,extra_pct,status"
  echo "$OUT_TS,0,40,2026-09-17T04:00:00Z,1,50.00,0,0,1000.00,5,ok"
  echo "$BEFORE_TS,0,60,2026-09-17T04:00:00Z,1,100.00,0,0,1000.00,10,ok"
  echo "$IN_TS,0,100,2026-09-17T04:00:00Z,1,175.00,0,1,1000.00,17.5,ok"
} > "$T/logs/extra-usage-acctA.csv"

# ---- source: builds/<dir>/pipeline.log --------------------------------------
# What bin/run-build.sh STAGE_END writes for the three phases the repo's suite
# runs under. alpha-A-1 holds two in-window runs (120s suite + 60s suite-fix),
# a `gates` line the metric must not count, a 10-day-old suite-head worth 999s
# the window must drop, and an unstamped line. The second dir belongs to no
# registered project: its minutes join the fleet total and no repo row.
mkdir -p "$T/builds/alpha-A-1" "$T/builds/no-such-project-X-1"
{
  echo "$IN_LOG [alpha/A-1] STAGE-TIMING suite start=1700000000 end=1700000120 secs=120"
  echo "$IN_LOG [alpha/A-1] STAGE-TIMING suite-fix start=1700000200 end=1700000260 secs=60"
  echo "$IN_LOG [alpha/A-1] STAGE-TIMING gates start=1700000300 end=1700000310 secs=10"
  echo "$OUT_LOG [alpha/A-1] STAGE-TIMING suite-head start=1600000000 end=1600000999 secs=999"
  echo "a pipeline line with no stamp at all, which the parser must skip"
} > "$T/builds/alpha-A-1/pipeline.log"
echo "$IN_LOG [x/X-1] STAGE-TIMING suite start=1 end=61 secs=60" \
  > "$T/builds/no-such-project-X-1/pipeline.log"

# ---- the ledger read, shimmed ----------------------------------------------
cat > "$T/fixtures-dora.json" <<'J'
{"window":{"days":1,"since":"2026-09-14T07:00:00Z","project":null},
 "projects":[
  {"project":"alpha","repos":["Org/alpha"],"merged":5,
   "lead_time":{"p50_s":3600,"p90_s":7200,"n":5,"basis":"build job created → PR merged"},
   "launch_lead_time":{"p50_s":1800,"p90_s":9000,"n":4,"basis":"issue created → first spawn","dropped_n":1},
   "change_failure":{"rate":0.2,"bad":1,"merges":5,"main_red":2}},
  {"project":"beta","repos":["Org/beta"],"merged":1,
   "lead_time":{"p50_s":600,"p90_s":600,"n":1,"basis":"build job created → PR merged"},
   "change_failure":{"rate":0,"bad":0,"merges":1,"main_red":0}}],
 "totals":{"merged":6,"projects":2,"lead_time":{"p50_s":3000,"p90_s":7200,"n":6},
           "launch_lead_time":{"p50_s":1500,"p90_s":9000,"n":5,"basis":"issue created → first spawn","dropped_n":1},
           "change_failure_rate":0.1667,"bad":1},
 "as_of":"2026-09-15T07:00:00Z"}
J
cat > "$T/bin/jobs-client.sh" <<'SH'
# /api/settings is the kill switch's read (lane_switch, BH-2320): answered as
# the worker answers it with no rows, and counted apart from the ledger reads.
_jobs_req() {
  if [ "$2" = /api/settings ]; then echo "$*" >> "$HARNESS/calls/settings"; printf '{"settings":[]}'; return 0; fi
  echo "$*" >> "$HARNESS/calls/jobs"; cat "$HARNESS/fixtures-dora.json"; }
SH
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$HARNESS/calls/beat"
SH
chmod +x "$T/bin/beat.sh"

run() { "$DIR/bin/dora-digest.sh" "$@" >"$T/stdout" 2>"$T/stderr"; }
J24="$T/state/dora/$TODAY.json"
J7="$T/state/dora/$TODAY-7d.json"
TXT="$T/state/dora/latest.txt"
q() { jq -r "$1" "$J24"; }
alpha() { jq -r ".repos[] | select(.project==\"alpha\") | $1" "$J24"; }
beta()  { jq -r ".repos[] | select(.project==\"beta\")  | $1" "$J24"; }

# ── 1. the 24h run: the sources are read and the window filters ──────────────
run --window 24h --no-send
eq "24h run exits 0" "$?" "0"
[ -s "$J24" ] && ok || bad "state/dora/<date>.json must exist (stderr: $(cat "$T/stderr"))"
[ -s "$TXT" ]  && ok || bad "state/dora/latest.txt must exist"
eq "the ledger was consulted" "$(grep -c 'metrics/dora' "$T/calls/jobs" 2>/dev/null)" "1"
# TEST-CHANGE BH-6969: the digest now makes two worker reads, the dora route and
# the review-tiers route (at least 7 days); the list still pins every request.
# TEST-CHANGE BH-6748: the landing block reads landing_decisions once per fleet
# repo. This stub answers every route with the dora fixture, which has no
# `rows` array, so every decisions read is refused and nothing else is read
# (the block says n/a). The list stays exact; it gains those three lines.
eq "the worker reads are a GET on dora days=1, review-tiers days=7, then landing decisions per repo" "$(cat "$T/calls/jobs")" "GET /api/metrics/dora?days=1
GET /api/metrics/review-tiers?days=7
GET /api/landing-decisions?repo=Org/alpha&limit=200
GET /api/landing-decisions?repo=Org/beta&limit=200
GET /api/landing-decisions?repo=Org/gamma&limit=200"
grep -q '^landing: n/a (landing decisions error: ' "$TXT" && ok \
  || bad "a refused decisions body must say landing n/a: $(grep '^landing' "$TXT")"
eq "ledger source status" "$(q '.sources.ledger_dora.status')" "ok"
eq "conductor log status" "$(q '.sources.conductor_log.status')" "ok"
eq "resolver log status" "$(q '.sources.resolver_log.status')" "ok"
eq "cost csv status" "$(q '.sources.fleet_cost_csv.status')" "ok"
eq "per-pr csv status" "$(q '.sources.cost_per_pr_csv.status')" "ok"
eq "window arg is carried" "$(q '.window.arg')" "24h"
eq "window hours" "$(q '.window.hours')" "24"
eq "the ledger is asked for whole days" "$(q '.window.ledger_days')" "1"

# ── 2. merges: DISTINCT, windowed, ledger-first ──────────────────────────────
eq "alpha merges from the ledger" "$(alpha '.merged')" "5"
eq "alpha's own conductor-log count survives beside it" "$(alpha '.merged_conductor_log')" "4"
alpha '.merged_source' | grep -q 'ledger /api/metrics/dora' && ok || bad "alpha merged_source must name the ledger"
eq "beta merges" "$(beta '.merged')" "1"
eq "fleet merges come from the ledger totals" "$(q '.fleet.merged')" "6"
eq "the fleet keeps the log's count too" "$(q '.fleet.merged_conductor_log')" "6"
eq "conductor merges are counted per DISTINCT pr" "$(q '.sources.conductor_log.merged_prs')" "6"
# Eleven stamped lines are in the 24h window; the 5-day-old line, the 10-day-old
# pair and the unstamped line are not.
eq "only in-window conductor lines are read" "$(q '.sources.conductor_log.lines_in_window')" "11"
eq "the log's total line count is recorded" "$(q '.sources.conductor_log.lines_total')" "15"

# ── 2b. box test minutes: the suite time the box spent, per project ─────────
neq "alpha box test minutes" "$(alpha '.box_test.minutes')" "3.0"
eq "alpha suite runs (the gates line and the 10-day-old line are not counted)" "$(alpha '.box_test.runs')" "2"
eq "alpha build dirs" "$(alpha '.box_test.builds')" "1"
neq "alpha box test per PR, over the ledger's 5 merges" "$(alpha '.box_test.per_pr_min')" "0.6"
eq "the per-PR denominator is the row's merge count" "$(alpha '.box_test.denominator')" "5"
alpha '.box_test.source' | grep -q 'STAGE-TIMING' && ok || bad "box test must name the line it counted"
eq "alpha does not claim its source is absent" "$(alpha '.box_test.unavailable')" "null"
eq "a dir belonging to no registered project is counted, not rowed" "$(q '.sources.builds_pipeline_logs.unattributed_builds')" "1"
neq "the fleet total carries the unattributed dir's minutes" "$(q '.fleet.box_test.minutes')" "4.0"
eq "only in-window STAGE-TIMING suite lines are read" "$(q '.sources.builds_pipeline_logs.lines_in_window')" "3"
eq "every build dir with a pipeline.log was walked" "$(q '.sources.builds_pipeline_logs.build_dirs')" "2"
grep -qE '^alpha: 5 merged, .*\(\$120\), box test 0.6m/PR$' "$TXT" && ok \
  || bad "the alpha line must end with its box test minutes: $(grep '^alpha:' "$TXT")"
grep -qE '^fleet \$: .*, box test 0.7m/PR$' "$TXT" && ok \
  || bad "the fleet line must carry the fleet figure: $(grep '^fleet \$:' "$TXT")"
grep -q '^sources: .*, builds/ 3 lines in window' "$TXT" && ok \
  || bad "the sources line must say what builds/ gave: $(grep '^sources:' "$TXT")"

# ── 2c. the same minutes over the conductor log's 4 merges ──────────────────
DORA_LEDGER=0 run --window 24h --no-send
eq "a ledger-off run exits 0" "$?" "0"
eq "alpha merges without the ledger" "$(alpha '.merged')" "4"
neq "alpha box test per PR over 4 merges" "$(alpha '.box_test.per_pr_min')" "0.8"
neq "the minutes themselves do not move with the denominator" "$(alpha '.box_test.minutes')" "3.0"
eq "nor does the run count" "$(alpha '.box_test.runs')" "2"

# ── 2d. a pool- copy of an alpha build rows under alpha ─────────────────────
mkdir -p "$T/builds/pool-alpha-A-2"
echo "$IN_LOG [alpha/A-2] STAGE-TIMING suite start=1 end=61 secs=60" \
  > "$T/builds/pool-alpha-A-2/pipeline.log"
run --window 24h --no-send
eq "the second-dir run exits 0" "$?" "0"
eq "the copy marker does not hide the project" "$(alpha '.box_test.builds')" "2"
neq "minutes across both dirs" "$(alpha '.box_test.minutes')" "4.0"
neq "per PR across both dirs, over the ledger's 5" "$(alpha '.box_test.per_pr_min')" "0.8"

# ── 2e. no builds/ at all: n/a, never 0 ─────────────────────────────────────
DORA_BUILDS_DIR="$T/no-such-builds" run --window 24h --no-send
eq "a run with no builds dir exits 0" "$?" "0"
eq "no builds dir: minutes are null, not 0" "$(alpha '.box_test.minutes')" "null"
eq "no builds dir: the reason is named" "$(alpha '.box_test.unavailable')" "n/a (source builds/ absent)"
eq "no builds dir: the fleet figure is null too" "$(q '.fleet.box_test.minutes')" "null"
eq "the source reports itself absent" "$(q '.sources.builds_pipeline_logs.status')" "absent"
grep -qE '^alpha: .*, box test n/a$' "$TXT" && ok \
  || bad "an absent builds dir must render n/a: $(grep '^alpha:' "$TXT")"
jq -r '.notes[]' "$J24" | grep -q 'builds/ is absent' && ok || bad "an absent builds dir must leave a note"
run --window 24h --no-send   # back to the full fixture for everything below

# ── 3. lead time: the ledger's, or honestly absent ───────────────────────────
eq "alpha lead p50" "$(alpha '.lead_time.p50_s')" "3600"
eq "alpha lead p90" "$(alpha '.lead_time.p90_s')" "7200"
eq "alpha lead n" "$(alpha '.lead_time.n')" "5"
alpha '.lead_time.source' | grep -q 'jobs.created_at' && ok || bad "lead time must name the clock it started on"
eq "fleet lead p50" "$(q '.fleet.lead_time.p50_s')" "3000"
grep -q 'lead p50 50m p90 2h' "$TXT" && ok || bad "the message must render lead time as durations: $(grep '^fleet:' "$TXT")"

# ── 3b. launch lead time: the clock that starts when the CLIENT asks ─────────
# lead_time starts when this fleet claimed the ticket, so a ticket that sat
# untriaged for a day reads as fast. launch_lead_time starts at the issue, and
# a worker that does not report it must read as absent — never as zero, which
# would say "we start instantly" about a queue nobody measured.
eq "alpha launch p50" "$(alpha '.launch_lead_time.p50_s')" "1800"
eq "alpha launch p90" "$(alpha '.launch_lead_time.p90_s')" "9000"
eq "alpha launch n" "$(alpha '.launch_lead_time.n')" "4"
alpha '.launch_lead_time.source' | grep -q 'jobs.issue_created_at' && ok \
  || bad "launch lead time must name the clock it started on"
eq "a project the worker reported no launch lead time for is null" "$(beta '.launch_lead_time.p50_s')" "null"
eq "and its n is null, not 0" "$(beta '.launch_lead_time.n')" "null"
beta '.launch_lead_time.unavailable' | grep -q 'n/a (source /api/metrics/dora launch_lead_time absent)' && ok \
  || bad "an absent launch_lead_time must say which key is missing: $(beta '.launch_lead_time.unavailable')"
eq "fleet launch p50" "$(q '.fleet.launch_lead_time.p50_s')" "1500"
grep -q 'launch p50 25m p90 2h30m' "$TXT" && ok \
  || bad "the fleet line must render launch lead time as durations: $(grep '^fleet:' "$TXT")"

# ── 4. conflict rate: distinct DIRTY prs over the SAME log's merges ──────────
eq "alpha counts one conflicted PR, not three lines" "$(alpha '.conflict.dirty_prs')" "1"
eq "alpha conflict denominator is the conductor log's 4" "$(alpha '.conflict.denominator')" "4"
eq "alpha conflict rate" "$(alpha '.conflict.rate')" "0.25"
alpha '.conflict.denominator_source' | grep -q 'SAME log' && ok || bad "the conflict rate must name its denominator"
eq "beta had no conflicts" "$(beta '.conflict.dirty_prs')" "0"
neq "beta conflict rate is 0, not null" "$(beta '.conflict.rate')" "0"
eq "fleet conflict rate" "$(q '.fleet.conflict.rate')" "0.1667"

# ── 5. rebuilds, lane deaths, abandonment ────────────────────────────────────
eq "alpha rebuild events" "$(alpha '.rebuild.rebuilds')" "2"
eq "alpha rebuild rate over the log's merges" "$(alpha '.rebuild.rate')" "0.5"
eq "alpha fix rounds" "$(alpha '.fix_rounds')" "1"
eq "alpha lost no lanes" "$(alpha '.lane_deaths.count')" "0"
eq "beta lost one lane" "$(beta '.lane_deaths.count')" "1"
eq "the dead lane names its ticket" "$(beta '.lane_deaths.tickets[0]')" "beta-B-3"
eq "beta abandoned one ticket" "$(beta '.abandoned')" "1"
eq "fleet rebuild rate" "$(q '.fleet.rebuild.rate')" "0.3333"
eq "fleet lane deaths" "$(q '.fleet.lane_deaths')" "1"
eq "fleet abandoned" "$(q '.fleet.abandoned')" "1"
eq "only in-window resolver lines are read" "$(q '.sources.resolver_log.lines_in_window')" "7"

# ── 5b. a repo the ledger never mentioned still rows, off the log alone ─────
gamma() { jq -r ".repos[] | select(.project==\"gamma\") | $1" "$J24"; }
eq "gamma rows from the conductor log" "$(gamma '.merged')" "1"
gamma '.merged_source' | grep -q 'merge-conductor.log' && ok || bad "gamma must name the log as its source"
eq "gamma lead time is n/a, not 0" "$(gamma '.lead_time.p50_s')" "null"
gamma '.lead_time.unavailable' | grep -q 'n/a (source /api/metrics/dora' && ok \
  || bad "a project the ledger does not know must say why lead time is missing"
eq "gamma launch lead time is n/a, not 0" "$(gamma '.launch_lead_time.p50_s')" "null"
gamma '.launch_lead_time.unavailable' | grep -q 'n/a (source /api/metrics/dora launch_lead_time absent)' && ok \
  || bad "a project the ledger does not know must say why launch lead time is missing"
# THE DISTINCTION: the csv was readable and held no gamma row, so gamma measured
# $0. Reporting that as n/a would hide a project that ships for free.
neq "a readable csv with no rows for a repo measures \$0" "$(gamma '.cost.total_usd')" "0"
eq "and does not claim to be unavailable" "$(gamma '.cost.unavailable')" "null"
# Same distinction for suite minutes: builds/ was readable and held no gamma
# build, so gamma ran its suite for 0.0 minutes — a fact, not a blind spot.
eq "a readable builds dir with no build for a repo measures 0 minutes" "$(gamma '.box_test.minutes')" "0.0"
eq "and gamma's box test does not claim to be unavailable" "$(gamma '.box_test.unavailable')" "null"

# ── 6. change-failure proxy: ledger reverts PLUS red-twice parks ─────────────
eq "alpha reverts/reopens from the ledger" "$(alpha '.change_failure_proxy.reverts_or_reopens')" "1"
eq "alpha red-twice parks, distinct" "$(alpha '.change_failure_proxy.red_twice')" "1"
eq "alpha proxy numerator" "$(alpha '.change_failure_proxy.bad')" "2"
eq "alpha proxy divides by the merge count" "$(alpha '.change_failure_proxy.denominator')" "5"
eq "alpha proxy rate" "$(alpha '.change_failure_proxy.rate')" "0.4"
eq "main-red rides along without entering the rate" "$(alpha '.change_failure_proxy.main_red')" "2"
eq "fleet proxy rate" "$(q '.fleet.change_failure_proxy.rate')" "0.3333"

# ── 7. money: by name, by repo, by account, cash vs absorbed ────────────────
neq "alpha window spend" "$(alpha '.cost.total_usd')" "120"
neq "alpha absorbed" "$(alpha '.cost.subscription_usd')" "100"
neq "alpha cash" "$(alpha '.cost.cash_usd')" "20"
eq "the unpriced row still counts as a row" "$(alpha '.cost.rows')" "3"
eq "unpriced rows are named" "$(q '.sources.fleet_cost_csv.unpriced_rows_in_window')" "1"
neq "alpha \$/PR" "$(alpha '.cost.per_pr_usd')" "24"
neq "a blank billing_mode is unknown, not absorbed" "$(beta '.cost.unknown_billing_usd')" "10"
neq "beta \$/PR" "$(beta '.cost.per_pr_usd')" "10"
eq "per-PR attribution excludes PRs this window did not merge" "$(alpha '.cost.attributed.n')" "2"
neq "attributed sum" "$(alpha '.cost.attributed.sum_usd')" "40"
neq "attributed median" "$(alpha '.cost.attributed.median_usd')" "20"
eq "the join reports how many PRs matched" "$(q '.sources.cost_per_pr_csv.matched_window_prs')" "3"
neq "fleet total \$ includes every lane" "$(q '.fleet.cost.total_usd')" "135"
neq "fleet repo \$ excludes the lanes that own no repo" "$(q '.fleet.cost.repo_usd')" "130"
neq "the non-repo lanes are itemised" "$(q '.fleet.cost.non_repo_usd["alert-triage"]')" "5"
eq "fleet \$/PR (repos)" "$(q '.fleet.cost.per_pr_usd')" "21.67"
eq "fleet \$/PR (all in)" "$(q '.fleet.cost.per_pr_usd_all_in')" "22.5"
neq "fleet cash" "$(q '.fleet.cost.cash_usd')" "20"
neq "fleet absorbed" "$(q '.fleet.cost.subscription_usd')" "105"
neq "per-account total" "$(jq -r '.accounts[] | select(.account=="acct:max1") | .cost_usd' "$J24")" "115"
neq "per-account cash" "$(jq -r '.accounts[] | select(.account=="xai-key:k") | .cash_usd' "$J24")" "20"
eq "an out-of-window \$999 row is not spent twice" "$(q '.sources.fleet_cost_csv.rows_in_window')" "5"
eq "gamma spent nothing and so adds nothing" "$(q '.fleet.cost.repo_usd')" "130.0"

# ── 8. quota + cash overage ─────────────────────────────────────────────────
eq "both accounts are listed, the dotfile is not" "$(q '.quota | length')" "2"
neq "max1 weekly %" "$(jq -r '.quota[] | select(.account=="max1") | .weekly_pct' "$J24")" "55"
eq "max1 reset instant" "$(jq -r '.quota[] | select(.account=="max1") | .weekly_resets_at' "$J24")" "2026-09-16T08:59:59.851666+00:00"
eq "a 429'd account is null, not 0" "$(jq -r '.quota[] | select(.account=="max2") | .weekly_pct' "$J24")" "null"
grep -q 'weekly caps: max1 55% resets 2026-09-16T08:59:59Z' "$TXT" && ok || bad "the message must carry the weekly % and its reset: $(grep 'weekly caps' "$TXT")"
grep -q 'caps unreadable: max2' "$TXT" && ok || bad "an account that cannot self-report must be named"
eq "overage account is read" "$(jq -r '.cash_overage[0].account' "$J24")" "acctA"
neq "cash used" "$(jq -r '.cash_overage[0].extra_used_usd' "$J24")" "175"
neq "cash spent IN the window" "$(jq -r '.cash_overage[0].window_delta_usd' "$J24")" "75"
jq -r '.cash_overage[0].window_delta_basis' "$J24" | grep -q 'last sample before the window' && ok \
  || bad "the delta must name its baseline"
eq "overage flag" "$(jq -r '.cash_overage[0].in_overage' "$J24")" "true"

# ── 9. the message is plain text, short lines, one repo per line ─────────────
grep -q '^DORA + unit economics — 24h to ' "$TXT" && ok || bad "the message needs a window headline"
grep -qE '^alpha: 5 merged, lead 1h/2h, launch 30m/2h30m, conflict 25%, rebuild 50%, deaths 0, CFR 40%, \$24.00/PR \(\$120\), box test 0.8m/PR$' "$TXT" \
  && ok || bad "the alpha line is not as specified: $(grep '^alpha:' "$TXT")"
grep -qE '^gamma: 1 merged, lead n/a/n/a, launch n/a/n/a, ' "$TXT" \
  && ok || bad "a repo with neither clock measured renders n/a on both: $(grep '^gamma:' "$TXT")"
grep -qE '^beta: 1 merged, ' "$TXT" && ok || bad "one repo per line"
grep -q '|' "$TXT" && [ "$(grep -c '^|' "$TXT")" = "0" ] && ok || bad "no markdown tables"
grep -q '^sources: ledger 2 projects, conductor.log 11 lines in window' "$TXT" && ok \
  || bad "the message must state what it read: $(grep '^sources:' "$TXT")"
grep -q "every number's source + line counts: $J24" "$TXT" && ok || bad "the message must point at the json"
eq "--no-send posts nothing" "$([ -f "$T/calls/beat" ] && echo posted || echo silent)" "silent"

# ── 10. the send path: the fleet-topic beat carries the text verbatim ────────
run --window 24h --send
eq "a send exits 0" "$?" "0"
[ -s "$T/calls/beat" ] && ok || bad "a send must post a beat"
B=$(tail -1 "$T/calls/beat")
eq "beat kind" "$(jq -r '.kind' <<<"$B")" "fleet_alert"
eq "beat project" "$(jq -r '.project' <<<"$B")" "fleet"
eq "the digest bypasses alert quarantine" "$(jq -r '.triaged' <<<"$B")" "true"
eq "beat akey is one per window per day" "$(jq -r '.akey' <<<"$B")" "dora-digest:24h:$TODAY"
eq "the beat line IS the message" "$(jq -r '.line' <<<"$B")" "$(cat "$TXT")"

# ── 11. the 7d window sees the 5-day-old rows and writes its own file ───────
run --window 7d --no-send
eq "7d run exits 0" "$?" "0"
[ -s "$J7" ] && ok || bad "a non-default window writes <date>-<window>.json"
eq "7d asks the ledger for 7 days" "$(jq -r '.window.ledger_days' "$J7")" "7"
eq "7d sees the 5-day-old merge" "$(jq -r '.fleet.merged_conductor_log' "$J7")" "7"
neq "7d sees the 5-day-old \$60 row" "$(jq -r '.repos[]|select(.project=="alpha")|.cost.total_usd' "$J7")" "180"
neq "7d still excludes the 10-day-old \$999 row" "$(jq -r '.fleet.cost.total_usd' "$J7")" "195"
eq "the 24h file is not overwritten by the 7d run" "$(jq -r '.window.arg' "$J24")" "24h"

# ── 12. flags/dora-digest.conf configures, and the CLI still wins ───────────
printf 'DORA_MAX_ROWS=1\nDORA_SEND=0\nEVIL=$(touch %s/pwned)\n' "$T" > "$T/flags/dora-digest.conf"
rm -f "$T/calls/beat"
run --window 24h
eq "the conf-configured run exits 0" "$?" "0"
eq "DORA_MAX_ROWS from the conf trims the message" "$(grep -c '^alpha:\|^beta:' "$TXT")" "1"
grep -q '^(2 more repo(s) in the json)$' "$TXT" && ok || bad "a trimmed message must say what it trimmed"
eq "the json is never trimmed" "$(q '.repos | length')" "3"
eq "DORA_SEND=0 from the conf suppresses the beat" "$([ -f "$T/calls/beat" ] && echo posted || echo silent)" "silent"
[ ! -e "$T/pwned" ] && ok || bad "the conf file is PARSED, never sourced — it must not be able to run code"
DORA_MAX_ROWS=2 run --window 24h --no-send
eq "the environment beats the conf file" "$(grep -c '^alpha:\|^beta:' "$TXT")" "2"
rm -f "$T/flags/dora-digest.conf"
# A knob that is not a number must fall back loudly, not reach python and crash.
DORA_MAX_ROWS=lots run --window 24h --no-send
eq "a non-numeric knob does not kill the run" "$?" "0"
grep -q "DORA_MAX_ROWS='lots' is not a number" "$T/logs/dora-digest.log" && ok \
  || bad "the fallback must be logged, not silent"
eq "the digest still renders every repo" "$(grep -c '^alpha:\|^beta:\|^gamma:' "$TXT")" "3"

# ── 13. the kill switch and a window nobody can parse ──────────────────────
touch "$T/flags/dora-digest-off"
rm -f "$J24"
run --window 24h --no-send
eq "the kill switch exits 0" "$?" "0"
[ ! -f "$J24" ] && ok || bad "flags/dora-digest-off must write nothing"
rm -f "$T/flags/dora-digest-off"
run --window 3weeks --no-send
eq "an unparseable window is refused" "$?" "2"
grep -q 'must be <n>h or <n>d' "$T/stderr" && ok || bad "the refusal must say what a window looks like"

# ── 14. every source missing: n/a, one ALERTS line, exit 0 ─────────────────
S=$(mktemp -d "$T/s-XXXXXX"); mkdir -p "$S/bin" "$S/logs" "$S/flags" "$S/state"
cp "$T/bin/beat.sh" "$S/bin/beat.sh"
HARNESS="$S" FLEET_CONF="$T/fleet.conf" "$DIR/bin/dora-digest.sh" --window 24h --no-send >/dev/null 2>&1
eq "a box with no sources at all still exits 0" "$?" "0"
JS="$S/state/dora/$TODAY.json"
[ -s "$JS" ] && ok || bad "a degraded run still writes its json"
eq "merges are n/a, not 0" "$(jq -r '.fleet.merged' "$JS")" "null"
eq "the ledger is reported absent" "$(jq -r '.sources.ledger_dora.status' "$JS")" "absent"
eq "the conductor log is reported absent" "$(jq -r '.sources.conductor_log.status' "$JS")" "absent"
eq "\$ is n/a, not 0" "$(jq -r '.fleet.cost.total_usd' "$JS")" "null"
eq "no repo rows are invented" "$(jq -r '.repos | length' "$JS")" "0"
jq -e '.notes | length >= 4' "$JS" >/dev/null && ok || bad "every degradation must leave a note"
jq -r '.notes[]' "$JS" | grep -q 'merge-conductor.log is absent' && ok || bad "the notes must name the absent file"
grep -q 'n/a' "$S/state/dora/latest.txt" && ok || bad "the message must say n/a"
# Not "$0 other lanes": with the cost csv unreadable, every dollar figure on that
# line is unknown, and a zero there would read as a free day.
grep -q '^fleet \$: n/a total (n/a repos + n/a other lanes), all-in n/a/PR' "$S/state/dora/latest.txt" \
  && ok || bad "an unreadable cost csv must not render as \$0: $(grep '^fleet \$' "$S/state/dora/latest.txt")"
eq "fleet box test is n/a on a box with no builds/" "$(jq -r '.fleet.box_test.unavailable' "$JS")" "n/a (source builds/ absent)"
eq "an unmeasurable fleet writes exactly one ALERTS line" "$(alerts "$S/logs/ALERTS.log")" "1"
grep -q 'MERGES UNMEASURABLE' "$S/logs/ALERTS.log" && ok || bad "the alert must say what is unknown"
[ -f "$S/flags/alerted-dora-digest-$(date -u +%Y%m%d)" ] && ok || bad "the alert must be flagged once a day"
HARNESS="$S" FLEET_CONF="$T/fleet.conf" "$DIR/bin/dora-digest.sh" --window 24h --no-send >/dev/null 2>&1
eq "a second degraded run does not re-page" "$(alerts "$S/logs/ALERTS.log")" "1"
scratch_rm "$S"

# ── 15. the ledger down, the logs up: merges fall back and say so ──────────
rm -f "$T/bin/jobs-client.sh"
run --window 24h --no-send
eq "a ledger-less run exits 0" "$?" "0"
eq "merges fall back to the conductor log" "$(q '.fleet.merged')" "6"
q '.fleet.merged_source' | grep -q 'merge-conductor.log' && ok || bad "the fallback must name itself"
eq "lead time is n/a rather than invented" "$(q '.fleet.lead_time.p50_s')" "null"
q '.fleet.lead_time.unavailable' | grep -q 'n/a (source' && ok || bad "an absent metric says which source is missing"
eq "launch lead time is n/a rather than invented" "$(q '.fleet.launch_lead_time.p50_s')" "null"
q '.fleet.launch_lead_time.unavailable' | grep -q 'launch_lead_time absent' && ok \
  || bad "an absent launch lead time says which key is missing"
grep -q 'launch p50 n/a p90 n/a' "$TXT" && ok \
  || bad "a ledger-less fleet line must say n/a for launch lead time: $(grep '^fleet:' "$TXT")"
eq "alpha still reports its own merges" "$(alpha '.merged')" "4"
eq "the conflict rate is unaffected by the ledger being down" "$(alpha '.conflict.rate')" "0.25"
neq "the \$ figures are unaffected" "$(alpha '.cost.total_usd')" "120"
neq "alpha box test per PR over the conductor log's 4 merges" "$(alpha '.box_test.per_pr_min')" "1.0"
neq "the minutes do not depend on the ledger either" "$(alpha '.box_test.minutes')" "4.0"
eq "no ALERTS line while one merge source still answers" "$(alerts "$T/logs/ALERTS.log")" "0"

# ── 16. no merge count anywhere: the minutes survive, the rate does not ────
mv "$T/logs/merge-conductor.log" "$T/mc.bak"
run --window 24h --no-send
eq "a run with neither merge source exits 0" "$?" "0"
eq "with no merge count, per PR is null rather than invented" "$(alpha '.box_test.per_pr_min')" "null"
neq "but the minutes are still summed" "$(alpha '.box_test.minutes')" "4.0"
eq "and the denominator says it is missing" "$(alpha '.box_test.denominator')" "null"
mv "$T/mc.bak" "$T/logs/merge-conductor.log"

echo "dora-digest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
