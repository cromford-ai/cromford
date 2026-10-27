#!/bin/bash
# bin/archie.sh — BH-4062 (BH-3966.1): Archie's initiative tracer. Archie is
# the hub orchestrator's persona (prompts/archie-soul.d/, one file per section,
# read in glob order; a new section is a new NN-<slug>.md); an initiative is a
# goal he keeps an eye on, stored in the jobs DB (worker/jobs/src/routes/
# initiatives.js: tables initiatives + initiative_events).
#
#   archie.sh [tick]              the archie hub lane, every 15 minutes
#                                 (no argument is a tick: the cron line)
#   archie.sh intercept <text>    called by bin/orchestrate.sh on every chat
#                                 message, before any model turn
#
# INTERCEPT. rc 0 means <text> was an Archie command and stdout is the reply
# (a success, or an honest "nothing was recorded"); rc 1 means it was not one,
# nothing was requested, and the normal turn runs. The grammar is
# archie_parse_cmd in bin/lib/archie.sh:
#   Archie, track <goal> [| metric: …] [| every: <n>h|<n>d] [| escalate: …] [| links: <url> …]
#   Archie approve|change|drop I<n> [note]      (or bare: approve|change|drop I<n>)
#   Archie delegate <class> | Archie ask first <class>        (BH-4067)
# A reply is keyed reply:<id>:<ARCHIE_CMD_ID>, or a hash of the text when the
# message carried no command id, so a re-delivered message records once.
#
# EARNED AUTONOMY (BH-4067). After a reply lands, the same key records the operator's
# choice on the initiative's newest escalation (POST /api/archie/decisions/
# choice; a re-delivered message counts once). An approve on an unprotected,
# non-sensitive escalation adds to its class's streak; at ARCHIE_DELEGATE_AFTER
# in a row the reply offers to take that class. A change or drop puts the class
# back to ask-first, and the reply says so. `Archie delegate <class>` is the
# ONLY way a class moves into Archie's authority (POST /api/archie/classes/
# delegation, refused for the protected classes and below the streak);
# `Archie ask first <class>` takes it back. Every reply maps one to one onto
# the worker's answer; a DB that did not answer is "Nothing changed".
#
# TICK, in this order:
#   1. lane_gate_or_exit / lane_env_apply archie; NOW read once
#      (ARCHIE_NOW only under HARNESS_TEST_SANDBOX=1); ARCHIE_ENABLED=0 exits;
#      flock -n locks/archie.lock (held = skip, never wait); the whole
#      tick runs under timeout 600 (D21).
#   1b. WAKES (BH-4063, bin/lib/archie-wake.sh): the event collectors (merges,
#      replan-escalate, outcome rows, ALERTS lines, a lane over its daily
#      budget, due follow-ups) mark the initiatives they concern due NOW and
#      leave the events in state/archie/wake-context/<id>.txt; then held beats
#      go out as one digest if quiet hours and the cap allow. A woken check
#      carries its events in the prompt and is not silenced by the escalation
#      rule; a FOLLOWUP: line in its answer sets a follow-up and is cut from
#      the beat. flags/archie-wake-off stops the collectors only.
#   2. GET the due list (status=active, next_check_at <= NOW, at most
#      ARCHIE_MAX_PER_TICK). Unreachable: one log line, exit 0. Empty: exit 0
#      with no other request and no model call. More than the cap: the rest
#      stay due for the next tick (logged `deferred`).
#   3. per row: re-check active + due on this side too, else skip;
#   4. read the slot's event check:<id>:<due_at> BEFORE anything billable.
#      composed = resend the stored body (no second model call); a closed
#      status = only repair the advance; model_failed = retry with its count;
#      an unreadable ledger = skip (no spend without the ledger);
#   5. read the metric (archie_metric_csv). Readable: the told marker
#      state/archie/unreadable-told/<id> goes. Unreadable, marker present:
#      event `unreadable`, advance min(ARCHIE_UNREADABLE_RECHECK_H, cadence)
#      hours (BH-4609: a daily re-check, not a lost cadence), no call.
#      Unreadable, no marker (BH-4765): ONE told check. The prompt carries
#      check.metric_unreadable true, step 6 is skipped, and steps 7-9 run with
#      a fixed ticket-file sentence when calls are off, unrouted, or the answer
#      is blank or no-action. The beat reads `Metric: unreadable`, `sent`
#      advances the same re-check hours, and the marker is written only after
#      archie_beat_gate returns 0 (a held beat counts as told);
#   6. archie_escalates says no: event `silent`, advance, no call;
#   7. one agent-call, stage archie, model from model_routes stage.archie (no
#      route = no call, row stays due). The attempt is written first (event
#      `model_failed`, attempts+1; a failed write = no call), so every paid
#      call is counted. A slot already at ARCHIE_MAX_ATTEMPTS is closed with
#      no call and ONE ALERTS line. rc 74-79 billed nothing: the attempt is
#      handed back, the next tick retries. Any other failure leaves it counted;
#      at the cap the slot closes the same way. A BUDGET STOP (agent-call's
#      envelope says the call hit ARCHIE_LLM_MAX_USD, BH-4609) is self-caused:
#      the slot stays open with body `budget_stop <retry_after> usd= cost=`,
#      ONE ALERTS line per slot names the settings row, and the next attempt
#      waits ARCHIE_RETRY_BACKOFF_MIN (checked before the metric read and any
#      spend), up to ARCHIE_RETRY_MAX billed attempts. A blank answer: event
#      `empty`, advance, no beat;
#   8. the answer's first line `CLASS: <slug>` is split off (archie_split_class;
#      missing or malformed = unclassified; a blank sentence = `empty` as
#      above). A sentence that only says nothing is needed from the operator
#      (archie_no_action, BH-4779: ARCHIE_NO_ACTION_RE, no ARCHIE_ASK_RE and
#      no ARCHIE_NEWS_RE) is `empty` too, with no decision row and no send. Then
#      archie_sensitive checks class, goal and sentence, and
#      POST /api/archie/decisions records the escalation (BH-4067). The worker
#      answers mode auto only for a delegated, unprotected, non-sensitive class,
#      and in that case has ALREADY recorded Archie's approve; the body is then
#      the after-report (archie_compose auto:<class>). A ledger that does not
#      answer is one warn line and the ordinary ask: failure always asks.
#      Then archie_compose (always within the worker's 4000-char body cap); event
#      `composed` (with the body) BEFORE the send. If that write fails the
#      attempt still counts, and a 4xx refusal closes the slot at once;
#   9. re-read the row (a drop since step 2 means no message), then ONE
#      Telegram message to Archie's target (bin/archie-tg-send.sh, BH-4779:
#      the lane.archie.archie_telegram_target chat, else the operator's DM), akey
#      archie:<id>:<due_at>, through archie_beat_gate: sent now, or held for the
#      digest in quiet hours / past today's ARCHIE_BEAT_CAP_DAY. Either: event
#      `sent` and advance to NOW + cadence. Anything else: stays `composed`,
#      retried.
#  10. one line in logs/archie.log per tick that had work:
#      <ts> due=<n> checked=<n> beats=<n> model_calls=<n> skipped=<n>
#
# OFF: ARCHIE_ENABLED=0, flags/lane-off-archie, bin/harness-ctl.sh off
# archie. Registry: catalog/lanes.d/archie.json. Note:
# docs/notes/2026-10-03-BH-4062-archie-tracer.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-tick}"
# Almost every chat message is not an Archie command: answer that before
# loading anything else, so the turn it falls through to pays ~nothing.
if [ "$MODE" = intercept ]; then
  # shellcheck source=lib/archie.sh
  . "$SELF/lib/archie.sh" 2>/dev/null && archie_parse_cmd "${2:-}" >/dev/null || exit 1
fi
if [ "$MODE" = tick ] && [ "${ARCHIE_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  ARCHIE_TIMED=1 exec timeout 600 bash "$0" "$@"
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/archie.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/lib/archie-wake.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_FIXTURE"
fi
command -v archie_parse_cmd >/dev/null 2>&1 && command -v archie_beat_gate >/dev/null 2>&1 \
  && command -v _jobs_req >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "archie: bin/lib/archie.sh, bin/lib/archie-wake.sh, jobs-client or jq missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOWISO=$(iso "$NOW")
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/archie.log"
TOLD_DIR="$H/state/archie/unreadable-told"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# knob_int <name> <value> <default> <min> <max>: out of range is one warn line
# and the default, never a silent clamp (D11).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}

# ═════ intercept ═════════════════════════════════════════════════════════════
intercept() {
  local text="${1:-}" parsed kind f2 f3 f4 body resp rc key cad goal
  parsed=$(archie_parse_cmd "$text") || return 1
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie
  ARCHIE_DEFAULT_CADENCE_H=$(knob_int ARCHIE_DEFAULT_CADENCE_H "${ARCHIE_DEFAULT_CADENCE_H:-24}" 24 1 2160)
  ARCHIE_DELEGATE_AFTER=$(knob_int ARCHIE_DELEGATE_AFTER "${ARCHIE_DELEGATE_AFTER:-5}" 5 2 50)
  IFS=$'\t' read -r kind f2 f3 f4 <<<"$parsed"
  case "$kind" in
    ask) printf '%s\n' "$f2"; return 0 ;;
    track)
      if ! body=$(archie_parse_track "$f2"); then
        printf "I couldn't read the %s part, so I didn't save anything. The shape is: Archie, track <goal> | metric: csv:logs/<file>.csv#<column>[@<column>=<value>] | every: <n>h or <n>d (up to 90d) | escalate: always, change, or > < >= <= <number> | links: <url> <url>\n" "$body"
        return 0
      fi
      cad=$(jq -r .cadence_hours <<<"$body")
      body=$(jq -c --arg n "$(iso $((NOW + cad * 3600)))" '. + {next_check_at: $n, created_by: "chat"}' <<<"$body")
      resp=$(_jobs_req POST /api/initiatives "$body"); rc=$?
      case "$rc" in
        0)
          if [ "$(jq -r '.existing // false' <<<"$resp")" = true ]; then
            printf 'I already track that as I%s. Nothing changed.\n' "$(jq -r .initiative.id <<<"$resp")"
          else
            goal=$(jq -r .initiative.goal <<<"$resp")
            printf 'Tracking it as I%s: %s. First check %s, then every %sh. Metric %s, escalate on %s.\n' \
              "$(jq -r .initiative.id <<<"$resp")" "$goal" "$(jq -r .next_check_at <<<"$body")" "$cad" \
              "$(jq -r .metric_query <<<"$body")" "$(jq -r .escalation_rule <<<"$body")"
          fi ;;
        9) printf 'I already track a goal like that as I%s, with different settings. Nothing was recorded. Drop it first (Archie drop I%s) if you want to replace it.\n' \
             "$(jq -r '.initiative.id // "?"' <<<"$resp")" "$(jq -r '.initiative.id // "?"' <<<"$resp")" ;;
        *) [ "${JOBS_HTTP:-}" = 400 ] \
             && printf "The jobs DB refused that (%s). Nothing was recorded.\n" "$(jq -r '.error // "bad request"' <<<"${JOBS_BODY:-}" 2>/dev/null)" \
             || printf "I couldn't save that, the jobs DB didn't answer. Nothing was recorded.\n" ;;
      esac
      return 0 ;;
    reply)
      local dec="$f2" id="$f3" note="$f4" cid
      cid=$(printf '%s' "${ARCHIE_CMD_ID:-}" | tr -dc 'A-Za-z0-9_-' | cut -c1-64)
      [ -n "$cid" ] || cid=$(printf '%s' "$text" | sha256sum | cut -c1-16)
      key="reply:$id:$cid"
      body=$(jq -nc --argjson i "$id" --arg d "$dec" --arg n "$note" --arg k "$key" \
        '{id: $i, decision: $d, note: (if $n == "" then null else $n end), dedupe_key: $k, actor: "chat"}')
      resp=$(_jobs_req POST /api/initiatives/reply "$body"); rc=$?
      case "$rc" in
        0) case "$dec" in
             approve) printf 'Recorded: you approved I%s.\n' "$id" ;;
             drop) printf "Dropped I%s. I won't check it again.\n" "$id" ;;
             change) printf "Recorded your change for I%s: %s. I haven't edited the initiative itself yet.\n" "$id" "$note" ;;
           esac
      # >>> archie choice
           record_choice "$id" "$dec" "$key"
      # <<< archie choice
           ;;
        2) printf "I don't have an initiative I%s. Nothing was recorded.\n" "$id" ;;
        9) printf 'I already have a different answer recorded for that message on I%s. Nothing was recorded.\n' "$id" ;;
        *) printf "I couldn't save that, the jobs DB didn't answer. Nothing was recorded.\n" ;;
      esac
      return 0 ;;
    delegate|askfirst)
      local cls="$f2" dbody
      dbody=$(jq -nc --arg c "$cls" --arg d "$([ "$kind" = delegate ] && echo delegate || echo ask_first)" \
        --argjson n "$ARCHIE_DELEGATE_AFTER" '{class: $c, decision: $d, min_streak: $n, actor: "chat"}')
      resp=$(_jobs_req POST /api/archie/classes/delegation "$dbody"); rc=$?
      case "$rc:$kind" in
        0:delegate) printf "Done. I'll handle %s calls and report after each one. One overrule puts it back.\n" "$cls" ;;
        0:askfirst) printf "OK, %s calls stay with you, and I'll ask first. Its count starts again from zero.\n" "$cls" ;;
        9:*) case "$(jq -r '.error // ""' <<<"$resp" 2>/dev/null)" in
               never_delegable) printf '%s stays with you. Clients, money, direct merges, pushes to main, production DB writes and deploys outside the deploy lanes always do.\n' "$cls" ;;
               not_earned) printf 'Not yet. %s is at %s of %s agreements in a row.\n' "$cls" "$(jq -r '.streak // 0' <<<"$resp")" "$ARCHIE_DELEGATE_AFTER" ;;
               *) printf "The jobs DB refused that. Nothing changed.\n" ;;
             esac ;;
        2:*) printf "I don't have a %s category. Nothing changed.\n" "$cls" ;;
        *) printf "I couldn't save that, the jobs DB didn't answer. Nothing changed.\n" ;;
      esac
      return 0 ;;
  esac
  return 1
}

# record_choice <id> <decision> <reply key>: the operator's answer on the newest
# escalation of I<id>, and at most ONE sentence about what it did to its class.
# Runs only after the reply itself landed, so a failure here adds nothing and
# leaves the "Recorded" line true; it is one warn line in logs/archie.log.
record_choice() {
  local b r rc
  b=$(jq -nc --argjson i "$1" --arg c "$2" --arg k "$3" '{initiative_id: $i, choice: $c, choice_key: $k}')
  r=$(_jobs_req POST /api/archie/decisions/choice "$b"); rc=$?
  if [ "$rc" != 0 ]; then
    log "warn: initiative $1: choice $2 not recorded on its escalation (rc=$rc http=${JOBS_HTTP:-none})"
    return 0
  fi
  if [ "$(jq -r '.reverted == true' <<<"$r")" = true ]; then
    printf 'Got it, %s calls go back to asking you first.\n' "$(jq -r .class <<<"$r")"
  elif jq -e --argjson n "$ARCHIE_DELEGATE_AFTER" \
      '.counted == true and .protected == false and .state == "ask_first" and (.streak | type == "number") and .streak >= $n' \
      <<<"$r" >/dev/null 2>&1; then
    printf "You've agreed with my last %s %s calls. Want me to handle those myself and tell you after? Say: Archie delegate %s, or Archie ask first %s.\n" \
      "$(jq -r .streak <<<"$r")" "$(jq -r .class <<<"$r")" "$(jq -r .class <<<"$r")" "$(jq -r .class <<<"$r")"
  fi
  return 0
}

# ═════ tick ══════════════════════════════════════════════════════════════════
# post_check <id> <due_at> <status> <value> <attempts|""> <advance> [body]
# advance: 0 = stay open, 1 = now + cadence, <n>h = now + n hours.
post_check() {
  local b adv=null
  case "$6" in
    1) adv="\"$(iso $((NOW + CAD * 3600)))\"" ;;
    *h) [[ ${6%h} =~ ^[0-9]+$ ]] && adv="\"$(iso $((NOW + ${6%h} * 3600)))\"" ;;
  esac
  b=$(jq -nc --argjson i "$1" --arg d "$2" --arg s "$3" --arg v "$4" --arg a "$5" --argjson adv "$adv" --arg body "${7:-}" \
    '{id: $i, due_at: $d, status: $s, value: (if $v == "" then null else $v end), actor: "archie"}
     + (if $a == "" then {} else {attempts: ($a | tonumber)} end)
     + (if $adv == null then {} else {advance_to: $adv} end)
     + (if $body == "" then {} else {body: $body} end)')
  _jobs_req POST /api/initiatives/check "$b" >/dev/null
  local rc=$?
  [ "$rc" = 0 ] || log "warn: initiative $1 check $2: writing $3 failed (rc=$rc http=${JOBS_HTTP:-none})"
  return "$rc"
}

# send <row> <due_at> <body> <value> [advance] [told id]: the drop re-read, the
# message, then `sent` (advance as post_check, default 1). With a told id, the
# unreadable-told marker is written once the beat gate took the message.
send() {
  local row="$1" due="$2" body="$3" v="$4" adv="${5:-1}" told="${6:-}" id cur payload
  id=$(jq -r .id <<<"$row")
  cur=$(_jobs_req GET "/api/initiatives?id=$id") || { log "initiative $id: re-read before the send failed; retried next tick"; SKIPPED=$((SKIPPED + 1)); return 0; }
  if [ "$(jq -r .initiative.status <<<"$cur")" != active ]; then
    log "initiative $id: no longer active; composed body not sent"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  payload=$(jq -nc --arg a "archie:$id:$due" --arg l "$body" '{akey: $a, line: $l}')
  # The one Telegram send point (BH-4779), through the BH-4063 gate: sent now,
  # or held for the digest (quiet hours / today's cap). Either way the slot
  # closes `sent`; a held body lives on in its archie_digest row until the
  # digest goes out.
  if archie_beat_gate "$payload"; then
    [ "$AW_GATE_LAST" = sent ] && BEATS=$((BEATS + 1))
    post_check "$id" "$due" sent "$v" "" "$adv" || true
    if [ -n "$told" ]; then
      { mkdir -p "$TOLD_DIR" && : > "$TOLD_DIR/$told"; } 2>/dev/null \
        || log "warn: initiative $id: told marker not written; the next re-check tells again"
    fi
  else
    log "initiative $id: not delivered (rc=$?); stays composed, resent next tick"
  fi
}

# close_failed <id> <due_at> <value> <attempts> <why>: the slot closes as
# model_failed, advanced, and ONE ALERTS line says so.
close_failed() {
  post_check "$1" "$2" model_failed "$3" "$4" 1 || true
  archie_wake_done "$1"
  HARNESS="$H" "$H/bin/alert-line.sh" "archie: initiative $1 check $2 $5; skipped to the next cadence" >/dev/null 2>&1 || true
}

check_row() {
  local row="$1" id status due metric rule last ev erc est att=0 v body model pf raw rc text
  local prev_body="" class=attempt retry_after="" cost RH
  id=$(jq -r .id <<<"$row"); status=$(jq -r .status <<<"$row"); due=$(jq -r .next_check_at <<<"$row")
  metric=$(jq -r .metric_query <<<"$row"); rule=$(jq -r .escalation_rule <<<"$row")
  last=$(jq -r '.last_value // "" | tostring' <<<"$row"); CAD=$(jq -r .cadence_hours <<<"$row")
  [[ $id =~ ^[0-9]+$ ]] && [[ $CAD =~ ^[0-9]+$ ]] || { log "warn: malformed initiative row skipped"; SKIPPED=$((SKIPPED + 1)); return 0; }
  # An unreadable metric re-checks daily, or every cadence when that is shorter.
  RH=$RECHECK_H; [ "$CAD" -lt "$RH" ] && RH=$CAD
  # >>> due recheck
  # The worker already filtered; this side checks again, because a row it
  # handed back by mistake would otherwise be paid for.
  if [ "$status" != active ] || [[ ! $due =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || [[ $due > $NOWISO ]]; then
    log "initiative $id: not due (status=$status next_check_at=$due); skipped"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  # <<< due recheck
  CHECKED=$((CHECKED + 1))
  ev=$(_jobs_req GET "/api/initiatives/events?key=check:$id:$due"); erc=$?
  case "$erc" in
    0) est=$(jq -r '.event.status // ""' <<<"$ev"); att=$(jq -r '.event.attempts // 0' <<<"$ev")
       prev_body=$(jq -r '.event.body // ""' <<<"$ev") ;;
    2) est="" ;;
    *) log "initiative $id: the check ledger did not answer (rc=$erc); nothing spent, retried next tick"
       SKIPPED=$((SKIPPED + 1)); return 0 ;;
  esac
  case "$est" in
    sent|silent|unreadable|empty)
      # Closed, but the advance was lost: repair it, nothing else. An
      # unreadable slot repairs to its daily re-check, not a full cadence.
      local adv=1; [ "$est" = unreadable ] && adv="${RH}h"
      post_check "$id" "$due" "$est" "$(jq -r '.event.value // ""' <<<"$ev")" "" "$adv" || true
      return 0 ;;
    # >>> composed reuse
    composed)
      body=$(jq -r '.event.body // ""' <<<"$ev")
      if [ -n "$body" ]; then
        # A metric-backed slot composed with no value told an unreadable metric.
        if [ "$metric" != none ] && [ -z "$(jq -r '.event.value // ""' <<<"$ev")" ]; then
          send "$row" "$due" "$body" "" "${RH}h" "$id"
        else
          send "$row" "$due" "$body" "$(jq -r '.event.value // ""' <<<"$ev")"
        fi
        return 0
      fi ;;
    # <<< composed reuse
  esac
  [[ $att =~ ^[0-9]+$ ]] || att=0
  if [ "$est" = model_failed ]; then
    IFS=$'\t' read -r class retry_after <<<"$(archie_fail_class "$prev_body")"
  fi
  # The attempts the ledger already holds are spent: at the cap the slot
  # closes without another call (a close whose write was lost lands here).
  # A slot whose last failure was a budget stop has its own, larger cap.
  if [ "$class" = budget_stop ]; then
    if [ "$att" -ge "$RETRY_MAX" ]; then
      close_failed "$id" "$due" "" "$att" "hit its dollar cap $att times (ARCHIE_LLM_MAX_USD=$USD)"
      return 0
    fi
    # >>> budget backoff
    # Before the metric read and before any spend.
    if [[ $NOWISO < $retry_after ]]; then
      log "initiative $id: backing off after a budget stop until $retry_after; no call"
      SKIPPED=$((SKIPPED + 1)); return 0
    fi
    # <<< budget backoff
  elif [ "$att" -ge "$MAX_ATT" ]; then
    close_failed "$id" "$due" "" "$att" "failed $att times"
    return 0
  fi

  v=""
  local UNREAD=0
  if [ "$metric" != none ]; then
    if v=$(archie_metric_csv "$metric"); then
      rm -f "$TOLD_DIR/$id"
    elif [ -e "$TOLD_DIR/$id" ]; then
      log "initiative $id: metric $metric unreadable, already told; no call"
      post_check "$id" "$due" unreadable "" "" "${RH}h" || true
      archie_wake_done "$id"
      return 0
    else
      # BH-4765: the first unreadable check of a stretch tells the operator once.
      log "initiative $id: metric $metric unreadable; telling it once"
      UNREAD=1; v=""
    fi
  fi
  # A woken check (BH-4063: a wake context is waiting) answers its events, so
  # the escalation rule does not silence it.
  local ctx=""
  ctx=$(archie_wake_context "$id") || ctx=""
  if [ "$UNREAD" = 0 ] && [ -z "$ctx" ] && ! archie_escalates "$rule" "$v" "$last"; then
    post_check "$id" "$due" silent "$v" "" 1 || true
    return 0
  fi

  # An unreadable metric is told with the fixed sentence when no call can run.
  local skip_call=0
  if [ "$USD_OFF" = 1 ]; then
    if [ "$UNREAD" = 1 ]; then
      log "initiative $id: ARCHIE_LLM_MAX_USD=0, model calls are off; the unreadable metric is told without a call"
      skip_call=1
    else
      log "initiative $id: ARCHIE_LLM_MAX_USD=0, model calls are off; row stays due"
      SKIPPED=$((SKIPPED + 1)); return 0
    fi
  fi
  if [ "$skip_call" = 0 ] && { ! model=$(lane_role_model stage.archie) || [ -z "$model" ]; }; then
    if [ "$UNREAD" = 1 ]; then
      log "initiative $id: no model route for stage.archie (rc 75); the unreadable metric is told without a call"
      skip_call=1
    else
      log "initiative $id: no model route for stage.archie (rc 75); nothing guessed, row stays due"
      SKIPPED=$((SKIPPED + 1)); return 0
    fi
  fi
  if [ "$skip_call" = 1 ]; then
    archie_wake_done "$id"
  else
    pf=$(mktemp "${TMPDIR:-/tmp}/archie-prompt.XXXXXX") || { SKIPPED=$((SKIPPED + 1)); return 0; }
    raw=$(mktemp "${TMPDIR:-/tmp}/archie-answer.XXXXXX") || { rm -f "$pf"; SKIPPED=$((SKIPPED + 1)); return 0; }
    { cat "$H"/prompts/archie-soul.d/*.md 2>/dev/null
      printf '\n'
      cat "$H/catalog/prompts/archie-check.md" 2>/dev/null
      printf '\n## Initiative and check\n'
      jq -c --arg v "$v" --arg d "$due" --arg n "$NOWISO" --argjson u "$([ "$UNREAD" = 1 ] && echo true || echo false)" \
        '{initiative: {id, goal, metric_query, escalation_rule, cadence_hours, links, last_value, last_decision, last_decision_note},
          check: {value: (if $v == "" then null else $v end), metric_unreadable: $u, due_at: $d, now: $n}}' <<<"$row"
      [ -n "$ctx" ] && printf '\n## Events this check is answering\n%s\n' "$ctx"
    } > "$pf"
    # The attempt is written BEFORE the call (no spend without the ledger): an
    # answer that is paid for and then lost still counts toward MAX_ATT.
    if ! post_check "$id" "$due" model_failed "$v" "$((att + 1))" 0 attempt; then
      log "initiative $id: attempt $((att + 1)) not recorded; no call, retried next tick"
      rm -f "$pf" "$raw"; SKIPPED=$((SKIPPED + 1)); return 0
    fi
    att=$((att + 1))
    MODEL_CALLS=$((MODEL_CALLS + 1))
    AGENT_CALL_LANE=archie AGENT_CALL_FP="archie:$id:$due" AGENT_CALL_BUDGET_USD_ARCHIE="$USD" \
      "$H/bin/agent-call.sh" archie fleet "$model" 300 "$raw" "@$pf" >/dev/null 2>&1
    rc=$?
    text=$(cat "$raw" 2>/dev/null)
    cost=""
    if [ "$rc" != 0 ] && { [ "$rc" -lt 74 ] || [ "$rc" -gt 79 ]; }; then
      cost=$(archie_budget_stop "$raw.json") || cost=""
    fi
    # agent-call leaves $raw.json, .err and other sidecars next to $raw.
    rm -f "$pf" "$raw" "$raw".*
    if [ "$rc" = 0 ]; then
      # >>> archie followup parse (BH-4063)
      archie_followup_parse "$text" "$id"
      text=$(archie_followup_strip "$text")
      archie_wake_done "$id"
      # <<< archie followup parse
    fi
    if [ "$rc" != 0 ]; then
      if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
        log "initiative $id: agent-call refused (rc=$rc, nothing billed); retried next tick"
        # Nothing was billed, so the attempt is handed back.
        post_check "$id" "$due" model_failed "$v" "$((att - 1))" 0 || true
        SKIPPED=$((SKIPPED + 1)); return 0
      fi
      if [ -n "$cost" ]; then
        # A budget stop is self-caused: billed and counted, retried after the
        # backoff, not a lost cadence. A failed write leaves the body `attempt`,
        # so the next tick treats it as an ordinary failure (the smaller cap).
        post_check "$id" "$due" model_failed "$v" "" 0 "budget_stop $(iso $((NOW + BACKOFF * 60))) usd=$USD cost=$cost" \
          || log "initiative $id: budget stop not recorded; treated as an ordinary failure"
        if [ "$class" != budget_stop ]; then
          HARNESS="$H" "$H/bin/alert-line.sh" "archie: initiative $id check $due hit its dollar cap (ARCHIE_LLM_MAX_USD=$USD, cost $cost); raise the settings row lane.archie.archie_llm_max_usd; retrying every ${BACKOFF}m, up to $RETRY_MAX attempts" >/dev/null 2>&1 || true
        fi
        [ "$att" -ge "$RETRY_MAX" ] && close_failed "$id" "$due" "$v" "$att" "hit its dollar cap $att times (ARCHIE_LLM_MAX_USD=$USD)"
        return 0
      fi
      [ "$att" -ge "$MAX_ATT" ] && close_failed "$id" "$due" "$v" "$att" "failed $att times"
      return 0
    fi
  fi
  # BH-4067: the decision class, then the ledger (which acts, for a delegated class).
  local split cls rec goal auto="" dresp drc
  split=$(archie_split_class "$text"); cls=${split%%$'\n'*}; rec=""
  [[ $split == *$'\n'* ]] && rec=${split#*$'\n'}
  goal=$(jq -r .goal <<<"$row")
  # BH-4765: an unreadable metric is always told. No call, a blank answer or a
  # no-action answer gets this sentence instead.
  if [ "$UNREAD" = 1 ] && { [[ $rec =~ ^[[:space:]]*$ ]] || archie_no_action "$rec"; }; then
    cls=ticket-file
    rec="I can't read the metric for I$id ($metric), so this goal has no number until the source is fixed. I'd file a ticket for the source."
  fi
  if [[ $rec =~ ^[[:space:]]*$ ]]; then
    post_check "$id" "$due" empty "$v" "" 1 || true
    return 0
  fi
  # >>> archie no-action (BH-4779)
  # "Nothing for you to do" is not a message: closed like a blank answer,
  # before the decision ledger, so no non-decision is recorded either.
  if archie_no_action "$rec"; then
    log "initiative $id: answer says nothing is needed; closed empty, nothing sent"
    post_check "$id" "$due" empty "$v" "" 1 || true
    return 0
  fi
  # <<< archie no-action
  local sens=false
  archie_sensitive "$cls" "$goal" "$rec" && sens=true
  dresp=$(_jobs_req POST /api/archie/decisions "$(jq -nc --arg k "check:$id:$due" --argjson i "$id" --arg c "$cls" \
    --argjson s "$sens" --arg r "$rec" '{escalation_key: $k, initiative_id: $i, class: $c, sensitive: $s,
      recommendation: ($r | gsub("^\\s+|\\s+$"; "") | .[0:2000])}')"); drc=$?
  if { [ "$drc" = 0 ] || [ "$drc" = 9 ]; } && jq -e '.decision.mode | type == "string"' <<<"$dresp" >/dev/null 2>&1; then
    # The ledger is the record of this escalation: a replay (or a 409 from an
    # earlier answer on the same slot) reports what it stored, never a new guess.
    rec=$(jq -r '.decision.recommendation' <<<"$dresp")
    [ "$(jq -r .decision.mode <<<"$dresp")" = auto ] && auto="auto:$(jq -r .decision.class <<<"$dresp")"
  else
    log "warn: initiative $id: decision ledger unavailable (rc=$drc http=${JOBS_HTTP:-none}); asking"
  fi
  if ! body=$(archie_compose "$rec" "$goal" "$([ "$UNREAD" = 1 ] && echo unreadable || printf %s "$v")" "$rule" "$(jq -c '.links // []' <<<"$row")" "$id" "$TEXT_MAX" "$auto"); then
    post_check "$id" "$due" empty "$v" "" 1 || true
    return 0
  fi
  # Written BEFORE the send: a lost send is resent from this, never re-asked.
  if ! post_check "$id" "$due" composed "$v" "" 0 "$body"; then
    # Paid for and not recorded. The attempt already counts; a refusal (4xx)
    # would refuse the same body again, so that closes the slot now.
    log "initiative $id: composed body not recorded (http=${JOBS_HTTP:-none}); not sending an unrecorded beat"
    if [[ ${JOBS_HTTP:-} =~ ^4 ]] || [ "$att" -ge "$MAX_ATT" ]; then
      close_failed "$id" "$due" "$v" "$att" "answered but its body could not be recorded (http=${JOBS_HTTP:-none})"
    fi
    return 0
  fi
  if [ "$UNREAD" = 1 ]; then
    send "$row" "$due" "$body" "$v" "${RH}h" "$id"
  else
    send "$row" "$due" "$body" "$v"
  fi
}

tick() {
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie
  case "${ARCHIE_ENABLED:-1}" in
    0) exit 0 ;;
    1) ;;
    *) log "warn: ARCHIE_ENABLED=${ARCHIE_ENABLED} is not 0 or 1; using the default 1" ;;
  esac
  exec 9>"$H/locks/archie.lock" || exit 0
  flock -n 9 || exit 0

  local max resp rc n row
  max=$(knob_int ARCHIE_MAX_PER_TICK "${ARCHIE_MAX_PER_TICK:-3}" 3 1 20)
  MAX_ATT=$(knob_int ARCHIE_MAX_ATTEMPTS "${ARCHIE_MAX_ATTEMPTS:-2}" 2 1 10)
  TEXT_MAX=$(knob_int ARCHIE_TEXT_MAX_CHARS "${ARCHIE_TEXT_MAX_CHARS:-600}" 600 100 2000)
  RETRY_MAX=$(knob_int ARCHIE_RETRY_MAX "${ARCHIE_RETRY_MAX:-6}" 6 1 48)
  BACKOFF=$(knob_int ARCHIE_RETRY_BACKOFF_MIN "${ARCHIE_RETRY_BACKOFF_MIN:-60}" 60 15 1440)
  RECHECK_H=$(knob_int ARCHIE_UNREADABLE_RECHECK_H "${ARCHIE_UNREADABLE_RECHECK_H:-24}" 24 1 168)
  USD="${ARCHIE_LLM_MAX_USD:-0.60}"
  if ! [[ $USD =~ ^[0-9]+(\.[0-9]+)?$ ]]; then log "warn: ARCHIE_LLM_MAX_USD=$USD is not a number; using the default 0.60"; USD=0.60; fi
  CHECKED=0; BEATS=0; MODEL_CALLS=0; SKIPPED=0

  # >>> archie wake (BH-4063)
  # Events mark initiatives due now (bin/lib/archie-wake.sh); held beats go out
  # as one digest when quiet hours and the cap allow. Both before the due read.
  archie_wake_init
  archie_wake_collect
  archie_digest_flush
  # <<< archie wake

  resp=$(_jobs_req GET "/api/initiatives?status=active&due_before=$NOWISO&limit=$max"); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '.initiatives | type == "array"' <<<"$resp" >/dev/null 2>&1; then
    log "could not read the due initiatives (rc=$rc http=${JOBS_HTTP:-none}); nothing checked"
    exit 0
  fi
  n=$(jq '.initiatives | length' <<<"$resp")
  [ "$n" -gt 0 ] || exit 0
  [ "$(jq -r '.truncated == true' <<<"$resp")" = true ] \
    && log "more than $max initiatives due; the rest are deferred to the next tick"
  USD_OFF=0
  awk -v u="$USD" 'BEGIN { exit !(u + 0 > 0) }' || USD_OFF=1
  while IFS= read -r row; do
    check_row "$row"
  done < <(jq -c '.initiatives[]' <<<"$resp")
  log "due=$n checked=$CHECKED beats=$BEATS model_calls=$MODEL_CALLS skipped=$SKIPPED"
  exit 0
}

case "$MODE" in
  tick) tick ;;
  intercept) shift; intercept "${1:-}"; exit $? ;;
  *) echo "usage: archie.sh tick | archie.sh intercept <text>" >&2; exit 2 ;;
esac
