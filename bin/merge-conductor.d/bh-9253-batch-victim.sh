# shellcheck shell=bash
# bin/merge-conductor.d/bh-9253-batch-victim.sh - A BATCH VICTIM IS REQUEUED
# SOLO, NOT PARKED (BH-9253). Sourced by bin/merge-conductor.sh (the BH-7453
# fragment block); functions only, no side effect at source time.
#
# WHY. 2026-11-08 09:22-09:44Z: #9141 #9132 #9130 #9103 each had green CI on
# their own head. Mergify batched them, the batch drafts failed on one shard,
# and Mergify dequeued every member with BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS.
# The conductor counted that as a second ejection and parked all four
# BLOCKED_HUMAN `queue-ejected-twice` (12:01Z). A batch failure alone does not
# show that THIS PR is red.
#
# THE RULE. A queue-ejected-twice PR is a batch victim when ALL of these are
# true:
#   1. its newest mergify[bot] comment is a dequeue payload whose code is an
#      exact item of MC_BATCH_VICTIM_CODES;
#   2. mc_ci_state on its own head prints `green` (required checks, BH-9210);
#   3. its verdict is APPROVE and the reviewed sha is that head, and the live
#      PR head is that head too;
#   4. it was not requeued solo on that head before (`batchvictim <key> <head>`).
# Then the conductor adds the `queue-solo` label and requeues it alone, so
# .mergify.yml's "queue on the solo label" rule puts it in the batch_size-1
# `solo` queue. One solo try per head: the next ejection of the same head parks
# it as before, and the solo run is then the evidence against it.
#
# THE VERBS (Mergify repos only; MC_BATCH_VICTIM=0 makes mc_bv_solo rc 1 with
# no read).
#   mc_bv_code <slug> <num>     the newest mergify[bot] dequeue code, rc 1 none
#   mc_bv_decide <code> <ci> <bound 0|1> <solo-done 0|1> <codes-csv>
#                               PURE: `victim` or `park:<why>`
#   mc_bv_solo <project> <slug> <key> <head> <url>
#                               rc 0 = requeued solo (the caller must not park),
#                               rc 1 = park as before
#
# Log lines: BATCH_VICTIM_SOLO <key> <head> code=<code> ci=green, once per
# solo requeue; BATCH_VICTIM_PARK <key> <head8> <why>, once per (key, head, why).

# _mc_bv_knob <ENV> <fallback> — the settings row lane.merge-conductor.<env
#   lower> through lane_knob, else the env var, else <fallback>. Rows:
#   lane.merge-conductor.mc_batch_victim (fallback 1) and
#   lane.merge-conductor.mc_batch_victim_codes (fallback
#   BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS).
_mc_bv_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  [ -n "$v" ] || v="$2"
  printf '%s' "$v"
}

# mc_bv_code <slug> <num> — see the header. One ETag-cached comments read (the
#   list mc_dequeue_reason reads in the same tick).
mc_bv_code() {
  local slug="$1" num="$2" raw body pd
  [ -n "$slug" ] && [ -n "$num" ] || return 1
  command -v gh_rest_issue_comments >/dev/null 2>&1 && command -v mc_mergify_payload_dequeue >/dev/null 2>&1 || return 1
  mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000 || return 1
  [ -n "$raw" ] || return 1
  raw=$(jq -r '.[]? | select((.user.login // "") == "mergify[bot]") | ((.body // "") | gsub("[\r\n]+"; "\u0001"))' <<<"$raw" 2>/dev/null) || return 1
  body=$(printf '%s\n' "$raw" | tail -n 1 | tr '\001' '\n')
  [ -n "$body" ] || return 1
  pd=$(printf '%s\n' "$body" | mc_mergify_payload_dequeue) || return 1
  pd="${pd%%$'\n'*}"
  [ -n "$pd" ] || return 1
  printf '%s' "$pd"
}

# mc_bv_decide <code> <ci> <bound 0|1> <solo-done 0|1> <codes-csv> — PURE.
#   The first failing check names the park: solo-tried, unbound, code,
#   ci-<word>. The code must be an exact item of the csv (case and length).
mc_bv_decide() {
  local code="${1:-}" ci="${2:-}" bound="${3:-0}" done="${4:-1}" csv="${5:-}" item hit=0
  [ "$done" = 0 ] || { printf 'park:solo-tried'; return 0; }
  [ "$bound" = 1 ] || { printf 'park:unbound'; return 0; }
  if [ -n "$code" ]; then
    local IFS=,
    for item in $csv; do
      item="${item//[[:space:]]/}"
      [ -n "$item" ] && [ "$item" = "$code" ] && { hit=1; break; }
    done
  fi
  [ "$hit" = 1 ] || { printf 'park:code'; return 0; }
  [ "$ci" = green ] || { printf 'park:ci-%s' "${ci:-none}"; return 0; }
  printf 'victim'
}

# _mc_bv_park <key> <head> <why> — one BATCH_VICTIM_PARK line per (key, head,
#   why); rc 1 always, so a caller can `return` it.
_mc_bv_park() {
  mc_attempt_has "bvpark $1 $2 $3" 2>/dev/null && return 1
  mc_attempt_put "bvpark $1 $2 $3"
  mc_log "BATCH_VICTIM_PARK $1 ${2:0:8} $3 — not a batch victim; the queue-ejected-twice park stands (BH-9253)"
  return 1
}

# mc_bv_solo <project> <slug> <key> <head> <url> — see the header.
mc_bv_solo() {
  local p="$1" slug="$2" key="$3" head="$4" url="$5" n rec v vprov vrev vjob vhb live
  local bound=0 done=0 code="" ci="" word codes rc why
  [ "$(_mc_bv_knob MC_BATCH_VICTIM 1)" != 0 ] || return 1
  [ "${PROVIDER:-}" = mergify ] || return 1
  [ -n "$key" ] && [ -n "$head" ] && [ -n "$url" ] || return 1
  n="${key##*#}"
  codes=$(_mc_bv_knob MC_BATCH_VICTIM_CODES BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS)
  # A final answer for this head is not asked again: the code, a red own CI
  # and a spent solo try do not change while the head stays.
  for why in code ci-red solo-tried; do
    mc_attempt_has "bvpark $key $head park:$why" 2>/dev/null && return 1
  done
  mc_attempt_has "batchvictim $key $head" 2>/dev/null && done=1
  if [ "$done" = 0 ]; then
    rec=$(mc_record_for "$url" 2>/dev/null || true)
    IFS=$'\t' read -r v vprov vrev vjob vhb <<<"$(mc_verdict "$url" "$rec" 2>/dev/null)"
    [ "${v:-}" = APPROVE ] && [ "${vrev:-}" = "$head" ] && bound=1
    # The queue takes the LIVE head. A head that moved since the park is not
    # the head the approval and the CI read are about.
    if [ "$bound" = 1 ] && command -v mc_pr_view >/dev/null 2>&1; then
      live=$(mc_pr_view "$url" '.head.sha // ""' 2>/dev/null) || live=""
      [ -z "$live" ] || [ "$live" = "$head" ] || bound=0
    fi
  fi
  if [ "$done" = 0 ] && [ "$bound" = 1 ]; then
    code=$(mc_bv_code "$slug" "$n") || code=""
    if [ "$(mc_bv_decide "$code" green 1 0 "$codes")" = victim ]; then
      ci=$(mc_ci_state "$slug" "$head" 2>/dev/null) || ci=""
    fi
  fi
  word=$(mc_bv_decide "$code" "$ci" "$bound" "$done" "$codes")
  case "$word" in
    victim) ;;
    *) _mc_bv_park "$key" "$head" "$word"; return 1 ;;
  esac
  if [ "${MERGES:-0}" != 1 ]; then
    mc_log "$key ${head:0:8} is a batch victim (Mergify dequeue $code, own CI green) — would add queue-solo and requeue it alone (observe mode: nothing written; the park stands)"
    return 1
  fi
  if ! mc_tick_budget_take "$p" requeue "${MC_REQUEUE_CAP:-5}"; then
    mc_log "$key ${head:0:8} is a batch victim, but this tick's requeue budget (MC_REQUEUE_CAP=${MC_REQUEUE_CAP:-5}) is spent — the park stands and the parked-row pass asks again next tick"
    return 1
  fi
  if ! mc_label_add "$slug" "$n" queue-solo; then
    mc_log "$key ${head:0:8} is a batch victim, but the queue-solo label could not be added — the park stands and the parked-row pass asks again next tick"
    return 1
  fi
  # BOTH MARKS BEFORE THE WRITE: a crash after the requeue costs this head its
  # one solo try, never a loop.
  mc_attempt_put "batchvictim $key $head"
  mc_requeued_record "$key" "$head"
  rc=0; why=$(QR_KEEP_SOLO=1 mc_requeue_mergify "$slug" "$url" "$head") || rc=$?
  case "$rc" in
    0|2)
      mc_transition "$key" QUEUED "batch-victim: requeued solo on ${head:0:8} (own CI green; Mergify dequeue $code)" "$head" "$head" "$url" APPROVE UNKNOWN "${rec:--}" >/dev/null ;;
    3)
      mc_transition "$key" WAIT_CI "batch-victim: requeued solo on ${head:0:8}, awaiting Mergify's witness" "$head" "$head" "$url" APPROVE UNKNOWN "${rec:--}" >/dev/null ;;
    *)
      mc_log "REQUEUE_FAILED $key ${head:0:8} batch victim: the solo requeue was refused (rc $rc${why:+: $why}) — the park stands; this head's solo try is spent"
      return 1 ;;
  esac
  mc_handoff_release "$key" batch-victim
  command -v mc_fbh_clear >/dev/null 2>&1 && mc_fbh_clear "$key" "$head" batch-victim
  mc_log "BATCH_VICTIM_SOLO $key $head code=$code ci=green — requeued alone in the solo queue, not parked (BH-9253)"
  return 0
}
