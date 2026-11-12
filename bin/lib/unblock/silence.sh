#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/silence.sh — the silence default of a Tackler card (BH-9447).
# Sourced, never executed. Defines functions and does nothing else. card.sh
# loads it when it needs it (unblock_card_compose, unblock_card_sweep) and
# provides the helpers it uses (_unblock_card_setting_int, _unblock_card_log,
# _unblock_card_epoch, _unblock_card_hex, _unblock_card_root,
# _unblock_card_actvar).
#
# The rule (the operator, 2026-11-10): when the recommended option of a card is a safe
# lever and nobody answers, silence means "run it". Only for a project whose
# row unblock.silence_auto.<p> is exactly `on`; every other card keeps "nothing
# runs on silence".
#
#   unblock_silence_on <project>
#       rc 0 when setting_get answers rc 0 for unblock.silence_auto.<project>
#       and the trimmed value is exactly `on`. No row, unreadable, `On`, `yes`
#       or setting_get not defined = rc 1 (off, the fallback).
#   unblock_silence_safe_levers [alert]
#       the safe list on stdout, space separated: the row
#       unblock.silence_safe_levers (comma list), no row or unreadable = the
#       code fallback below. Each name is trimmed and lower-cased. A never-auto
#       name (act.sh UB_NEVER_CLASSES + UB_NEVER_ACTIONS, plus the ticket's
#       list) is dropped; with `alert`, any drop is ONE warn alert per sweep,
#       id unblock-silence-never-auto. A name act.sh does not know
#       (UB_ACTIONS) is dropped with one log line.
#   unblock_silence_record <ctx-json> <lever> <card-id> <option-text>
#       the ub_act record of a silence run on stdout, built from the ctx (the
#       decision at compose time, the ledger row at sweep time), never from the
#       model: decision_key silence:<card-id> (its own GitHub marker), rule_id
#       silence-default, class = ctx.class. The levers that have a builder:
#         requeue, update_branch          a PR subject
#         fix_round {brief: option}       a PR subject
#         lead_rerequest {request_id none, priority: the row
#           unblock.silence_rereview_priority, notes: option}   a PR subject
#         rebuild {key}                   a ticket subject
#       A PR subject is subject_kind pr, subject <repo>#<n>, a 40-hex head and
#       a repo slug. A ticket subject is ticket:<p>:<KEY> or <p>:<KEY> with KEY
#       matching act.sh's UB_TICKET_RE. Anything else: rc 1, no output.
#   unblock_silence_promise <ctx-json> <lever> <now_epoch> <card-id> <option-text>
#       the epoch the lever runs at (now + unblock.silence_auto_after_min
#       minutes) on stdout and rc 0 only when: the project is on, the lever is
#       in the safe list, the ctx class is not never-auto and
#       unblock_silence_record builds a record. Else rc 1 and no output.
#   unblock_silence_sweep <project> <now_epoch> <rows-jsonl>
#       the count of levers run on stdout (card.sh's unblock_card_sweep calls
#       it on the escalated rows it read; 0 list reads of its own).
#       1. The project is not on = 0, no request.
#       2. Kept rows: card.silence_at and card.silence_option set, outcome
#          escalated, no silence_claimed_at, and the operator was shown the card
#          (card.route operator, or routed_to operator with paged_at set). None = 0.
#       3. ub_act not loaded = one log line, 0, nothing claimed.
#       4. Per kept row, oldest first: now >= silence_at AND the row is open
#          for unblock.silence_auto_after_min minutes; silence_option is the
#          recommendation; its lever (card.levers) is in the safe list; the
#          class is not never-auto; a record builds. A miss is skipped (the
#          time miss silently, any other with one log line).
#       5. POST /api/unblock/silence/<id>/claim {lever, cap: the row
#          unblock.silence_auto_day_cap}. 409 day_cap = one warn alert, id
#          unblock-silence-cap-<p>-<UTC day>, and the loop stops; 409 claimed
#          = skip; 404 = one log line and the loop stops (fail closed); any
#          other failure = one log line, skip.
#       6. ub_act <record> in this shell. rc 1 = outcome failed, bad-input.
#       7. POST /api/unblock/silence/<id>/result {outcome, detail}: done
#          answers the row as silence-default; failed, refused and would leave
#          the card open with its deadline (no second page). A failed POST is
#          one log line: the claim still stops a second run.
#       8. One `--severity info` line, id unblock-silence-<key12>:
#          `Tackler <id>: no answer in <n> min, ran <lever>: <outcome>`.
#          Never --critical.
#
# Rows (schema.d/*-bh-9447-unblock-silence.sql), each read with a code fallback:
#   unblock.silence_auto.<p>           on | off      fallback off
#   unblock.silence_safe_levers        comma list    fallback UNBLOCK_SILENCE_SAFE_DEFAULT
#   unblock.silence_auto_after_min     5..4320       fallback 120
#   unblock.silence_auto_day_cap       1..1000       fallback 10
#   unblock.silence_rereview_priority  1..9          fallback 5
# Columns: worker/jobs/src/lib/core.d/bh-9447-unblock-silence.js. Routes:
# worker/jobs/src/routes/unblock-silence.js. Note:
# docs/notes/2026-11-11-BH-9447-silence-default.md.

# The code fallback of the row unblock.silence_safe_levers.
UNBLOCK_SILENCE_SAFE_DEFAULT="lead_rerequest,update_branch,fix_round,rebuild,requeue"
# The never-auto names of the ticket (act.sh gate 1). The reader adds act.sh's
# own UB_NEVER_CLASSES and UB_NEVER_ACTIONS to them.
UNBLOCK_SILENCE_NEVER="spend production live-probe client-board merge deploy governance force_push pause_project"

_unblock_silence_trim() { local v="${1:-}"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }

# _unblock_silence_never <name> — rc 0 when the name is never-auto.
_unblock_silence_never() {
  case " $UNBLOCK_SILENCE_NEVER $(_unblock_card_actvar UB_NEVER_CLASSES) $(_unblock_card_actvar UB_NEVER_ACTIONS) " in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

unblock_silence_on() {
  local v rc
  declare -F setting_get >/dev/null || return 1
  v=$(setting_get "unblock.silence_auto.${1:-}" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] && [ "$(_unblock_silence_trim "$v")" = on ]
}

unblock_silence_safe_levers() {
  local raw rc=1 n acts out="" dropped=""
  local IFS=,
  if declare -F setting_get >/dev/null; then raw=$(setting_get unblock.silence_safe_levers 2>/dev/null); rc=$?; fi
  [ "$rc" = 0 ] || raw="$UNBLOCK_SILENCE_SAFE_DEFAULT"
  acts=$(_unblock_card_actvar UB_ACTIONS)
  for n in $raw; do
    n=$(_unblock_silence_trim "$n" | tr '[:upper:]' '[:lower:]')
    [ -n "$n" ] || continue
    if _unblock_silence_never "$n"; then dropped="${dropped:+$dropped }$n"; continue; fi  # never-auto-drop
    case " $acts " in
      *" $n "*) out="${out:+$out }$n" ;;
      *) _unblock_card_log "silence: '$n' in unblock.silence_safe_levers is not an act.sh action; dropped" ;;
    esac
  done
  if [ -n "$dropped" ] && [ "${1:-}" = alert ] && [ -z "${_UNBLOCK_SILENCE_NEVER_SENT:-}" ]; then
    _UNBLOCK_SILENCE_NEVER_SENT=1
    "$(_unblock_card_root)/bin/lane-alert.sh" --id unblock-silence-never-auto --severity warn unblock \
      "$dropped dropped from unblock.silence_safe_levers: never-auto" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$out"
}

unblock_silence_record() {
  local ctx="${1:-}" lever="${2:-}" cid="${3:-}" opt="${4:-}" tre pri nmax
  [[ $cid =~ ^u-[0-9a-f]{6}$ ]] && [[ $lever =~ ^[a-z_]{1,40}$ ]] || return 1
  tre=$(_unblock_card_actvar UB_TICKET_RE); [ -n "$tre" ] || return 1
  pri=$(_unblock_card_setting_int unblock.silence_rereview_priority 5 1 9)
  # act.sh refuses lead_rerequest notes over UNBLOCK_NOTES_MAX_CHARS (its knob, fallback 300).
  nmax="${UNBLOCK_NOTES_MAX_CHARS:-300}"; [[ $nmax =~ ^[1-9][0-9]{0,5}$ ]] || nmax=300
  jq -ce --arg l "$lever" --arg cid "$cid" --arg o "$opt" --arg tre "$tre" --argjson pri "$pri" --argjson nmax "$nmax" '
    select(type == "object")
    | (.subject // "" | tostring) as $s
    | ((first($s | capture("#(?<n>[0-9]+)$")) | .n | tonumber) // null) as $pr
    | ((first($s | capture("^ticket:[^:]+:(?<k>.+)$")) | .k)
       // ((.project // "") as $pj | if ($pj != "" and ($s | startswith($pj + ":"))) then $s[(($pj | length) + 1):] else null end)) as $k0
    | (if ($k0 != null and ($k0 | test($tre))) then $k0 else null end) as $key
    | ((.subject_kind == "pr") and $pr != null and ((.head // "") | test("^[0-9a-f]{40}$"))
       and ((.repo // "") | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))) as $is_pr
    | ($o | gsub("[\r\n\t]+"; " ")) as $txt
    | {decision_key: ("silence:" + $cid), project, repo, subject_kind, subject, pr: $pr, head: (.head // null),
       rule_id: "silence-default", class: (.class // null), cites: []} as $base
    | if ($l | IN("requeue", "update_branch", "fix_round", "lead_rerequest")) then
        if ($is_pr | not) then null
        elif $l == "requeue" then $base + {action: {name: "requeue", args: {}}}
        elif $l == "update_branch" then $base + {action: {name: "update_branch", args: {}}}
        elif $l == "fix_round" then $base + {action: {name: "fix_round", args: {brief: $txt}}}
        else $base + {action: {name: "lead_rerequest",
          args: ({request_id: "none", priority: $pri} + (if $txt == "" then {} else {notes: $txt[0:$nmax]} end))}}
        end
      elif $l == "rebuild" then (if $key == null then null else $base + {action: {name: "rebuild", args: {key: $key}}} end)
      else null end' <<<"$ctx" 2>/dev/null
}

unblock_silence_promise() {
  local ctx="${1:-}" lever="${2:-}" now="${3:-}" p class after
  [[ $now =~ ^[0-9]+$ ]] || return 1
  p=$(jq -r '.project // "" | tostring' <<<"$ctx" 2>/dev/null) || return 1
  unblock_silence_on "$p" || return 1
  case " $(unblock_silence_safe_levers) " in *" $lever "*) ;; *) return 1 ;; esac
  class=$(jq -r '.class // "" | tostring' <<<"$ctx" 2>/dev/null)
  [ -n "$class" ] && _unblock_silence_never "$class" && return 1
  unblock_silence_record "$ctx" "$lever" "${4:-}" "${5:-}" >/dev/null || return 1
  after=$(_unblock_card_setting_int unblock.silence_auto_after_min 120 5 4320 2>/dev/null)
  echo $((now + after * 60))
}

unblock_silence_sweep() {
  local p="${1:-}" now="${2:-}" rows="${3:-}" cand safe after cap n=0 row rid created sat sopt rec lever class cid opt key12
  local ctx record out rc err outcome detail age day body
  [[ $now =~ ^[0-9]+$ ]] || now=$(date -u +%s)
  unblock_silence_on "$p" || { echo 0; return 0; }
  _UNBLOCK_SILENCE_NEVER_SENT=""
  cand=$(printf '%s\n' "$rows" | jq -cR 'fromjson? | select(type == "object" and (.card | type) == "object"
      and (.card.silence_at | type) == "string" and (.card.silence_option | type) == "number"
      and (.outcome // "escalated") == "escalated" and (.silence_claimed_at // null) == null
      and (.card.route == "operator" or (.routed_to == "operator" and (.paged_at // "") != "")))' 2>/dev/null \
    | jq -sc 'sort_by(.created_at // "", .id) | .[]' 2>/dev/null)
  [ -n "$cand" ] || { echo 0; return 0; }
  if ! declare -F ub_act >/dev/null; then
    _unblock_card_log "sweep $p: silence: ub_act (bin/lib/unblock/act.sh) is not loaded; nothing claimed"; echo 0; return 0
  fi
  safe=$(unblock_silence_safe_levers alert)
  after=$(_unblock_card_setting_int unblock.silence_auto_after_min 120 5 4320)
  cap=$(_unblock_card_setting_int unblock.silence_auto_day_cap 10 1 1000)
  day=$(date -u -d "@$now" +%Y-%m-%d)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\037' read -r rid created sat sopt rec lever class cid < <(jq -r '[(.id // "" | tostring), (.created_at // ""),
      .card.silence_at, (.card.silence_option | tostring), (.card.recommendation // "" | tostring),
      ((.card.levers // [])[.card.silence_option - 1] // "none" | tostring), (.card.class // "" | tostring),
      (.card.id // "")] | join("\u001f")' <<<"$row" 2>/dev/null)
    [[ ${rid:-} =~ ^[0-9]{1,15}$ ]] || continue
    created=$(_unblock_card_epoch "$created"); sat=$(_unblock_card_epoch "$sat")
    [[ $created =~ ^[0-9]+$ ]] && [[ $sat =~ ^[0-9]+$ ]] || { _unblock_card_log "sweep $p: silence row $rid: unreadable times; skipped"; continue; }
    age=$((now - created))
    [ "$now" -ge "$sat" ] && [ "$age" -ge $((after * 60)) ] || continue
    if [ "$sopt" != "$rec" ]; then _unblock_card_log "sweep $p: silence row $rid: option $sopt is not the recommendation $rec; skipped"; continue; fi
    case " $safe " in
      *" $lever "*) ;;
      *) _unblock_card_log "sweep $p: silence row $rid: lever $lever is not in the safe list; skipped"; continue ;;
    esac
    if [ -n "$class" ] && _unblock_silence_never "$class"; then
      _unblock_card_log "sweep $p: silence row $rid: class $class is never-auto; skipped"; continue
    fi
    ctx=$(jq -c '{project, repo, subject_kind, subject, head, class: (.card.class // null)}' <<<"$row")
    opt=$(jq -r '.card.options[.card.silence_option - 1] // "" | tostring' <<<"$row")
    if ! record=$(unblock_silence_record "$ctx" "$lever" "$cid" "$opt"); then
      _unblock_card_log "sweep $p: silence row $rid: no $lever record for subject $(jq -r '.subject // "?"' <<<"$row"); skipped"; continue
    fi
    # 5. CLAIM before the lever runs: one attempt per card, the worker counts the day.
    body=$(jq -nc --arg l "$lever" --argjson c "$cap" '{lever: $l, cap: $c}')
    out=$(_jobs_req POST "/api/unblock/silence/$rid/claim" "$body"); rc=$?
    case "$rc" in
      0) ;;
      9) err=$(jq -r '.error // ""' <<<"$out" 2>/dev/null)
         if [ "$err" = day_cap ]; then
           "$(_unblock_card_root)/bin/lane-alert.sh" --id "unblock-silence-cap-$p-$day" --severity warn unblock \
             "silence default: day cap $cap reached for $p; cards wait for an answer" >/dev/null 2>&1 || true
           _unblock_card_log "sweep $p: silence: day cap $cap reached; the rest wait"; break
         fi
         _unblock_card_log "sweep $p: silence row $rid: claim 409 ${err:-?}; skipped"; continue ;;
      2) _unblock_card_log "sweep $p: silence: claim 404, no silence route on the worker; nothing runs"; break ;;
      *) _unblock_card_log "sweep $p: silence row $rid: claim failed (http ${JOBS_HTTP:-none}); skipped"; continue ;;
    esac
    # 6. the lever, through Tackler's one writer, every gate of it.
    UB_ACT_OUTCOME="" UB_ACT_DETAIL=""
    ub_act "$record" >/dev/null 2>&1; rc=$?
    outcome="${UB_ACT_OUTCOME:-}"; detail="${UB_ACT_DETAIL:-}"
    if [ "$rc" != 0 ] || [ -z "$outcome" ]; then outcome=failed detail=bad-input; fi
    case "$outcome" in done|failed|refused|would) ;; *) detail="$outcome: $detail"; outcome=failed ;; esac
    n=$((n + 1))
    # 7. the result: done answers the card; any other outcome leaves it open.
    body=$(jq -nc --arg o "$outcome" --arg d "${detail:0:500}" '{outcome: $o, detail: $d}')
    _jobs_req POST "/api/unblock/silence/$rid/result" "$body" >/dev/null \
      || _unblock_card_log "sweep $p: silence row $rid: ran $lever ($outcome), result POST failed (http ${JOBS_HTTP:-none}); the claim stops a rerun"
    # 8. one info line, never critical.
    key12=$(_unblock_card_hex "$(jq -r '.card.key // .decision_key // ""' <<<"$row")" | cut -c1-12)
    "$(_unblock_card_root)/bin/lane-alert.sh" --id "unblock-silence-$key12" --severity info unblock \
      "Tackler $cid: no answer in $((age / 60)) min, ran $lever: $outcome" >/dev/null 2>&1 || true
    _unblock_card_log "sweep $p: silence row $rid: ran $lever: $outcome $detail"
  done <<<"$cand"
  echo "$n"
}
