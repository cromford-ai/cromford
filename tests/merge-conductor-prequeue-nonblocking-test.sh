#!/bin/bash
# tests/merge-conductor-prequeue-nonblocking-test.sh — BH-7376 item 2: the
# prequeue step never holds a keyed run open. The gate dispatches
# prequeue-gate.yml, records the head (a `pending` cache entry) and returns; a
# later run reads the verdict. Nothing inside the gate sits on the project's
# git lock (pq_restamp, pq_merge_test) for longer than
# MC_PREQUEUE_GIT_LOCK_WAIT_S (default 5): a busy lock is a hold, asked again
# by the next run.
#
# THE INCIDENT (hub, 2026-10-17/18). The prequeue step of a keyed READY run
# took up to 265 s (cromford) and 290 s (project-5), so `timeout
# MC_BACKSTOP_TIMEOUT_S` (290 s) killed the run before `enqueue`. The restamp
# write runs under mc_git_locked, which waits MC_GIT_LOCK_WAIT (180 s) for the
# project's git lock that rebase workers hold; a write is never cut by the
# BH-7029 call budget.
#
# The REAL pq_gate (bin/lib/mc-prequeue.sh), its REAL hooks
# (bin/lib/mc-prequeue.d/*.sh, pq_restamp included) and the REAL mc_git_locked
# (bin/lib/mc/locks.sh) run against a stubbed GitHub (gh_rest, gh).
#   N0  a miss: the gate dispatches once, writes `pending` for (head, main) and
#       answers hold
#   N1  pending run in progress, git lock held by another worker: the gate
#       answers hold in under 30 s (MC_GIT_LOCK_WAIT is 45 s on this box)
#   N2  N1 dispatches nothing new and the pending entry still names the head
#   N3  the run ends green, the lock is free: the next run answers proceed (the
#       READY arm enqueues on proceed) and the entry is recorded green
#   N4  the knob is read through pq_knob: MC_PREQUEUE_GIT_LOCK_WAIT_S has a
#       default in PQ_KNOB_DEFAULTS and a registry file
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-prequeue-nonblocking-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

HEAD=$(printf 'cd%038d' 7)
MAIN=$(printf 'ab%038d' 0)
RUN_ID=777001
UL="$T/u"; mkdir -p "$UL/hh/bin" "$UL/hh/locks" "$UL/hh/tmp/conductor/example-org_demo/.git"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$UL" > "$UL/hh/bin/lane-alert.sh"; chmod +x "$UL/hh/bin/lane-alert.sh"
: > "$UL/alerts"

# load <case> — the real libs and the GitHub stubs, in the caller's subshell.
# RUN_STATE is the run's status in the run list: in_progress or completed.
# shellcheck disable=SC2034  # the libs this sources read these globals
load() {
  C="$UL/$1"; mkdir -p "$C/tmp"
  MC_H="$UL/hh" HARNESS="$UL/hh" TMPDIR="$C/tmp"
  SLUG=example-org/demo P=demo KEY="example-org/demo#7" ACTIONS=1
  MC_STATE_DIR="$UL/state" MC_TICK_ID="t7376-$1" MC_TICK_DIR="$C/tick" MC_LOG="$C/mclog"
  mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
  mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
  mc_log() { printf '%s\n' "$*" >> "$C/log"; }
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/fanin.sh"; . "$DIR/bin/lib/mc/queue.sh"; . "$DIR/bin/lib/mc/locks.sh"; . "$DIR/bin/lib/mc-prequeue.sh"
  mc_log() { printf '%s\n' "$*" >> "$C/log"; }
  mc_attempt_has() { return 1; }; mc_attempt_put() { :; }
  mc_use_token() { :; }
  pq_status_gate() { printf '%s\n' "$*" >> "$C/status"; }
  pq_impact_reuse() { _pq_ir=none; }
  pq_invariants_args() { :; }; pq_learned_args() { :; }
  # The restamp's own work is stubbed; the lock it takes is the real one.
  sr_plan() { :; }; sr_top() { echo 0001_stamp; }
  mc_funnel_repo() { return 0; }; mc_git_auth_clear() { :; }
  _pq_rs_run() { _PQ_RS=none; }
  gh() { printf '%s\n' "$*" >> "$UL/dispatches"; }
  gh_rest() {
    printf '%s\n' "$2" >> "$C/reads"
    case "$2" in
      */commits/*) printf '{"sha":"%s"}' "$MAIN" ;;
      */actions/workflows/prequeue-gate.yml) printf '{}' ;;
      */actions/workflows/prequeue-gate.yml/runs\?*)
        if [ "${RUN_STATE:-none}" = none ]; then printf '{"workflow_runs":[]}'; return 0; fi
        jq -nc --arg t "prequeue pr=7 head=$HEAD main=$MAIN" --arg s "$RUN_STATE" --argjson id "$RUN_ID" \
          '{workflow_runs:[{id:$id,status:$s,conclusion:(if $s=="completed" then "success" else null end),display_title:$t,created_at:"2026-10-18T00:00:00Z"}]}' ;;
      */compare/*) printf '{"status":"ahead","ahead_by":1}' ;;
      */actions/runs/$RUN_ID/jobs) printf '{"jobs":[{"id":9001}]}' ;;
      */check-runs/9001/annotations)
        jq -nc --arg m "green main=$MAIN head=$HEAD suites=-" '[{title:"prequeue-verdict",message:$m}]' ;;
      *) return 44 ;;
    esac
  }
}
ENTRY="$UL/state/prequeue/example-org_demo_7_${HEAD}_${MAIN}"
: > "$UL/dispatches"

# --- N0. a miss: dispatch, record the head, return -----------------------------
( load n0; RUN_STATE=none
  pq_gate example-org/demo 7 u "$HEAD" main >/dev/null
  echo "verdict=$PQ_VERDICT"; echo "why=$PQ_WHY" ) > "$UL/n0.out" 2>&1
grep -qx 'verdict=hold' "$UL/n0.out" && ok || bad "N0 a fresh dispatch answers hold ($(cat "$UL/n0.out"))"
[ "$(grep -c 'workflow run prequeue-gate.yml' "$UL/dispatches")" = 1 ] && ok || bad "N0 exactly one dispatch ($(cat "$UL/dispatches"))"
read -r ST _ < "$ENTRY" 2>/dev/null
[ "${ST:-}" = pending ] && ok || bad "N0 the pending entry names (head, main) ($(cat "$ENTRY" 2>/dev/null || echo none))"
grep -q 'its verdict is read on a later tick' "$UL/n0.out" && ok || bad "N0 PQ_WHY says the verdict is read later ($(cat "$UL/n0.out"))"

# --- N1/N2. pending run, git lock busy: returns at once ------------------------
GITLOCK="$UL/hh/locks/merge-conductor-demo-git.lock"
( exec 7>>"$GITLOCK"; flock 7; touch "$UL/holding"; sleep 60 ) &   # determinism: ok a rebase worker that holds the project git lock
HOLDER=$!
n=0; while [ ! -e "$UL/holding" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done   # determinism: ok waits for the holder to take the lock
# shellcheck disable=SC2034  # MC_GIT_LOCK_WAIT is the box's wait; mc_git_locked reads it
( load n1; RUN_STATE=in_progress MC_GIT_LOCK_WAIT=45
  t0=$(date +%s)
  pq_gate example-org/demo 7 u "$HEAD" main >/dev/null
  echo "secs=$(( $(date +%s) - t0 ))"; echo "verdict=$PQ_VERDICT"; echo "why=$PQ_WHY" ) > "$UL/n1.out" 2>&1
S=$(sed -n 's/^secs=//p' "$UL/n1.out")
[ -n "$S" ] && [ "$S" -lt 30 ] && ok || bad "N1 a keyed run with a pending dispatch must return in under 30 s (took ${S:-?}s: $(cat "$UL/n1.out"))"
grep -qx 'verdict=hold' "$UL/n1.out" && ok || bad "N1 the answer is hold ($(cat "$UL/n1.out"))"
[ "$(grep -c 'workflow run prequeue-gate.yml' "$UL/dispatches")" = 1 ] && ok || bad "N2 no second dispatch ($(cat "$UL/dispatches"))"
read -r ST _ < "$ENTRY" 2>/dev/null
[ "${ST:-}" = pending ] && ok || bad "N2 the entry still records the pending head ($(cat "$ENTRY" 2>/dev/null || echo none))"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# --- N3. the run ended green, the lock is free: proceed --------------------------
( load n3; RUN_STATE=completed
  pq_gate example-org/demo 7 u "$HEAD" main >/dev/null
  echo "verdict=$PQ_VERDICT" ) > "$UL/n3.out" 2>&1
grep -qx 'verdict=proceed' "$UL/n3.out" && ok || bad "N3 the second run reads the green verdict and proceeds ($(cat "$UL/n3.out"); $(cat "$UL/n3/log" 2>/dev/null | tail -3))"
read -r ST _ < "$ENTRY" 2>/dev/null
[ "${ST:-}" = green ] && ok || bad "N3 the entry is recorded green ($(cat "$ENTRY" 2>/dev/null || echo none))"
[ "$(grep -c 'workflow run prequeue-gate.yml' "$UL/dispatches")" = 1 ] && ok || bad "N3 still exactly one dispatch ($(cat "$UL/dispatches"))"

# --- N5. a busy lock on the reuse merge test: hold, never a new dispatch ----------
# Main moved from OLD to MAIN. The head's verdict for OLD is green, dispatched
# past MC_PREQUEUE_FRESH_S (so the dispatch-time rule has nothing) but READ a
# moment ago (so the read-time reuse rule asks the merge test). The git lock is
# busy: the merge test cannot answer, and the gate must hold, not pay for a new
# prequeue-gate.yml run that the reuse covered (BH-7376 review, finding 2).
OLD=$(printf 'ef%038d' 1)
HEAD5=$(printf 'cd%038d' 8)
mkdir -p "$UL/state/prequeue"
printf 'green %s 555 \n' "$(( $(date +%s) - 4000 ))" > "$UL/state/prequeue/example-org_demo_8_${HEAD5}_${OLD}"
: > "$UL/dispatches"
( exec 7>>"$GITLOCK"; flock 7; touch "$UL/holding5"; sleep 60 ) &   # determinism: ok a rebase worker that holds the project git lock
HOLDER=$!
n=0; while [ ! -e "$UL/holding5" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done   # determinism: ok waits for the holder to take the lock
( load n5; RUN_STATE=none
  # GNU stat's `-c %Y` on any box (the read-time rule ages the entry by mtime).
  stat() { if [ "${1:-}" = -c ]; then perl -e 'print((stat $ARGV[0])[9], "\n")' "$3"; else command stat "$@"; fi; }
  mc_merge_tree() { echo "must not run: the lock is busy" >> "$C/merge-tree"; return 0; }
  pq_restamp() { echo none; }
  pq_gate example-org/demo 8 u "$HEAD5" main >/dev/null
  echo "verdict=$PQ_VERDICT"; echo "why=$PQ_WHY" ) > "$UL/n5.out" 2>&1
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
grep -qx 'verdict=hold' "$UL/n5.out" && ok || bad "N5 a busy git lock on the reuse merge test answers hold ($(cat "$UL/n5.out"); $(tail -3 "$UL/n5/log" 2>/dev/null))"
grep -q 'git lock' "$UL/n5.out" && ok || bad "N5 PQ_WHY names the busy git lock ($(cat "$UL/n5.out"))"
[ ! -s "$UL/dispatches" ] && ok || bad "N5 a busy lock must never dispatch a new prequeue-gate.yml run ($(cat "$UL/dispatches"))"
[ ! -s "$UL/n5/merge-tree" ] && ok || bad "N5 the merge test never ran under someone else's lock"

# --- N6. the impact-reuse merge test: a busy lock is `busy`, and the gate holds ----
( load n6; RUN_STATE=none
  stat() { if [ "${1:-}" = -c ]; then perl -e 'print((stat $ARGV[0])[9], "\n")' "$3"; else command stat "$@"; fi; }
  . "$DIR/bin/lib/mc-prequeue.d/impact-reuse.sh"   # load() stubs it; N6 needs the real one
  HARNESS_REPO=example-org/demo
  pq_knob() { case "$1" in MC_PREQUEUE_IMPACT_REUSE) echo 1 ;; MC_PREQUEUE_REUSE) echo 1 ;; MC_PREQUEUE_IMPACT_MAX_S) echo 21600 ;; *) echo 0 ;; esac; }
  pq_ir_root() { echo "$C"; }; pq_ir_map() { echo "$C/map"; }
  pq_ir_reach() { if grep -q main-only "$1"; then echo tests/a-test.sh; else echo tests/b-test.sh; fi; }
  mc_pr_files() { echo pr-only.sh; }
  mc_rest_var() { local __v="$1"; shift; local __o; __o=$("$@") || return $?; printf -v "$__v" '%s' "$__o"; }
  gh_rest() { printf '{"status":"ahead","ahead_by":2,"files":[{"filename":"main-only.sh"}]}'; }
  pq_merge_test() { printf 'the git lock for demo was busy'; return 3; }
  PRE="$UL/state/prequeue/example-org_demo_9_${HEAD}_"
  printf 'green %s 556 \n' "$(( $(date +%s) - 60 ))" > "${PRE}${OLD}"
  pq_impact_reuse example-org/demo 9 u "$HEAD" "$MAIN" "$PRE"
  echo "ir=$_pq_ir"; echo "why=$PQ_WHY" ) > "$UL/n6.out" 2>&1
grep -qx 'ir=busy' "$UL/n6.out" && ok || bad "N6 a busy lock in the impact-reuse merge test answers busy, not dispatch ($(cat "$UL/n6.out"))"
grep -q 'git lock' "$UL/n6.out" && ok || bad "N6 PQ_WHY names the busy lock ($(cat "$UL/n6.out"))"
grep -q '_pq_ir" in' "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" && grep -A4 'case "\$_pq_ir" in' "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" | grep -q 'busy) .*echo hold' \
  && ok || bad "N6 pq_resolve answers hold on _pq_ir=busy"

# --- N4. the knob ---------------------------------------------------------------
grep -q 'MC_PREQUEUE_GIT_LOCK_WAIT_S=5' "$DIR/bin/lib/mc-prequeue.sh" && ok || bad "N4 MC_PREQUEUE_GIT_LOCK_WAIT_S=5 is in PQ_KNOB_DEFAULTS"
K="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_GIT_LOCK_WAIT_S.json"
[ -r "$K" ] && [ "$(jq -r .default "$K")" = 5 ] && ok || bad "N4 the knob is registered with default 5 ($K)"

echo "merge-conductor-prequeue-nonblocking: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
