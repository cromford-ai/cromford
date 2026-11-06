#!/bin/bash
# tests/verdict-builder-context.bh-9039-test.sh — BH-9039 (slice C1 of #8890):
# a builder-only clearance publishes `harness-verdict` on EVERY repo, the row-0
# default included. `lead-verdict` comes only from a lead or human MERGE /
# MERGE-WITH-NOTES standing on the head. cromford's own queue accepts
# either context, and a lead BLOCK (`lead-verdict=failure`) still holds the PR.
#
# Part A (unit, a subshell) sources the REAL bin/lib/verdict-status.sh,
# bin/lib/lead-required.sh and the conductor modules, with only the transports
# stubbed: setting_get, vd_standing and lead_carry from fixture files, gh_rest
# answers a combined status from FXD/status.<sha> and records every POST.
#   C1-C8   lr_clear_context: the context a conductor publish uses (C1 is RED
#           on main: a row-0 repo answered lead-verdict with no verdict read)
#   V1-V10  vs_clear_row: the queue clearance on a combined-status body
#   R1-R3   mc_vs_success_on, mc_vs_state_on, mc_vs_ttl_republish
#   R5      mc_rebind_publish on row 0, and its carry gate
#   R6      mc_enqueue_mergify on row 0 (the console Merge button's path)
# Part C (unit) the other readers:
#   R4      landing_eligible step 7
#   R7      lsr_sweep --dry-run
#   R8      stuck-work facts columns 6 and 7, and pipeline-health's LUAT jq
# Part M (the renderer and the repo's queue):
#   M1-M7   bin/mergify-template.sh status_check_any, cromford.conf,
#           .mergify.yml, and the four check-run parsers
# 0 network calls: every transport is a shell function or a file.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/verdict-builder-context.bh-9039-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0
bad() { FAIL=$((FAIL+1)); echo "FAIL: verdict-builder-context: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40))
SLUG=example-org/bh9039-test
RKEY=lead_required.example-org.bh9039-test
VS="$DIR/bin/lib/verdict-status.sh"
LIB="$DIR/bin/lib/lead-required.sh"

# body <ctx>=<state>[@<iso>] ... — a combined-status body on stdout.
body() {
  local a out='[]' c s t
  for a in "$@"; do
    c=${a%%=*}; s=${a#*=}; t=2026-11-04T10:00:00Z
    case "$s" in *@*) t=${s#*@}; s=${s%%@*} ;; esac
    out=$(jq -c --arg c "$c" --arg s "$s" --arg t "$t" '. + [{context:$c, state:$s, updated_at:$t, description:("d " + $c)}]' <<<"$out")
  done
  jq -nc --argjson s "$out" '{state:"pending", statuses:$s}'
}

# ============================================================================
# Part A — lr_clear_context, vs_clear_row and the conductor's readers.
# ============================================================================
(
  A="$T/a"; FXD="$A/fx"; mkdir -p "$A/h/state/merge-conductor" "$FXD/set"
  export HARNESS="$A/h" MC_STATE_DIR="$A/h/state/merge-conductor" JOBS_URL=http://worker.test HARNESS_SECRET=fixture-secret
  setting_get() { echo "$1" >> "$FXD/setting-reads"; [ -e "$FXD/set/.down" ] && return 1
    [ -f "$FXD/set/$1" ] || return 2; cat "$FXD/set/$1"; }
  vd_standing() { echo "$3" >> "$FXD/vd-reads"
    [ -f "$FXD/vd-rc" ] && return "$(cat "$FXD/vd-rc")"
    [ -f "$FXD/standing.$3" ] || return 1; cat "$FXD/standing.$3"; }
  lead_carry() { echo "$4" >> "$FXD/carries"; return 1; }
  gh_rest() {
    printf '%s\n' "$*" >> "$FXD/gh.log"
    case "$1 $2" in
      "GET repos/"*"/commits/"*"/status")
        local h=${2%/status}; h=${h##*/}
        GH_REST_STATUS=200
        if [ -f "$FXD/status.$h" ]; then cat "$FXD/status.$h"; else echo '{"state":"pending","statuses":[]}'; fi ;;
      POST*) GH_REST_STATUS=201; echo '{"id":1}' ;;
      *) GH_REST_STATUS=404; return 1 ;;
    esac
  }
  gh_auth_for() { return 0; }
  la_decide() { return 0; }
  # shellcheck source=bin/lib/verdict-status.sh
  . "$VS" || exit 91
  # shellcheck source=bin/lib/lead-required.sh
  . "$LIB" || exit 92
  MC_H="$A/h"
  # shellcheck source=bin/lib/mc/classify.sh
  . "$DIR/bin/lib/mc/classify.sh" || exit 93
  # shellcheck source=bin/lib/mc/settle.sh
  . "$DIR/bin/lib/mc/settle.sh" || exit 94
  # shellcheck source=bin/lib/mc/queue.sh
  . "$DIR/bin/lib/mc/queue.sh" || exit 95
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  mc_attempt_has() { grep -qxF "$1" "$FXD/attempts" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$FXD/attempts"; }
  mc_la_decide() { return 0; }
  mc_row_field() { cat "$FXD/row-state" 2>/dev/null || echo QUEUED; }
  F=0; no() { F=$((F+1)); echo "FAIL: verdict-builder-context: $1"; }
  n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
  reset() { scratch_rm "$FXD"; mkdir -p "$FXD/set"; _LR_MEMO=""; }
  row() { printf '%s' "$2" > "$FXD/set/$1"; }
  stand_src() { printf '%s\t%s\t12\t2026-11-04T08:00:00Z\t-\t-\n' "$2" "$3" > "$FXD/standing.$1"; }
  status_on() { local h="$1"; shift; body "$@" > "$FXD/status.$h"; }
  posted_ctx() { grep '/statuses/' "$FXD/gh.log" 2>/dev/null | grep -o 'context=[^ ]*' | cut -d= -f2; }

  # ---- C1-C8 lr_clear_context ----
  p() { LR_CTX=unset; lr_clear_context "$SLUG" 41 "$H1"; [ "$LR_CTX" = "$1" ] || no "$2: want $1, got '$LR_CTX'"; }
  reset; p harness-verdict "C1 no lead_required row, no verdict row: a builder-only clearance"
  [ "$(n "$FXD/vd-reads")" = 1 ] || no "C1b no row: exactly 1 verdict read ($(n "$FXD/vd-reads"))"
  reset; row "$RKEY" 0; stand_src "$H1" APPROVE box; p harness-verdict "C2 row 0, a box APPROVE on HEAD"
  reset; stand_src "$H1" MERGE risk-tier; p harness-verdict "C3 row 0, a risk-tier MERGE on HEAD"
  reset; stand_src "$H2" MERGE lead; p harness-verdict "C4 row 0, a lead MERGE on an older head only"
  reset; echo 2 > "$FXD/vd-rc"; p harness-verdict "C5 row 0, vd_standing rc 2"
  reset; stand_src "$H1" MERGE lead
  ( unset -f vd_standing; LR_CTX=unset; lr_clear_context "$SLUG" 41 "$H1"; [ "$LR_CTX" = harness-verdict ] ) || no "C5b vd_standing not loaded: harness-verdict"
  reset; : > "$FXD/set/.down"; p harness-verdict "C5c the lead_required row unreadable"
  reset; stand_src "$H1" MERGE lead; p lead-verdict "C6 row 0, a lead MERGE on HEAD"
  reset; stand_src "$H1" MERGE-WITH-NOTES human; p lead-verdict "C7 row 0, a human MERGE-WITH-NOTES on HEAD"
  reset; stand_src "$H1" BLOCK lead; p harness-verdict "C7b row 0, a lead BLOCK on HEAD"
  reset; row "$RKEY" 1; stand_src "$H1" BLOCK lead; p harness-verdict "C8 row 1, a lead BLOCK on HEAD"
  reset; row "$RKEY" 1; stand_src "$H1" MERGE lead; p lead-verdict "C8b row 1, a lead MERGE on HEAD"
  [ "$(vs_builder_context 2>/dev/null)" = harness-verdict ] || no "C8c vs_builder_context prints harness-verdict"

  # ---- V1-V10 vs_clear_row ----
  v() { # v <want state> <want at|-any> <label> <ctx=state>...
    local want="$1" at="$2" label="$3" out rc=0; shift 3
    body "$@" > "$FXD/v.json"; out=$(vs_clear_row "$FXD/v.json") || rc=$?
    [ "$rc" = 0 ] || { no "$label: rc $rc"; return; }
    [ "$(cut -f1 <<<"$out")" = "$want" ] || no "$label: want state $want, got '$(cut -f1 <<<"$out")'"
    [ "$at" = -any ] || [ "$(cut -f2 <<<"$out")" = "$at" ] || no "$label: want updated_at $at, got '$(cut -f2 <<<"$out")'"; }
  reset
  v success -any "V1 lead success, harness absent" lead-verdict=success
  v success 2026-11-04T11:11:11Z "V2 lead absent, harness success" ci=failure harness-verdict=success@2026-11-04T11:11:11Z
  v failure -any "V3 lead failure vetoes harness success" lead-verdict=failure harness-verdict=success
  v success 2026-11-04T12:00:00Z "V4 lead pending, harness success" lead-verdict=pending@2026-11-04T09:00:00Z harness-verdict=success@2026-11-04T12:00:00Z
  v success -any "V5 both success" lead-verdict=success harness-verdict=success
  v error -any "V6 lead error vetoes harness success" harness-verdict=success lead-verdict=error
  v pending -any "V7 lead pending, harness absent" lead-verdict=pending
  v - - "V8 both absent" ci=success
  v failure -any "V8b harness failure only" harness-verdict=failure
  v - - "V9 a prequeue-verdict success only" prequeue-verdict=success
  v - - "V9b a lead-verdict-old success (partial name)" lead-verdict-old=success harness-verdict-x=success
  echo '{"state":"pending"}' > "$FXD/v.json"; vs_clear_row "$FXD/v.json" >/dev/null 2>&1; [ "$?" = 2 ] || no "V10 no statuses array: rc 2"
  echo 'not json' > "$FXD/v.json"; vs_clear_row "$FXD/v.json" >/dev/null 2>&1; [ "$?" = 2 ] || no "V10b not JSON: rc 2"
  vs_clear_row "$FXD/none.json" >/dev/null 2>&1; [ "$?" = 2 ] || no "V10c no file: rc 2"

  # ---- R1 mc_vs_success_on ----
  reset; status_on "$H1" harness-verdict=success
  mc_vs_success_on "$SLUG" "$H1"; [ "$?" = 0 ] || no "R1 harness-verdict success only: cleared (rc 0)"
  status_on "$H1" lead-verdict=failure harness-verdict=success
  mc_vs_success_on "$SLUG" "$H1"; [ "$?" = 1 ] || no "R1b lead failure + harness success: not cleared (rc 1)"
  echo '{}' > "$FXD/status.$H1"; mc_vs_success_on "$SLUG" "$H1"; [ "$?" = 2 ] || no "R1c no statuses array: rc 2"
  # ---- R2 mc_vs_state_on ----
  status_on "$H1" harness-verdict=success
  [ "$(mc_vs_state_on "$SLUG" "$H1")" = success ] || no "R2 no context argument, harness success only: success ($(mc_vs_state_on "$SLUG" "$H1"))"
  [ "$(mc_vs_state_on "$SLUG" "$H1" prequeue-verdict)" = absent ] || no "R2b an explicit prequeue-verdict reads that context only"
  status_on "$H1" prequeue-verdict=success
  [ "$(mc_vs_state_on "$SLUG" "$H1")" = absent ] || no "R2c prequeue-verdict alone is not the clearance (absent)"
  [ "$(mc_vs_state_on "$SLUG" "$H1" prequeue-verdict)" = success ] || no "R2d the explicit context path does not change"

  # ---- R3 the TTL republish on row 0 ----
  ACTIONS=1; MERGES=1
  reset
  mc_vs_ttl_republish "$SLUG#41" QUEUED "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" APPROVE "$H1" mergify
  [ "$(posted_ctx | tr '\n' ' ')" = "harness-verdict " ] || no "R3 the TTL republish on row 0 posts harness-verdict once (got '$(posted_ctx | tr '\n' ' ')')"
  grep -q "VS_REPUBLISHED $H1 harness-verdict=success" "$FXD/log" || no "R3b the log names harness-verdict ($(cat "$FXD/log" 2>/dev/null))"
  reset; status_on "$H1" harness-verdict=success
  mc_vs_ttl_republish "$SLUG#41" QUEUED "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" APPROVE "$H1" mergify
  [ -z "$(posted_ctx)" ] || no "R3c a head with harness-verdict success: 0 POSTs (got '$(posted_ctx)')"
  grep -q "is already success on ${H1:0:8}" "$FXD/log" || no "R3d the 'already success' line ($(cat "$FXD/log" 2>/dev/null))"

  # ---- R5 the rebind on row 0 ----
  PROVIDER=mergify
  reset
  mc_rebind_publish "$SLUG#41" bh "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" "$H2"
  [ "$(posted_ctx | tr '\n' ' ')" = "harness-verdict " ] || no "R5 a rebind on row 0 with no lead row posts harness-verdict (got '$(posted_ctx | tr '\n' ' ')')"
  grep -q "VS_REBIND_PUBLISHED $H1 harness-verdict=success" "$FXD/log" || no "R5b the rebind log names harness-verdict ($(cat "$FXD/log" 2>/dev/null))"
  reset; echo READY > "$FXD/row-state"; status_on "$H2" harness-verdict=success
  mc_rebind_publish "$SLUG#41" bh "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" "$H2"
  [ "$(posted_ctx | tr '\n' ' ')" = "harness-verdict " ] || no "R5c the carry gate reads harness-verdict success on the old head as success (log $(cat "$FXD/log" 2>/dev/null))"
  reset; echo READY > "$FXD/row-state"; status_on "$H2" lead-verdict=failure harness-verdict=success
  mc_rebind_publish "$SLUG#41" bh "$SLUG" 41 "https://github.com/$SLUG/pull/41" "$H1" "$H2"
  [ -z "$(posted_ctx)" ] && grep -q "not carried to ${H1:0:8}" "$FXD/log" || no "R5d a lead BLOCK on the old head is not carried (posts '$(posted_ctx)')"

  # ---- R6 mc_enqueue_mergify on row 0 ----
  prr_write() { printf '%s\n' "$*" >> "$FXD/writes"; return 0; }
  mc_mergify_ask_file() { echo "$FXD/ask"; }
  mc_mergify_ask_due() { return 1; }
  mc_queue_state() { echo queued; }
  mc_mergify_witness() { return 0; }
  mc_status_unpublished_alert() { echo "alert" >> "$FXD/alerts"; }
  qp_enqueue_step() { return 0; }; qff_enqueue_step() { return 0; }; qr_enqueue_step() { return 0; }
  lsr_dismiss_on_enqueue() { return 0; }
  reset; rc=0
  mc_enqueue_mergify "$SLUG" "https://github.com/$SLUG/pull/41" "$H1" >/dev/null 2>"$FXD/enq.err" || rc=$?
  [ "$rc" = 0 ] || no "R6 the enqueue answers rc 0 (rc $rc: $(cat "$FXD/enq.err"))"
  [ "$(posted_ctx | tr '\n' ' ')" = "harness-verdict " ] || no "R6b one statuses POST, context harness-verdict (got '$(posted_ctx | tr '\n' ' ')')"
  [ "$(posted_ctx | grep -c '^lead-verdict$')" = 0 ] || no "R6c 0 lead-verdict POSTs for a builder-only clearance"
  reset; stand_src "$H1" MERGE lead
  mc_enqueue_mergify "$SLUG" "https://github.com/$SLUG/pull/41" "$H1" >/dev/null 2>&1
  [ "$(posted_ctx | tr '\n' ' ')" = "lead-verdict " ] || no "R6d a lead MERGE on HEAD: the enqueue posts lead-verdict (got '$(posted_ctx | tr '\n' ' ')')"

  echo "part A: $F failed"
  exit "$F"
)
FAIL=$((FAIL + $?))

# ============================================================================
# Part C — landing step 7, the stale-review sweep, the stuck-work facts and
# pipeline-health's lead-merge-unqueued read.
# ============================================================================
(
  C="$T/c"; mkdir -p "$C/state/prequeue" "$C/fx"
  F=0; no() { F=$((F+1)); echo "FAIL: verdict-builder-context: $1"; }
  REPO=example-org/landing-9039; PR=9039
  # ---- R4 landing_eligible step 7 ----
  (
    export MC_STATE_DIR="$C/state" LANDING_NOW=2000000000
    # shellcheck source=bin/lib/verdict-status.sh
    gh_auth_for() { return 0; }; la_decide() { return 0; }
    . "$VS" || exit 1
    # shellcheck source=bin/lib/mc/landing.sh
    . "$DIR/bin/lib/mc/landing.sh" || exit 1
    unset -f lane_knob ae_mergify_admit_checks 2>/dev/null
    main_red_flag() { return 1; }
    printf 'green %s run s1\n' $((2000000000 - 60)) > "$C/state/prequeue/${REPO//\//_}_${PR}_${H1}_main"
    _jobs_req() { printf '{"rows":[{"head_sha":"%s","tier":"low"}]}\n' "$H1"; }
    gh_rest() { GH_REST_STATUS=200; cat "$C/fx/status.json"; }
    G=0
    e() { # e <want reason> <label> <ctx=state>...
      local want="$1" label="$2"; shift 2; body "$@" > "$C/fx/status.json"
      LANDING_REASON=""; landing_eligible "$REPO" "$PR" "$H1" landing "" >/dev/null 2>&1
      [ "$LANDING_REASON" = "$want" ] || { G=$((G+1)); echo "FAIL: verdict-builder-context: $label: want $want, got '$LANDING_REASON'"; }; }
    # Step 8 refuses unreadable-checks with no admit reader: that proves step 7 passed.
    e unreadable-checks "R4 landing step 7 passes on harness-verdict success only" harness-verdict=success
    e lead-verdict "R4b landing step 7 refuses lead-verdict failure + harness success" lead-verdict=failure harness-verdict=success
    e lead-verdict "R4c landing step 7 refuses no clearance at all" ci=success
    e unreadable-checks "R4d landing step 7 passes on lead-verdict success (as today)" lead-verdict=success
    exit "$G"
  ) || F=$((F + $?))

  # ---- R7 lsr_sweep --dry-run ----
  (
    # shellcheck source=bin/lib/lead-stale-review.sh
    . "$DIR/bin/lib/lead-stale-review.sh" || exit 1
    gh_rest() {
      GH_REST_STATUS=200
      case "$2" in
        repos/*/pulls\?state=open*) printf '[{"number":%s,"draft":false,"head":{"sha":"%s"}}]\n' "$PR" "$H1" ;;
        repos/*/commits/*/status) cat "$C/fx/lsr-status.json" ;;
        repos/*/pulls/*/reviews*) printf '[{"id":77,"state":"CHANGES_REQUESTED","commit_id":"%s","body":"BLOCK <!-- lead-review:5 -->","user":{"login":"cromford[bot]","type":"Bot"}}]\n' "$H2" ;;
        *) GH_REST_STATUS=404; return 1 ;;
      esac
    }
    G=0
    body harness-verdict=success > "$C/fx/lsr-status.json"
    out=$(lsr_sweep "$REPO" --dry-run 2>&1)
    grep -q "^$REPO#$PR would dismiss review 77 on ${H2:0:12} (head ${H1:0:12}" <<<"$out" \
      || { G=$((G+1)); echo "FAIL: verdict-builder-context: R7 the sweep sees a harness-verdict head as cleared (out: $out)"; }
    body lead-verdict=failure harness-verdict=success > "$C/fx/lsr-status.json"
    out=$(lsr_sweep "$REPO" --dry-run 2>&1)
    ! grep -q "would dismiss" <<<"$out" || { G=$((G+1)); echo "FAIL: verdict-builder-context: R7b a lead BLOCK head is not swept (out: $out)"; }
    exit "$G"
  ) || F=$((F + $?))

  # ---- R8 stuck-work facts columns 6, 7 ----
  mkdir -p "$C/sw/gh" "$C/sw/h/logs" "$C/sw/shim"
  printf '#!/bin/bash\nexit 1\n' > "$C/sw/shim/gh"; chmod +x "$C/sw/shim/gh"
  cat > "$C/sw/prelude.sh" <<EOF
. "$DIR/bin/lib/gh-rest.sh"
. "$DIR/bin/lib/gh-rest-list.sh"
gh_auth_for() { return 0; }; la_decide() { return 0; }
. "$DIR/bin/lib/verdict-status.sh"
. "$DIR/bin/lib/stuck-work/facts-pr.sh"
gh_rest() {
  local f="$C/sw/gh/\${2//\//_}"; GH_REST_STATUS=200
  if [ -f "\$f" ]; then cat "\$f"; return 0; fi
  case "\$2" in */status) echo '{"state":"pending","statuses":[]}' ;; */check-runs) echo '{"total_count":0,"check_runs":[]}' ;; *) GH_REST_STATUS=404; return 44 ;; esac
}
EOF
  jq -nc --arg h "$H1" '[{number:41, html_url:"https://github.com/o/r/pull/41", draft:false, created_at:"2026-11-04T08:00:00Z", head:{sha:$h}, labels:[]}]' > "$C/sw/gh/repos_o_r_pulls"
  facts() {
    env -i PATH="$C/sw/shim:$PATH" HOME="$C/sw" HARNESS="$C/sw/h" HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW=1793800000 PR_SNAPSHOT=0 \
      bash -c ". '$C/sw/prelude.sh'; swf_pr_facts o/r" 2>/dev/null | awk -F'\t' '$2 == "o/r#41" {print $6"|"$7}'
  }
  body harness-verdict=success@2026-11-04T10:00:00Z > "$C/sw/gh/repos_o_r_commits_${H1}_status"
  want="success|$(date -u -d 2026-11-04T10:00:00Z +%s)"
  got=$(facts)
  [ "$got" = "$want" ] || no "R8 facts columns 6,7 on a harness-verdict head: want '$want', got '$got'"
  body lead-verdict=failure harness-verdict=success > "$C/sw/gh/repos_o_r_commits_${H1}_status"
  got=$(facts)
  [ "${got%%|*}" = failure ] || no "R8b facts column 6 on lead failure + harness success: want failure, got '$got'"
  # pipeline-health's LUAT jq, taken from the shipped script and run on the body.
  LUJQ=$(awk '/^ *LUAT=\$\(printf/ {on=1} on {print} on && /2>\/dev\/null\)/ {exit}' "$DIR/bin/pipeline-health.sh" | sed '$ s/[[:space:]]*\\$//')
  [ -n "$LUJQ" ] || no "R8c the LUAT read was not found in bin/pipeline-health.sh"
  luat() { local LUST="$1" LUAT=""; eval "$LUJQ" || LUAT="(jq failed)"; printf '%s' "$LUAT"; }
  got=$(luat "$(body harness-verdict=success@2026-11-04T10:00:00Z)")
  [ "$got" = 2026-11-04T10:00:00Z ] || no "R8d LUAT on a harness-verdict success: want its updated_at, got '$got'"
  got=$(luat "$(body lead-verdict=failure harness-verdict=success)")
  [ -z "$got" ] || no "R8e LUAT on lead failure + harness success: want '', got '$got'"
  got=$(luat "$(body lead-verdict=success@2026-11-04T09:00:00Z)")
  [ "$got" = 2026-11-04T09:00:00Z ] || no "R8f LUAT on a lead-verdict success (as today): got '$got'"
  echo "part C: $F failed"
  exit "$F"
)
FAIL=$((FAIL + $?))

# ============================================================================
# Part M — the renderer key status_check_any and the repo's queue.
# ============================================================================
(
  F=0; no() { F=$((F+1)); echo "FAIL: verdict-builder-context: $1"; }
  MT="$DIR/bin/mergify-template.sh"
  CONF="$DIR/config/mergify/repos/cromford.conf"
  # The PyYAML skip/CI-fail pattern of tests/hotfix-mergify-template-test.sh
  # (BH-1741): a CI runner without PyYAML is a counted failure, never a skip.
  if ! { command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; }; then
    [ "${CI:-}" = true ] && { echo "FAIL: verdict-builder-context: part M PyYAML missing under CI=true"; exit 1; }
    echo "part M: PyYAML missing — skipped on this dev machine"; exit 0
  fi
  M="$T/m"; mkdir -p "$M"
  # ---- M1 the cromford render ----
  "$MT" render "$CONF" > "$M/bh.yml" 2>"$M/bh.err" || no "M1 the cromford conf renders ($(cat "$M/bh.err"))"
  python3 - "$M/bh.yml" > "$M/m1.out" 2>&1 <<'PY' || no "M1 the verdict conditions per queue: $(cat "$M/m1.out")"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
want = ["check-success~=^(lead-verdict|harness-verdict)$", "-check-failure=lead-verdict", "-check-failure=harness-verdict"]
q = {r["name"]: r for r in d["queue_rules"]}
bad = []
for name in ("hotfix", "flake-fix", "solo", "default"):
    if name not in q:
        bad.append("no queue %s" % name); continue
    qc = [str(x) for x in q[name]["queue_conditions"]]
    mc = [str(x) for x in q[name].get("merge_conditions", [])]
    if [x for x in qc if x in want] != want:
        bad.append("%s queue_conditions: %r" % (name, [x for x in qc if "verdict" in x]))
    if any("check-success=lead-verdict" == x.replace(" ", "") for x in qc):
        bad.append("%s still has a plain check-success=lead-verdict" % name)
    if any("verdict" in x for x in mc):
        bad.append("%s merge_conditions carry a verdict condition" % name)
print("; ".join(bad))
sys.exit(1 if bad else 0)
PY
  # ---- M2 a conf without the key renders as before ----
  for c in project-5 project-3 project-2; do
    "$MT" render "$DIR/config/mergify/repos/$c.conf" > "$M/$c.yml" 2>/dev/null || no "M2 $c renders"
    ! grep -qE 'check-failure|~=' "$M/$c.yml" || no "M2b $c renders no veto and no regex condition"
  done
  BASE=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null || true)
  if [ -n "$BASE" ] && git -C "$DIR" show "$BASE:bin/mergify-template.sh" > /dev/null 2>&1; then
    mkdir -p "$M/base/bin" "$M/base/config/mergify"
    git -C "$DIR" show "$BASE:bin/mergify-template.sh" > "$M/base/bin/mergify-template.sh"; chmod +x "$M/base/bin/mergify-template.sh"
    git -C "$DIR" show "$BASE:config/mergify/template.yml" > "$M/base/config/mergify/template.yml"
    for c in project-5 project-3 project-2; do
      "$M/base/bin/mergify-template.sh" render "$DIR/config/mergify/repos/$c.conf" > "$M/$c.base.yml" 2>/dev/null
      cmp -s "$M/$c.yml" "$M/$c.base.yml" || no "M2c $c renders byte for byte as the merge-base renderer"
    done
  else
    echo "part M: no merge base with origin/main — M2c byte comparison not run"
  fi
  # ---- M3 the queue rule agrees with vs_clear_row on the D2 table ----
  (
    gh_auth_for() { return 0; }; la_decide() { return 0; }
    # shellcheck source=bin/lib/verdict-status.sh
    . "$VS" || exit 1
    G=0
    for case in "lead-verdict=success" "harness-verdict=success" "lead-verdict=pending harness-verdict=success" \
                "lead-verdict=success harness-verdict=success" "lead-verdict=failure harness-verdict=success" \
                "lead-verdict=error harness-verdict=success" "lead-verdict=pending" "ci=success" "harness-verdict=failure" \
                "prequeue-verdict=success" "lead-verdict-old=success"; do
      # shellcheck disable=SC2086
      body $case > "$M/d2.json"
      s=$(vs_clear_row "$M/d2.json" | cut -f1); [ "$s" = success ] && mine=1 || mine=0
      theirs=$(python3 - "$M/bh.yml" "$M/d2.json" <<'PY'
import json, re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
st = {s["context"]: s["state"] for s in json.load(open(sys.argv[2]))["statuses"]}
succ = [c for c, s in st.items() if s == "success"]
fail = [c for c, s in st.items() if s in ("failure", "error")]
q = [r for r in d["queue_rules"] if r["name"] == "default"][0]
ok = True
for c in (str(x) for x in q["queue_conditions"]):
    if "verdict" not in c:
        continue
    m = re.fullmatch(r"check-success~=(.*)", c)
    if m:
        ok = ok and any(re.search(m.group(1), x) for x in succ); continue
    m = re.fullmatch(r"-check-failure=(.*)", c)
    if m:
        ok = ok and m.group(1) not in fail; continue
    m = re.fullmatch(r"check-success=(.*)", c)
    if m:
        ok = ok and m.group(1) in succ
print(1 if ok else 0)
PY
)
      [ "$mine" = "$theirs" ] || { G=$((G+1)); echo "FAIL: verdict-builder-context: M3 '$case': vs_clear_row cleared=$mine, the default queue cleared=$theirs"; }
    done
    exit "$G"
  ) || F=$((F + $?))
  # ---- M4 the conf line and the repo sync ----
  grep -qx 'status_check_any=lead-verdict|harness-verdict' "$CONF" || no "M4 cromford.conf carries status_check_any=lead-verdict|harness-verdict"
  ! grep -qx 'status_check=lead-verdict' "$CONF" || no "M4b cromford.conf no longer carries status_check=lead-verdict"
  "$MT" compare "$CONF" "$DIR/.mergify.yml" > "$M/cmp.out" 2>&1 || no "M4c .mergify.yml equals the render ($(head -20 "$M/cmp.out"))"
  # ---- M5, M6 the parse refusals ----
  mk() { { printf 'slug=o/r\ncheck=ci\n'; printf '%s\n' "$@"; } > "$M/t.conf"; }
  refused() { # refused <label> <line>...
    local label="$1" rc=0; shift; mk "$@"
    "$MT" render "$M/t.conf" > /dev/null 2>"$M/t.err" || rc=$?
    [ "$rc" = 2 ] && grep -q "t.conf" "$M/t.err" || no "$label: want rc 2 naming the conf, got rc $rc ($(cat "$M/t.err"))"; }
  refused "M5 a single name" 'status_check_any=a'
  refused "M5b a name with a dot" 'status_check_any=a.b|c'
  refused "M5c a name with a space" 'status_check_any=a b|c'
  refused "M5d an empty member" 'status_check_any=a||b'
  refused "M5e a second status_check_any line" 'status_check_any=a|b' 'status_check_any=c|d'
  refused "M5f a name that is also check=" 'status_check_any=ci|b'
  refused "M5g a name that is also default_status_check=" 'default_status_check=b' 'status_check_any=a|b'
  refused "M6 a name that is also status_check=" 'status_check=x' 'status_check_any=x|y'
  mk 'status_check_any=a|b'; "$MT" render "$M/t.conf" > "$M/t.yml" 2>"$M/t.err" || no "M5h a|b is accepted ($(cat "$M/t.err"))"
  grep -qF -- '- "check-success~=^(a|b)$"' "$M/t.yml" && grep -qF -- '- "-check-failure=a"' "$M/t.yml" && grep -qF -- '- "-check-failure=b"' "$M/t.yml" \
    || no "M5i a|b renders the regex and the two vetoes"
  # ---- M7 the check-run parsers do not list the status contexts ----
  (
    G=0
    mc_policy_get() { printf -v "$1" '%s' "$(jq -nc --arg c "$(base64 -w0 < "$DIR/.mergify.yml")" '{content:$c}')"; }
    # shellcheck source=bin/lib/autoenqueue.sh
    eval "$(sed -n '/^ae_mergify_admit_checks() {/,/^}/p' "$DIR/bin/lib/autoenqueue.sh")"
    eval "$(sed -n '/^mc_mergify_required_checks() {/,/^}/p' "$DIR/bin/lib/mc/queue.sh")"
    eval "$(sed -n '/^lr_ci_required() {/,/^}/p' "$DIR/bin/lead-review.sh")"
    # shellcheck source=bin/lib/queue-batch-only.sh
    . "$DIR/bin/lib/queue-batch-only.sh" || exit 1
    for fn in ae_mergify_admit_checks mc_mergify_required_checks; do
      out=$("$fn" example-org/cromford 2>/dev/null)
      [ -n "$out" ] || { G=$((G+1)); echo "FAIL: verdict-builder-context: M7 $fn listed nothing"; }
      ! grep -qE 'harness-verdict|~=|check-failure' <<<"$out" || { G=$((G+1)); echo "FAIL: verdict-builder-context: M7 $fn lists a status condition: $out"; }
    done
    out=$(lr_ci_required "$DIR/.mergify.yml")
    want=$(printf '%s\n' "Prompt replay evals (prompts/** only)" "Syntax + shellcheck + config integrity" "Test determinism lint")
    [ "$out" = "$want" ] || { G=$((G+1)); echo "FAIL: verdict-builder-context: M7b lr_ci_required lists the three fast checks only (got: $out)"; }
    mc_queue_batch_only_yml < "$DIR/.mergify.yml" || { G=$((G+1)); echo "FAIL: verdict-builder-context: M7c the repo is still batch-only"; }
    exit "$G"
  ) || F=$((F + $?))
  echo "part M: $F failed"
  exit "$F"
)
FAIL=$((FAIL + $?))

echo "verdict-builder-context: $FAIL failed"
[ "$FAIL" -eq 0 ]
