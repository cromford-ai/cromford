#!/bin/bash
# tests/mc-rebase-gates.bh-8035-test.sh — BH-8035: no conductor rebase spawn,
# and no pool rebase push, goes into a PR that another lane holds.
#
# WHAT IT PINS (project-6 #2362, 2026-10-22 18:53Z: a migration PR of the
# mac-batch apply lane got a merge of main pushed, through WAIT_CI -> REBASING
# and a pool machine):
#   a  The land arm on a WAIT_CI row (the WAIT_CI -> REBASING path): a PR the
#      migration hold gives to the apply lane gets no spawn and one LAND_SKIP.
#      An apply_lane row that cannot be read spawns nothing (LAND_DEFER); with
#      BH-8021 a failed read was `lane=""` and the rebase was spawned.
#   b  A PR Mergify waits on ("Waiting for queue conditions to match", no
#      label) gets no spawn from the land arm, the eject arm or the gate the
#      NEEDS_REBASE arm calls (mc_rebase_gate). The skip line is written once
#      per (PR, head, reason). The pool row for a Mergify repo carries
#      `mergify:true`, and `hold` when the apply lane owns the PR.
#   c  The pool rebase job (the REAL rebase_job_run on scratch git repos): the
#      PR is Mergify-held at the push -> nothing pushed, RESULT
#      `REBASE_SKIPPED mergify-queue: ...`. A row with `hold` -> nothing
#      pushed, `REBASE_SKIPPED migration-apply-lane: ...`. The hub apply
#      (mc_pool_rebase_apply) reads it as a clean no-op: rc 0, the job file of
#      that head is gone, one SKIPPED line, no rc-4 job file.
#   d  Control: a PR no lane holds still spawns, and the pool job still pushes.
#   e  The process has NO mmh_decide and NO setting_get (project-6 #2362 and
#      #2374 at 19:17Z: hold rows set, no LAND_SKIP). The gate loads
#      bin/lib/migration-hold.sh and the jobs client itself and skips. A lib
#      that cannot be loaded, or a jobs client with no settings reader, is a
#      LAND_DEFER and no spawn; a pool row then carries a hold flag.
#
# HOW. The conductor lib is sourced in a scratch harness. The arms run for
# real; their seams are stubbed: gh_rest answers check runs and the files list
# from fixture files (every other path goes to the real gh_rest and the hold
# fixture gh), setting_get reads fixture rows, the spawn and queue_put only
# write a trace. 0 network calls.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-rebase-gates.bh-8035-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-rebase-gates: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

H1=$(printf '1%.0s' $(seq 40)); H2=$(printf '2%.0s' $(seq 40))
H4=$(printf '4%.0s' $(seq 40)); MAIN2=$(printf 'b%.0s' $(seq 40))
SLUG=example-org/mgfy-os
FX="$T/fx"

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.detachedHead false

export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/wt" "$T/tmp" "$FX/set" "$FX/setfail" "$FX/checks"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/rebase-job.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
rm -f "$T/h/bin/test-select.sh"
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_gh "$T/fakebin" || exit 1
export PATH="$T/fakebin:$PATH" REBASE_WT_DIR="$T/wt"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=bin/lib/gh-rest-list.sh
. "$T/h/bin/lib/gh-rest-list.sh" || { echo "gh-rest-list did not load"; exit 1; }
H="$T/h"
# shellcheck source=bin/lib/migration-hold.sh
. "$T/h/bin/lib/migration-hold.sh" || { echo "migration-hold did not load"; exit 1; }
declare -F gh_rest >/dev/null || { echo "gh_rest did not load"; exit 1; }
eval "_real_gh_rest() $(declare -f gh_rest | tail -n +2)"

# ---- the seams --------------------------------------------------------------
# gh_rest: check runs from FX/checks/<sha8>.json (absent = none; a file `fail`
# = rc 75), the files list from FX/files-<num>.json, anything else real.
gh_rest() {
  local path="$2" page=1 a
  for a in "$@"; do case "$a" in page=*) page="${a#page=}" ;; esac; done
  case "$path" in
    */check-runs)
      echo "$path" >> "$FX/rest.log"
      local sha="${path%/check-runs}"; sha="${sha##*/}"
      [ -e "$FX/checks/fail" ] && { GH_REST_STATUS=502; return 75; }
      GH_REST_STATUS=200
      if [ -f "$FX/checks/${sha:0:8}.json" ]; then cat "$FX/checks/${sha:0:8}.json"; else echo '{"check_runs":[]}'; fi ;;
    */pulls/*/files)
      echo "$path" >> "$FX/rest.log"
      local n="${path%/files}"; n="${n##*/}"
      GH_REST_STATUS=200
      if [ -f "$FX/files-$n.json" ]; then jq -c --argjson p "$page" '.[(($p-1)*100):($p*100)]' "$FX/files-$n.json"; else echo '[]'; fi ;;
    *) _real_gh_rest "$@" ;;
  esac
}
setting_get() { [ -e "$FX/setfail/$1" ] && return 1; [ -f "$FX/set/$1" ] || return 2; cat "$FX/set/$1"; }
mc_land_needed() { return 0; }
mc_pool_rebase_enabled() { return 1; }
mc_rr_state() { echo none; }
mc_transition() { printf '%s\t%s\n' "$1" "$2" >> "$FX/transitions"; }
mc_rebase_spawn() { printf '%s\n' "$*" >> "$FX/spawns"; return 0; }
mc_rebase_job_ref() { printf 'job'; }
mc_queue_provider() { cat "$FX/provider" 2>/dev/null || printf 'mergify'; }
queue_put() { printf '%s\t%s\n' "$2" "$6" >> "$FX/queue"; printf 'queued'; }

LOG="$MC_LOG"
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
logn() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
check() {
  local sha="$1"; shift
  printf '%s\n' "$@" | jq -Rnc '[inputs | split("|") | {name: "Mergify Merge Queue", status: .[0],
    conclusion: (if .[1] == "" then null else .[1] end), output: {title: .[2]}}] | {check_runs: .}' \
    > "$FX/checks/${sha:0:8}.json"
}
files() { local num="$1" x; shift; for x in "$@"; do printf '%s\n' "$x"; done \
  | jq -Rnc '[inputs | split(":") | {filename: .[0], status: .[1]}]' > "$FX/files-$num.json"; }
lanerows() {
  printf 'prisma/sql/*.sql' > "$FX/set/mc_migration_hold.globs.mgfy"
  printf 'mac-batch' > "$FX/set/mc_migration_hold.apply_lane.mgfy"
}
reset() {
  : > "$LOG"; : > "$MC_ATTEMPTS"; rm -f "$FX/spawns" "$FX/transitions" "$FX/rest.log" "$FX/queue" "$FX/provider" \
    "$FX"/files-*.json "$FX"/checks/* "$FX"/set/* "$FX"/setfail/*
  scratch_rm "$MC_STATE_DIR/migration-hold"
  PROVIDER=""
}
# rowvars <num> <head> [labels] — pr_worker's row variables for project mgfy.
rowvars() {
  P=mgfy SLUG="$SLUG" NUM="$1" KEY="$SLUG#$1" HEAD="$2" BR="ticket/mg-$1" URL="https://github.com/$SLUG/pull/$1"
  RAWLBL="${3:-}" ACTIONS=1 MERGES=1 PROVIDER=mergify REC=- REVIEWED="$2" VERDICT=APPROVE MSTATE=BEHIND
}
# arm <num> <head> [labels] — one land_rebase_arm on a WAIT_CI row.
arm() {
  rowvars "$@"
  MC_LAND_REBASE=1 LAND_FIRE=1 LAND_SHA="$MAIN2" PBASE=main BASEREF=main STATE=WAIT_CI WHY="ci pending" land_rebase_arm
}

# ============================================================================
# a. WAIT_CI -> REBASING with a migration PR the apply lane owns
# ============================================================================
reset; lanerows
files 2 'prisma/sql/20261022161459_object_view.sql:added' 'src/a.ts:modified'
arm 2 "$H2"; RC=$?
[ "$RC" = 1 ] && ok || bad "a: the arm must answer rc 1 (nothing spawned), got $RC"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "a: a migration PR the apply lane owns must get no spawn ($(cat "$FX/spawns" 2>/dev/null))"
[ "$(logn "$SLUG#2 LAND_REBASE_SPAWNED")" = 0 ] && ok || bad "a: no LAND_REBASE_SPAWNED line may be written"
[ "$(n "$FX/transitions")" = 0 ] && ok || bad "a: no WAIT_CI -> REBASING transition ($(cat "$FX/transitions" 2>/dev/null))"
[ "$(logn "$SLUG#2 LAND_SKIP migration-apply-lane: 20261022161459_object_view on ${H2:0:8} left to the mac-batch lane")" = 1 ] && ok \
  || bad "a: exactly one LAND_SKIP line must name the apply lane: $(grep LAND "$LOG" | tail -3)"
# The apply_lane row cannot be read this tick: a deferral, never a spawn.
reset; lanerows; : > "$FX/setfail/mc_migration_hold.apply_lane.mgfy"
files 21 'prisma/sql/x.sql:added'
arm 21 "$H2"; RC=$?
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "a2: an unreadable apply_lane row must spawn nothing ($(cat "$FX/spawns" 2>/dev/null))"
[ "$(logn "$SLUG#21 LAND_DEFER migration-apply-lane: the apply_lane row could not be read")" = 1 ] && ok \
  || bad "a2: one LAND_DEFER line must say the row could not be read: $(grep LAND "$LOG" | tail -3)"
grep -q "landrebase $SLUG#21" "$MC_ATTEMPTS" && bad "a2: a deferral must write no marker" || ok

# ============================================================================
# b. A PR Mergify waits on: the land arm, the eject arm, the NEEDS_REBASE gate
# ============================================================================
reset
check "$H1" 'completed|neutral|Waiting for queue conditions to match'
arm 1 "$H1"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "b1: the land arm must not spawn for a PR Mergify waits on"
[ "$(logn "$SLUG#1 LAND_SKIP mergify-queue: Mergify queue check \"Waiting for queue conditions to match\"")" = 1 ] && ok \
  || bad "b1: one LAND_SKIP line must name the Mergify state: $(grep LAND "$LOG" | tail -3)"
# The eject arm: a head Mergify ejected for a base conflict, now waiting again.
reset
check "$H1" 'completed|neutral|Waiting for queue conditions to match'
rowvars 3 "$H1"; mc_attempt_put "ejectconflict $KEY $HEAD"
eject_rebase_arm; RC=$?
[ "$RC" = 0 ] && ok || bad "b2: the eject arm must end the tick (rc 0) for a held PR, got $RC"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "b2: the eject arm must not spawn for a PR Mergify waits on ($(cat "$FX/spawns" 2>/dev/null))"
[ "$(logn "$SLUG#3 LAND_SKIP mergify-queue:")" = 1 ] && ok || bad "b2: one LAND_SKIP line from the eject arm: $(tail -3 "$LOG")"
grep -q "ejectrebase $SLUG#3" "$MC_ATTEMPTS" && bad "b2: a held PR must not use its one eject rebase" || ok
# The NEEDS_REBASE arm's first call (eject_rebase_arm) with no eject mark: the
# gate ends the tick, so no pool, inline or detached spawn follows.
reset
check "$H1" 'completed|neutral|Waiting for queue conditions to match'
rowvars 31 "$H1"
eject_rebase_arm; RC=$?
[ "$RC" = 0 ] && ok || bad "b2b: the NEEDS_REBASE arm's first call must end the tick (rc 0) for a held PR, got $RC"
[ "$(logn "$SLUG#31 LAND_SKIP mergify-queue: Mergify queue check \"Waiting for queue conditions to match\" on ${H1:0:8} — Mergify owns this PR, no needs-rebase rebase")" = 1 ] && ok \
  || bad "b2b: one LAND_SKIP line for the NEEDS_REBASE arm: $(grep LAND "$LOG")"
reset; rowvars 32 "$H1"
eject_rebase_arm; RC=$?
[ "$RC" = 1 ] && ok || bad "b2c: a PR nobody holds and no eject mark must fall through to the NEEDS_REBASE arm (rc 1), got $RC"
# The NEEDS_REBASE arm's gate, asked on two ticks: rc 1 both times, one line.
reset
check "$H1" 'in_progress||In merge queue'
rowvars 4 "$H1"
mc_rebase_gate needs-rebase; RC1=$?
mc_rebase_gate needs-rebase; RC2=$?
{ [ "$RC1" = 1 ] && [ "$RC2" = 1 ]; } && ok || bad "b3: the gate must answer rc 1 (held) on both ticks (got $RC1 $RC2)"
[ "$(logn "$SLUG#4 LAND_SKIP mergify-queue: Mergify queue check \"In merge queue\" on ${H1:0:8} — Mergify owns this PR, no needs-rebase rebase")" = 1 ] && ok \
  || bad "b3: exactly one LAND_SKIP line over two ticks: $(grep LAND "$LOG")"
# The migration lane through the same gate.
reset; lanerows; files 5 'prisma/sql/y.sql:added'; rowvars 5 "$H1"
mc_rebase_gate needs-rebase; RC=$?
[ "$RC" = 1 ] && ok || bad "b4: the gate must answer rc 1 for an apply-lane PR (got $RC)"
[ "$(logn "$SLUG#5 LAND_SKIP migration-apply-lane: y on")" = 1 ] && ok || bad "b4: the skip line must name the lane: $(grep LAND "$LOG")"
# The pool row: `mergify:true` on a Mergify repo, `hold` for an apply-lane PR.
reset
mc_pool_rebase_enqueue "$SLUG" mgfy ticket/mg-6 "$H1" "https://github.com/$SLUG/pull/6" >/dev/null; RC=$?
[ "$RC" = 6 ] && ok || bad "b5: the enqueue must answer rc 6 (got $RC)"
[ "$(cut -f2 "$FX/queue" | jq -r '.mergify' 2>/dev/null)" = true ] && ok || bad "b5: the row meta must carry mergify:true ($(cat "$FX/queue" 2>/dev/null))"
[ "$(cut -f2 "$FX/queue" | jq -r '.hold // "none"' 2>/dev/null)" = none ] && ok || bad "b5: no hold without an apply lane"
reset; lanerows; files 7 'prisma/sql/z.sql:added'
mc_pool_rebase_enqueue "$SLUG" mgfy ticket/mg-7 "$H1" "https://github.com/$SLUG/pull/7" >/dev/null
case "$(cut -f2 "$FX/queue" | jq -r '.hold // ""' 2>/dev/null)" in
  "migration-apply-lane: z left to the mac-batch lane"*) ok ;;
  *) bad "b6: the row meta must carry the apply-lane hold ($(cat "$FX/queue" 2>/dev/null))" ;;
esac
reset; echo none > "$FX/provider"
mc_pool_rebase_enqueue "$SLUG" mgfy ticket/mg-8 "$H1" "https://github.com/$SLUG/pull/8" >/dev/null
[ "$(cut -f2 "$FX/queue" | jq -c 'del(.kind,.slug,.url,.pr,.branch,.head,.base)' 2>/dev/null)" = '{}' ] && ok \
  || bad "b7: a repo with no Mergify and no lane adds nothing to the meta ($(cat "$FX/queue" 2>/dev/null))"
# The tick's PROVIDER wins over a probe (a machine spawn probes nothing).
reset; PROVIDER=mergify; echo none > "$FX/provider"
mc_pool_rebase_enqueue "$SLUG" mgfy ticket/mg-9 "$H1" "https://github.com/$SLUG/pull/9" >/dev/null
[ "$(cut -f2 "$FX/queue" | jq -r '.mergify' 2>/dev/null)" = true ] && ok || bad "b8: the tick's PROVIDER must decide the flag ($(cat "$FX/queue" 2>/dev/null))"

# ============================================================================
# c. The pool rebase job: held at the push -> nothing pushed, a clean no-op
# ============================================================================
PSLUG=o/tproj
PURL="https://github.com/$PSLUG/pull/9"
mkorigin() { # mkorigin <name> — origin + one branch, main moved after it
  git init -q --bare "$T/$1.git"
  git clone -q "$T/$1.git" "$T/$1.seed" 2>/dev/null
  echo a > "$T/$1.seed/a.txt"
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm base1
  git -C "$T/$1.seed" push -q origin main
  git -C "$T/$1.seed" checkout -q -b ticket/bh-9
  echo d > "$T/$1.seed/d.txt"
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm branch >/dev/null
  git -C "$T/$1.seed" push -q origin ticket/bh-9
  HEAD_SHA=$(git -C "$T/$1.seed" rev-parse HEAD)
  git -C "$T/$1.seed" checkout -q main
  echo z > "$T/$1.seed/z.txt"
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm main2 >/dev/null
  git -C "$T/$1.seed" push -q origin main
  rm -rf "$T/machine"
  git clone -q "file://$T/$1.git" "$T/machine" 2>/dev/null
}
RUNJOB() { # RUNJOB [VAR=value...] — rebase ticket/bh-9 at $HEAD_SHA
  rm -f "$T/RESULT"
  ( # shellcheck source=/dev/null
    . "$T/h/bin/lib/rebase-job.sh"
    env_args=("$@")
    for kv in ${env_args[@]+"${env_args[@]}"}; do export "${kv?}"; done
    REBASE_JOB_URL="$PURL" TMPDIR="$T/tmp" rebase_job_run "$T/machine" "$PSLUG" ticket/bh-9 "$HEAD_SHA" main "$T/RESULT" "$T/h" ) >/dev/null 2>&1
}
R1() { head -1 "$T/RESULT" 2>/dev/null; }
TIP() { git -C "$1" ls-remote "$2" refs/heads/ticket/bh-9 2>/dev/null | cut -f1; }

reset; mkorigin c1
check "$HEAD_SHA" 'completed|neutral|Waiting for queue conditions to match'
mc_pool_rebase_enqueue "$PSLUG" tproj ticket/bh-9 "$HEAD_SHA" "$PURL" >/dev/null
JF=$(mc_rb_file "$PSLUG" 9 "$HEAD_SHA")
[ "$(mc_rr_field "$JF" status)" = pool ] && ok || bad "c: fixture: the enqueue must write the pool job file"
RUNJOB REBASE_JOB_MERGIFY=true; RC=$?
[ "$RC" = 1 ] && ok || bad "c1: a held job must answer rc 1 (got $RC, RESULT '$(R1)')"
case "$(R1)" in
  "REBASE_SKIPPED mergify-queue: Mergify queue check \"Waiting for queue conditions to match\" on ${HEAD_SHA:0:8}") ok ;;
  *) bad "c1: the RESULT must be REBASE_SKIPPED mergify-queue (got '$(R1)')" ;;
esac
[ "$(TIP "$T/machine" "$T/c1.git")" = "$HEAD_SHA" ] && ok || bad "c1: a PR Mergify holds at the push must not be pushed"
grep -q "commits/$HEAD_SHA/check-runs" "$FX/rest.log" 2>/dev/null && ok || bad "c1: the job must read the check runs of the old head at the push"
"$DIR/bin/result-prefix-ok.sh" "$(R1)" && ok || bad "c1: REBASE_SKIPPED must pass the pool's RESULT gate"
# The hub apply: a clean no-op.
cp "$T/RESULT" "$T/RESULT.c1"
mc_pool_rebase_apply tproj "RB-9-${HEAD_SHA:0:8}" "$T/RESULT.c1"; RC=$?
[ "$RC" = 0 ] && ok || bad "c3: the hub apply must answer rc 0 for REBASE_SKIPPED (got $RC)"
[ -e "$JF" ] && bad "c3: the apply must remove the job file of the skipped head ($(cat "$JF"))" || ok
[ "$(mc_rb_state "$JF")" = none ] && ok || bad "c3: no tick may read a result for the skipped head (state $(mc_rb_state "$JF"))"
[ "$(logn "tproj RB-9-${HEAD_SHA:0:8} pool rebase applied: SKIPPED")" = 1 ] && ok || bad "c3: one SKIPPED line: $(tail -2 "$LOG")"
grep -q "SETUP_FAILED" "$LOG" && bad "c3: a skip is not a setup failure: $(grep SETUP_FAILED "$LOG")" || ok
# The apply-lane hold from the row meta: no git, nothing pushed.
reset; mkorigin c2
RUNJOB "REBASE_JOB_HOLD=migration-apply-lane: x left to the mac-batch lane"; RC=$?
case "$(R1)" in
  "REBASE_SKIPPED migration-apply-lane: x left to the mac-batch lane") ok ;;
  *) bad "c2: the RESULT must be REBASE_SKIPPED migration-apply-lane (got '$(R1)')" ;;
esac
[ "$(TIP "$T/machine" "$T/c2.git")" = "$HEAD_SHA" ] && ok || bad "c2: an apply-lane PR must not be pushed"

# ============================================================================
# d. Control: no lane holds it -> spawn, and the pool job pushes
# ============================================================================
reset; lanerows
files 40 'src/a.ts:added' 'prisma/sql/old.sql:modified'
check "$H4" 'completed|neutral|Merge queue is ready'
arm 40 "$H4"; RC=$?
[ "$RC" = 0 ] && ok || bad "d1: the land arm must spawn (rc 0), got $RC: $(grep LAND "$LOG" | tail -3)"
[ "$(n "$FX/spawns")" = 1 ] && ok || bad "d1: exactly one spawn (got $(n "$FX/spawns"))"
[ "$(logn "$SLUG#40 LAND_SKIP")" = 0 ] && ok || bad "d1: no skip line"
reset; rowvars 41 "$H4"
mc_rebase_gate needs-rebase; RC=$?
[ "$RC" = 0 ] && ok || bad "d2: the gate must answer rc 0 for a PR nobody holds (got $RC)"
reset; mkorigin d3
check "$HEAD_SHA" 'completed|neutral|Merge queue is ready'
RUNJOB REBASE_JOB_MERGIFY=true; RC=$?
case "$(R1)" in REBASED\ *) ok ;; *) bad "d3: a PR Mergify does not hold must be rebased (got '$(R1)')" ;; esac
NEW=$(TIP "$T/machine" "$T/d3.git")
{ [ -n "$NEW" ] && [ "$NEW" != "$HEAD_SHA" ] && [ "$(R1)" = "REBASED $NEW" ]; } && ok \
  || bad "d3: the job must push the merged head (origin $NEW, RESULT '$(R1)')"

# ============================================================================
# e. No mmh_decide and no setting_get in the process: the gate loads them
# ============================================================================
# h2 is a second harness root: the real migration-hold lib (closure install)
# and a FIXTURE bin/jobs-client.sh whose setting_get reads the fixture rows.
HB="$T/h2"; mkdir -p "$HB/bin"
scratch_install_closure bin/lib/migration-hold.sh "$HB" >/dev/null || { echo "closure install failed"; exit 1; }
jcfix() { # jcfix [none] — the FIXTURE jobs client in h2
  if [ "${1:-}" = none ]; then printf '# FIXTURE jobs client (BH-8035) with no setting_get\n' > "$HB/bin/jobs-client.sh"; return; fi
  printf '# FIXTURE jobs client (BH-8035): setting_get only, from the fixture rows.\n' > "$HB/bin/jobs-client.sh"
  printf 'setting_get() { [ -e "%s/setfail/$1" ] && return 1; [ -f "%s/set/$1" ] || return 2; cat "%s/set/$1"; }\n' \
    "$FX" "$FX" "$FX" >> "$HB/bin/jobs-client.sh"
}
jcfix
# bare <fn>... — run "$@" with the migration hold lib and setting_get undefined.
bare() {
  ( unset -f setting_get mmh_decide mmh_globs mmh_files mmh_probe mmh_cache_get mmh_cache_put \
      _mmh_ensure_client _mmh_root 2>/dev/null
    unset H
    MC_H="$HB" HARNESS="$HB" "$@" )
}
reset; lanerows; files 50 'prisma/sql/20261022161459_object_view.sql:added'
bare arm 50 "$H2"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "e1: with no mmh_decide/setting_get predefined, the gate must load them and spawn nothing ($(cat "$FX/spawns" 2>/dev/null))"
[ "$(logn "$SLUG#50 LAND_SKIP migration-apply-lane: 20261022161459_object_view on")" = 1 ] && ok \
  || bad "e1: one LAND_SKIP line from the self-loaded gate: $(grep LAND "$LOG" | tail -3)"
# The lib cannot be loaded: a deferral.
reset; lanerows; files 51 'prisma/sql/x.sql:added'; mv "$HB/bin/lib/migration-hold.sh" "$T/mh.aside"
bare arm 51 "$H2"
mv "$T/mh.aside" "$HB/bin/lib/migration-hold.sh"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "e2: a migration hold lib that cannot be loaded must spawn nothing"
[ "$(logn "$SLUG#51 LAND_DEFER migration-apply-lane: the migration hold lib could not be loaded")" = 1 ] && ok \
  || bad "e2: one LAND_DEFER line must say the lib could not be loaded: $(grep LAND "$LOG" | tail -3)"
# A jobs client with no settings reader: a deferral.
reset; lanerows; files 52 'prisma/sql/x.sql:added'; jcfix none
bare arm 52 "$H2"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "e3: no settings reader must spawn nothing"
[ "$(logn "$SLUG#52 LAND_DEFER migration-apply-lane:")" = 1 ] && ok || bad "e3: one LAND_DEFER line: $(grep LAND "$LOG" | tail -3)"
# The pool row: an unreadable hold is a hold flag, never no flag.
bare mc_pool_rebase_enqueue "$SLUG" mgfy ticket/mg-53 "$H2" "https://github.com/$SLUG/pull/53" >/dev/null
case "$(cut -f2 "$FX/queue" | jq -r '.hold // ""' 2>/dev/null)" in
  "migration-apply-lane: unreadable: "*) ok ;;
  *) bad "e4: an unreadable hold must put a hold flag on the pool row ($(cat "$FX/queue" 2>/dev/null))" ;;
esac
jcfix
# An unreadable globs row: not gated this tick, said in one line (mc_mig_hold's rule).
reset; lanerows; : > "$FX/setfail/mc_migration_hold.globs.mgfy"; files 55 'prisma/sql/x.sql:added'
bare arm 55 "$H4"
[ "$(n "$FX/spawns")" = 1 ] && ok || bad "e6: an unreadable globs row is not gated this tick ($(grep LAND "$LOG" | tail -3))"
[ "$(logn "migration hold: mgfy globs row unreadable this tick")" -ge 1 ] && ok || bad "e6: the unreadable globs row must be logged: $(tail -3 "$LOG")"
# Control: the self-loaded gate with no globs row lets the rebase go.
reset; files 54 'prisma/sql/x.sql:added'
bare arm 54 "$H4"
[ "$(n "$FX/spawns")" = 1 ] && ok || bad "e5: a project with no globs row must still spawn ($(grep LAND "$LOG" | tail -3))"

echo "mc-rebase-gates.bh-8035: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
