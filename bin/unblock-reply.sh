#!/bin/bash
# bin/unblock-reply.sh — an owner's answer to a Tackler card, with no model
# turn (BH-7725, UNB-3). bin/orchestrate.sh runs `intercept` in its
# `# >>> tackler reply intercept` block, after the box request block and
# before the turn claim.
#
#   unblock-reply.sh intercept <text>   rc 0 = the reply is on stdout;
#                                       rc 1 = not a card answer, nothing read
#   unblock-reply.sh archie <card-id> <hold|none|needs-operator> <note>
#   unblock-reply.sh archie <card-id> acted <note> <lever>
#                                       Archie's answer to a card routed to
#                                       him (bin/archie-cards.sh, BH-8817);
#                                       see ARCHIE below.
#
# THE GRAMMAR. The message, after poll-commands.sh's one `[telegram: from …]`
# attribution line, must be ONE line:
#   Tackler <id> <n>             pick option n of card <id>
#   Tackler <id> hold [<note>]   keep it parked, with an optional note
# <id> is u- and 6 lower-case hex. "Tackler" may be lower-case and may carry a
# comma or a colon. Anything else (a second line, text before the verb, a
# trailing `; cmd`) is rc 1 and the normal turn runs.
#
# THE STEPS, in this order, each one a reply that starts "Tackler:":
#   1. Owner check: the transport (UNBLOCK_TRANSPORT) must be telegram and the
#      sender (UNBLOCK_FROM_USER) must map to an email in BOX_CHAT_OWNERS
#      (env/global.env: telegram:<username>=<email>, the map
#      bin/box-request.sh br_owner reads). Slack display names are not unique,
#      so a Slack, missing or other transport resolves nobody (BH-5751). A
#      broken map resolves nobody. A non-owner gets "only an owner" and 0 HTTP
#      calls.
#   2. Dedup: state/unblock-replies/<command id> exists = "already recorded",
#      0 HTTP calls. No command id (or one that is not a safe file name) = no
#      local dedup; the worker's command_id key is the backstop.
#   3. GET /api/unblock/decisions?outcome=escalated&card=<id> (UNB-0's decision
#      ledger, #7722). No answer or not a 2xx = "did not answer", nothing
#      recorded. No row = "no open card".
#   4. An option outside 1..<the card's option count> = "not an option".
#   4b. A U14-ASK card (BH-8736) answered 1, whose card.lifecycle names a
#      project and a ticket key: lifecycle_transition <project> <key> planned
#      lifecycle "answered by <email> on card <id>" (bin/lib/jobs/lifecycle.sh,
#      #8731) BEFORE the answer POST, so a recorded answer always has its move.
#      rc 0, or a 409 whose current is planned = "moved <KEY> to planned"; a
#      409 with another current goes on and says "the ticket is already
#      <current>"; no lib, rc 1 or rc 2 = "not recorded", NO answer POST, so
#      the owner can send it again. hold, option 2 and every other rule's
#      card make no lifecycle call.
#   5. POST /api/unblock/decisions/<row id>/answer {answer, answered_by,
#      command_id[, note]}. 2xx, or 409 (the worker already holds that command
#      id), writes the marker. Anything else = "not recorded", no marker.
# The answer only records (step 4b excepted). The next Tackler tick
# (UNB-0/UNB-4) acts on it.
#
# ARCHIE (BH-8817). <card-id> is u- and 6 lower-case hex. Any other answer than
# hold, none, acted or needs-operator is ARCHIE_REFUSED, rc 2, 0 requests; `none`
# (closed as false) and `acted` need a note; `acted` (Archie pulled a lever
# through bin/lib/unblock/act.sh, the note carries the writer's answer) needs a
# lever from: requeue fix_round re_review rebase rebuild re_offer ticket_comment
# file_ticket. Any other answer takes no lever. The note goes through unblock_card_scrub and is cut to
# ARCHIE_CARDS_NOTE_MAX characters (default 500, the worker's TEXT_MAX).
#   1. GET /api/unblock/decisions?outcome=escalated&card=<id>. Refused when it
#      fails, when there is no open row, when card.route is not archie, or when
#      routed_to is already set (the operator owns the card).
#   2. hold|none|acted: POST /<row id>/answer {answer, answered_by: "archie",
#      source: "archie", command_id: "archie-<card id>", note, lever (acted)}. 2xx, or 409
#      (that command id is already recorded) = ARCHIE_ANSWERED <id> <answer>.
#      needs-operator: POST /<row id>/route {to: "operator", by: "archie", reason:
#      <note>} = ARCHIE_ROUTED <id>; the page is Tackler's next tick
#      (unblock_card_sweep). Anything else = ARCHIE_REFUSED <id> <why>.
# rc 0 = recorded, rc 1 = not recorded. One line per call in the log.
#
# INPUT (set by bin/orchestrate.sh from the message sidecar): UNBLOCK_TRANSPORT,
# UNBLOCK_FROM_USER, UNBLOCK_CMD_ID. Log: logs/unblock-reply.log.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" 2>/dev/null || { echo "unblock-reply: cannot load bin/jobs-client.sh" >&2; exit 1; }
# lifecycle_transition (#8731), for step 4b. Absent = a U14-ASK answer 1 is not
# recorded.
# shellcheck source=bin/lib/jobs/lifecycle.sh
[ -r "$SELF/lib/jobs/lifecycle.sh" ] && . "$SELF/lib/jobs/lifecycle.sh"

LOG="$H/logs/unblock-reply.log"
MARKS="$H/state/unblock-replies"
NOTHING="Nothing recorded."
mkdir -p "$H/logs" 2>/dev/null
log() { printf '%s [unblock-reply] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null; }

# owner_email — the sender's owner email on stdout; rc 1 when the sender is not
# an owner or the map is broken. The same parse as bin/box-request.sh br_owner
# (telegram only; trimmed, lower-cased once, a leading @ dropped; a bad entry or
# a username with two emails resolves nobody), with no alert: box-request
# already sends that one. Unlike br_owner, a missing transport resolves nobody.
owner_email() {
  local tr="${UNBLOCK_TRANSPORT:-}" u="${UNBLOCK_FROM_USER:-}" e user email
  local -A map=()
  u=$(printf '%s' "$u" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'); u="${u#@}"
  [ "$tr" = telegram ] && [ -n "$u" ] || return 1
  IFS=',' read -r -a ents <<< "${BOX_CHAT_OWNERS:-}"
  for e in "${ents[@]}"; do
    e=$(printf '%s' "$e" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -n "$e" ] || continue
    [[ $e =~ ^telegram:@?([a-z0-9_]{1,64})=([a-z0-9._%+-]+@[a-z0-9.-]+)$ ]] || { log "BOX_CHAT_OWNERS entry does not parse; nobody resolves"; return 1; }
    user="${BASH_REMATCH[1]}"; email="${BASH_REMATCH[2]}"
    if [ -n "${map[$user]:-}" ] && [ "${map[$user]}" != "$email" ]; then log "BOX_CHAT_OWNERS lists $user twice; nobody resolves"; return 1; fi
    map[$user]="$email"
  done
  [ -n "${map[$u]:-}" ] || return 1
  printf '%s\n' "${map[$u]}"
}

# req <method> <path> [body] — one jobs request in THIS shell. Sets RC (the
# _jobs_req contract: 0 2xx, 9 409, 2 404, 1 anything else) and BODY.
req() {
  local f; f=$(mktemp "${TMPDIR:-/tmp}/unblock-reply.XXXXXX") || { RC=1; BODY=""; return; }
  _jobs_req "$@" > "$f"; RC=$?
  BODY=$(cat "$f"); rm -f "$f"
}

intercept() {
  local t="$1" first id ans note="" who cmd mark row rid n subject body moved="" lp lk lout lrc cur
  first="${t%%$'\n'*}"
  if [[ $t == *$'\n'* ]] && [[ $first =~ ^\[(telegram|slack):\ from\ .*\]$ ]]; then t="${t#*$'\n'}"; fi
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
  [[ $t == *$'\n'* ]] && return 1
  [[ $t =~ ^[Tt]ackler[\ ,:]+(u-[0-9a-f]{6})\ +([0-9]{1,3}|hold(\ .*)?)$ ]] || return 1
  id="${BASH_REMATCH[1]}"; ans="${BASH_REMATCH[2]}"
  if [[ $ans == hold* ]]; then note="${ans#hold}"; note="${note# }"; ans=hold; fi

  if ! who=$(owner_email); then
    log "card $id: sender '${UNBLOCK_FROM_USER:-}' (transport '${UNBLOCK_TRANSPORT:-}') is not an owner"
    echo "Tackler: only an owner can answer a Tackler card. $NOTHING"; return 0
  fi
  cmd="${UNBLOCK_CMD_ID:-}"; mark=""
  [[ $cmd =~ ^[A-Za-z0-9._:-]{1,128}$ ]] && [[ $cmd != .* ]] && mark="$MARKS/$cmd"
  if [ -n "$mark" ] && [ -e "$mark" ]; then
    echo "Tackler: already recorded under command $cmd."; return 0
  fi

  req GET "/api/unblock/decisions?outcome=escalated&card=$id"
  if [ "$RC" != 0 ]; then
    log "card $id: ledger GET rc=$RC http=${JOBS_HTTP:-none}"
    echo "Tackler: the decision ledger did not answer (HTTP ${JOBS_HTTP:-no answer}). $NOTHING"; return 0
  fi
  row=$(jq -c --arg id "$id" '[(.decisions // [])[] | select(.card.id == $id)] | first // empty' <<<"$BODY" 2>/dev/null)
  if [ -z "$row" ]; then echo "Tackler: no open card $id. $NOTHING"; return 0; fi
  rid=$(jq -r '.id // ""' <<<"$row"); n=$(jq -r '.card.options // [] | length' <<<"$row"); subject=$(jq -r '.card.subject // "?"' <<<"$row")
  if ! [[ $rid =~ ^[0-9A-Za-z_-]{1,64}$ ]]; then
    log "card $id: ledger row has no usable id"
    echo "Tackler: the decision ledger row for $id has no usable id. $NOTHING"; return 0
  fi
  if [ "$ans" != hold ] && { [ "$((10#$ans))" -lt 1 ] || [ "$((10#$ans))" -gt "$n" ]; }; then
    echo "Tackler: $((10#$ans)) is not an option on $id (1-$n). $NOTHING"; return 0
  fi
  [ "$ans" = hold ] || ans=$((10#$ans))

  # 4b. U14-ASK answered 1: the ticket moves to planned before the answer is recorded.
  if [ "$ans" = 1 ] && [ "$(jq -r '.rule_id // ""' <<<"$row")" = U14-ASK ]; then
    lp=$(jq -r '.card.lifecycle.project // "" | tostring' <<<"$row")
    lk=$(jq -r '.card.lifecycle.ticket_key // "" | tostring' <<<"$row")
    if [[ $lp =~ ^[a-z0-9._-]+$ ]] && [[ $lk =~ ^[A-Z][A-Z0-9]*-[0-9]+([.][0-9]+)?$ ]]; then
      if declare -F lifecycle_transition >/dev/null; then
        lout=$(lifecycle_transition "$lp" "$lk" planned lifecycle "answered by $who on card $id" 2>/dev/null); lrc=$?
      else
        lrc=lib
      fi
      case "$lrc" in
        0) moved="moved $lk to planned" ;;
        9) cur=$(jq -r '.current // ""' <<<"$lout" 2>/dev/null); cur=$(printf '%s' "$cur" | tr -c 'A-Za-z0-9_-' '_')
           if [ "$cur" = planned ]; then moved="moved $lk to planned"; else moved="the ticket is already ${cur:-unknown}"; fi ;;
        *) log "card $id: lifecycle_transition $lp $lk planned rc=$lrc; answer not posted"
           echo "Tackler: answer 1 for $id was not recorded (the ticket move failed: rc $lrc)."; return 0 ;;
      esac
      log "card $id: $lp $lk -> planned by $who (rc $lrc)"
    fi
  fi

  body=$(jq -nc --arg a "$ans" --arg w "$who" --arg c "$cmd" --arg n "$note" \
    '{answer: $a, answered_by: $w, command_id: (if $c == "" then null else $c end)} + (if $a == "hold" and $n != "" then {note: $n} else {} end)')
  req POST "/api/unblock/decisions/$rid/answer" "$body"
  case "$RC" in
    0|9)
      if [ -n "$mark" ]; then mkdir -p "$MARKS" 2>/dev/null && printf '%s %s %s\n' "$id" "$ans" "$rid" > "$mark"; fi
      log "card $id: answer $ans by $who recorded (row $rid, command ${cmd:-none}, rc $RC)"
      if [ "$RC" = 9 ]; then echo "Tackler: already recorded under command ${cmd:-none}."
      elif [ "$ans" = hold ]; then echo "Tackler: recorded hold for $id ($subject). It stays parked."
      elif [ -n "$moved" ]; then echo "Tackler: recorded answer $ans for $id ($subject); $moved."
      else echo "Tackler: recorded answer $ans for $id ($subject). It runs on the next Tackler tick."; fi ;;
    *)
      log "card $id: answer POST rc=$RC http=${JOBS_HTTP:-none}"
      echo "Tackler: answer $ans for $id was not recorded (HTTP ${JOBS_HTTP:-no answer})." ;;
  esac
  return 0
}

ARCHIE_LEVERS="requeue fix_round re_review rebase rebuild re_offer ticket_comment file_ticket"
archie_answer() {
  local id="$1" ans="$2" note="$3" lever="${4:-}" row rid route routed body max
  if ! [[ $id =~ ^u-[0-9a-f]{6}$ ]] || ! [[ $ans =~ ^(hold|none|acted|needs-operator)$ ]]; then
    echo "ARCHIE_REFUSED ${id:-?} usage"; echo "$USAGE" >&2; return 2
  fi
  if [ "$ans" = acted ]; then
    [[ $lever =~ ^[a-z_]+$ ]] && [[ " $ARCHIE_LEVERS " == *" $lever "* ]] || { echo "ARCHIE_REFUSED $id lever"; return 2; }
  elif [ -n "$lever" ]; then
    echo "ARCHIE_REFUSED $id lever"; return 2
  fi
  if ! type unblock_card_scrub >/dev/null 2>&1; then
    # shellcheck source=bin/lib/unblock/card.sh
    . "$SELF/lib/unblock/card.sh" 2>/dev/null || { echo "ARCHIE_REFUSED $id no-scrub"; return 1; }
  fi
  # Fallback 500 for the archie-cards lane knob ARCHIE_CARDS_NOTE_MAX
  # (catalog/lanes.d/archie-cards.json), the worker's TEXT_MAX.
  max="${ARCHIE_CARDS_NOTE_MAX:-500}"
  if ! [[ $max =~ ^[0-9]{2,3}$ ]] || [ "$max" -lt 50 ] || [ "$max" -gt 500 ]; then max=500; fi
  note=$(printf '%s' "$note" | tr '\r\n\t' '   ' | unblock_card_scrub) || { echo "ARCHIE_REFUSED $id no-scrub"; return 1; }
  note="${note:0:$max}"
  if [ "$ans" = none ] || [ "$ans" = acted ]; then
    [ -n "${note//[[:space:]]/}" ] || { echo "ARCHIE_REFUSED $id $ans-needs-a-note"; return 2; }
  fi
  req GET "/api/unblock/decisions?outcome=escalated&card=$id"
  if [ "$RC" != 0 ]; then
    log "archie $id: ledger GET rc=$RC http=${JOBS_HTTP:-none}"; echo "ARCHIE_REFUSED $id ledger-unreadable"; return 1
  fi
  row=$(jq -c --arg id "$id" '[(.decisions // [])[] | select(.card.id == $id)] | first // empty' <<<"$BODY" 2>/dev/null)
  [ -n "$row" ] || { echo "ARCHIE_REFUSED $id no-open-card"; return 1; }
  rid=$(jq -r '.id // ""' <<<"$row"); route=$(jq -r '.card.route // ""' <<<"$row"); routed=$(jq -r '.routed_to // ""' <<<"$row")
  [[ $rid =~ ^[0-9]{1,15}$ ]] || { echo "ARCHIE_REFUSED $id no-row-id"; return 1; }
  if [ "$route" != archie ]; then log "archie $id: card route '${route:-none}', not archie"; echo "ARCHIE_REFUSED $id not-routed-to-archie"; return 1; fi
  if [ -n "$routed" ]; then log "archie $id: already routed to $routed"; echo "ARCHIE_REFUSED $id routed-to-$routed"; return 1; fi
  if [ "$ans" = needs-operator ]; then
    body=$(jq -nc --arg r "$note" '{to: "operator", by: "archie", reason: $r}')
    req POST "/api/unblock/decisions/$rid/route" "$body"
    if [ "$RC" = 0 ]; then log "archie $id: routed to operator (row $rid)"; echo "ARCHIE_ROUTED $id"; return 0; fi
    log "archie $id: route POST rc=$RC http=${JOBS_HTTP:-none}"; echo "ARCHIE_REFUSED $id route-http-${JOBS_HTTP:-none}"; return 1
  fi
  body=$(jq -nc --arg a "$ans" --arg c "archie-$id" --arg n "$note" --arg l "$lever" \
    '{answer: $a, answered_by: "archie", source: "archie", command_id: $c} + (if $n == "" then {} else {note: $n} end)
      + (if $l == "" then {} else {lever: $l} end)')
  req POST "/api/unblock/decisions/$rid/answer" "$body"
  case "$RC" in
    0|9) log "archie $id: answer $ans recorded (row $rid, rc $RC)"; echo "ARCHIE_ANSWERED $id $ans"; return 0 ;;
  esac
  log "archie $id: answer POST rc=$RC http=${JOBS_HTTP:-none}"; echo "ARCHIE_REFUSED $id answer-http-${JOBS_HTTP:-none}"; return 1
}

USAGE="usage: unblock-reply.sh intercept <text> | archie <card-id> <hold|none|needs-operator> <note> | archie <card-id> acted <note> <lever>"
case "${1:-}" in
  intercept) shift; intercept "${1:-}"; exit $? ;;
  archie) shift; archie_answer "${1:-}" "${2:-}" "${3:-}" "${4:-}"; exit $? ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
