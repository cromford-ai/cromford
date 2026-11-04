#!/bin/bash
# tests/merge-conductor-lead-required.bh-8890-test.sh — BH-8890: on a repo with
# the settings row lead_required.<owner>.<name> = 1, a builder APPROVE alone
# never makes a PR READY, and `lead-verdict` success comes only from a real
# lead or human row. On such a repo a builder-only clearance publishes
# `harness-verdict`. With no row (or 0) every context is `lead-verdict`, as
# today (the row-0 rename is the child slice C1 of #8890).
#
# Part A (unit) sources bin/lib/lead-required.sh, bin/lib/verdict-status.sh,
# the fragment bin/merge-conductor.d/bh-8890-lead-required.sh and the conductor
# modules that publish, with their seams stubbed: setting_get from fixture
# files, vd_standing and lead_carry from fixture files, gh_rest records every
# POST, and a fake bin/lead-verdict.sh records every request.
#   L1-L9    lr_required: the row's value table and the per-process memo
#   L10-L16  lr_lead_stands: which standing rows count
#   L17-L22  lr_clear_context: the context a conductor publish uses
#   P1-P4    the rebind and TTL publishers (mc_rebind_publish,
#            mc_vs_ttl_republish) publish the right context
#   G1-G9    the exit paths of mc_lead_req_hold and their side-effect counts
#   S1-S5    the WAIT_LEAD state readers
#   B1-B5    the batch-resolve train: br_member_fenced and
#            br_lead_required_fenced, taken from the shipped bin/batch-resolve.sh
# Part B (whole tick) drives the WHOLE bin/merge-conductor.sh in a scratch tree
# (the fixture of tests/merge-conductor-migration-hold.bh-7785-test.sh part B).
#   W1  lead_required=1, builder APPROVE, no lead row: WAIT_LEAD, 1 request,
#       no label, no queue ask, no status; a second tick asks nothing more
#   W2  lead_required=1 and a lead MERGE on HEAD: READY, enqueued,
#       lead-verdict=success
#   W3  no row (the default): READY, enqueued, lead-verdict=success as today
#   W5  a row for another repo does not hold this one
#   P5  the W1 fixture with the fragment absent (an enqueue that no gate held,
#       as the console Merge button does): enqueued, and the status is
#       harness-verdict, never lead-verdict
#   V1  every curl URL is on a .test host
# 0 network calls: the fake gh and curl are first on PATH.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-lead-required.bh-8890-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: merge-conductor-lead-required: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/lead-required.sh"
FRAG="$DIR/bin/merge-conductor.d/bh-8890-lead-required.sh"
VS="$DIR/bin/lib/verdict-status.sh"
for SRC in "$LIB" "$FRAG" "$VS" "$DIR/bin/merge-conductor.sh"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done

H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40)); H3=$(printf 'c%.0s' $(seq 40))
SLUG=example-org/mk-test
RKEY=lead_required.example-org.mk-test

# ============================================================================
# Part A — the lib, the fragment and the publishers, sourced, seams stubbed.
# In a subshell; it prints its own FAIL lines and exits with its fail count.
# ============================================================================
(
  A="$T/a"; FXD="$A/fx"; mkdir -p "$A/h/bin" "$A/h/state/merge-conductor" "$FXD/set"
  export HARNESS="$A/h" MC_STATE_DIR="$A/h/state/merge-conductor" JOBS_URL=http://worker.test HARNESS_SECRET=fixture-secret
  H="$A/h"
  # The fake request: one line per call; FXD/req-rc is its exit code.
  cat > "$A/h/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FXD/requests"
rc=\$(cat "$FXD/req-rc" 2>/dev/null || echo 0)
[ "\$rc" = 0 ] && echo "requested lead review #7 on \$2#\$3 @ \${4:0:12} (queued)"
[ "\$rc" = 0 ] || echo "lead-verdict: request refused: HTTP 503" >&2
exit "\$rc"
EOF
  chmod +x "$A/h/bin/lead-verdict.sh"
  # Seams, defined BEFORE the libs so their conditional loads keep them.
  # setting_get: FXD/set/<key> is a row; FXD/set/.down is an outage (rc 1).
  setting_get() { echo "$1" >> "$FXD/setting-reads"; [ -e "$FXD/set/.down" ] && return 1
    _setting_key_ok "$1" || return 1; [ -f "$FXD/set/$1" ] || return 2; cat "$FXD/set/$1"; }
  # The real key rule (bin/lib/jobs/settings.sh), so a key over 64 characters
  # is refused here as the box refuses it.
  # shellcheck disable=SC1090
  . <(sed -n '/^_setting_key_ok() {/,/^}/p' "$DIR/bin/lib/jobs/settings.sh")
  # vd_standing: FXD/standing.<head> is the TSV line; FXD/vd-rc forces a rc.
  vd_standing() { echo "$3" >> "$FXD/vd-reads"
    [ -f "$FXD/vd-rc" ] && return "$(cat "$FXD/vd-rc")"
    [ -f "$FXD/standing.$3" ] || return 1; cat "$FXD/standing.$3"; }
  # lead_carry: FXD/carry.<head> is the line a carry would make stand.
  lead_carry() { echo "$4" >> "$FXD/carries"; [ -f "$FXD/carry.$4" ] || return 1; cp "$FXD/carry.$4" "$FXD/standing.$4"; }
  gh_rest() { printf '%s\n' "$*" >> "$FXD/gh.log"; GH_REST_STATUS=201; echo '{"id":1}'; }
  gh_auth_for() { return 0; }
  la_decide() { return 0; }
  # shellcheck source=bin/lib/verdict-status.sh
  . "$VS" || exit 91
  # shellcheck source=bin/lib/lead-required.sh
  if ! . "$LIB" 2>/dev/null; then echo "FAIL: merge-conductor-lead-required: part A: bin/lib/lead-required.sh did not load"; exit 1; fi
  MC_H="$A/h"
  # shellcheck source=bin/lib/mc/classify.sh
  . "$DIR/bin/lib/mc/classify.sh" || exit 93
  # shellcheck source=bin/lib/mc/settle.sh
  . "$DIR/bin/lib/mc/settle.sh" || exit 94
  # shellcheck source=bin/lib/mc/locks.sh
  . "$DIR/bin/lib/mc/locks.sh" || exit 95
  # shellcheck source=bin/merge-conductor.d/bh-8890-lead-required.sh
  . "$FRAG" || exit 96
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  mc_attempt_has() { grep -qxF "$1" "$FXD/attempts" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$FXD/attempts"; }
  mc_la_decide() { return 0; }
  mc_row_field() { echo QUEUED; }
  mc_vs_state_on() { echo pending; }
  F=0; no() { F=$((F+1)); echo "FAIL: merge-conductor-lead-required: $1"; }
  n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
  reset() { scratch_rm "$FXD"; mkdir -p "$FXD/set"; _LR_MEMO=""; }
  row() { printf '%s' "$2" > "$FXD/set/$1"; }
  stand() { printf '%s\tlead\t11\t2026-11-01T08:00:00Z\t-\t-\n' "$2" > "$FXD/standing.$1"; }
  stand_src() { printf '%s\t%s\t12\t2026-11-01T08:00:00Z\t-\t-\n' "$2" "$3" > "$FXD/standing.$1"; }
  # posted_ctx — the context= field of every status POST, one per line.
  posted_ctx() { grep '/statuses/' "$FXD/gh.log" 2>/dev/null | grep -o 'context=[^ ]*' | cut -d= -f2; }

  # ---- L1-L9 lr_required ----
  d() { # d <value|-none|-down> <want rc> <label> [slug]
    reset
    case "$1" in -none) ;; -down) : > "$FXD/set/.down" ;; *) row "$RKEY" "$1" ;; esac
    lr_required "${4:-$SLUG}"; local rc=$?
    [ "$rc" = "$2" ] || no "$3: want rc $2, got $rc"; }
  d 1 0 "L1 the row 1 is required"
  d $' 1\n' 0 "L1b the row ' 1<newline>' is required (whitespace trimmed)"
  d -none 1 "L2 no row is not required (the default)"
  d 0 1 "L3 the row 0 is not required"
  d -down 2 "L4 an unreadable row holds"
  for v in true 01 yes 2 ''; do d "$v" 2 "L5 the value '$v' is not 0/1: held"; done
  d 1 0 "L6 the slug is lowercased" "example-org/TK-TEST"
  reset; row lead_required.example-org.mk-test-os 1; lr_required "$SLUG"; [ "$?" = 1 ] || no "L7 a row for mk-test-os does not apply to mk-test"
  reset; row "$RKEY" 1; lr_required "example-org/mk-test-os"; [ "$?" = 1 ] || no "L7b a row for mk-test does not apply to mk-test-os"
  LONG="example-org/$(printf 'x%.0s' $(seq 60))"
  reset; : > "$FXD/set/.down"; lr_required "$LONG"; [ "$?" = 1 ] && [ "$(n "$FXD/setting-reads")" = 0 ] || no "L8 a key over 64 characters can never be a row: not required, not read"
  reset; row "$RKEY" 1; ( JOBS_URL=""; lr_required "$SLUG"; [ "$?" = 1 ] ) || no "L8b JOBS_URL empty: not required"
  reset; row "$RKEY" 1; ( HARNESS_SECRET=""; lr_required "$SLUG"; [ "$?" = 1 ] ) || no "L8c HARNESS_SECRET empty: not required"
  reset; row "$RKEY" 1; lr_required "$SLUG"; lr_required "$SLUG"; lr_required "$SLUG"
  [ "$(grep -c "^$RKEY\$" "$FXD/setting-reads")" = 1 ] || no "L9 the memo: 1 read for 3 asks ($(n "$FXD/setting-reads"))"
  reset; : > "$FXD/set/.down"; lr_required "$SLUG"; lr_required "$SLUG"
  [ "$(n "$FXD/setting-reads")" = 2 ] || no "L9b an unreadable answer is not memoized ($(n "$FXD/setting-reads") reads)"
  ( unset -f setting_get; _LR_MEMO=""; lr_required "$SLUG"; [ "$?" = 1 ] ) || no "L9c no setting_get loaded: not required"
  lr_required ""; [ "$?" = 1 ] || no "L9d an empty slug is not required"

  # ---- L10-L16 lr_lead_stands ----
  s() { # s <want rc> <label> — fixture set by the caller
    lr_lead_stands "$SLUG#41" "$SLUG" 41 "$H1" >/dev/null; local rc=$?
    [ "$rc" = "$1" ] || no "$2: want rc $1, got $rc"; }
  reset; stand "$H1" MERGE; s 0 "L10 a lead MERGE on HEAD stands"
  reset; stand_src "$H1" MERGE-WITH-NOTES human; s 0 "L11 a human MERGE-WITH-NOTES on HEAD stands"
  reset; stand_src "$H1" MERGE risk-tier; s 1 "L12 a risk-tier MERGE does not count"
  reset; stand_src "$H1" MERGE box; s 1 "L12b a box MERGE does not count"
  reset; stand "$H1" BLOCK; s 1 "L13 a lead BLOCK is not a MERGE"
  [ "$(lr_lead_stands "$SLUG#41" "$SLUG" 41 "$H1")" = "BLOCK lead" ] || no "L13b a standing BLOCK prints its word and source"
  reset; stand "$H2" MERGE; s 1 "L14 a lead MERGE on another head does not stand on HEAD (no carry)"
  [ "$(n "$FXD/carries")" = 1 ] || no "L14b nothing stands: lead_carry is asked once"
  reset; stand "$H2" MERGE; cp "$FXD/standing.$H2" "$FXD/carry.$H1"; s 0 "L15 a carried lead MERGE stands"
  [ "$(n "$FXD/vd-reads")" = 2 ] || no "L15b a carry reads the head again (reads $(n "$FXD/vd-reads"))"
  reset; echo 2 > "$FXD/vd-rc"; s 2 "L16 vd_standing rc 2 is unreadable"
  [ "$(n "$FXD/carries")" = 0 ] || no "L16b unreadable: no carry"
  reset; lr_lead_stands - "$SLUG" 41 "$H1" >/dev/null; [ "$?" = 1 ] && [ "$(n "$FXD/carries")" = 0 ] || no "L16c key '-': no carry"

  # ---- L17-L22 lr_clear_context ----
  p() { # p <want> <label> — LR_CTX after one call
    LR_CTX=unset; lr_clear_context "$SLUG" 41 "$H1"; [ "$LR_CTX" = "$1" ] || no "$2: want $1, got '$LR_CTX'"; }
  reset; row "$RKEY" 1; stand "$H1" MERGE; p lead-verdict "L17 lead_required=1 with a lead MERGE on HEAD"
  reset; row "$RKEY" 1; p harness-verdict "L18 lead_required=1 with no verdict row"
  reset; row "$RKEY" 1; stand_src "$H1" MERGE risk-tier; p harness-verdict "L19 lead_required=1 with a risk-tier MERGE"
  reset; row "$RKEY" 1; stand_src "$H1" APPROVE box; p harness-verdict "L19b lead_required=1 with a box row"
  reset; row "$RKEY" 1; stand "$H2" MERGE; p harness-verdict "L19c lead_required=1 with a lead MERGE on another head only"
  reset; p lead-verdict "L20 no lead_required row: today's context"
  [ "$(n "$FXD/vd-reads")" = 0 ] || no "L20b no row: no verdict read ($(n "$FXD/vd-reads"))"
  reset; row "$RKEY" 0; p lead-verdict "L20c the row 0: today's context"
  reset; : > "$FXD/set/.down"; p harness-verdict "L21 lead_required unreadable: never lead-verdict"
  reset; echo 2 > "$FXD/vd-rc"; row "$RKEY" 1; p harness-verdict "L21b an unreadable lead verdict never gives lead-verdict"
  # stdout stays empty, so a caller can run it in its own shell and keep the memo
  reset; row "$RKEY" 1; [ -z "$(lr_clear_context "$SLUG" 41 "$H1")" ] || no "L22 lr_clear_context prints nothing"
  # vs_publish honours the override and keeps its default
  reset; LEAD_VERDICT_CONTEXT=harness-verdict vs_publish "$SLUG" "$H1" success "x" >/dev/null 2>&1
  vs_publish "$SLUG" "$H1" success "x" >/dev/null 2>&1
  [ "$(posted_ctx | tr '\n' ' ')" = "harness-verdict lead-verdict " ] || no "L22b vs_publish posts the override, then its default ($(posted_ctx | tr '\n' ' '))"

  # ---- P1-P4 the rebind and TTL publishers ----
  ACTIONS=1; MERGES=1; PROVIDER=mergify
  reset; row "$RKEY" 1
  mc_rebind_publish "$SLUG#41" mk "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" "$H2"
  [ "$(posted_ctx)" = harness-verdict ] || no "P1 a rebind with no lead row on lead_required=1 posts harness-verdict (got '$(posted_ctx)')"
  grep -q "VS_REBIND_PUBLISHED $H1 harness-verdict=success" "$FXD/log" || no "P1b the log names the context ($(cat "$FXD/log"))"
  reset; row "$RKEY" 1; stand "$H1" MERGE
  mc_rebind_publish "$SLUG#41" mk "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" "$H2"
  [ "$(posted_ctx)" = lead-verdict ] || no "P2 a rebind with a lead MERGE on the head posts lead-verdict (got '$(posted_ctx)')"
  reset; row "$RKEY" 1
  mc_vs_ttl_republish "$SLUG#41" QUEUED "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" APPROVE "$H1" mergify
  [ "$(posted_ctx)" = harness-verdict ] || no "P3 the TTL republish with no lead row posts harness-verdict (got '$(posted_ctx)')"
  grep -q "VS_REPUBLISHED $H1 harness-verdict=success" "$FXD/log" || no "P3b the log names the context ($(cat "$FXD/log"))"
  reset
  mc_vs_ttl_republish "$SLUG#41" QUEUED "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" APPROVE "$H1" mergify
  [ "$(posted_ctx)" = lead-verdict ] || no "P4 no lead_required row: the TTL republish posts lead-verdict as today (got '$(posted_ctx)')"

  # ---- G1-G9 mc_lead_req_hold ----
  run() { STATE="${ST_X:-READY}"; WHY="clean, approved, checks green"; P=mk; SLUG=example-org/mk-test; NUM=41
    KEY="$SLUG#41"; HEAD="${1:-$H1}"; VERDICT=APPROVE; ACTIONS="${ACTIONS_X:-1}"; KILL="${KILL_X:-0}"; mc_lead_req_hold; }
  # G1 not READY: nothing read
  reset; row "$RKEY" 1; ST_X=WAIT_CI run
  [ "$STATE" = WAIT_CI ] && [ "$(n "$FXD/setting-reads")" = 0 ] && [ "$(n "$FXD/requests")" = 0 ] || no "G1 a row that is not READY is left alone, unread"
  # G2 not required
  reset; run
  [ "$STATE" = READY ] && [ "$(n "$FXD/vd-reads")" = 0 ] && [ "$(n "$FXD/requests")" = 0 ] || no "G2 no row: READY, no verdict read, no request"
  # G3 a lead MERGE stands: READY, one log line per head
  reset; row "$RKEY" 1; stand "$H1" MERGE; run; run
  [ "$STATE" = READY ] && [ "$(n "$FXD/requests")" = 0 ] && [ "$(grep -c 'LEAD_REQUIRED_OK' "$FXD/log")" = 1 ] \
    || no "G3 a lead MERGE: READY, no request, one log line for two ticks (state $STATE, log $(cat "$FXD/log" 2>/dev/null))"
  # G4 the row is unreadable: held, no ask, no mark
  reset; : > "$FXD/set/.down"; run
  [ "$STATE" = WAIT_LEAD ] && [[ $WHY == "WAIT_LEAD lead_required unreadable for $SLUG"* ]] && [ "$(n "$FXD/requests")" = 0 ] && [ "$(n "$FXD/attempts")" = 0 ] \
    || no "G4 unreadable row: WAIT_LEAD, no request, no mark (why '$WHY')"
  # G5 a lead BLOCK stands: held, no ask
  reset; row "$RKEY" 1; stand "$H1" BLOCK; run
  [ "$STATE" = WAIT_LEAD ] && [[ $WHY == *"lead BLOCK stands on ${H1:0:8}"* ]] && [ "$(n "$FXD/requests")" = 0 ] \
    || no "G5 a lead BLOCK: WAIT_LEAD, no request (why '$WHY')"
  # G6 builder-only, first tick: held, mark first, one request, LEAD_REQUESTED
  reset; row "$RKEY" 1; run
  [ "$STATE" = WAIT_LEAD ] && [[ $WHY == "WAIT_LEAD lead_required=1: builder APPROVE on ${H1:0:8}, no lead or human MERGE on this head" ]] \
    && [ "$(n "$FXD/requests")" = 1 ] && [ "$(cat "$FXD/attempts")" = "leadreq $SLUG#41 $H1" ] \
    && grep -q "^request $SLUG 41 $H1 --notes auto: lead_required=1, builder APPROVE on ${H1:0:12}" "$FXD/requests" \
    && grep -q "LEAD_REQUESTED on ${H1:0:8}: requested lead review #7" "$FXD/log" || no "G6 builder-only: WAIT_LEAD, 1 mark, 1 request (why '$WHY'; requests $(cat "$FXD/requests" 2>/dev/null); log $(cat "$FXD/log" 2>/dev/null))"
  # G7 a later tick on the same head: no request; a new head: one more
  run
  [ "$STATE" = WAIT_LEAD ] && [ "$(n "$FXD/requests")" = 1 ] || no "G7 a second tick on one head: no second request ($(n "$FXD/requests"))"
  run "$H3"
  [ "$(n "$FXD/requests")" = 2 ] || no "G7b a new head: one more request ($(n "$FXD/requests"))"
  # G8 observe mode and the kill switch: held, a WOULD line, no mark, no request
  reset; row "$RKEY" 1; ACTIONS_X=0 run
  [ "$STATE" = WAIT_LEAD ] && [ "$(n "$FXD/requests")" = 0 ] && [ "$(n "$FXD/attempts")" = 0 ] && grep -q 'WOULD request a lead review' "$FXD/log" \
    || no "G8 observe: WAIT_LEAD, a WOULD line, no mark, no request"
  reset; row "$RKEY" 1; KILL_X=1 run
  [ "$STATE" = WAIT_LEAD ] && [ "$(n "$FXD/requests")" = 0 ] || no "G8b kill switch: no request"
  reset; row "$RKEY" 1; echo 2 > "$FXD/vd-rc"; run
  [ "$STATE" = WAIT_LEAD ] && [[ $WHY == *"lead verdict unreadable"* ]] && [ "$(n "$FXD/requests")" = 0 ] || no "G8c an unreadable lead row: held, no request (why '$WHY')"
  # G9 a failed request: logged as failed, never as requested; the mark stands
  reset; row "$RKEY" 1; echo 1 > "$FXD/req-rc"; run
  [ "$STATE" = WAIT_LEAD ] && grep -q 'LEAD_REQUEST_FAILED rc=1' "$FXD/log" && ! grep -q 'LEAD_REQUESTED' "$FXD/log" \
    && [ "$(n "$FXD/attempts")" = 1 ] || no "G9 a failed request: LEAD_REQUEST_FAILED, no LEAD_REQUESTED, the mark stands ($(cat "$FXD/log"))"
  run; [ "$(n "$FXD/requests")" = 1 ] || no "G9b a failed request is not retried on that head"

  # ---- S1-S5 the state readers ----
  [ "$(mc_ttl WAIT_LEAD)" = 21600 ] || no "S1 mc_ttl WAIT_LEAD is 21600 (got $(mc_ttl WAIT_LEAD))"
  [ "$(MC_TTL_WAIT_LEAD=60 mc_ttl WAIT_LEAD)" = 60 ] || no "S2 MC_TTL_WAIT_LEAD overrides"
  [ "$(mc_budget WAIT_LEAD)" = 3600 ] && [ "$(MC_BUDGET_WAIT_LEAD=120 mc_budget WAIT_LEAD)" = 120 ] || no "S3 mc_budget WAIT_LEAD is 3600 and MC_BUDGET_WAIT_LEAD overrides"
  [[ $(mc_stuck_waiting_on WAIT_LEAD "x y") == "a lead or human MERGE verdict on this head (x y)" ]] || no "S4 mc_stuck_waiting_on WAIT_LEAD ($(mc_stuck_waiting_on WAIT_LEAD "x y"))"
  reset; stuck_rekick "$SLUG#41" WAIT_LEAD "why" "$SLUG" 41 url "$H1" CLEAN MERGEABLE main main success
  grep -q 'stuck in WAIT_LEAD past its TTL — only a lead or human verdict on this head moves it' "$FXD/log" || no "S4b stuck_rekick names WAIT_LEAD ($(cat "$FXD/log"))"
  ( . "$DIR/bin/lib/mc/log.sh" >/dev/null 2>&1; [[ " $MC_STATES " == *" WAIT_LEAD "* ]] ) || no "S5 MC_STATES has WAIT_LEAD"
  ( HARNESS_DEPLOYMENT_FILE=/dev/null; . "$DIR/bin/lib/stuck-work/classify.sh" >/dev/null 2>&1; [[ $SW_CONDUCTOR_STATES == *" WAIT_LEAD "* ]] ) || no "S5b stuck-work knows WAIT_LEAD"
  ( . "$DIR/bin/lib/utilization/section-prs.sh" >/dev/null 2>&1; [[ " $UTIL_PR_REVIEW_STATES " == *" WAIT_LEAD "* ]] ) || no "S5c utilization counts WAIT_LEAD as review"

  # ---- B1-B5 the batch-resolve train (br_member_fenced) ----
  # The two functions are taken from the SHIPPED bin/batch-resolve.sh and run
  # beside the real lead-required.sh, with the ownership fences stubbed.
  BRF=$(sed -n '/^br_member_fenced() {/,/^}/p; /^br_lead_required_fenced() {/,/^}/p' "$DIR/bin/batch-resolve.sh")
  [[ $BRF == *"br_lead_required_fenced() {"* ]] || no "B0 bin/batch-resolve.sh defines br_lead_required_fenced"
  eval "$BRF"
  PROJECT=mk; LOG="$FXD/br.log"
  say() { printf '%s\n' "$*" >> "$FXD/br.log"; }
  to_lead_authors() { :; }
  to_lane_hold() { [ -f "$FXD/to-hold" ]; }
  to_lane_lead_fence() { return 1; }
  b() { # b <want rc> <label> [head] — br_member_fenced on #41
    br_member_fenced 41 "${3:-$H1}" - </dev/null; local rc=$?
    [ "$rc" = "$1" ] || no "$2: want rc $1, got $rc (log: $(cat "$FXD/br.log" 2>/dev/null))"; }
  reset; row "$RKEY" 1; b 0 "B1 lead_required=1, builder APPROVE only: fenced"
  [ "$(grep -c "^#41 MERGE_HELD lead-required on ${H1:0:12}: lead_required=1 for $SLUG" "$FXD/br.log")" = 1 ] || no "B1b one MERGE_HELD lead-required line ($(cat "$FXD/br.log" 2>/dev/null))"
  reset; row "$RKEY" 1; stand_src "$H1" MERGE risk-tier; b 0 "B1c a risk-tier MERGE does not admit"
  grep -q '(standing: MERGE risk-tier)' "$FXD/br.log" || no "B1d the line names the standing row ($(cat "$FXD/br.log" 2>/dev/null))"
  reset; row "$RKEY" 1; stand "$H2" MERGE; b 0 "B1e a lead MERGE on an older head with another patch does not admit"
  [ "$(n "$FXD/carries")" = 0 ] || no "B1f the train never carries (key -)"
  reset; b 1 "B2 no lead_required row: admitted"
  [ "$(n "$FXD/vd-reads")" = 0 ] && [ ! -s "$FXD/br.log" ] || no "B2b no row: no verdict read, no line"
  reset; row "$RKEY" 0; b 1 "B2c the row 0: admitted"
  reset; row "$RKEY" 1; stand "$H1" MERGE; b 1 "B3 a lead MERGE on the member's head admits it"
  reset; row "$RKEY" 1; stand_src "$H1" MERGE-WITH-NOTES human; b 1 "B3b a human MERGE-WITH-NOTES admits it"
  reset; : > "$FXD/set/.down"; b 0 "B4 an unreadable row: fenced"
  grep -q "^#41 MERGE_HELD lead-required: the lead_required row of $SLUG could not be read" "$FXD/br.log" || no "B4b the unreadable-row line ($(cat "$FXD/br.log" 2>/dev/null))"
  reset; row "$RKEY" yes; b 0 "B4c a value that is not 0/1: fenced"
  reset; row "$RKEY" 1; echo 2 > "$FXD/vd-rc"; b 0 "B4d an unreadable lead verdict: fenced"
  grep -q 'the lead verdict could not be read' "$FXD/br.log" || no "B4e the unreadable-verdict line"
  reset; row "$RKEY" 1; ( unset -f lr_required; br_member_fenced 41 "$H1" - </dev/null; [ "$?" = 1 ] ) || no "B5 lead-required.sh not loaded: admitted"
  reset; row "$RKEY" 1; ( unset -f to_lane_lead_fence; br_member_fenced 41 "$H1" - </dev/null; [ "$?" = 0 ] ) || no "B5b no ownership lib: the lead_required row still fences"
  reset; row "$RKEY" 1; stand "$H1" MERGE; : > "$FXD/to-hold"; b 0 "B5c a HOLD fences before the row is read"
  [ "$(n "$FXD/setting-reads")" = 0 ] || no "B5d a HOLD answers first: the row is not read"
  # a second pass on the same head says the line again (no memo file, r6)
  reset; row "$RKEY" 1; b 0 "B5e pass 1"; _LR_MEMO=""; b 0 "B5e pass 2"
  [ "$(grep -c 'MERGE_HELD lead-required on' "$FXD/br.log")" = 2 ] || no "B5f one line per pass, no say-once file"
  [ ! -e "$A/h/state/lead-required-said" ] || no "B5g no lead-required-said state dir"

  echo "part A: $F failed"
  exit "$F"
)
PA=$?; FAIL=$((FAIL + PA))

# ============================================================================
# Part B — the WHOLE bin/merge-conductor.sh in a scratch tree.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
C="$T/w"; CH="$C/h"; FX="$C/fx"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
( cd "$DIR" && for s in bin/lib/autoenqueue.sh bin/lib/mc-hold-comment.sh bin/lib/gh-repo-token.sh bin/lib/verdict-status.sh; do scratch_install_closure "$s" "$CH" >/dev/null || exit 1; done ) || exit 1
mkdir -p "$C/fakebin" "$FX"
# The fake curl: FX/set/<key> is a settings row; FX/standing.json answers the
# standing verdict read (absent: none stands); the history read has no rows.
cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
FXD="$FX"
out=""; w=""; M=GET; URL=""
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
printf '%s %s\n' "\$M" "\$URL" >> "$C/curl-all.log"
emit() {
  if [ -n "\$out" ]; then printf '%s' "\$2" > "\$out"; else printf '%s' "\$2"; fi
  case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$1" ;; *) printf '%s' "\$1" ;; esac
}
case "\$M \$URL" in
  "GET "*/api/settings/*)
    k="\${URL##*/api/settings/}"
    if [ -f "\$FXD/set/\$k" ]; then emit 200 "\$(jq -nc --arg k "\$k" --arg v "\$(cat "\$FXD/set/\$k")" '{setting:{key:\$k,value:\$v}}')"
    else emit 404 '{"error":"not found"}'; fi ;;
  "GET "*/api/verdicts\?*standing_only=1*)
    echo "\$URL" >> "\$FXD/vd-reads"
    emit 200 "\$(cat "\$FXD/standing.json" 2>/dev/null || echo '{"standing":null}')" ;;
  "GET "*/api/verdicts\?*) emit 200 '{"rows":[],"truncated":false}' ;;
  "GET "*/api/lead-protected-paths*) emit 200 '{"rows":[]}' ;;
  "PUT "*|"POST "*) emit 200 '{"ok":true}' ;;
  *) emit 404 '{"error":"not found"}' ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/curl"
cat > "$CH/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
# install_frag — the fragment and its lib, as the closure of the fragment.
install_frag() { ( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-8890-lead-required.sh "$CH" >/dev/null ); }
install_frag || bad "the fragment's closure did not install"
# The lead request seam: the real script asks the jobs worker with the lead
# token; this one records the call.
cat > "$CH/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/lead-requests.txt"
echo "requested lead review #9 on \$2#\$3 @ \${4:0:12} (queued)"
EOF
chmod +x "$CH/bin/lead-verdict.sh"
printf 'mk %s - - 2 box-m\n' "$SLUG" > "$CH/fleet.conf"
: > "$CH/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
REC="$CH/builds/pool-mk-TK-41-202611010001"; mkdir -p "$REC"
U="https://github.com/$SLUG/pull"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
HD="$H1"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-09-29T10:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*) restpr --raw 200 '{"state":"pending","statuses":[]}' ;;
  *"api -i -X POST repos/$SLUG/statuses/"*) printf '%s\n' "\$*" >> "$FX/status-posts.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X POST repos/$SLUG/issues/41/comments -f body=@mergifyio queue"*) printf '%s\n' "\$*" >> "$FX/queue-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"issues/41/labels"*) printf '%s\n' "\$*" >> "$FX/label-posts.txt"; restpr --raw 200 '[]' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$FX/merges.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$FX/merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$FX/comment-posts.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/$SLUG/issues/41/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[{"filename":"src/a.ts","status":"modified"}]' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*) restpr OPEN "\$HD" ticket/TK-41 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$C/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
cat > "$C/list.json" <<J
[{"number":41,"url":"$U/41","headRefOid":"$H1","headRefName":"ticket/TK-41","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"; chmod +x "$C/fakebin/flock"
touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
# fresh — a clean slate: state, logs, fixture answers and the build record (a
# builder APPROVE bound to H1, the #3501 shape).
fresh() {
  scratch_rm "$CH/state"; scratch_rm "$FX"; mkdir -p "$CH/state" "$FX/set"
  : > "$CH/logs/merge-conductor.log"; : > "$CH/logs/ALERTS.log"
  echo "PR_CREATED $U/41" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
}
tick() {
  ( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$CH" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture \
    JOBS_SETTINGS_CACHE_S=0 MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    "$@" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$C/tick.err"; }
}
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
clog() { grep -E '#41' "$CH/logs/merge-conductor.log" | tail -"${1:-6}"; }
crow() { awk -F'\t' -v k="$SLUG#41" '$1==k' "$CH/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
ctx() { grep -o 'context=[^ ]*' "$FX/status-posts.txt" 2>/dev/null | cut -d= -f2 | sort -u | tr '\n' ' '; }
lead_merge() { jq -nc --arg h "$H1" '{standing:{verdict:"MERGE",source:"lead",id:31,created_at:"2026-11-01T08:00:00Z",head_sha:$h}}' > "$FX/standing.json"; }

# W1 — lead_required=1, builder APPROVE on HEAD, no lead row (#3501).
fresh; echo 1 > "$FX/set/$RKEY"; tick
[ "$(cut -f2 <<<"$(crow)")" = WAIT_LEAD ] && grep -q $'\tWAIT_LEAD lead_required=1: builder APPROVE on '"${H1:0:8}" <<<"$(crow)" && ok \
  || bad "W1 the stored row is WAIT_LEAD (row: $(crow); log: $(clog))"
[ "$(n "$FX/lead-requests.txt")" = 1 ] && grep -q "^request $SLUG 41 $H1 --notes " "$FX/lead-requests.txt" && ok \
  || bad "W1 exactly one lead request for (repo, pr, head) (requests: $(cat "$FX/lead-requests.txt" 2>/dev/null))"
[ "$(n "$FX/queue-posts.txt")" = 0 ] && [ "$(n "$FX/label-posts.txt")" = 0 ] && [ "$(n "$FX/merges.txt")" = 0 ] && ok \
  || bad "W1 no @mergifyio queue, no label, no merge (queue $(n "$FX/queue-posts.txt"), labels $(n "$FX/label-posts.txt"))"
[ "$(n "$FX/status-posts.txt")" = 0 ] && ok || bad "W1 no commit status at all (posts: $(cat "$FX/status-posts.txt" 2>/dev/null))"
grep -q "#41 LEAD_REQUESTED on ${H1:0:8}" "$CH/logs/merge-conductor.log" && ok || bad "W1 the LEAD_REQUESTED log line (log: $(clog))"
tick
[ "$(n "$FX/lead-requests.txt")" = 1 ] && [ "$(n "$FX/queue-posts.txt")" = 0 ] && [ "$(cut -f2 <<<"$(crow)")" = WAIT_LEAD ] && ok \
  || bad "W1 a second tick on the same head: still WAIT_LEAD, 0 more requests ($(n "$FX/lead-requests.txt"))"

# W2 — lead_required=1 and a lead MERGE on HEAD: READY, enqueued, lead-verdict.
fresh; echo 1 > "$FX/set/$RKEY"; lead_merge; tick
[ "$(n "$FX/queue-posts.txt")" = 1 ] && [ "$(n "$FX/lead-requests.txt")" = 0 ] && ok \
  || bad "W2 a lead MERGE on HEAD is enqueued with no request (queue $(n "$FX/queue-posts.txt"), requests $(n "$FX/lead-requests.txt"); log: $(clog))"
[ "$(ctx)" = "lead-verdict " ] && grep -q 'state=success' "$FX/status-posts.txt" && ok \
  || bad "W2 lead-verdict=success is published (contexts '$(ctx)'; posts $(cat "$FX/status-posts.txt" 2>/dev/null))"

# W3 — no row (the default): READY, enqueued, lead-verdict=success, as today.
fresh; tick
[ "$(n "$FX/queue-posts.txt")" = 1 ] && [ "$(ctx)" = "lead-verdict " ] && [ "$(n "$FX/lead-requests.txt")" = 0 ] && ok \
  || bad "W3 no row: enqueued with lead-verdict, no request (queue $(n "$FX/queue-posts.txt"), contexts '$(ctx)')"
! grep -q 'WAIT_LEAD\|LEAD_REQUIRED_OK' "$CH/logs/merge-conductor.log" && ok || bad "W3 no row: the gate logs nothing (log: $(clog))"

# W5 — a row for another repo does not hold this one.
fresh; echo 1 > "$FX/set/lead_required.example-org.mk-test-os"; tick
[ "$(n "$FX/queue-posts.txt")" = 1 ] && [ "$(n "$FX/lead-requests.txt")" = 0 ] && ok \
  || bad "W5 a row for mk-test-os leaves mk-test as today (queue $(n "$FX/queue-posts.txt"))"

# P5 — the W1 fixture with the fragment absent is enqueued: the gate is what
# holds. merge-conductor-lib.sh still loads bin/lib/lead-required.sh, so this
# ungated enqueue (the console Merge button's shape) publishes harness-verdict.
scratch_rm "$CH/bin/merge-conductor.d"
fresh; echo 1 > "$FX/set/$RKEY"; tick
[ "$(n "$FX/queue-posts.txt")" = 1 ] && [ "$(n "$FX/lead-requests.txt")" = 0 ] && ok \
  || bad "P5 without the fragment the W1 PR is enqueued (queue $(n "$FX/queue-posts.txt"))"
[ "$(ctx)" = "harness-verdict " ] && ok || bad "P5 a builder-only enqueue on lead_required=1 publishes harness-verdict, never lead-verdict (contexts '$(ctx)')"

# V1 — every curl went to a .test host.
[ -s "$C/curl-all.log" ] && ok || bad "V1 the fake curl saw no call at all"
OUT=$(awk '{print $2}' "$C/curl-all.log" 2>/dev/null | grep -vE '^https?://[a-z0-9.-]+\.test(/|$)' || true)
[ -z "$OUT" ] && ok || bad "V1 a curl left the fixture hosts: $OUT"

echo "merge-conductor-lead-required: part B $PASS passed; $FAIL failed in all (part A counted above)"
[ "$FAIL" -eq 0 ]
