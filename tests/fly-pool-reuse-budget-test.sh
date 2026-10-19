#!/bin/bash
# tests/fly-pool-reuse-budget-test.sh — the machine-reuse search in
# next_job_or_destroy stops at the tick budget (hub incident 2026-10-19).
#
# The reuse loop walked every queued row and read each row's issue
# (spec_repos_load) BEFORE the spawn-decision gate that knows the tick budget.
# 156 queued rows were ~156 issue reads of 5-20 s each: a project-6-os tick ran
# 25 minutes past its 600 s budget holding the pool lock.
#   a  budget already spent, 50 rows queued: at most 1 spec_repos_load, one log
#      line naming the machine, the machine is destroyed, every row stays queued
#   b  budget left: the first fitting row is still handed to the machine
#   c  pool_spawn_decision refuses on budget (_POOL_BUDGET_SAID): the loop stops
#   d  POOL_TICK_T0 unset: no budget applies, the machine is reused as before
# The function is extracted alone, like tests/pool-account-routing-test.sh.
# Run from anywhere: tests/fly-pool-reuse-budget-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NR="$T/reusebudget"; mkdir -p "$NR/q" "$NR/pool" "$NR/bin"
sed -n '/^next_job_or_destroy() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$NR/fn.sh"
sed -n '/^pool_tick_budget_spent() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$NR/budget.sh"
grep -q 'REUSED=0' "$NR/fn.sh" || bad "could not extract next_job_or_destroy"
grep -q 'date +%s' "$NR/budget.sh" || bad "could not extract pool_tick_budget_spent"
printf '#!/bin/bash\necho "$*" >> "${FAKE_FLY_LOG:?}"\n' > "$NR/fly"
printf '#!/bin/bash\nexit 0\n' > "$NR/bin/beat.sh"
chmod +x "$NR/fly" "$NR/bin/beat.sh"

# drive <rows> <mode> -> prints DESTROYED|REUSED; counters land in $NR/loads
# mode: spent | left | decide_budget | unset
drive() {
  local rows="$1" mode="$2" i
  rm -f "$NR/q"/*.json "$NR/pool"/*.json "$NR/flylog" "$NR/loads" "$NR/decided"
  : > "$NR/log"; : > "$NR/loads"; : > "$NR/decided"
  for i in $(seq 1 "$rows"); do
    jq -nc --arg k "TK-$i" --arg t "$i" '{key:$k,ticket_id:$t,attempt:0}' > "$NR/q/TK-$i.json"
  done
  jq -nc '{machine:"m1",key:"TK-DONE"}' > "$NR/pool/m1.json"
  (
    set +u
    HARNESS="$NR"; P=project-5; APP=app; FLY="$NR/fly"; export FAKE_FLY_LOG="$NR/flylog"
    QDIR="$NR/q"; POOL="$NR/pool"; LOG="$NR/log"
    MID=m1; MSTATE=started; KEY=TK-DONE; MF="$NR/pool/m1.json"; MACCT=""
    STAMP() { echo now; }; say() { echo "$*" >> "$LOG"; }
    mexec() { return 0; }; mput() { return 0; }; push_preplan() { :; }
    push_reroute() { :; }; push_build_note() { :; }; push_bake_evidence() { :; }
    pool_account_armed() { return 1; }
    spec_repos_load() { echo "$2" >> "$NR/loads"; SPEC_REPOS=""; }
    . "$NR/budget.sh"; . "$NR/fn.sh"
    case "$mode" in
      spent) POOL_TICK_T0=$(( $(date +%s) - 700 )); POOL_TICK_BUDGET_S=600
        dm_job_admit() { return 1; } ;;  # no row fits: the old loop reads all 50
      left)  POOL_TICK_T0=$(date +%s); POOL_TICK_BUDGET_S=600 ;;
      decide_budget) POOL_TICK_T0=$(date +%s); POOL_TICK_BUDGET_S=600
        pool_spawn_decision() { echo "$2" >> "$NR/decided"; _POOL_BUDGET_SAID=1; return 1; } ;;
      unset) unset POOL_TICK_T0 ;;
    esac
    next_job_or_destroy
    if grep -q 'machine destroy m1' "$NR/flylog" 2>/dev/null; then echo DESTROYED; else echo REUSED; fi
  )
}
count() { local n; n=$(grep -c . "$1" 2>/dev/null) || n=0; echo "$n"; }

# a. budget spent, 50 rows queued
R=$(drive 50 spent)
[ "$(count "$NR/loads")" -le 1 ] && ok || bad "a: $(count "$NR/loads") spec_repos_load calls with the budget spent and 50 rows queued"
[ "$R" = DESTROYED ] && ok || bad "a: machine was not destroyed (got $R)"
[ "$(grep -c 'tick budget' "$NR/log")" = 1 ] && ok || bad "a: expected one budget log line"
L=$(grep 'tick budget' "$NR/log" | head -1)
case "$L" in *m1*) ok ;; *) bad "a: the log line does not name the machine" ;; esac
[ "$(find "$NR/q" -name '*.json' | wc -l | tr -d ' ')" = 50 ] && ok || bad "a: a queued row was consumed"

# b. budget left: first fitting row is reused
R=$(drive 50 left)
[ "$R" = REUSED ] && ok || bad "b: machine was not reused with budget left (got $R)"
[ "$(count "$NR/loads")" -le 1 ] && ok || bad "b: reuse read more than one row ($(count "$NR/loads"))"
[ "$(grep -c 'tick budget' "$NR/log")" = 0 ] && ok || bad "b: a budget line was logged with budget left"

# c. pool_spawn_decision answers budget: the loop stops after one decision
R=$(drive 50 decide_budget)
[ "$(count "$NR/decided")" -le 1 ] && ok || bad "c: loop kept deciding rows after the budget answer ($(count "$NR/decided"))"
[ "$R" = DESTROYED ] && ok || bad "c: machine was not destroyed (got $R)"

# d. no POOL_TICK_T0: no budget applies
R=$(drive 3 unset)
[ "$R" = REUSED ] && ok || bad "d: unset POOL_TICK_T0 stopped the reuse (got $R)"

scratch_rm "$NR"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
