#!/bin/bash
# bin/unblock-reply.sh — an owner's answer to a Tackler card, with no model
# turn (BH-7725, UNB-3). bin/orchestrate.sh runs `intercept` in its
# `# >>> tackler reply intercept` block, after the box request block and
# before the turn claim.
#
#   unblock-reply.sh intercept <text>   rc 0 = the reply is on stdout;
#                                       rc 1 = not a card answer, nothing read
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
#   5. POST /api/unblock/decisions/<row id>/answer {answer, answered_by,
#      command_id[, note]}. 2xx, or 409 (the worker already holds that command
#      id), writes the marker. Anything else = "not recorded", no marker.
# The answer only records. The next Tackler tick (UNB-0/UNB-4) acts on it.
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
  local t="$1" first id ans note="" who cmd mark row rid n subject body
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

  body=$(jq -nc --arg a "$ans" --arg w "$who" --arg c "$cmd" --arg n "$note" \
    '{answer: $a, answered_by: $w, command_id: (if $c == "" then null else $c end)} + (if $a == "hold" and $n != "" then {note: $n} else {} end)')
  req POST "/api/unblock/decisions/$rid/answer" "$body"
  case "$RC" in
    0|9)
      if [ -n "$mark" ]; then mkdir -p "$MARKS" 2>/dev/null && printf '%s %s %s\n' "$id" "$ans" "$rid" > "$mark"; fi
      log "card $id: answer $ans by $who recorded (row $rid, command ${cmd:-none}, rc $RC)"
      if [ "$RC" = 9 ]; then echo "Tackler: already recorded under command ${cmd:-none}."
      elif [ "$ans" = hold ]; then echo "Tackler: recorded hold for $id ($subject). It stays parked."
      else echo "Tackler: recorded answer $ans for $id ($subject). It runs on the next Tackler tick."; fi ;;
    *)
      log "card $id: answer POST rc=$RC http=${JOBS_HTTP:-none}"
      echo "Tackler: answer $ans for $id was not recorded (HTTP ${JOBS_HTTP:-no answer})." ;;
  esac
  return 0
}

case "${1:-}" in
  intercept) shift; intercept "${1:-}"; exit $? ;;
  *) echo "usage: unblock-reply.sh intercept <text>" >&2; exit 2 ;;
esac
