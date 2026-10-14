#!/bin/bash
# shellcheck shell=bash
# bin/lib/dequeue-watch/act.sh — BH-3729 (slice 4 of BH-3719): what dequeue-watch
# DOES about a classified dequeue. Sourced by the lane (bin/dequeue-watch.sh,
# a sibling slice), never run; nothing here runs on source.
#
#   dqw_act <P> <slug> <num> <url> <head> <class> <ctx-json>
#     Picks one action for the class, claims it through dqw_action_claim BEFORE
#     any side effect (one action per (pr, head, class)), then does it:
#       bystander, flake                    -> requeue (flake: metric_flake first)
#       stale-status                        -> lead-request
#       main-red                            -> main-red-wait (dqw_mainred_recheck)
#       rule-break, scanner-fp,
#       semantic-test, textual-conflict     -> fix-round, or hold past the bound
#       unclassified                        -> hold
#     A bystander/flake with no standing verdict (verdict_word not MERGE or
#     MERGE-WITH-NOTES) is claimed as stale-status/lead-request instead, so
#     mc_requeue_mergify is never reached without one.
#     ctx: {rule_id, suite, fail_lines, hint, brief, run_id, run_url, draft,
#           head_ref, verdict_word, workflow?}. rc 1 = bad input, nothing claimed.
#     Sets DQW_A_CLASS to the class it claimed under (after the stale-status
#     remap; "" when it never got that far) and DQW_A_OUTCOME (BH-3859) to one of:
#       acted   act mode 1 and the claim (or an observe-row takeover) reached the
#               side effect, whatever that side effect's own status
#       would   act mode 0, WOULD_<ACTION> logged
#       owned   another row owns (pr, head, class), or the takeover failed
#       unread  the fix-round count or the claim could not be read
#       bad-input  rc 1
#   dqw_mainred_recheck <P> <slug>
#     Every waiting main-red-wait row of <slug> whose main has gone green gets
#     its requeue (verdict=MERGE* in the row note) or lead request, on the SAME
#     row. No new claim.
#   dqw_watchdog <P> <slug> <num> <head> <age_s> <url> [class]
#     Pages once when a dequeued head has no non-failed action row after
#     DEQUEUE_WATCH_UNOWNED_MIN minutes; resolves the page once a row owns it.
#     With <class> (BH-3859: the class this tick claimed under) only a row of
#     THAT class owns it, so a second class on the same head is never resolved
#     off the first class's row. Without it, any class owns it.
#
# Knobs (env, the lane registers them; the code default is the fallback):
#   DEQUEUE_WATCH_ACT          0   0 = claim `observe` and log WOULD_<ACTION>;
#                                  ships at 0 (BH-3859), 1 acts
#   DEQUEUE_WATCH_FIX_ROUNDS   2   fix rounds per (pr, class) before a hold
#   DEQUEUE_WATCH_HOLD_CLASSES ""  classes that always hold (comma/space list)
#   DEQUEUE_WATCH_UNOWNED_MIN  30  watchdog window in minutes
#
# Every read that fails (claim, count, list) is "do nothing this tick", never
# "no rows" (D9). `done` is set only after the side effect answered.
#
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither every verb
# returns 1 and builds no path.
#
# Ticket branches (ticket/bh-77, and the rebuild form ticket/bh-77-r2) are parsed
# by bin/lib/ticket-branch.sh, sourced below from this file's own directory
# (BH-3835). If it did not load, _dqw_ticket logs that and resolves no ticket.

. "$(dirname "${BASH_SOURCE[0]}")/../ticket-branch.sh" 2>/dev/null || true

_dqw_root() { printf '%s' "${HARNESS:-${H:-}}"; }

_dqw_log() {
  local h; h=$(_dqw_root)
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$h/logs/dequeue-watch.log" 2>/dev/null || true
}

# _dqw_alert <lane-alert args…> — never fails the caller.
_dqw_alert() { "$(_dqw_root)/bin/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

# _dqw_set <slug> <num> <head> <class> <status> [ref] [note] [action] — a failed
# set is logged only; the watchdog covers the row it left behind.
_dqw_set() {
  dqw_action_set "$@" >/dev/null 2>&1 || _dqw_log "act: dqw_action_set $1#$2 ${3:0:12} $4 $5 failed"
  return 0
}

_dqw_standing() { case "$1" in MERGE|MERGE-WITH-NOTES) return 0 ;; esac; return 1; }

# _dqw_ticket <head_ref> -> "<PREFIX>-<n>" for ticket/<prefix>-<n> or
# ticket/<prefix>-<n>-r<k>, else nothing. Always rc 0.
_dqw_ticket() {
  local r="${1:-}"
  if ! declare -F ticket_branch_key >/dev/null; then
    _dqw_log "act: bin/lib/ticket-branch.sh not loaded, no ticket for $r"
    return 0
  fi
  ticket_branch_key "$r" || true
}

# _dqw_class_held <class> — is it in DEQUEUE_WATCH_HOLD_CLASSES?
_dqw_class_held() {
  local c="$1" list w
  list=$(printf '%s' "${DEQUEUE_WATCH_HOLD_CLASSES:-}" | tr ',' ' ')
  local -
  set -f
  for w in $list; do [ "$w" = "$c" ] && return 0; done
  return 1
}

dqw_act() {
  DQW_A_CLASS="" DQW_A_OUTCOME=bad-input
  local h; h=$(_dqw_root)
  [ -n "$h" ] || return 1
  [ "$#" -eq 7 ] || { _dqw_log "act: usage: dqw_act <P> <slug> <num> <url> <head> <class> <ctx-json> (got $# args)"; return 1; }
  local P="$1" slug="$2" num="$3" url="$4" head="$5" class="$6" ctx="$7"
  local verdict action reason="" n cap act ans claimed row_action want
  printf '%s' "$ctx" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { _dqw_log "act: $slug#$num ctx is not a JSON object, nothing claimed"; return 1; }
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { _dqw_log "act: $slug#$num head '$head' is not a 40-hex sha, nothing claimed"; return 1; }
  [[ "$num" =~ ^[0-9]+$ ]] || { _dqw_log "act: $slug pr '$num' is not a number, nothing claimed"; return 1; }
  verdict=$(printf '%s' "$ctx" | jq -r '.verdict_word // ""')

  case "$class" in
    bystander|flake)
      action=requeue
      if ! _dqw_standing "$verdict"; then
        _dqw_log "act: $slug#$num ${head:0:12} $class with verdict '${verdict:-none}': no standing verdict, claimed as stale-status"
        class=stale-status; action=lead-request
      fi ;;
    stale-status) action=lead-request ;;
    main-red) action=main-red-wait ;;
    rule-break|scanner-fp|semantic-test|textual-conflict) action=fix-round ;;
    unclassified) action=hold; reason=unclassified ;;
    *) _dqw_log "act: $slug#$num unknown class '$class', nothing claimed"; return 1 ;;
  esac

  # The bound, before any claim (D11: an unreadable count is not 0).
  if [ "$action" = fix-round ]; then
    if ! n=$(dqw_rounds_count "$slug" "$num" "$class" 2>/dev/null) || ! [[ "$n" =~ ^[0-9]+$ ]]; then
      _dqw_log "act: $slug#$num ${head:0:12} $class rounds-unreadable, nothing claimed this tick"
      DQW_A_CLASS="$class" DQW_A_OUTCOME=unread
      return 0
    fi
    cap="${DEQUEUE_WATCH_FIX_ROUNDS:-2}"
    if ! [[ "$cap" =~ ^[0-9]+$ ]] || [ "$cap" -lt 1 ]; then
      _dqw_alert --severity warn --id "dqw-knob:DEQUEUE_WATCH_FIX_ROUNDS" dequeue-watch \
        "DEQUEUE_WATCH_FIX_ROUNDS is '$cap', not a positive integer. dequeue-watch is using 2 until it is fixed."
      cap=2
    fi
    if [ "$n" -ge "$cap" ]; then action=hold; reason="$n fix rounds spent"
    elif _dqw_class_held "$class"; then action=hold; reason="class held by DEQUEUE_WATCH_HOLD_CLASSES"
    fi
  fi

  act="${DEQUEUE_WATCH_ACT:-0}"
  case "$act" in 0|1) ;; *) _dqw_log "act: DEQUEUE_WATCH_ACT='$act' is not 0 or 1, observing only"; act=0 ;; esac
  want="$action"; [ "$act" = 1 ] || want=observe
  DQW_A_CLASS="$class"

  if ! ans=$(dqw_action_claim "$slug" "$num" "$head" "$class" "$want" "$P" 2>/dev/null) \
     || ! claimed=$(printf '%s' "$ans" | jq -er '.claimed | if type == "boolean" then tostring else error("x") end' 2>/dev/null); then
    _dqw_log "act: $slug#$num ${head:0:12} $class claim-unreadable, nothing done this tick"
    DQW_A_OUTCOME=unread
    return 0
  fi
  if [ "$claimed" != true ]; then
    row_action=$(printf '%s' "$ans" | jq -r '.row.action // ""' 2>/dev/null)
    if [ "$act" = 1 ] && [ "$row_action" = observe ]; then
      dqw_action_set "$slug" "$num" "$head" "$class" claimed "" "" "$action" >/dev/null 2>&1 \
        || { _dqw_log "act: $slug#$num ${head:0:12} $class observe row could not be taken over for $action, nothing done"; DQW_A_OUTCOME=owned; return 0; }
      _dqw_log "act: $slug#$num ${head:0:12} $class observe row taken over for $action"
    else
      _dqw_log "act: $slug#$num ${head:0:12} $class already-owned (${row_action:-?}), nothing done"
      DQW_A_OUTCOME=owned
      return 0
    fi
  fi
  if [ "$act" != 1 ]; then
    _dqw_log "act: $slug#$num ${head:0:12} $class WOULD_$(printf '%s' "$action" | tr '[:lower:]-' '[:upper:]_')${reason:+ ($reason)}"
    DQW_A_OUTCOME=would
    return 0
  fi

  DQW_A_OUTCOME=acted
  local suite wf run_url
  suite=$(printf '%s' "$ctx" | jq -r '.suite // ""')
  run_url=$(printf '%s' "$ctx" | jq -r '.run_url // ""')
  wf=$(printf '%s' "$ctx" | jq -r '.workflow // "unknown" | if . == "" then "unknown" else . end')
  case "$action" in
    requeue)       _dqw_requeue "$slug" "$num" "$url" "$head" "$class" "$suite" "$wf" "" ;;
    lead-request)  _dqw_lead "$slug" "$num" "$head" "$class" "run ${run_url:-unknown}" "" ;;
    main-red-wait) _dqw_set "$slug" "$num" "$head" "$class" waiting "" "verdict=${verdict:-none}" ;;
    fix-round)     _dqw_fix "$P" "$slug" "$num" "$url" "$head" "$class" "$ctx" ;;
    hold)          _dqw_hold "$P" "$slug" "$num" "$url" "$head" "$class" "$ctx" "$reason" ;;
  esac
  return 0
}

# _dqw_requeue <slug> <num> <url> <head> <class> <suites> <wf> <set-action>
# Conductor mark first, then the one requeue. Never retried on that head.
_dqw_requeue() {
  local slug="$1" num="$2" url="$3" head="$4" class="$5" suites="$6" wf="$7" sa="$8" s out rc
  if ! declare -F mc_requeue_mergify >/dev/null || ! declare -F mc_requeued_mark >/dev/null \
     || ! declare -F mc_requeued_record >/dev/null; then
    _dqw_set "$slug" "$num" "$head" "$class" failed "" "conductor libs not loaded" "$sa"
    return 0
  fi
  if [ -n "$(mc_requeued_mark "$slug#$num" "$head" 2>/dev/null)" ]; then
    _dqw_set "$slug" "$num" "$head" "$class" "done" "" "already requeued by the conductor" "$sa"
    return 0
  fi
  if [ "$class" = flake ]; then
    local -
    set -f
    for s in $suites; do
      if ! declare -F metric_flake >/dev/null; then _dqw_log "act: $slug#$num metric_flake not loaded, flake $s not recorded"; break; fi
      metric_flake "$slug" "$wf" "$s" "$head" "" flake >/dev/null 2>&1 \
        || _dqw_log "act: $slug#$num metric_flake $s failed, requeueing anyway"
    done
    set +f
  fi
  if ! mc_requeued_record "$slug#$num" "$head" >/dev/null 2>&1; then
    _dqw_set "$slug" "$num" "$head" "$class" failed "" "the conductor requeued mark could not be written" "$sa"
    return 0
  fi
  out=$(mc_requeue_mergify "$slug" "$url" "$head" 2>/dev/null); rc=$?
  case "$rc" in
    0) _dqw_set "$slug" "$num" "$head" "$class" "done" "" "requeued" "$sa" ;;
    2) _dqw_set "$slug" "$num" "$head" "$class" "done" "" "merged meanwhile" "$sa" ;;
    3) _dqw_set "$slug" "$num" "$head" "$class" waiting "" "requeue posted, no queue ack yet" "$sa" ;;
    *) _dqw_set "$slug" "$num" "$head" "$class" failed "" "${out:-mc_requeue_mergify rc $rc}" "$sa" ;;
  esac
  return 0
}

# _dqw_lead <slug> <num> <head> <class> <why> <set-action> — rc 0 or a 409 (a
# request already open) is done.
_dqw_lead() {
  local slug="$1" num="$2" head="$3" class="$4" why="$5" sa="$6" err rc
  err=$("$(_dqw_root)/bin/lead-verdict.sh" request "$slug" "$num" "$head" \
        --notes "dequeue-watch: $class on ${head:0:12}, $why" 2>&1 >/dev/null); rc=$?
  if [ "$rc" = 0 ]; then
    _dqw_set "$slug" "$num" "$head" "$class" "done" "" "lead verdict requested" "$sa"
  elif grep -q 'HTTP 409' <<<"$err"; then
    _dqw_set "$slug" "$num" "$head" "$class" "done" "" "lead verdict already requested (409)" "$sa"
  else
    _dqw_set "$slug" "$num" "$head" "$class" failed "" "lead-verdict request rc $rc: $(head -1 <<<"$err")" "$sa"
  fi
  return 0
}

_dqw_fix() {
  local P="$1" slug="$2" num="$3" url="$4" head="$5" class="$6" ctx="$7"
  local h box rec tkey out id
  h=$(_dqw_root)
  box=$("$h/bin/box-for.sh" "$P" 2>/dev/null)
  if [ -z "$box" ] || [ "$box" = local ] || { declare -F is_hub_box >/dev/null && is_hub_box "$box"; }; then
    _dqw_set "$slug" "$num" "$head" "$class" failed "" "no non-hub box owns $P (box-for.sh answered '${box:--}')"
    _dqw_alert --severity warn --id "dqw-nobox:$P" dequeue-watch \
      "$P: dequeue-watch cannot queue fix rounds, no non-hub box owns it (box-for.sh answered '${box:--}'). $url was left without one."
    return 0
  fi
  if ! declare -F mc_attempt_put >/dev/null || ! declare -F fix_round_enqueue >/dev/null; then
    _dqw_set "$slug" "$num" "$head" "$class" failed "" "conductor or fix-round libs not loaded"
    return 0
  fi
  if ! mc_attempt_put "dqwculprit $slug#$num $head" >/dev/null 2>&1; then
    _dqw_set "$slug" "$num" "$head" "$class" failed "" "the dqwculprit mark could not be written"
    return 0
  fi
  rec=$(printf '%s' "$ctx" | jq -c --arg pr "$num" --arg head "$head" --arg class "$class" \
    '{dequeue: {pr: ($pr | tonumber), head: $head, class: $class, rule_id, suite, fail_lines, hint, brief, run_id, run_url, draft}}')
  tkey=$(_dqw_ticket "$(printf '%s' "$ctx" | jq -r '.head_ref // ""')")
  if out=$(fix_round_enqueue "$P" "dqw-$num-${head:0:12}-$class" "$box" 0 "$rec" \
             "$P" "dqw-$num-${head:0:12}" queue-dequeued "$url" - "${tkey:--}" 2>/dev/null); then
    id=$(printf '%s' "$out" | jq -r '.id // ""' 2>/dev/null)
    _dqw_set "$slug" "$num" "$head" "$class" "done" "$id" "fix round queued on $box"
  else
    _dqw_set "$slug" "$num" "$head" "$class" failed "" "fix_round_enqueue failed"
    _dqw_alert --severity warn --id "dqw-enqueue-failed:$P:$num" dequeue-watch \
      "$P: dequeue-watch could not queue a fix round for $url ($class on ${head:0:12}). It will not retry this head."
  fi
  return 0
}

_dqw_hold() {
  local P="$1" slug="$2" num="$3" url="$4" head="$5" class="$6" ctx="$7" reason="$8"
  local h ref tkey issue="" suite fail1 fp rc=1 line extra=""
  h=$(_dqw_root)
  ref=$(printf '%s' "$ctx" | jq -r '.head_ref // ""')
  tkey=$(_dqw_ticket "$ref"); [ -n "$tkey" ] && issue=${tkey##*-}
  suite=$(printf '%s' "$ctx" | jq -r '.suite // ""')
  fail1=$(printf '%s' "$ctx" | jq -r '.fail_lines // "" | if type == "array" then (.[0] // "") else . end' | grep -m1 . )
  if [ -z "$issue" ]; then
    extra=" no ticket issue, so no hold was placed."
  elif ! declare -F nh_fingerprint >/dev/null || ! fp=$(nh_fingerprint "dequeue-watch $class $suite") || [ -z "$fp" ]; then
    extra=" hold NOT placed (the needs-human lib is not loaded)."
  else
    "$h/bin/needs-human-hold.sh" "$P" "$issue" "$fp" \
      "dequeue-watch stopped on $url: $class in ${suite:-an unknown suite}, $reason. Fix it or re-queue it by hand." \
      dequeue-watch >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] || extra=" hold NOT placed (rc $rc)."
  fi
  line="$url was dequeued on ${head:0:12} and dequeue-watch stopped: $class, $reason. Suite: ${suite:-unknown}. First FAIL: ${fail1:-none}.$extra"
  _dqw_alert --severity critical --id "dqw-hold:$P:$num:$class" dequeue-watch "$line"
  if [ "$rc" = 0 ]; then _dqw_set "$slug" "$num" "$head" "$class" "done" "" "held: $reason"
  else _dqw_set "$slug" "$num" "$head" "$class" failed "" "hold not placed: $reason${extra}"
  fi
  return 0
}

dqw_mainred_recheck() {
  local h; h=$(_dqw_root)
  [ -n "$h" ] || return 1
  local P="$1" slug="$2" list rows pr head note verdict url
  if ! list=$(dqw_actions_list "$slug" "" "" main-red main-red-wait waiting 2>/dev/null) \
     || ! rows=$(printf '%s' "$list" | jq -ce '.rows | if type == "array" then . else error("x") end' 2>/dev/null); then
    _dqw_log "recheck: $slug main-red-wait rows unreadable, nothing rechecked"
    return 0
  fi
  [ "$(printf '%s' "$rows" | jq 'length')" -gt 0 ] || return 0
  declare -F main_red_flag >/dev/null || { _dqw_log "recheck: $slug main_red_flag not loaded, nothing rechecked"; return 0; }
  main_red_flag "$P" "$slug" >/dev/null 2>&1 && return 0
  while IFS=$'\t' read -r pr head note; do
    [[ "$pr" =~ ^[0-9]+$ ]] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { _dqw_log "recheck: $slug skipped a malformed row ($pr ${head:0:12})"; continue; }
    url="https://github.com/$slug/pull/$pr"
    verdict=$(printf '%s' "$note" | sed -n 's/.*verdict=\([A-Z-]*\).*/\1/p')
    if _dqw_standing "$verdict"; then
      _dqw_requeue "$slug" "$pr" "$url" "$head" main-red "" "" requeue
    else
      _dqw_lead "$slug" "$pr" "$head" main-red "main is green again" lead-request
    fi
  done < <(printf '%s' "$rows" | jq -r '.[] | [(.pr | tostring), (.head // ""), (.note // "")] | @tsv')
  return 0
}

dqw_watchdog() {
  local h; h=$(_dqw_root)
  [ -n "$h" ] || return 1
  local P="$1" slug="$2" num="$3" head="$4" age="$5" url="$6" class="${7:-}" min list owned id
  [[ "$age" =~ ^[0-9]+$ ]] || { _dqw_log "watchdog: $slug#$num age '$age' is not seconds, nothing checked"; return 1; }
  min="${DEQUEUE_WATCH_UNOWNED_MIN:-30}"
  if ! [[ "$min" =~ ^[0-9]+$ ]] || [ "$min" -lt 1 ]; then
    _dqw_log "watchdog: DEQUEUE_WATCH_UNOWNED_MIN='$min' is not a positive integer, using 30"
    min=30
  fi
  if ! list=$(dqw_actions_list "$slug" "$num" "$head" 2>/dev/null) \
     || ! owned=$(printf '%s' "$list" | jq -r --arg c "$class" \
          '.rows | if type == "array" then (map(select(.status != "failed" and ($c == "" or .class == $c))) | length > 0) else error("x") end' 2>/dev/null) \
     || { [ "$owned" != true ] && [ "$owned" != false ]; }; then
    _dqw_log "watchdog: $slug#$num ${head:0:12} watchdog-unreadable, nothing paged or resolved"
    return 0
  fi
  id="dqw-unowned:$P:$num:${head:0:12}"
  if [ "$owned" = true ]; then
    _dqw_alert --resolve --id "$id" dequeue-watch "$url on ${head:0:12} is owned by a dequeue-watch action now"
  elif [ "$age" -gt $((min * 60)) ]; then
    _dqw_alert --severity critical --id "$id" dequeue-watch \
      "$url was dequeued on ${head:0:12} $((age / 60)) minutes ago and no dequeue-watch action owns it."
  fi
  return 0
}
