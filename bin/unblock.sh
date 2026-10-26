#!/bin/bash
# bin/unblock.sh — BH-7722 (UNB-0): the unblock lane (Tackler). A hub lane.
#
#   unblock.sh tick [--project <p>]   one tick; the cron line, every 10 min.
#                                     No --project: every fleet.conf project
#                                     whose mode is not off (unb_scope_projects,
#                                     bin/lib/unblock/scope.sh).
#
# ONE TICK, in this order (spec "One tick, in order"):
#   0. KILL, before any read of a collector, GitHub or the ledger:
#      staff-kill-all, staff-kill-tackler (flag_active: the pause_flags row,
#      else the file; the console's /staff kill switch), staff-off-tackler
#      (lane_switch, file: Archie's Overlooker pause). Then lane_gate_or_exit
#      unblock (flag lane-off-unblock) and lane_env_apply unblock. Then the
#      row unblock.enabled: 0 exits; unreadable exits (fail closed); no row
#      runs. Each stop is one line in logs/unblock.log and rc 0.
#   1. Per project: the lock is unb_scope_lock <p> (scope.sh: pl_lane_lock
#      unblock <p>, locks/unblock-<p>.lock; held = one line, the project is
#      skipped, never a wait). The mode is unb_scope_mode <p> (scope.sh, the
#      same grammar as act.sh): `shadow` or `act` runs; missing, `off`, any
#      other word or no settings cache is off: one `mode off` line and no
#      collector call.
#   2. COLLECT: ubc_collect (bin/lib/unblock/collect.sh) over
#      bin/lib/unblock/collectors/*.sh, at most UNBLOCK_MAX_RECORDS records.
#   3. RULES: ub_rules_eval, when bin/lib/unblock/rules.sh defines it, reads
#      the records (JSONL on stdin) and prints decisions (JSONL). Not defined
#      = `rules=unwired`, 0 decisions.
#   4. Per decision, BEFORE the claim, the seam it needs must be loaded:
#      a judge question -> ubt_stage_judge; decision escalate -> ubt_stage_card;
#      decision act -> ub_act (bin/lib/unblock/act.sh); refuse -> none.
#      Not loaded = one `deferred <seam>` line and NO claim (the key stays free
#      for the tick that has the seam). digest has no seam yet: deferred.
#   5. CLAIM: POST /api/unblock/decisions/claim (evidence through token_redact;
#      a record over 8000 bytes AFTER JSON encoding is cut, truncated:true). 409 = another tick owns the key: stop
#      for this decision, no further call. Any other failure: one line, stop
#      (nothing was spent).
#   6. ROUTE (judge, card): lane_role_model <role> (unblock.judge,
#      stage.unblock). No route = RECORD no-route (the detail names the role),
#      0 model calls, and ONE bin/lane-alert.sh --severity warn --id
#      unblock-no-route-<role> per role per tick. Else the seam is called with
#      (decision JSON, model, claim mode) and prints {outcome, detail, model_calls,
#      cost_usd, card?}; anything else is RECORD failed.
#   7. ACT: ub_act in this shell, with act.sh's input shape; RECORD
#      UB_ACT_OUTCOME / UB_ACT_DETAIL. rc 1 = RECORD failed bad-input.
#   8. One summary line per project:
#      <UTC> tick <p> mode=<m> collectors=<n> unwired=<n> failed=<n>
#        records=<n> decisions=<n> claimed=<n> rows=<n> deferred=<n>
#      and, when no collector is wired and no claim was new:
#      <UTC> tick <p> mode=<m> 0 collectors, 0 rows
#
# THE SEAMS (S0 defines them; the families and stages wire to them):
#   ub_collect_<family> <project> <repo>  in collectors/<family>.sh -> JSONL
#   ub_rules_eval < records.jsonl         -> decisions JSONL, each:
#     {decision_key, project, repo, subject_kind, subject, pr?, head?,
#      stall_class, rule_id, cites[], class, decision, action:{name,args}|null,
#      judge:{...}|null, evidence:{...}}
#   ubt_stage_judge <decision-json> <model> <mode>  -> {outcome,detail,model_calls,cost_usd}
#     (it must call agent-call stage unblock-judge on route unblock.judge)
#   ubt_stage_card  <decision-json> <model> <mode>  -> the same, plus card
#     (bin/lib/unblock/card.sh; it calls agent-call stage unblock on route
#     stage.unblock, and only for the key in UBT_CLAIMED_KEY)
#   <mode> is the claim's mode (shadow, or act with UNBLOCK_ACT=1). After a
#   claim answered rc 0 the tick sets UBT_CLAIMED_KEY to that decision_key.
#   Both manifest rows: catalog/context-budgets.d/7722-unblock.json.
#   ub_act <record-json>                     bin/lib/unblock/act.sh (BH-7726)
#
# A tick that dies after a claim leaves the row `claimed`: visible in
# GET /api/unblock/decisions?outcome=claimed, and never spent twice (the key
# blocks a second claim).
#
# OFF: unblock.enabled=0, flags/lane-off-unblock, bin/harness-ctl.sh off
# unblock, staff-kill-tackler, staff-kill-all, flags/staff-off-tackler.
# Registry: catalog/lanes.d/unblock.json. Cron: cron/lanes/417-unblock.cron.
# Note: docs/notes/2026-10-22-BH-7722-unblock-contract.md.
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
VERB="${1:-}"
[ "$VERB" = tick ] || { echo "usage: unblock.sh tick [--project <p>]" >&2; exit 2; }
shift
PROJECTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [[ ${2:-} =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || { echo "unblock: bad project '${2:-}'" >&2; exit 2; }
      PROJECTS="$2"; shift 2 ;;
    *) echo "usage: unblock.sh tick [--project <p>]" >&2; exit 2 ;;
  esac
done
if [ "${UNBLOCK_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  UNBLOCK_TIMED=1 exec timeout 540 bash "$0" "$VERB" ${PROJECTS:+--project "$PROJECTS"}
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/project-lanes.sh" 2>/dev/null || true
  . "$SELF/lib/token-redact.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/unblock/collect.sh
. "$SELF/lib/unblock/collect.sh" || { echo "unblock: bin/lib/unblock/collect.sh missing" >&2; exit 1; }
# shellcheck source=bin/lib/unblock/scope.sh
. "$SELF/lib/unblock/scope.sh" || { echo "unblock: bin/lib/unblock/scope.sh missing" >&2; exit 1; }
# shellcheck source=bin/lib/unblock/act.sh
. "$SELF/lib/unblock/act.sh" || { echo "unblock: bin/lib/unblock/act.sh missing" >&2; exit 1; }
# The conductor libs (BH-8418): mc_attempt_has and mc_requeued_mark for the
# queue collector's ejected_on_head and requeued_on_head, and the requeue,
# post_block and queue_approve arms of act.sh. Not on the tree = those reads
# are null (unknown) and those arms answer conductor-libs-not-loaded.
# shellcheck source=bin/lib/merge-conductor-lib.sh
[ -r "$SELF/lib/merge-conductor-lib.sh" ] && . "$SELF/lib/merge-conductor-lib.sh"
# fix_round_enqueue, for act.sh's fix_round arm (U10).
# shellcheck source=bin/lib/fix-round-queue.sh
[ -r "$SELF/lib/fix-round-queue.sh" ] && . "$SELF/lib/fix-round-queue.sh"
# Every seam module the tick dispatches to loads when its file is on the tree:
# the rules engine (#7752), the judge (judge.sh, BH-7724 #7753) and the card
# (card.sh, ubt_stage_card, BH-8418). tests/unblock-rules-contract.bh-8418-test.sh
# S5 checks each ubt_stage_* below is defined after this loop.
for m in rules judge card; do
  # shellcheck disable=SC1090
  [ -r "$SELF/lib/unblock/$m.sh" ] && . "$SELF/lib/unblock/$m.sh"
done
# The suite's seam. Sandbox only, and settable:false in the registry.
COLLECTORS_DIR="$SELF/lib/unblock/collectors"
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ]; then
  [ -n "${UNBLOCK_COLLECTORS_DIR:-}" ] && COLLECTORS_DIR="$UNBLOCK_COLLECTORS_DIR"
  # shellcheck disable=SC1090
  [ -n "${UNBLOCK_FIXTURE:-}" ] && . "$UNBLOCK_FIXTURE"
fi
command -v _jobs_req >/dev/null 2>&1 && command -v flag_active >/dev/null 2>&1 \
  && command -v setting_get >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "unblock: jobs-client (_jobs_req, flag_active, setting_get) or jq missing" >&2; exit 1; }
command -v token_redact >/dev/null 2>&1 || { echo "unblock: bin/lib/token-redact.sh missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${UNBLOCK_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$UNBLOCK_NOW; fi
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/unblock.log"
ubt_log() { printf '%s %s\n' "$(date -u -d "@${NOW:-$(date -u +%s)}" +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# ═════ 0. KILL: before any read ══════════════════════════════════════════════
for F in staff-kill-all staff-kill-tackler; do
  if flag_active "$F"; then ubt_log "killed by $F"; exit 0; fi
done
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }   # no lib: the file
if lane_switch staff-off-tackler file; then ubt_log "killed by staff-off-tackler"; exit 0; fi
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit unblock
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply unblock
EN=$(setting_get unblock.enabled 2>/dev/null); rc=$?
EN=$(printf '%s' "$EN" | tr -d '[:space:]')
case "$rc:$EN" in
  0:1|2:*) ;;
  0:0) ubt_log "off: unblock.enabled=0"; exit 0 ;;
  0:*) ubt_log "off: unblock.enabled='$EN' is not 0 or 1 (fail closed)"; exit 0 ;;
  *) ubt_log "unblock.enabled unreadable (rc $rc); tick skipped (fail closed)"; exit 0 ;;
esac

MAXREC="${UNBLOCK_MAX_RECORDS:-200}"
if ! [[ $MAXREC =~ ^[0-9]+$ ]] || [ "$MAXREC" -lt 10 ] || [ "$MAXREC" -gt 1000 ]; then
  ubt_log "warn: UNBLOCK_MAX_RECORDS='$MAXREC' is not 10..1000; 200 used"
  MAXREC=200
fi
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/unblock.XXXXXX") || exit 0
trap 'rm -rf "$TMPD"' EXIT

# ubt_evidence <decision-json> — the stall record, redacted, at most 8000
# bytes as it goes on the wire. A record over that is cut: the wrapper
# {truncated:true, head:<string>} is measured AFTER jq encodes it (a quote
# or a backslash costs 2 bytes there), and the head is halved until it fits.
ubt_evidence() {
  local ev cut n
  ev=$(jq -c '.evidence // {} | if type == "object" then . else {value: .} end' <<<"$1" | token_redact)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$ev" || ev='{"unreadable":true}'
  n=$(printf '%s' "$ev" | wc -c)
  if [ "$n" -gt 8000 ]; then
    cut=7600
    while :; do
      ev=$(jq -nc --arg h "${ev:0:$cut}" '{truncated: true, head: $h}')
      n=$(printf '%s' "$ev" | wc -c)
      [ "$n" -le 8000 ] || [ "$cut" -le 1 ] && break
      cut=$((cut / 2))
    done
  fi
  printf '%s' "$ev"
}

# ubt_record <key> <outcome> <detail> <model_calls> <cost_usd> [card-json]
# model_calls goes out as an integer and cost_usd as a number (the route
# refuses anything else): "1" and 1.0 are 1; a word is 0.
ubt_record() {
  local body
  body=$(jq -nc --arg k "$1" --arg o "$2" --arg d "${3:0:500}" --arg n "$4" --arg c "$5" \
    --argjson card "${6:-null}" '{decision_key: $k, outcome: $o, outcome_detail: $d,
      model_calls: (($n | tonumber? // 0) | floor), cost_usd: ($c | tonumber? // 0)}
      + (if $card == null then {} else {card: $card} end)') || return 1
  if _jobs_req POST /api/unblock/decisions/record "$body" >/dev/null; then
    ROWS=$((ROWS + 1)); return 0
  fi
  ubt_log "record $1 $2 failed (http ${JOBS_HTTP:-none}); the row stays claimed"
  return 1
}

# ubt_decide <decision-json> <mode> — steps 4 to 7 for one decision.
ubt_decide() {
  local d="$1" mode="$2" key kind seam="" role="" model ans out body ev cm rc
  UBT_CLAIMED_KEY=""
  key=$(jq -r '.decision_key // ""' <<<"$d")
  kind=$(jq -r '.decision // ""' <<<"$d")
  if ! [[ $key =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then ubt_log "decision dropped: bad decision_key"; return 0; fi
  if jq -e '.judge != null' >/dev/null 2>&1 <<<"$d"; then seam=ubt_stage_judge role=unblock.judge
  else
    case "$kind" in
      escalate) seam=ubt_stage_card role=stage.unblock ;;
      act) seam=ub_act ;;
      refuse) seam=refuse ;;
      *) DEFERRED=$((DEFERRED + 1)); ubt_log "deferred $kind $key (no seam for decision '$kind')"; return 0 ;;
    esac
  fi
  if [ "$seam" != refuse ] && ! declare -F "$seam" >/dev/null; then
    DEFERRED=$((DEFERRED + 1)); ubt_log "deferred $seam $key (seam not loaded; not claimed)"; return 0
  fi
  # 5. CLAIM, before any spend.
  ev=$(ubt_evidence "$d")
  cm=shadow; [ "$mode" = act ] && [ "${UNBLOCK_ACT:-0}" = 1 ] && cm=act
  body=$(jq -c --argjson ev "$ev" --arg m "$cm" '{decision_key, project, repo, subject_kind, subject, head,
      stall_class, rule_id, rule_cites: (.cites // []), evidence: $ev, decision,
      action: (.action.name // null), action_args: (.action.args // null), mode: $m}' <<<"$d") \
    || { ubt_log "decision $key dropped: unreadable"; return 0; }
  out=$(_jobs_req POST /api/unblock/decisions/claim "$body"); rc=$?
  case "$rc" in
    0) CLAIMED=$((CLAIMED + 1)); UBT_CLAIMED_KEY=$key ;;
    9) ubt_log "claim $key: held by row $(jq -r '.id // "?"' <<<"$out" 2>/dev/null) ($(jq -r '.outcome // "?"' <<<"$out" 2>/dev/null)); skipped"; return 0 ;;
    *) ubt_log "claim $key failed (http ${JOBS_HTTP:-none}); nothing spent"; return 0 ;;
  esac
  # 6/7. the seam
  case "$seam" in
    refuse) ubt_record "$key" refused "rule refused" 0 0 ;;
    ub_act)
      UB_ACT_OUTCOME="" UB_ACT_DETAIL=""
      ub_act "$(jq -c '{decision_key, project, repo, subject_kind, subject, pr, head, rule_id, class,
          cites, action: {name: (.action.name // ""), args: (.action.args // {})}}' <<<"$d")" >/dev/null
      rc=$?
      if [ "$rc" = 0 ] && [ -n "$UB_ACT_OUTCOME" ]; then
        ubt_record "$key" "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL" 0 0
      else
        ubt_record "$key" failed bad-input 0 0
      fi ;;
    *)
      if ! model=$(lane_role_model "$role" "$P" 2>/dev/null) || [ -z "$model" ]; then
        ubt_record "$key" no-route "no model route for role $role" 0 0
        case " $ALERTED " in
          *" $role "*) ;;
          *) ALERTED="$ALERTED $role"
             "$H/bin/lane-alert.sh" --severity warn --id "unblock-no-route-$role" unblock \
               "unblock: no model route for role $role; decisions recorded no-route (fail closed)" >/dev/null 2>&1 || true ;;
        esac
        return 0
      fi
      ans=$("$seam" "$d" "$model" "$cm" 2>/dev/null)
      if jq -e 'type == "object" and (.outcome | IN("would","done","failed","refused","escalated"))
          and ([.model_calls | tonumber?] | length == 1) and ([.cost_usd | tonumber?] | length == 1)' >/dev/null 2>&1 <<<"$ans"; then
        ubt_record "$key" "$(jq -r .outcome <<<"$ans")" "$(jq -r '.detail // ""' <<<"$ans")" \
          "$(jq -r .model_calls <<<"$ans")" "$(jq -r .cost_usd <<<"$ans")" "$(jq -c '.card // null' <<<"$ans")"
      else
        ubt_record "$key" failed "$seam answered no outcome object" 0 0
      fi ;;
  esac
  return 0
}

# The projects: --project <p>, else unb_scope_projects (mode not off).
if [ -n "$PROJECTS" ]; then
  LIST=$(printf '%s\t%s\n' "$PROJECTS" "$(unb_scope_mode "$PROJECTS")")
else
  LIST=$(unb_scope_projects)
  [ -n "$LIST" ] || ubt_log "tick: no project has an unblock mode other than off"
fi
# ubt_unlock — release what unb_scope_lock took (fd 9 and the shared fd 4).
ubt_unlock() { exec 9>&- 4>&- 2>/dev/null; return 0; }
while IFS=$'\t' read -r -u 3 P MODE; do
  [ -n "$P" ] || continue
  if [ "$MODE" != shadow ] && [ "$MODE" != act ]; then ubt_log "tick $P: $P mode off; no collector"; continue; fi
  if ! unb_scope_lock "$P"; then ubt_log "tick $P: lock held (locks/unblock-$P.lock); skipped"; continue; fi
  REPO=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
  [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { ubt_log "tick $P: no fleet.conf repo; skipped"; ubt_unlock; continue; }
  CLAIMED=0 ROWS=0 DEFERRED=0 NDEC=0 ALERTED=""
  UBC_MAX=$MAXREC ubc_collect "$P" "$REPO" "$COLLECTORS_DIR" > "$TMPD/records.jsonl"
  [ "$UBC_BAD" -gt 0 ] || [ "$UBC_OWN" -gt 0 ] && ubt_log "tick $P: dropped bad=$UBC_BAD own=$UBC_OWN"
  [ "$UBC_TRUNCATED" -gt 0 ] && ubt_log "tick $P: records truncated=$UBC_TRUNCATED (UNBLOCK_MAX_RECORDS=$MAXREC)"
  RULES=wired
  : > "$TMPD/decisions.jsonl"
  if ! declare -F ub_rules_eval >/dev/null; then
    RULES=unwired
  elif [ "$UBC_RECORDS" -gt 0 ]; then
    ub_rules_eval < "$TMPD/records.jsonl" > "$TMPD/decisions.jsonl" 2>/dev/null \
      || ubt_log "tick $P: ub_rules_eval rc $?"
  fi
  while IFS= read -r D; do
    [ -n "$D" ] || continue
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$D" || { ubt_log "tick $P: a decision line is not an object; dropped"; continue; }
    NDEC=$((NDEC + 1))
    ubt_decide "$D" "$MODE"
  done < "$TMPD/decisions.jsonl"
  if [ "$UBC_COLLECTORS" = 0 ] && [ "$CLAIMED" = 0 ]; then
    LINE="tick $P mode=$MODE 0 collectors, 0 rows"
  else
    LINE="tick $P mode=$MODE collectors=$UBC_COLLECTORS unwired=$UBC_UNWIRED failed=$UBC_FAILED records=$UBC_RECORDS decisions=$NDEC claimed=$CLAIMED rows=$ROWS deferred=$DEFERRED"
  fi
  [ "$RULES" = unwired ] && [ "$UBC_RECORDS" -gt 0 ] && LINE="$LINE rules=unwired"
  ubt_log "$LINE"
  printf '%s\n' "$LINE"
  ubt_unlock
done 3<<< "$LIST"
exit 0
