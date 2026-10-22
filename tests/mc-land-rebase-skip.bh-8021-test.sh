#!/bin/bash
# tests/mc-land-rebase-skip.bh-8021-test.sh — BH-8021: the conductor's land
# rebase does not push into a PR that another lane holds.
#
# WHAT IT PINS (project-6, 2026-10-22):
#   1  #2300: a `@mergifyio queue` request waits for its queue conditions. The
#      PR has no label, only Mergify's check "Waiting for queue conditions to
#      match". A landing must not spawn a rebase (no LAND_REBASE_SPAWNED), and
#      one LAND_SKIP line names the reason.
#   2  #2305: a PR adds prisma/sql/x.sql, and the migration hold rows give it
#      to the apply lane mac-batch. No rebase, and the skip line names the lane.
#   3  #2309: a rebase result reaches the push after the PR entered the
#      Mergify queue. The result is dropped: nothing pushed, rc 3, one line.
#   4  A Mergify repo PR with only the idle check ("Merge queue is ready") and
#      a dequeued check, on a project with the hold rows but no migration file,
#      still rebases. The check runs and the files list are read once each,
#      which proves the gates were asked and said no.
#
# HOW. The lib is sourced in a scratch harness. land_rebase_arm and mc_rebase
# run for real; their seams are stubbed: gh_rest answers check runs and the
# files list from fixture files, setting_get reads fixture rows, git is a fake
# on PATH, the spawn and the push only write a trace. 0 network calls.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-land-rebase-skip.bh-8021-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-land-rebase-skip: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=$(printf '1%.0s' $(seq 40)); H2=$(printf '2%.0s' $(seq 40))
H3=$(printf '3%.0s' $(seq 40)); H4=$(printf '4%.0s' $(seq 40))
NEW=$(printf '9%.0s' $(seq 40)); MAIN2=$(printf 'b%.0s' $(seq 40))
SLUG=example-org/mgfy-os
FX="$T/fx"

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos" "$FX/set" "$FX/checks"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }

# The fake git: clone makes the dir, rev-parse answers the PR head first and the
# merged head after the merge, every other verb succeeds. No push verb is
# reached: the push is the stubbed hold_push below.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
printf '%s\n' "\$A" >> "$T/git-argv.txt"
case "\$A" in
  *" clone "*|clone*) for d; do :; done; mkdir -p "\$d/.git"; exit 0 ;;
  *rev-parse*) if [ -f "$T/merged" ]; then printf '%s\n' "$NEW"; else cat "$T/ctl-head"; fi; exit 0 ;;
  *" merge -q "*) touch "$T/merged"; exit 0 ;;
  *" log "*) exit 0 ;;
  *" diff "*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
export PATH="$T/fakebin:$PATH"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=bin/lib/gh-rest-list.sh
. "$T/h/bin/lib/gh-rest-list.sh" || { echo "gh-rest-list did not load"; exit 1; }
H="$T/h"
# shellcheck source=bin/lib/migration-hold.sh
. "$T/h/bin/lib/migration-hold.sh" || { echo "migration-hold did not load"; exit 1; }

# ---- the seams --------------------------------------------------------------
# gh_rest: check runs from FX/checks/<sha8>.json (absent = no check runs; a
# file `fail` = rc 75), the files list from FX/files-<num>.json.
gh_rest() {
  local path="$2" page=1 a
  for a in "$@"; do case "$a" in page=*) page="${a#page=}" ;; esac; done
  echo "$path" >> "$FX/rest.log"
  case "$path" in
    */check-runs)
      local sha="${path%/check-runs}"; sha="${sha##*/}"
      [ -e "$FX/checks/fail" ] && { GH_REST_STATUS=502; return 75; }
      GH_REST_STATUS=200
      if [ -f "$FX/checks/${sha:0:8}.json" ]; then cat "$FX/checks/${sha:0:8}.json"; else echo '{"check_runs":[]}'; fi ;;
    */pulls/*/files)
      local n="${path%/files}"; n="${n##*/}"
      GH_REST_STATUS=200
      if [ -f "$FX/files-$n.json" ]; then jq -c --argjson p "$page" '.[(($p-1)*100):($p*100)]' "$FX/files-$n.json"; else echo '[]'; fi ;;
    *) GH_REST_STATUS=404; return 1 ;;
  esac
}
setting_get() { [ -f "$FX/set/$1" ] || return 2; cat "$FX/set/$1"; }
mc_land_needed() { return 0; }
mc_pool_rebase_enabled() { return 1; }
mc_rr_state() { echo none; }
mc_transition() { printf '%s\t%s\n' "$1" "$2" >> "$FX/transitions"; }
mc_rebase_spawn() { printf '%s\n' "$*" >> "$FX/spawns"; return 0; }
mc_rebase_job_ref() { printf 'job'; }
mc_queue_provider() { printf 'mergify'; }
# mc_rebase's own seams (case 3).
mc_tmp_room() { return 0; }
mc_git_auth() { MC_REMOTE="https://example.test/$1.git"; return 0; }
mc_git_auth_clear() { :; }
mc_hold_push_load() { return 0; }
hold_push_verdict() { return 0; }
hold_push() { printf '%s\n' "$*" >> "$FX/pushes"; return 0; }
mc_resolve_vmap_clean_merge() { return 0; }
mc_regen_generated() { :; }
mc_rebase_cleanup() { :; }
mc_record_for() { return 1; }
job_verdict_rebind() { return 0; }

LOG="$MC_LOG"
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
logn() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
# check <sha> <status|conclusion|title>... — the Mergify check runs on a head.
check() {
  local sha="$1"; shift
  printf '%s\n' "$@" | jq -Rnc '[inputs | split("|") | {name: "Mergify Merge Queue", status: .[0],
    conclusion: (if .[1] == "" then null else .[1] end), output: {title: .[2]}}] | {check_runs: .}' \
    > "$FX/checks/${sha:0:8}.json"
}
files() { local num="$1" x; shift; for x in "$@"; do printf '%s\n' "$x"; done \
  | jq -Rnc '[inputs | split(":") | {filename: .[0], status: .[1]}]' > "$FX/files-$num.json"; }
reset() {
  : > "$LOG"; : > "$MC_ATTEMPTS"; rm -f "$FX/spawns" "$FX/pushes" "$FX/transitions" "$FX/rest.log" \
    "$FX"/files-*.json "$FX"/checks/* "$FX"/set/* "$T/merged"
  scratch_rm "$MC_STATE_DIR/migration-hold"
}
# arm <num> <head> [labels] — one land_rebase_arm on a WAIT_CI row of project mgfy.
arm() {
  MC_LAND_REBASE=1 LAND_FIRE=1 LAND_SHA="$MAIN2" PBASE=main BASEREF=main STATE=WAIT_CI WHY="ci pending" \
  P=mgfy SLUG="$SLUG" NUM="$1" KEY="$SLUG#$1" HEAD="$2" BR="ticket/mg-$1" URL="https://github.com/$SLUG/pull/$1" \
  RAWLBL="${3:-}" ACTIONS=1 PROVIDER=mergify REC=- REVIEWED="$2" VERDICT=APPROVE MSTATE=BEHIND land_rebase_arm
}

# ============================================================================
# 1. A Mergify "waiting" queue state + behind main -> no LAND_REBASE_SPAWNED
# ============================================================================
reset
check "$H1" 'completed|neutral|Waiting for queue conditions to match'
arm 1 "$H1"; RC=$?
[ "$RC" = 1 ] && ok || bad "1: the arm must answer rc 1 (nothing spawned), got $RC"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "1: a PR Mergify waits on must get no rebase spawn ($(cat "$FX/spawns" 2>/dev/null))"
[ "$(logn "$SLUG#1 LAND_REBASE_SPAWNED")" = 0 ] && ok || bad "1: no LAND_REBASE_SPAWNED line may be written"
[ "$(logn "$SLUG#1 LAND_SKIP mergify-queue: Mergify queue check \"Waiting for queue conditions to match\"")" = 1 ] && ok \
  || bad "1: exactly one LAND_SKIP line must name the Mergify waiting state: $(grep LAND "$LOG" | tail -3)"
grep -qxF "landrebase $SLUG#1 $MAIN2" "$MC_ATTEMPTS" && ok || bad "1: the skip is an answer for this sha and is marked"
# The same with Mergify's own label and no check run: label wins, no read.
reset
arm 11 "$H1" 'queued'
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "1b: a PR with Mergify's queued label must get no rebase spawn"
[ "$(logn "$SLUG#11 LAND_SKIP mergify-queue: Mergify label")" = 1 ] && ok || bad "1b: the skip line must name the label"
# A check read that fails is a deferral: no spawn, no mark.
reset
touch "$FX/checks/fail"
arm 12 "$H1"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "1c: an unreadable check list must spawn nothing"
[ "$(logn "$SLUG#12 LAND_DEFER mergify-queue")" = 1 ] && ok || bad "1c: an unreadable check list must log one LAND_DEFER line"
grep -q "landrebase $SLUG#12" "$MC_ATTEMPTS" && bad "1c: a deferral must write no marker" || ok

# ============================================================================
# 2. A PR that adds prisma/sql/x.sql, hold rows set -> no rebase, lane named
# ============================================================================
reset
printf 'prisma/sql/*.sql' > "$FX/set/mc_migration_hold.globs.mgfy"
printf 'mac-batch' > "$FX/set/mc_migration_hold.apply_lane.mgfy"
files 2 'prisma/sql/x.sql:added' 'src/a.ts:modified'
arm 2 "$H2"
[ "$(n "$FX/spawns")" = 0 ] && ok || bad "2: a migration PR the apply lane owns must get no rebase spawn ($(cat "$FX/spawns" 2>/dev/null))"
[ "$(logn "$SLUG#2 LAND_REBASE_SPAWNED")" = 0 ] && ok || bad "2: no LAND_REBASE_SPAWNED line may be written"
[ "$(logn "$SLUG#2 LAND_SKIP migration-apply-lane: x on ${H2:0:8} left to the mac-batch lane")" = 1 ] && ok \
  || bad "2: exactly one LAND_SKIP line must name the apply lane: $(grep LAND "$LOG" | tail -3)"
grep -qxF "landrebase $SLUG#2 $MAIN2" "$MC_ATTEMPTS" && ok || bad "2: the skip is marked for this sha"

# ============================================================================
# 3. A rebase result applied after the PR became queued -> not pushed
# ============================================================================
reset
echo "$H3" > "$T/ctl-head"; : > "$T/git-argv.txt"
check "$H3" 'in_progress||In merge queue'
OUT=$(MC_REPOS="$T/repos" mc_rebase "$SLUG" mgfy ticket/mg-3 "$H3" "https://github.com/$SLUG/pull/3"); RC=$?
grep -q -- ' merge -q --no-edit ' "$T/git-argv.txt" && ok || bad "3: fixture: the rebase must reach its merge (git: $(tr '\n' ';' < "$T/git-argv.txt"))"
[ "$(n "$FX/pushes")" = 0 ] && ok || bad "3: a PR in the Mergify queue at the push must not be pushed ($(cat "$FX/pushes" 2>/dev/null))"
[ "$RC" = 3 ] && ok || bad "3: the dropped result must answer rc 3 (come back next tick), got $RC"
[ -z "$OUT" ] && ok || bad "3: a dropped result must print no new head (got '$OUT')"
[ "$(logn "pull/3 rebase: SKIP_PUSH mergify-queue: Mergify queue check \"In merge queue\"")" = 1 ] && ok \
  || bad "3: exactly one SKIP_PUSH line must name the reason: $(tail -3 "$LOG")"
# Control: the same rebase with no Mergify hold pushes.
reset
echo "$H3" > "$T/ctl-head"
OUT=$(MC_REPOS="$T/repos" mc_rebase "$SLUG" mgfy ticket/mg-3 "$H3" "https://github.com/$SLUG/pull/3"); RC=$?
[ "$(n "$FX/pushes")" = 1 ] && ok || bad "3b: a PR Mergify does not hold must be pushed once (got $(n "$FX/pushes"))"
{ [ "$RC" = 0 ] && [ "$OUT" = "$NEW" ]; } && ok || bad "3b: the push must answer rc 0 and the new head (rc $RC out '$OUT')"

# ============================================================================
# 4. A PR with none of these still rebases, and the gates were asked
# ============================================================================
reset
printf 'prisma/sql/*.sql' > "$FX/set/mc_migration_hold.globs.mgfy"
printf 'mac-batch' > "$FX/set/mc_migration_hold.apply_lane.mgfy"
files 4 'src/a.ts:added' 'prisma/sql/old.sql:modified'
check "$H4" 'completed|neutral|Merge queue is ready' 'completed|failure|Dequeued: checks failed'
arm 4 "$H4"; RC=$?
[ "$RC" = 0 ] && ok || bad "4: the arm must spawn (rc 0), got $RC: $(grep LAND "$LOG" | tail -3)"
[ "$(n "$FX/spawns")" = 1 ] && ok || bad "4: exactly one rebase spawn (got $(n "$FX/spawns"))"
[ "$(logn "$SLUG#4 LAND_REBASE_SPAWNED main ${MAIN2:0:8}")" = 1 ] && ok || bad "4: the spawn must be logged"
[ "$(logn "$SLUG#4 LAND_SKIP")" = 0 ] && ok || bad "4: no skip line"
[ "$(grep -c "commits/$H4/check-runs" "$FX/rest.log" 2>/dev/null)" = 1 ] && ok \
  || bad "4: the Mergify check runs must be read once (got $(grep -c check-runs "$FX/rest.log" 2>/dev/null))"
[ "$(grep -c "pulls/4/files" "$FX/rest.log" 2>/dev/null)" = 1 ] && ok \
  || bad "4: the files list must be read once for the apply-lane gate (got $(grep -c files "$FX/rest.log" 2>/dev/null))"
# No apply-lane row: no files read at all (the gate costs nothing off the lane).
reset
arm 41 "$H4"
[ "$(n "$FX/spawns")" = 1 ] && ok || bad "4b: a PR on a project with no apply lane must still spawn"
grep -q "/files" "$FX/rest.log" 2>/dev/null && bad "4b: no apply-lane row must cost no files read" || ok

echo "mc-land-rebase-skip.bh-8021: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
