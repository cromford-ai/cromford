#!/bin/bash
# tests/mc-dequeued-restamp.bh-9243-test.sh — BH-9243: two merge-conductor
# defects that held a PR open for days after a Mergify dequeue.
#
# WHAT IT PINS:
#   D1-D6  mc_mergify_holds: Mergify's dequeued-head check title "Another queue
#          action already ran", and its `dequeued` label, are not a hold. The
#          near misses ("In merge queue", "Waiting for queue conditions to
#          match", a queued/checking label, `predequeued`, a mixed check list)
#          still hold, and an unreadable check list is still rc 2.
#   D7     mc_rebase on a dequeued head pushes once (no SKIP_PUSH line). The
#          "In merge queue" control still drops the result (rc 3, no push).
#   D8     mc_rebase_gate with RAWLBL `merge-queue,dequeued` lets the rebase run.
#   S0     pq_gate marks a deferred-land answer PQ_RESTAMP_LAND=1, and a
#          conflict `rebase` answer PQ_RESTAMP_LAND=0.
#   S1-S8  mc_pq_restamp_rebase (bin/merge-conductor.d/bh-9243-restamp-rebase.sh):
#          a stale schema stamp gets its rebase in the same tick, once per head;
#          a refusal holds the row READY, never NEEDS_REBASE; a conflict, the
#          kill switch and pool mode keep today's NEEDS_REBASE line.
#   B1,B5  bin/merge-conductor.sh driven WHOLE: a READY row whose prequeue answer
#          is a restamp `rebase` spawns its rebase in the same tick and never
#          goes NEEDS_REBASE; a conflict `rebase` still goes NEEDS_REBASE.
#
# HOW. Part B runs the conductor whole in a scratch tree (the BH-5572 harness:
# real local git origin, stub gh and curl, a fixture fragment that answers
# pq_gate and records the spawn). Part A sources the conductor lib in a scratch
# harness; gh_rest answers check runs from fixture files, git is a fake on PATH,
# the spawn and the push only write a trace. 0 network calls.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-dequeued-restamp.bh-9243-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-dequeued-restamp: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v git   >/dev/null || { echo "git missing — skipping";   exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
FRAG="$DIR/bin/merge-conductor.d/bh-9243-restamp-rebase.sh"
[ -f "$DIR/bin/merge-conductor.sh" ] && [ -f "$DIR/bin/lib/mc/queue.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.sh" ] || exit 1   # impact: bin/merge-conductor.sh bin/lib/mc/queue.sh bin/lib/mc-prequeue.sh bin/merge-conductor.d/bh-9243-restamp-rebase.sh

# ============================================================================
# PART B. bin/merge-conductor.sh whole (runs first: it needs the real git)
# ============================================================================
part_b() {
  # shellcheck source=tests/lib/gh-list-bridge.sh
  . "$DIR/tests/lib/gh-list-bridge.sh" || { bad "B0 gh-list-bridge did not load"; return; }
  # shellcheck source=tests/lib/verdict-fixture.sh
  . "$DIR/tests/lib/verdict-fixture.sh" || { bad "B0 verdict-fixture did not load"; return; }
  vpf_export || { bad "B0 vpf_export failed"; return; }
  local B="$T/b" SLUG=example-org/demo-os NUM=41 S MB HOK MCD ROWS MCLOG REC MGFY_YML
  local U="https://github.com/$SLUG/pull"
  export GIT_CONFIG_GLOBAL="$B/gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$B"
  git config --global user.email t@example.com
  git config --global user.name  t
  git config --global init.defaultBranch main
  git config --global commit.gpgsign false
  git config --global protocol.file.allow always
  git config --global "url.$B/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
  git config --global "url.$B/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
  S="$B/seed"; git init -q --bare "$B/origin.git"; git init -q "$S"
  printf 'one\ntwo\n' > "$S/x.txt"; git -C "$S" add -A; git -C "$S" commit -qm A
  local MA; MA=$(git -C "$S" rev-parse HEAD)
  echo y > "$S/y.txt"; git -C "$S" add -A; git -C "$S" commit -qm hok; HOK=$(git -C "$S" rev-parse HEAD)
  git -C "$S" reset -q --hard "$MA"; printf 'one\nmain\n' > "$S/x.txt"; git -C "$S" commit -qam B; MB=$(git -C "$S" rev-parse HEAD)
  git -C "$S" push -q "$B/origin.git" "$MB:refs/heads/main" "$HOK:refs/pull/41/head" || { bad "B0 seed push failed"; return; }

  export HARNESS="$B/h"
  mkdir -p "$B/h/bin/lib" "$B/h/logs" "$B/h/state" "$B/h/flags" "$B/h/locks" "$B/h/builds" \
           "$B/h/env" "$B/h/tmp" "$B/fakebin" "$B/repos"
  cat > "$B/h/bin/lib/ticket-ownership.sh" <<'EOF'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lead_merge_hold() { return 1; }
EOF
  cat > "$B/h/bin/lib/block-gate.sh" <<'EOF'
bg_enforce() { return 0; }
bg_scan_read() { return 0; }
bg_scan() { return 0; }
bg_why() { :; }
bg_reason() { :; }
bg_refuse() { return 0; }
EOF
  : > "$B/h/bin/lib/pr-snapshot.sh"
  scratch_install_closure bin/merge-conductor.sh "$B/h" >/dev/null || { bad "B0 closure install failed"; return; }
  scratch_install_closure bin/jobs-client.sh "$B/h" >/dev/null || { bad "B0 closure install failed"; return; }
  scratch_rm "$B/h/bin/lib/gh-limit-logger.sh"
  mkdir -p "$B/h/bin/merge-conductor.d"
  # The fragment under test rides into the scratch tree from the checkout (the
  # closure installer does not follow the driver's directory glob).
  # The other fragments stay out, as in the BH-5572 harness: the READY arm
  # under test is the driver's own.
  [ -f "$FRAG" ] && cp "$FRAG" "$B/h/bin/merge-conductor.d/"
  # THE FIXTURE FRAGMENT. Sorted after every bh-* fragment, so it wins: pq_gate
  # answers `rebase` with the restamp mark from $B/pqland, and the spawn only
  # writes a trace.
  cat > "$B/h/bin/merge-conductor.d/zz-9243-fixture.sh" <<EOF
pq_gate() {
  PQ_VERDICT=rebase; PQ_MAIN="$MB"; PQ_SUITES=""; PQ_PATH=""
  PQ_RESTAMP_LAND=\$(cat "$B/pqland")
  PQ_WHY="fixture: stale schema stamp (land=\$PQ_RESTAMP_LAND)"
  echo rebase
}
mc_rebase_spawn() { printf '%s\n' "\$*" >> "$B/spawns"; return 0; }
mc_rebase_job_ref() { printf 'fixture-job'; }
EOF
  cp "$DIR/bin/fleet-conf.sh" "$B/h/bin/" || { bad "B0 fleet-conf copy"; return; }
  cp "$DIR/tests/lib/rest-emit.sh" "$B/fakebin/restpr" && chmod +x "$B/fakebin/restpr" || { bad "B0 restpr"; return; }
  local s
  for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$B/h/bin/$s.sh"; chmod +x "$B/h/bin/$s.sh"; done
  printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/h/logs/ALERTS.log"\n' "$B" > "$B/h/bin/lane-alert.sh"; chmod +x "$B/h/bin/lane-alert.sh"
  printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$B/h/fleet.conf"; export FLEET_CONF="$B/h/fleet.conf"
  : > "$B/h/env/global.env"
  REC="$B/h/builds/pool-demo-BH-20-202610050001"; mkdir -p "$REC"
  MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
  MCD="$B/h/state/merge-conductor"; ROWS="$MCD/pr-state.tsv"; MCLOG="$B/h/logs/merge-conductor.log"
  cat > "$B/fakebin/gh" <<EOF
#!/bin/bash
N=$NUM; HD=$HOK; MN=$MB
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*) restpr --raw 200 "{\"sha\":\"\$MN\"}" ;;
  *"api -i -X GET repos/$SLUG/compare/"*) restpr --raw 200 '{"status":"ahead","ahead_by":1}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$B/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$B/c-enq.txt" ;; esac ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$B/c-enq.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*) restpr OPEN "\$HD" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*)
    printf '[{"number":%s,"url":"$U/%s","headRefOid":"%s","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]\n' "\$N" "\$N" "\$HD" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
  chmod +x "$B/fakebin/gh"
  cat > "$B/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
  chmod +x "$B/fakebin/curl"
  breset() {
    rm -f "$B/tick.err" "$B/spawns"; : > "$B/c-enq.txt"
    scratch_rm "$MCD"; scratch_rm "$B/h/state/tier2-autoenqueue.txt"; scratch_rm "$B/h/tmp/conductor"
    rm -f "$B/h/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
    echo "$1" > "$B/pqland"
    echo "PR_CREATED $U/$NUM" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
    echo "$HOK" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
    touch "$B/h/flags/merge-conductor-actions" "$B/h/flags/merge-conductor-merge"
  }
  btick() {
    ( cd "$B" && env PATH="$B/fakebin:$PATH" HARNESS="$B/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
      MC_REPOS="$B/repos" MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
      MC_MAIN_RED_DETECT=0 MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 "$@" bash "$B/h/bin/merge-conductor.sh" >/dev/null 2>"$B/tick.err" ) \
      || { echo "tick rc=$? stderr:"; tail -5 "$B/tick.err"; }
  }
  local K="$SLUG#$NUM"
  bstate() { awk -F'\t' -v k="$K" '$1==k {print $2}' "$ROWS"; }
  bspawns() { if [ -f "$B/spawns" ]; then grep -c . "$B/spawns"; else echo 0; fi; }
  bneeds() { grep -c "$K.*NEEDS_REBASE\|NEEDS_REBASE.*$K" "$MCLOG" 2>/dev/null || true; }

  # B1. A restamp `rebase` answer: the spawn happens in the SAME tick, the row
  #     goes REBASING, and there is no NEEDS_REBASE transition.
  breset 1; btick
  [ "$(bspawns)" = 1 ] && ok || bad "B1: the restamp rebase must spawn in the same tick (spawns $(bspawns); state '$(bstate)'; log: $(grep -F "$K" "$MCLOG" 2>/dev/null | tail -4))"
  [ "$(bstate)" = REBASING ] && ok || bad "B1: the row must go REBASING, got '$(bstate)'"
  [ "$(bneeds)" = 0 ] && ok || bad "B1: no NEEDS_REBASE transition (log: $(grep NEEDS_REBASE "$MCLOG" 2>/dev/null | tail -3))"
  [ "$(grep -c "PQ_RESTAMP_REBASE_SPAWNED $K $HOK" "$MCLOG" 2>/dev/null)" = 1 ] && ok || bad "B1: one PQ_RESTAMP_REBASE_SPAWNED line"
  # Tick 2 on the same head (the spawn stub wrote no job, so nothing moved):
  # no second spawn and still no NEEDS_REBASE.
  btick
  [ "$(bspawns)" = 1 ] && ok || bad "B1 tick 2: no second spawn for the same head (spawns $(bspawns))"
  [ "$(bstate)" != NEEDS_REBASE ] && ok || bad "B1 tick 2: the row must not flip to NEEDS_REBASE without a push"
  [ "$(bneeds)" = 0 ] && ok || bad "B1 tick 2: no NEEDS_REBASE line (log: $(grep NEEDS_REBASE "$MCLOG" 2>/dev/null | tail -3))"

  # B5. A conflict `rebase` answer (PQ_RESTAMP_LAND=0): NEEDS_REBASE as today.
  breset 0; btick
  [ "$(bstate)" = NEEDS_REBASE ] && ok || bad "B5: a conflict rebase must go NEEDS_REBASE, got '$(bstate)' (log: $(grep -F "$K" "$MCLOG" 2>/dev/null | tail -4))"
  [ "$(bspawns)" = 0 ] && ok || bad "B5: no prequeue spawn for a conflict (spawns $(bspawns))"
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM HARNESS FLEET_CONF
}
part_b

# ============================================================================
# PART A. The functions, in a scratch harness with a fake git
# ============================================================================
H1=$(printf '1%.0s' $(seq 40)); H2=$(printf '2%.0s' $(seq 40))
NEW=$(printf '9%.0s' $(seq 40)); MAIN2=$(printf 'b%.0s' $(seq 40))
SLUG=example-org/mgfy-os
A="$T/a"; FX="$A/fx"
export HARNESS="$A/h"
mkdir -p "$A/h/bin/lib/mc" "$A/h/logs" "$A/h/state" "$A/h/env" "$A/h/tmp" "$A/fakebin" "$A/repos" "$FX/set" "$FX/checks"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$A/h" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/migration-hold.sh "$A/h" >/dev/null || { echo "closure install failed"; exit 1; }
cat > "$A/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
case "\$A" in
  *" clone "*|clone*) for d; do :; done; mkdir -p "\$d/.git"; exit 0 ;;
  *rev-parse*) if [ -f "$A/merged" ]; then printf '%s\n' "$NEW"; else cat "$A/ctl-head"; fi; exit 0 ;;
  *" merge -q "*) touch "$A/merged"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$A/fakebin/git"
export PATH="$A/fakebin:$PATH"
# shellcheck source=/dev/null
. "$A/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=bin/lib/gh-rest-list.sh
. "$A/h/bin/lib/gh-rest-list.sh" || { echo "gh-rest-list did not load"; exit 1; }
H="$A/h"
# shellcheck source=bin/lib/migration-hold.sh
. "$A/h/bin/lib/migration-hold.sh" || { echo "migration-hold did not load"; exit 1; }
# shellcheck source=bin/merge-conductor.d/bh-9243-restamp-rebase.sh
[ -f "$FRAG" ] && . "$FRAG"

gh_rest() {
  local path="$2"
  case "$path" in
    */check-runs)
      local sha="${path%/check-runs}"; sha="${sha##*/}"
      [ -e "$FX/checks/fail" ] && { GH_REST_STATUS=502; return 75; }
      GH_REST_STATUS=200
      if [ -f "$FX/checks/${sha:0:8}.json" ]; then cat "$FX/checks/${sha:0:8}.json"; else echo '{"check_runs":[]}'; fi ;;
    */pulls/*/files) GH_REST_STATUS=200; echo '[]' ;;
    *) GH_REST_STATUS=404; return 1 ;;
  esac
}
setting_get() { [ -f "$FX/set/$1" ] || return 2; cat "$FX/set/$1"; }
mc_pool_rebase_enabled() { [ -e "$FX/pool" ]; }
mc_transition() { printf '%s\t%s\n' "$1" "$2" >> "$FX/transitions"; }
mc_rebase_spawn() { printf '%s\n' "$*" >> "$FX/spawns"; return "$(cat "$FX/spawn.rc" 2>/dev/null || echo 0)"; }
mc_rebase_job_ref() { printf 'job'; }
mc_queue_provider() { printf 'mergify'; }
mc_tmp_room() { return 0; }
mc_git_auth() { MC_REMOTE="https://example.test/$1.git"; return 0; }
mc_git_auth_clear() { :; }
mc_hold_push_load() { return 0; }
hold_push_verdict() { return 0; }
hold_push() { printf '%s\n' "$*" >> "$FX/pushes"; return 0; }
mc_resolve_vmap_clean_merge() { return 0; }
mc_regen_generated() { :; }
mc_rebase_cleanup() { :; }
mc_rebase_restamp() { return 0; }
mc_record_for() { return 1; }
job_verdict_rebind() { return 0; }

LOG="$MC_LOG"
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
logn() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
check() {
  local sha="$1"; shift
  printf '%s\n' "$@" | jq -Rnc '[inputs | split("|") | {name: "Mergify Merge Queue", status: .[0],
    conclusion: (if .[1] == "" then null else .[1] end), output: {title: .[2]}}] | {check_runs: .}' \
    > "$FX/checks/${sha:0:8}.json"
}
reset() {
  : > "$LOG"; : > "$MC_ATTEMPTS"
  rm -f "$FX/spawns" "$FX/pushes" "$FX/transitions" "$FX/spawn.rc" "$FX/pool" "$FX"/checks/* "$A/merged"
  scratch_rm "$MC_STATE_DIR/ready-why"
}
# holds <want-rc> <label> <labels-csv> <check-line>... — one mc_mergify_holds call.
holds() {
  local want="$1" what="$2" lab="$3" rc; shift 3
  reset; [ $# -gt 0 ] && check "$H1" "$@"
  mc_mergify_holds "$SLUG" "https://github.com/$SLUG/pull/1" "$H1" "$lab" >/dev/null; rc=$?
  [ "$rc" = "$want" ] && ok || bad "$what: want rc $want, got $rc"
}

# ---- D1-D6 mc_mergify_holds -------------------------------------------------
holds 1 "D1 'Another queue action already ran' (completed|neutral) is a dequeue" "" 'completed|neutral|Another queue action already ran'
holds 1 "D2 the dequeued title with completed|success" "" 'completed|success|Another queue action already ran'
holds 1 "D2 the dequeued title in lower case" "" 'completed|neutral|another queue action already ran'
holds 1 "D3 Mergify's dequeued label with an 'In merge queue' check" 'merge-queue,dequeued' 'in_progress||In merge queue'
holds 1 "D3b a failure conclusion (today)" "" 'completed|failure|Checks failed'
holds 1 "D3c a 'Dequeued from the queue' title (today)" "" 'completed|neutral|Dequeued from the queue'
holds 0 "D4 'In merge queue' holds" "" 'in_progress||In merge queue'
holds 0 "D4 'Waiting for queue conditions to match' holds" "" 'completed|neutral|Waiting for queue conditions to match'
holds 0 "D4 a queued label wins over the dequeued title" 'queued' 'completed|neutral|Another queue action already ran'
holds 0 "D4 a checking label wins over the dequeued label" 'merge-queue,dequeued,checking' 'in_progress||In merge queue'
holds 0 "D4 'predequeued' is not the dequeued label" 'predequeued' 'in_progress||In merge queue'
holds 0 "D5 a live check beside the dequeued title holds" "" 'completed|neutral|Another queue action already ran' 'in_progress||In merge queue'
reset; touch "$FX/checks/fail"
mc_mergify_holds "$SLUG" "https://github.com/$SLUG/pull/1" "$H1" "" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "D6 an unreadable check list must answer rc 2, got $RC"

# ---- D7 mc_rebase pushes a dequeued head ------------------------------------
reset; echo "$H1" > "$A/ctl-head"
check "$H1" 'completed|neutral|Another queue action already ran'
OUT=$(MC_REPOS="$A/repos" mc_rebase "$SLUG" mgfy ticket/mg-7 "$H1" "https://github.com/$SLUG/pull/7"); RC=$?
[ "$(n "$FX/pushes")" = 1 ] && ok || bad "D7 a dequeued head must be pushed once (pushes $(n "$FX/pushes"); log: $(tail -2 "$LOG"))"
{ [ "$RC" = 0 ] && [ "$OUT" = "$NEW" ]; } && ok || bad "D7 the push must answer rc 0 and the new head (rc $RC out '$OUT')"
[ "$(logn 'SKIP_PUSH mergify-queue')" = 0 ] && ok || bad "D7 no SKIP_PUSH mergify-queue line on a dequeued head"
reset; echo "$H1" > "$A/ctl-head"
check "$H1" 'in_progress||In merge queue'
OUT=$(MC_REPOS="$A/repos" mc_rebase "$SLUG" mgfy ticket/mg-7 "$H1" "https://github.com/$SLUG/pull/7"); RC=$?
{ [ "$(n "$FX/pushes")" = 0 ] && [ "$RC" = 3 ]; } && ok || bad "D7 control: 'In merge queue' must drop the result (pushes $(n "$FX/pushes"), rc $RC)"

# ---- the row variables pr_worker holds at the prequeue arm ------------------
row() {
  P=mgfy SLUG="$SLUG" NUM=8 KEY="$SLUG#8" HEAD="$H2" BR=ticket/mg-8 URL="https://github.com/$SLUG/pull/8"
  REC=- REVIEWED="$H2" VERDICT=APPROVE MSTATE=CLEAN RAWLBL="${1:-}" PROVIDER=mergify MERGES=1
  PQ_RESTAMP_LAND=1 PQ_WHY="stale schema stamp on a reviewed head"
}
call() { mc_pq_restamp_rebase; }
trn() { if [ -f "$FX/transitions" ]; then grep -c "	$1\$" "$FX/transitions"; else echo 0; fi; }
whykind() { awk -F'\t' '{print $3}' "$MC_STATE_DIR/ready-why/"* 2>/dev/null | tail -1; }
has_fn() { command -v mc_pq_restamp_rebase >/dev/null 2>&1; }

# ---- D8 mc_rebase_gate with the dequeued label ------------------------------
reset; row 'merge-queue,dequeued'; check "$H2" 'in_progress||In merge queue'
mc_rebase_gate needs-rebase; RC=$?
[ "$RC" = 0 ] && ok || bad "D8 mc_rebase_gate with the dequeued label must let the rebase run (rc $RC)"
[ "$(logn 'LAND_SKIP mergify-queue')" = 0 ] && ok || bad "D8 no LAND_SKIP mergify-queue line"

# ---- S0 pq_gate marks a restamp deferral ------------------------------------
S0=$(
  # shellcheck source=bin/lib/mc-prequeue.sh
  . "$DIR/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || { echo load-failed; exit 0; }
  unset PQ_RESTAMP_LAND
  mc_rest_var() { printf -v "$1" '{"sha":"%s"}' "$MAIN2"; }
  gh_rest() { return 0; }
  mc_log() { :; }
  lane_knob() { return 0; }
  pq_hotfix_skip() { return 1; }
  pq_mignum_wanted() { return 1; }
  pq_fastlint_wanted() { return 1; }
  pq_status_gate() { :; }
  pq_restamp() { echo "deferred-land 1"; }
  pq_resolve() { echo rebase; }
  w1=$(MC_STATE_DIR="$A/pq" pq_gate "$SLUG" 9 "https://github.com/$SLUG/pull/9" "$H2" main >/dev/null; echo "$PQ_VERDICT:${PQ_RESTAMP_LAND:-unset}")
  MC_STATE_DIR="$A/pq" pq_gate "$SLUG" 9 "https://github.com/$SLUG/pull/9" "$H2" main >/dev/null
  pq_restamp() { :; }
  MC_STATE_DIR="$A/pq" pq_gate "$SLUG" 9 "https://github.com/$SLUG/pull/9" "$H2" main >/dev/null
  echo "$w1 $PQ_VERDICT:${PQ_RESTAMP_LAND:-unset}"
)
[ "${S0% *}" = "rebase:1" ] && ok || bad "S0 a deferred-land pq_gate must answer rebase with PQ_RESTAMP_LAND=1 (got '${S0% *}')"
[ "${S0#* }" = "rebase:0" ] && ok || bad "S0 a conflict rebase after it must reset PQ_RESTAMP_LAND to 0 (got '${S0#* }')"

if ! has_fn; then
  bad "S1-S8: mc_pq_restamp_rebase is not defined ($FRAG missing)"
else
  # S1 tick 1: the restamp rebase spawns in the same tick, the row goes REBASING.
  reset; row; unset MC_PQ_RESTAMP_REBASE; call; RC=$?
  [ "$RC" = 0 ] && ok || bad "S1 rc 0 (it acted), got $RC"
  [ "$(n "$FX/spawns")" = 1 ] && ok || bad "S1 one spawn in the same tick (got $(n "$FX/spawns"))"
  grep -q " ${MC_LAND_REBASE_PARALLEL:-4}\$" "$FX/spawns" && ok || bad "S1 the spawn takes the MC_LAND_REBASE_PARALLEL cap ($(cat "$FX/spawns"))"
  [ "$(trn REBASING)" = 1 ] && [ "$(trn NEEDS_REBASE)" = 0 ] && ok || bad "S1 REBASING, no NEEDS_REBASE ($(cat "$FX/transitions" 2>/dev/null))"
  [ "$(logn "PQ_RESTAMP_REBASE_SPAWNED $SLUG#8 $H2")" = 1 ] && ok || bad "S1 one PQ_RESTAMP_REBASE_SPAWNED line ($(tail -2 "$LOG"))"
  grep -qxF "pqrestamp $SLUG#8 $H2" "$MC_ATTEMPTS" && grep -qxF "rebase $SLUG#8 $H2" "$MC_ATTEMPTS" && ok || bad "S1 the pqrestamp and rebase marks ($(cat "$MC_ATTEMPTS"))"
  # S2 tick 2, same head: no second spawn, no NEEDS_REBASE, a ready-why hold.
  row; call; RC=$?
  [ "$RC" = 0 ] && ok || bad "S2 rc 0 (held, the row stays READY), got $RC"
  [ "$(n "$FX/spawns")" = 1 ] && ok || bad "S2 no second spawn (got $(n "$FX/spawns"))"
  [ "$(trn NEEDS_REBASE)" = 0 ] && [ "$(trn REBASING)" = 1 ] && ok || bad "S2 no new transition ($(cat "$FX/transitions"))"
  [ "$(whykind)" = prequeue-restamp ] && ok || bad "S2 ready-why prequeue-restamp (got '$(whykind)')"
  [ "$(logn "PQ_RESTAMP_REBASE_SPAWNED $SLUG#8")" = 1 ] && ok || bad "S2 still one SPAWNED line over two ticks"
  # S3 the cap refuses (rc 3): READY, mark cleared; the next tick spawns.
  reset; row; echo 3 > "$FX/spawn.rc"; call; RC=$?
  [ "$RC" = 0 ] && [ "$(trn NEEDS_REBASE)" = 0 ] && [ "$(trn REBASING)" = 0 ] && ok || bad "S3 a cap refusal holds READY (rc $RC; $(cat "$FX/transitions" 2>/dev/null))"
  grep -q "^pqrestamp $SLUG#8" "$MC_ATTEMPTS" && bad "S3 the pqrestamp mark must be cleared when nothing was spent" || ok
  [ "$(whykind)" = prequeue-restamp ] && ok || bad "S3 ready-why prequeue-restamp (got '$(whykind)')"
  rm -f "$FX/spawn.rc"; row; call
  [ "$(n "$FX/spawns")" = 2 ] && [ "$(trn REBASING)" = 1 ] && ok || bad "S3 the next tick spawns (spawns $(n "$FX/spawns"); $(cat "$FX/transitions" 2>/dev/null))"
  # S4 Mergify holds the head: no spawn, no NEEDS_REBASE, no mark.
  reset; row; check "$H2" 'in_progress||In merge queue'; call; RC=$?
  [ "$RC" = 0 ] && [ "$(n "$FX/spawns")" = 0 ] && [ ! -s "$FX/transitions" ] && ok || bad "S4 a Mergify hold: rc 0, no spawn, no transition (rc $RC)"
  grep -q "^pqrestamp " "$MC_ATTEMPTS" && bad "S4 no pqrestamp mark under a hold" || ok
  [ "$(whykind)" = prequeue-restamp ] && ok || bad "S4 ready-why prequeue-restamp (got '$(whykind)')"
  # S4b the check list cannot be read: held this tick.
  reset; row; touch "$FX/checks/fail"; call; RC=$?
  [ "$RC" = 0 ] && [ "$(n "$FX/spawns")" = 0 ] && [ ! -s "$FX/transitions" ] && ok || bad "S4b an unreadable gate: rc 0, no spawn, no transition (rc $RC)"
  # S5 a conflict rebase (PQ_RESTAMP_LAND=0): rc 1, today's path.
  reset; row; PQ_RESTAMP_LAND=0; call; RC=$?
  [ "$RC" = 1 ] && [ "$(n "$FX/spawns")" = 0 ] && ok || bad "S5 a conflict rebase must answer rc 1 with no spawn (rc $RC)"
  # S6 the kill switch.
  reset; row; MC_PQ_RESTAMP_REBASE=0 call; RC=$?
  [ "$RC" = 1 ] && [ "$(n "$FX/spawns")" = 0 ] && ok || bad "S6 MC_PQ_RESTAMP_REBASE=0 must answer rc 1 with no spawn (rc $RC)"
  # S7 pool mode.
  reset; row; touch "$FX/pool"; call; RC=$?
  [ "$RC" = 1 ] && [ "$(n "$FX/spawns")" = 0 ] && ok || bad "S7 pool mode must answer rc 1 with no spawn (rc $RC)"
  # S8 merges off: one would-line, no spawn, the row stays READY.
  reset; row; MERGES=0; call; RC=$?
  [ "$RC" = 0 ] && [ "$(n "$FX/spawns")" = 0 ] && [ ! -s "$FX/transitions" ] && ok || bad "S8 observe mode: rc 0, no spawn, no transition (rc $RC)"
  [ "$(logn "$SLUG#8 would PQ_RESTAMP_REBASE")" = 1 ] && ok || bad "S8 one 'would PQ_RESTAMP_REBASE' line ($(tail -2 "$LOG"))"
  grep -q "^pqrestamp " "$MC_ATTEMPTS" && bad "S8 no mark in observe mode" || ok
fi

echo "mc-dequeued-restamp.bh-9243: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
