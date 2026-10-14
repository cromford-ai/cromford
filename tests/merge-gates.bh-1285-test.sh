#!/bin/bash
# tests/merge-gates.bh-1285-test.sh — BH-1285: box-side merge lanes honour pause
# flags and refuse train/stacked PRs.
#
# What is proved:
#   AT-1..AT-3 proved bin/tier2-merge-sweep.sh, which BH-1366 retired on main
#   (the merge queue is fed at the APPROVE verdict instead); every merge that
#   sweep fed now goes through bin/merge-queue.sh, which AT-4/AT-5/AT-11 pin.
#   AT-4: merge-queue stands down when flags/automerge-disabled is on.
#   AT-5: merge-queue stands down when flags/paused-<project> is on.
#   AT-6: merge-queue refuses a PR whose base is not main.
#   AT-7: merge-queue refuses a PR whose head starts with train/, and drops the
#         row (a train/* head can never become eligible; see AT-13).
#   AT-8: review-prs merge_step stands down when flags/paused-<project> is on.
#   AT-9: review-prs merge_step still stands down when flags/automerge-disabled is on.
#   AT-10: a normal main-based PR still lands through the merge queue.
#   AT-11: merge-queue stands down on a console pause ROW with no flag file —
#          the flag_active path, which is the failure the ticket describes.
#   AT-12: a queued stacked PR that already MERGED into its parent branch is
#          dequeued (the not-OPEN dequeue runs before the base hold).
#   AT-13: an OPEN train/* row is dropped with a ledger reason, never merged.
#   AT-8P: positive control — with no flag, merge_step really merges, so AT-8/9's
#          "no merge" assertions are about the flag and nothing else.
#   AT-14: merge_retry under paused-<project> spends no attempt and writes no
#          ALERT, and the same APPROVE merges once the pause lifts.
#   AT-15: merge_step refuses a PR whose base is not main (AC3) and marks the
#          tick fenced; merge_retry hands that attempt back.
#
# Driven through the real production entry points (merge-queue whole script; review-prs merge_step extracted by its markers). Stubs provide the
# pause flag, GitHub REST answers, gh pr merge, the queue directory, and logs.
# Run from anywhere: tests/merge-gates.bh-1285-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SLUG=example-org/demo-os
PROJECT=demo-os
H1=aaaaaaaa1111

mkdir -p "$T/h/bin/lib" "$T/h/bin/lib/jobs" "$T/h/bin/lib/mc" \
         "$T/h/logs" "$T/h/locks" "$T/h/state" "$T/h/flags" \
         "$T/h/env" "$T/h/builds" "$T/h/repos/$PROJECT" "$T/fakebin"

# Scripts under test.
cp "$DIR/bin/merge-queue.sh" \
   "$DIR/bin/review-prs.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/bin/alert-line.sh" "$T/h/bin/"

# Real libs needed by the merge family and the scripts.
cp "$DIR"/bin/lib/*.sh "$T/h/bin/lib/" 2>/dev/null || true
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"

# Stub the coordination client and lane gate: pause flags are just files in the
# scratch tree, and the lane gate never pauses on its own. This keeps the test
# deterministic and independent of the worker.
cat > "$T/h/bin/jobs-client.sh" <<'JC'
#!/bin/bash
# stub coordination client for BH-1285 tests
# A pause is active when its flag file is there OR its console row is (the row
# is a file under state/rows/, so a case can set one with no flag file at all).
flag_active() { [ -f "$HARNESS/flags/${1:-}" ] || [ -f "$HARNESS/state/rows/${1:-}" ]; }
flag_sync()   { [ -f "$HARNESS/flags/${1:-}" ]; }
merge_queue_put() { :; }
merge_queue_set() { mkdir -p "$HARNESS/state/bh1285"; printf '%s|%s|%s\n' "$2" "$3" "${4:-}" >> "$HARNESS/state/bh1285/mq-rows.txt"; }
job_lane_open()   { :; }
job_lane_close()  { :; }
job_verdict()     { return 1; }
job_event()       { :; }
job_open()        { :; }
job_update()      { :; }
job_cap()         { :; }
# BH-1606: a READABLE lead_pr_authors row. The box queue asks the lead fence,
# which fails CLOSED on an unreadable row (#1603), and holds a lead-authored PR
# until a lead verdict row stands on its head. This suite's PRs are "normal"
# pool PRs whose fixture author happens to be the PAT login, so the row names
# a different lead: the fence answers "not a lead PR" and every case here is
# decided by the gate it is about (the lead fence has its own suite, 1606).
setting_get()     { [ "${1:-}" = lead_pr_authors ] && echo bh1285-lead; }
# BH-6428: the box queue's pre-merge guard lands only a head bound to a review.
# The conductor's pr_state row binds it here (reviewed_sha = the fixture head,
# state READY); every other ledger kind has no row, as before.
job_ledger_row()  { [ "${1:-}" = pr_state ] || return 2
  jq -nc '{status:"READY", detail:({head_sha:"aaaaaaaa1111", reviewed_sha:"aaaaaaaa1111"}|tojson)}'; }
JC
chmod +x "$T/h/bin/jobs-client.sh"

cat > "$T/h/bin/lib/lane-gate.sh" <<'LG'
#!/bin/bash
# stub lane gate for BH-1285 tests
lane_gate_or_exit() { return 1; }
lane_paused()       { return 1; }
lane_env_apply()    { :; }
lane_knob()         { :; }
LG

# Stubs that stand in for harness machinery.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"
for s in beat.sh deploy-request.sh lander.sh gh-app-auth.sh gh-limit-logger.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done

# Helper for REST PR answers.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

# fleet.conf gives the repo slug.
printf '%s %s - - 2 box-demo\n' "$PROJECT" "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"; : > "$T/h/env/$PROJECT.env"

# Track artifacts from child processes under HARNESS/state/bh1285 (T itself is
# deliberately not exported by scratch.sh).
mkdir -p "$T/h/state/bh1285"

# Fake git: every merge looks like a fast-forward on main.
cat > "$T/fakebin/git" <<'GIT'
#!/bin/bash
MAIN_SHA=cccccccc3333
case "$*" in
  *merge-base*) echo "$MAIN_SHA" ;;
  *"rev-parse origin/main"*) echo "$MAIN_SHA" ;;
  *"merge -q"*) exit 0 ;;
  *fetch*) exit 0 ;;
  *worktree*) exit 0 ;;
  *rebase*) exit 0 ;;
  *push*) exit 0 ;;
  *) exit 0 ;;
esac
exit 0
GIT
chmod +x "$T/fakebin/git"

# gh stub: answers PR reads via REST and records merge attempts. After a merge PUT
# or `gh pr merge`, subsequent reads of the same PR return MERGED so the queue
# can dequeue it.
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
SLUG=example-org/demo-os
TRACK="$HARNESS/state/bh1285"
MERGED_FLAG="$TRACK/merged-prs"
mkdir -p "$TRACK"
printf '%s\n' "$*" >> "$TRACK/gh-calls.txt"
PRN=""
case "$*" in
  *"api -i -X GET repos/$SLUG/actions/runs?head_sha="*) printf 'HTTP/1.1 200 OK\r\n\r\n{"workflow_runs":[{"name":"ci","status":"completed","conclusion":"success","created_at":"2026-10-13T00:00:00Z"}]}\n'; exit 0 ;;  # BH-6428: the guard reads head CI; green here
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"api -i -X PUT repos/$SLUG/pulls/"*"/merge"*)
    PRN=$(sed -E 's|.*/pulls/([0-9]+)/merge.*|\1|' <<<"$*")
    [ -n "$PRN" ] && { mkdir -p "$MERGED_FLAG"; touch "$MERGED_FLAG/$PRN"; }
    printf '%s\n' "$*" >> "$TRACK/gh-merges.txt"
    printf 'HTTP/1.1 200 OK\r\n\r\n{"sha":"%s","merged":true,"message":"merged"}\n' "$H1"
    exit 0
    ;;
  *"pr merge"*)
    PRN=$(sed -E 's|.*pr merge ([0-9]+).*|\1|' <<<"$*")
    [ -n "$PRN" ] && { mkdir -p "$MERGED_FLAG"; touch "$MERGED_FLAG/$PRN"; }
    printf '%s\n' "$*" >> "$TRACK/gh-merges.txt"
    exit 0
    ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    PRN=$(sed -E 's|.*/pulls/([0-9]+).*|\1|' <<<"$*")
    if [ -n "$PRN" ] && [ -f "$MERGED_FLAG/$PRN" ]; then
      restpr MERGED "$H1" ticket/x main '' MERGEABLE CLEAN operator
    else
      case "${MQ_SCENARIO:-normal}" in
        stacked)  restpr OPEN "$H1" ticket/bh-872 ticket/bh-999 '' MERGEABLE CLEAN operator ;;
        train)    restpr OPEN "$H1" train/bh-1282 main '' MERGEABLE CLEAN operator ;;
        nonbase)  restpr OPEN "$H1" ticket/x ticket/bh-872 '' MERGEABLE CLEAN operator ;;
        stackedmerged) restpr MERGED "$H1" ticket/bh-1067 ticket/bh-872 '' MERGEABLE CLEAN operator ;;
        *)        restpr OPEN "$H1" ticket/x main '' MERGEABLE CLEAN operator ;;
      esac
    fi
    exit 0
    ;;
  *"--json state"*)
    # review-prs merge_step re-reads PR state after gh pr merge
    if [ -f "$MERGED_FLAG/77" ]; then echo MERGED; else echo OPEN; fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GH
chmod +x "$T/fakebin/gh"

# No live credentials leak into the scratch harness.
unset GH_TOKEN GITHUB_TOKEN GH_ADMIN_TOKEN

# Pause flag helpers.
clear_flags() { rm -f "$T/h/flags"/automerge-disabled "$T/h/flags/paused-$PROJECT"; }
GH_CALLS="$T/h/state/bh1285/gh-calls.txt"
GH_MERGES="$T/h/state/bh1285/gh-merges.txt"
MQ_CALLS="$T/h/state/bh1285/mq-calls.txt"
MQ_ROWS="$T/h/state/bh1285/mq-rows.txt"

# ============================================================================
# MERGE QUEUE
# ============================================================================
run_mq() {
  local scenario="${1:-normal}"
  clear_flags
  rm -rf "$T/h/state/merge-queue/$PROJECT"/* "$T/h/logs/merge-queue.log" "$T/h/state/bh1285"
  export REPO_DIR="$T/h/repos/$PROJECT"/*
  mkdir -p "$T/h/state/merge-queue/$PROJECT" "$T/h/state/bh1285"
  touch "$T/h/state/merge-queue/$PROJECT/55"
  [ -n "${2:-}" ] && touch "$T/h/flags/$2"
  MQ_SCENARIO="$scenario" H1="$H1" SLUG="$SLUG" REPO_DIR="$T/h/repos/$PROJECT" \
    PATH="$T/fakebin:$PATH" HARNESS="$T/h" \
    bash "$T/h/bin/merge-queue.sh" "$PROJECT" >/dev/null 2>&1
  printf '%s' "$?" > "$T/mq-rc.txt"
}

# AT-4
run_mq normal automerge-disabled
[ "$(cat "$T/mq-rc.txt")" = "0" ] && ok || bad "AT-4: merge-queue must exit 0 when paused"
[ ! -s "$GH_MERGES" ] && ok || bad "AT-4: merge-queue merged while automerge-disabled was on"
grep -q "automerge-disabled" "$T/h/logs/merge-queue.log" && ok || bad "AT-4: merge-queue log did not name automerge-disabled"

# AT-5
run_mq normal "paused-$PROJECT"
[ ! -s "$GH_MERGES" ] && ok || bad "AT-5: merge-queue merged while paused-$PROJECT was on"
grep -q "paused-$PROJECT" "$T/h/logs/merge-queue.log" && ok || bad "AT-5: merge-queue log did not name paused-$PROJECT"

# AT-6
run_mq nonbase
[ ! -s "$GH_MERGES" ] && ok || bad "AT-6: merge-queue merged a stacked PR into a non-main base"
grep -q "ticket/bh-872" "$T/h/logs/merge-queue.log" && ok || bad "AT-6: merge-queue log did not name the non-main base"
[ -f "$T/h/state/merge-queue/$PROJECT/55" ] && ok || bad "AT-6: stacked PR was removed from the queue instead of held"

# AT-7
run_mq train
[ ! -s "$GH_MERGES" ] && ok || bad "AT-7: merge-queue merged a train/* PR"
grep -q "train/bh-1282" "$T/h/logs/merge-queue.log" && ok || bad "AT-7: merge-queue log did not name the train branch"
[ ! -f "$T/h/state/merge-queue/$PROJECT/55" ] && ok || bad "AT-7: an OPEN train/* PR must be dropped from the queue, not held forever"

# AT-13: the drop is on the ledger with its reason, and nothing merged.
grep -q '^55|dropped|merge-train PR (train/\*) is never eligible' "$MQ_ROWS" 2>/dev/null \
  && ok || bad "AT-13: the train/* row must be dropped with its reason (rows: $(cat "$MQ_ROWS" 2>/dev/null))"
[ ! -s "$GH_MERGES" ] && ok || bad "AT-13: a dropped train/* PR must not be merged"

# AT-12: a stacked PR that already merged into its parent leaves the queue.
run_mq stackedmerged
[ ! -f "$T/h/state/merge-queue/$PROJECT/55" ] && ok || bad "AT-12: a MERGED stacked PR must be dequeued, not held forever (log: $(cat "$T/h/logs/merge-queue.log" 2>/dev/null))"
grep -q '^55|dropped|dequeued: PR state=MERGED' "$MQ_ROWS" 2>/dev/null \
  && ok || bad "AT-12: the dequeue must be the not-OPEN one (rows: $(cat "$MQ_ROWS" 2>/dev/null))"
grep -q "#55 HELD" "$T/h/logs/merge-queue.log" && bad "AT-12: a MERGED stacked PR must not be logged HELD" || ok
[ ! -s "$GH_MERGES" ] && ok || bad "AT-12: a MERGED stacked PR must not be merged again"

# AT-10
run_mq normal
[ -s "$GH_MERGES" ] && ok || bad "AT-10: normal PR was not merged (merges: $(cat "$GH_MERGES" 2>/dev/null))"
[ ! -f "$T/h/state/merge-queue/$PROJECT/55" ] && ok || bad "AT-10: landed PR was not removed from the queue (log: $(cat "$T/h/logs/merge-queue.log" 2>/dev/null); gh: $(cat "$GH_CALLS" 2>/dev/null))"

# AT-11: the console row alone, no flag file on disk.
mkdir -p "$T/h/state/rows"; touch "$T/h/state/rows/paused-$PROJECT"
run_mq normal
rm -f "$T/h/state/rows/paused-$PROJECT"
[ ! -f "$T/h/flags/paused-$PROJECT" ] && ok || bad "AT-11: the case must run with no flag file"
[ ! -s "$GH_MERGES" ] && ok || bad "AT-11: merge-queue merged while the paused-$PROJECT row was active"
grep -q "paused-$PROJECT" "$T/h/logs/merge-queue.log" && ok || bad "AT-11: merge-queue log did not name the paused-$PROJECT row"
[ -f "$T/h/state/merge-queue/$PROJECT/55" ] && ok || bad "AT-11: paused PR was removed from the queue"

# ============================================================================
# REVIEW-PRS MERGE STEP
# ============================================================================
# Extract the merge block and drive merge_step directly.
awk '/^# >>> review-prs merge/{f=1;next} /^# <<< review-prs merge/{exit} f' \
  "$DIR/bin/review-prs.sh" > "$T/rmerge.sh"
[ -s "$T/rmerge.sh" ] && ok || bad "could not extract review-prs merge block"

run_review_merge() {
  local flag="${1:-}" scenario="${2:-normal}"
  clear_flags
  rm -rf "$T/pr-reviews.log" "$T/h/state/bh1285"
  mkdir -p "$T/h/state/bh1285"
  [ -n "$flag" ] && touch "$T/h/flags/$flag"
  OUT=$(
    cd "$T"
    MQ_SCENARIO="$scenario" H1="$H1" \
    PATH="$T/fakebin:$PATH" HARNESS="$T/h" PROJECT="$PROJECT" SLUG="$SLUG" LOG="$T/pr-reviews.log" \
      bash -c 'set -uo pipefail
        STAMP() { echo TS; }
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        rp_prov_is_claude() { [ "${1:-}" = claude ]; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        . "$0"
        # The holds AFTER the one under test are stubbed open, so a "no merge"
        # below is the flag and nothing else (the #1603 lead fence would hold
        # every case here on its own; AT-8P proves the merge is reachable).
        rp_ticket_fence() { return 1; }; bg_review_hold() { return 1; }; hold_main_red() { return 1; }
        merge_step 77 '"$H1"' claude
        printf "MERGED=%s FENCED=%s" "$MERGED" "${RP_FENCED:-0}"' "$T/rmerge.sh" 2>"$T/review-err.txt"
  )
  printf '%s' "$OUT" > "$T/review-out.txt"
}

# AT-8P: positive control — no flag, main base: the merge is reachable.
run_review_merge ""
[ -s "$GH_MERGES" ] && ok || bad "AT-8P: with no flag merge_step must reach gh pr merge (out: $(cat "$T/review-out.txt"), log: $(cat "$T/pr-reviews.log" 2>/dev/null), err: $(cat "$T/review-err.txt"))"

# AT-8
run_review_merge "paused-$PROJECT"
grep -q "MERGED=no" "$T/review-out.txt" && ok || bad "AT-8: paused project must leave MERGED=no (got $(cat "$T/review-out.txt"))"
[ ! -s "$GH_MERGES" ] && ok || bad "AT-8: merge_step merged while paused-$PROJECT was on"
grep -q "paused-$PROJECT" "$T/pr-reviews.log" && ok || bad "AT-8: review-prs log did not name paused-$PROJECT"

# AT-9
run_review_merge automerge-disabled
grep -q "MERGED=no" "$T/review-out.txt" && ok || bad "AT-9: automerge-disabled must leave MERGED=no (got $(cat "$T/review-out.txt"))"
[ ! -s "$GH_MERGES" ] && ok || bad "AT-9: merge_step merged while automerge-disabled was on"

# AT-15: a stacked PR (base ticket/bh-872) is not merged by merge_step, the
# one line names the base, and the tick is marked fenced for merge_retry.
run_review_merge "" nonbase
[ ! -s "$GH_MERGES" ] && ok || bad "AT-15: merge_step merged a PR whose base is ticket/bh-872 ($(cat "$GH_MERGES"))"
grep -q "MERGED=no FENCED=1" "$T/review-out.txt" && ok || bad "AT-15: a base hold is MERGED=no and fenced (got $(cat "$T/review-out.txt"))"
grep -q "#77 APPROVE left unmerged: base is ticket/bh-872, not main" "$T/pr-reviews.log" \
  && ok || bad "AT-15: review-prs log must name the non-main base (log: $(cat "$T/pr-reviews.log" 2>/dev/null))"
[ ! -e "$T/h/state/merge-queue/$PROJECT/77" ] && ok || bad "AT-15: a stacked PR must not be handed to the box queue"

# ============================================================================
# REVIEW-PRS MERGE RETRY (the block tests/main-red-box-freeze.bh-945-test.sh drives)
# ============================================================================
awk '/^# >>> review-prs merge-retry/{f=1;next} /^# <<< review-prs merge-retry/{exit} f' \
  "$DIR/bin/review-prs.sh" > "$T/rretry.sh"
[ -s "$T/rretry.sh" ] && ok || bad "could not extract review-prs merge-retry block"
RSTATE="$T/rp-state.json"
run_retry() { # run_retry <flag|""> <scenario> <ticks>
  clear_flags
  rm -rf "$T/pr-reviews.log" "$T/h/state/bh1285" "$T/h/state/merge-queue/$PROJECT/77"
  mkdir -p "$T/h/state/bh1285"; : > "$T/h/logs/ALERTS.log"
  [ -n "$1" ] && touch "$T/h/flags/$1"
  ( cd "$T" && MQ_SCENARIO="$2" H1="$H1" \
    PATH="$T/fakebin:$PATH" HARNESS="$T/h" PROJECT="$PROJECT" SLUG="$SLUG" \
    LOG="$T/pr-reviews.log" STATE="$RSTATE" \
      bash -c 'set -uo pipefail
        STAMP() { echo TS; }
        rp_state_write() { local f; f=$(mktemp); jq "$@" "$STATE" > "$f" && mv "$f" "$STATE"; }
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        rp_prov_is_claude() { [ "${1:-}" = claude ]; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        . "$0"
        . "$1"
        rp_ticket_fence() { return 1; }; bg_review_hold() { return 1; }; hold_main_red() { return 1; }
        main_red_hold() { return 1; }
        i=0; while [ "$i" -lt "$2" ]; do MERGED=; merge_retry 77 '"$H1"'; i=$((i+1)); done' \
        "$T/rmerge.sh" "$T/rretry.sh" "$3" 2>"$T/retry-err.txt" )
}

# AT-14: seven ticks under the project pause spend nothing and page no one.
printf '{"77":{"verdict":"APPROVE","served":"claude","merge_retries":0}}\n' > "$RSTATE"
run_retry "paused-$PROJECT" normal 7
[ ! -s "$GH_MERGES" ] && ok || bad "AT-14: merge_retry merged while paused-$PROJECT was on"
[ "$(jq -r '.["77"].merge_retries' "$RSTATE")" = 0 ] \
  && ok || bad "AT-14: merge_retries must stay 0 under the project pause (state: $(cat "$RSTATE"), err: $(cat "$T/retry-err.txt"))"
[ ! -s "$T/h/logs/ALERTS.log" ] && ok || bad "AT-14: a paused tick is not a failed attempt — no ALERT ($(cat "$T/h/logs/ALERTS.log"))"
run_retry "" normal 1
[ -s "$GH_MERGES" ] && ok || bad "AT-14: with the pause lifted the same APPROVE must merge (log: $(cat "$T/pr-reviews.log" 2>/dev/null), err: $(cat "$T/retry-err.txt"))"

# AT-15 (retry side): a stacked base is a hold, so its attempt is handed back.
printf '{"77":{"verdict":"APPROVE","served":"claude","merge_retries":0}}\n' > "$RSTATE"
run_retry "" nonbase 7
[ ! -s "$GH_MERGES" ] && ok || bad "AT-15: merge_retry merged a PR whose base is ticket/bh-872"
[ "$(jq -r '.["77"].merge_retries' "$RSTATE")" = 0 ] \
  && ok || bad "AT-15: a base hold must refund the attempt like RP_FENCED (state: $(cat "$RSTATE"), err: $(cat "$T/retry-err.txt"))"
! grep -q "merge attempts" "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "AT-15: a base hold must not page \"needs a look\" ($(cat "$T/h/logs/ALERTS.log"))"
# BH-1646: 7 held ticks on one head DO raise the one base-hold alert, and only one.
[ "$(grep -c "base-held" "$T/h/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "AT-15: 7 base holds must raise exactly one base-held alert ($(cat "$T/h/logs/ALERTS.log"))"

# ============================================================================
# SUMMARY
# ============================================================================
if [ "$FAIL" -eq 0 ]; then
  echo "OK: $PASS assertions passed"
  exit 0
else
  echo "FAIL: $FAIL assertions failed, $PASS passed"
  exit 1
fi
