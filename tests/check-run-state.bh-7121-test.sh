#!/bin/bash
# tests/check-run-state.bh-7121-test.sh — BH-7121: GitHub can report a check
# run as status in_progress with conclusion success and completed_at set (PR
# #7099, "Prompt replay evals (prompts/** only)"). The queue path read
# status/conclusion, took only completed/success, and the PR waited 20+ min.
# bin/lib/mc/check-run-state.sh holds one rule: a run with a non-empty
# completed_at and a conclusion in {success, neutral, skipped} has the
# effective status completed. Each reader keeps its own conclusion set.
#
#   C1-C9  crs_word on single fixtures (the #7099 shape, pending, red, edges)
#   A1-A4  autoenqueue G4 through the REAL ae_project (the tier2-autoenqueue
#          unit harness, copied): #7099 shape posts; {in_progress,null} does
#          not; crs_word unset fails closed; neutral still does not post
#   L1-L2  landing_eligible step 8 (fast-checks) on the #7099 shape / pending
#   B1-B2  mc_mergify_batch_green: #7099 shape and neutral green; pending rc 1;
#          the lib not loadable -> rc 75
# Each section runs in its own subshell; counts go through files.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/check-run-state.bh-7121-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
: > "$T/pass"; : > "$T/fail"
ok()  { echo . >> "$T/pass"; }
bad() { echo "FAIL: $1"; echo . >> "$T/fail"; }

LIB="$DIR/bin/lib/mc/check-run-state.sh"
P7099='Prompt replay evals (prompts/** only)'
# run <name> <status> <conclusion json> <completed_at json> [started_at]
run() { printf '{"name":"%s","status":"%s","conclusion":%s,"completed_at":%s,"started_at":"%s"}' \
  "$1" "$2" "$3" "$4" "${5:-2026-10-16T11:50:00Z}"; }
page() { local IFS=,; printf '{"total_count":%s,"check_runs":[%s]}' "$#" "$*"; }
SET='"2026-10-16T12:00:00Z"'

# ── C: crs_word ─────────────────────────────────────────────────────────────
(
  # shellcheck source=bin/lib/mc/check-run-state.sh
  [ -r "$LIB" ] && . "$LIB"
  command -v crs_word >/dev/null 2>&1 || { bad "C: $LIB is missing or defines no crs_word — every C case is red"; exit 0; }
  cw() { page "$@" > "$T/c.json"; crs_word "$T/c.json" X; }
  want() { local got; got=$(cw "${@:3}"); [ "$got" = "$2" ] && ok || bad "$1: want '$2', got '$got'"; }
  want C1 completed/success "$(run X in_progress '"success"' "$SET")"
  want C2 in_progress/none "$(run X in_progress null null)"
  want C3 in_progress/none "$(run X in_progress null "$SET")"
  want C4 queued/success "$(run X queued '"success"' null)"
  want C5 completed/failure "$(run X completed '"failure"' "$SET")"
  want "C6 neutral" completed/neutral "$(run X in_progress '"neutral"' "$SET")"
  want "C6 skipped" completed/skipped "$(run X queued '"skipped"' "$SET")"
  want C7 in_progress/failure "$(run X in_progress '"failure"' "$SET")"
  want C8 in_progress/success "$(run X in_progress '"success"' '""')"
  want "C9 absent" absent "$(run Y completed '"success"' "$SET")"
  want "C9 latest by started_at" completed/success \
    "$(run X completed '"failure"' "$SET" 2026-10-16T10:00:00Z)" "$(run X in_progress '"success"' "$SET" 2026-10-16T11:00:00Z)"
  want "C9 a normal completed/success" completed/success "$(run X completed '"success"' "$SET")"
)

# ── L: landing_eligible step 8 ──────────────────────────────────────────────
(
  REPO=example-org/landing-os PROJ=landing PR=7121
  HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa7121 MAIN=cccccccccccccccccccccccccccccccccccc7121
  NOW=2000000000 FX="$T/lfx"
  mkdir -p "$T/l/flags" "$T/l/state" "$FX"
  export HARNESS="$T/l" MC_STATE_DIR="$T/l/state" LANDING_NOW="$NOW"
  unset MC_LANDING_MODE MC_LANDING_PQ_AGE_MIN
  . "$DIR/bin/lib/main-red-gate.sh" || exit 1
  . "$DIR/bin/lib/lead-authority.sh" || exit 1
  . "$DIR/bin/lib/mc-prequeue.sh" || exit 1
  . "$DIR/bin/lib/queue-status-contexts.sh" || exit 1
  # shellcheck source=bin/lib/mc/landing.sh
  . "$DIR/bin/lib/mc/landing.sh" || exit 1
  unset -f lane_knob 2>/dev/null
  la_globs() { printf 'worker/**\n'; }
  gh_rest() {
    GH_REST_STATUS=200
    case "$2" in
      */commits/*/status) echo '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
      */check-runs*) cat "$FX/checks.json" ;;
      */files*page=1) echo '[{"filename":"docs/a.md"}]' ;;
      */files*) echo '[]' ;;
      *) GH_REST_STATUS=404; return 1 ;;
    esac
  }
  _jobs_req() { JOBS_HTTP=200; printf '{"rows":[{"head_sha":"%s","tier":"low"}]}\n' "$HEAD"; }
  ae_mergify_admit_checks() { printf '%s\n' "$P7099" lead-verdict; }
  pq_cache_put "$(pq_key "$REPO" "$PR" "$HEAD" "$MAIN")" green "$((NOW - 60))" run-fixture s1
  lexp() { # lexp <case> <want token> <check run>
    page "$3" > "$FX/checks.json"
    local rc=0 out; out=$(landing_eligible "$REPO" "$PR" "$HEAD" "$PROJ" "" 2>"$T/l.err") || rc=$?
    [ "$out" = "$2" ] && ok || bad "$1: want '$2', got rc $rc '$out' ($(head -c 200 "$T/l.err"))"
  }
  lexp "L1 the #7099 shape passes step 8" ok "$(run "$P7099" in_progress '"success"' "$SET")"
  lexp "L2 {in_progress, null} is fast-checks" fast-checks "$(run "$P7099" in_progress null null)"
)

# ── B: mc_mergify_batch_green ───────────────────────────────────────────────
(
  export MC_H="$T/b"
  # shellcheck source=bin/lib/mc/queue.sh
  . "$DIR/bin/lib/mc/queue.sh" || exit 1
  gh_rest() { cat "$T/b.json"; }
  bexp() { # bexp <case> <want rc> <want out> <check run>
    page "$4" > "$T/b.json"
    local rc=0 out; out=$(mc_mergify_batch_green o/r abc) || rc=$?
    [ "$rc" = "$2" ] && [ "$out" = "$3" ] && ok || bad "$1: want rc $2 '$3', got rc $rc '$out'"
  }
  # 2026-10-16T12:00:00Z
  E=1792152000
  bexp "B1 the #7099 shape is green" 0 "$E" "$(run CI in_progress '"success"' "$SET")"
  bexp "B1b neutral with completed_at is green" 0 "$E" "$(run CI in_progress '"neutral"' "$SET")"
  bexp "B2 {in_progress, null} is not green" 1 "" "$(run CI in_progress null null)"
  bexp "B2 {in_progress, failure, set} is not green" 1 "" "$(run CI in_progress '"failure"' "$SET")"
  # the lib not loadable: a copy of queue.sh with no check-run-state.sh beside it
  # scratch-closure-allow: B2 needs queue.sh WITHOUT its sibling lib, to prove the fail-closed rc 75
  mkdir -p "$T/iso/bin/lib/mc" && cp "$DIR/bin/lib/mc/queue.sh" "$T/iso/bin/lib/mc/"
  page "$(run CI in_progress '"success"' "$SET")" > "$T/b.json"
  rc=0; T="$T" bash -c 'unset CRS_JQ_DEFS CHECK_RUN_STATE_LIB; . "$1"; gh_rest() { cat "$T/b.json"; }; mc_mergify_batch_green o/r abc' _ "$T/iso/bin/lib/mc/queue.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 75 ] && ok || bad "B2 the lib not loadable must read unreadable (rc 75), got rc $rc"
)

# ── A: autoenqueue G4 through ae_project (the tier2-autoenqueue harness) ────
(
  SLUG=example-org/mgfy-os
  H1=$(printf 'a%.0s' $(seq 40))
  export HARNESS="$T/u"; H="$HARNESS"; MC_H="$H"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/fx" "$T/ubin"
  printf 'GH_ADMIN_TOKEN=pat-admin-fixture\n' > "$H/env/github-admin.env"
  printf '#!/bin/bash\n[ "$2" = board_prefix ] && echo X\nexit 0\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
  cp "$DIR/tests/lib/rest-emit.sh" "$T/ubin/restpr"; chmod +x "$T/ubin/restpr"
  MC_ATTEMPTS="$H/state/attempts.txt"; MC_LOG="$H/logs/merge-conductor.log"; : > "$MC_ATTEMPTS"; : > "$MC_LOG"
  MC_TICK_ID=unit-tick; MC_TICK_DIR="$H/state/tick"
  export MC_ATTEMPTS MC_LOG MC_TICK_ID MC_TICK_DIR
  cat > "$T/ubin/gh" <<EOF
#!/bin/bash
FX="$T/fx"
num_of() { printf '%s' "\$1" | sed -nE 's#.*/(pulls|issues)/([0-9]+).*#\2#p'; }
case "\$*" in
  "api repos/$SLUG -q .id") echo 1 ;;
  *"api -i -X GET repos/$SLUG/commits/"*"/check-runs"*) restpr --raw 200 "\$(cat "\$FX/checks")" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/posts.txt"; restpr --raw 201 '{"id":777,"body":"@mergifyio queue"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    n=\$(num_of "\$*"); restpr open "$H1" "ticket/mg-\$n" main "" MERGEABLE clean operator ;;
  *) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$T/ubin/gh"
  export PATH="$T/ubin:$PATH" GH_TOKEN=pat-default-fixture GH_ETAG=0
  . "$DIR/bin/lib/gh-rest.sh" || exit 1
  . "$DIR/bin/lib/gh-repo-token.sh" || exit 1
  export GH_TOKEN=app-tok-fixture
  mc_log()   { echo "$*" >> "$MC_LOG"; }
  mc_alert() { echo "ALERT $*" >> "$H/logs/ALERTS.log"; }
  mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
  mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
  mc_record_for() { echo "$T/rec"; }
  mc_issue_of() { echo 1; }
  mc_verdict() { printf '%s\t-\t%s\t%s\t-' APPROVE "$H1" J31; }
  vd_standing() { return 1; }
  to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
  to_lane_hold() { return 1; }
  bg_scan() { return 0; }
  bg_scan_read() { return 0; }
  main_red_exempt() { return 1; }
  hotfix_pr_is() { return 1; }
  mc_hotfix_proof() { echo ok; }
  flag_active() { [ -f "$H/flags/$1" ]; }
  job_ledger_get() {
    local s; s=$(jq -r --arg k "$1" --arg v "$2" 'select(.kind==$k and .key==$v) | .status' "$T/ledger.jsonl" 2>/dev/null | tail -1)
    [ -n "$s" ] || return 2; printf '%s' "$s"; }
  job_ledger_put() { jq -nc --arg k "$1" --arg v "$2" --arg s "$3" --arg d "${4:-}" '{kind:$k,key:$v,status:$s,detail:$d}' >> "$T/ledger.jsonl"; }
  job_artifact_put() { :; }
  # shellcheck source=bin/lib/autoenqueue.sh
  . "$DIR/bin/lib/autoenqueue.sh" || exit 1
  U="https://github.com/$SLUG/pull"
  row() { printf '%s\t%s\t%s\tticket/mg-%s\tfalse\tCLEAN\tMERGEABLE\tOPEN\tfalse\t-\tmain\t-\tfalse' "$1" "$U/$1" "$2" "$1"; }
  reset() {
    rm -f "$T/fx"/*; : > "$T/posts.txt"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$T/ledger.jsonl"
    rm -f "$H/state/tier2-autoenqueue.txt"; scratch_rm "$MC_TICK_DIR"
    page "$1" > "$T/fx/checks"; ae_mark mgfy ready "$SLUG#31" "$H1"
  }
  ae() { ( MODE=merge; MERGES=1; MC_AUTOENQUEUE_CHECK="$P7099"; ae_project mgfy "$SLUG" mergify main "$(row 31 "$H1")" ) }
  posts() { grep -c . "$T/posts.txt" 2>/dev/null || true; }

  reset "$(run "$P7099" in_progress '"success"' "$SET")"; ae
  [ "$(posts)" = 1 ] && ok || bad "A1 the #7099 shape must post exactly once (posts $(posts); log: $(cat "$MC_LOG"))"
  grep -q "AUTOENQUEUE $SLUG#31 posted @mergifyio queue" "$MC_LOG" && ok || bad "A1 the log names the post (log: $(cat "$MC_LOG"))"

  reset "$(run "$P7099" in_progress null null)"; ae
  [ "$(posts)" = 0 ] && ok || bad "A2 {in_progress, null} must never post (posts $(posts))"
  grep -q "^aeskip $SLUG#31 $H1 check$" "$MC_ATTEMPTS" && ok || bad "A2 one aeskip check line (attempts: $(cat "$MC_ATTEMPTS"))"
  grep -qF "'$P7099' is in_progress/none on this head" "$MC_LOG" && ok || bad "A2 the skip text names in_progress/none (log: $(cat "$MC_LOG"))"

  reset "$(run "$P7099" in_progress '"success"' "$SET")"; ( unset -f crs_word; ae )
  [ "$(posts)" = 0 ] && ok || bad "A3 crs_word undefined must fail closed (posts $(posts))"

  reset "$(run "$P7099" in_progress '"neutral"' "$SET")"; ae
  [ "$(posts)" = 0 ] && ok || bad "A4 G4 accepts success only: neutral must not post (posts $(posts))"
)

PASS=$(grep -c . "$T/pass"); FAIL=$(grep -c . "$T/fail")
echo "check-run-state.bh-7121: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && [ "$PASS" -gt 0 ]
