#!/bin/bash
# bin/archie-tg-send.sh — BH-4779: the ONE way Archie talks to the operator. Sends
# <text> as a Telegram sendMessage (plain text, no parse_mode, cut into
# 4000-character chunks) from the bot bin/orchestrate.sh replies with
# (TELEGRAM_BOT_TOKEN in env/global.env).
#
#   archie-tg-send.sh <akey> <text>
#
# Callers: bin/lib/archie-wake.sh (archie_beat_gate: every check and
# follow-up-woken check; archie_digest_flush: the held-beat digest),
# bin/daily-digest.sh (Archie's daily factory report), bin/archie-research.sh
# (the daily line and the weekly research digest) and bin/archie-learn.sh (the
# weekly learning report).
#
# TARGET. The settings row lane.archie.archie_telegram_target, shape
# <chat_id> or <chat_id>/<thread_id>; the thread is sent only to a -100…
# supergroup (the orchestrate.sh rule). Absent: the operator's DM, the chat
# lib.lane-alert.lane_alert_dm_chat (catalog/lanes.d/_lib.lane-alert.json),
# resolved the way bin/lane-alert.sh does, in a subshell. A malformed row is one
# warn line in logs/archie.log and that default, never a silent clamp. This
# script holds no chat id of its own.
#
# EXACTLY ONCE. jobs ledger archie_tg/<akey> is read BEFORE any send: `sent`
# answers rc 0 with no request to Telegram. It is written `sent` (detail
# {chat, thread, message_ids, chunks, at}) only after every chunk came back
# "ok":true. The one double-send window left is a crash between Telegram's ok
# and that write; a chunk-2 failure resends the whole text.
#
# rc 0   sent now, or already sent for this akey
# rc 1   Telegram refused or did not answer (nothing recorded; the caller retries)
# rc 2   no token or no target (ONE ALERTS line a day each; nothing is lost)
#        (no token also prints the cause and the fix on stderr, BH-8953)
# rc 3   the jobs ledger did not answer (nothing sent without the dedupe read)
# rc 64  usage: an empty akey or a blank text
#
# The token rides curl's STDIN config (-K -), never its argv. logs/archie.log
# gets one line per call: tg <akey> chat=<id> chunks=<n> rc=<rc> (never the
# token or the text). Note: docs/notes/2026-10-06-BH-4779-archie-dm.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
}
# The suite's seam, the same one bin/archie.sh has. Sandbox only, settable:false.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_FIXTURE"
fi

AKEY="${1:-}"
TEXT="${2:-}"
# Characters, not bytes, when the text is cut into chunks.
LC_ALL=C.UTF-8
mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/archie.log"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
CHAT=""; CHUNKS=0
done_rc() { log "tg $AKEY chat=${CHAT:-none} chunks=$CHUNKS rc=$1"; exit "$1"; }

if [ -z "$AKEY" ] || [ -z "${TEXT//[[:space:]]/}" ]; then
  echo "usage: archie-tg-send.sh <akey> <text>  (both non-blank)" >&2
  exit 64
fi
command -v job_ledger_get >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { log "tg $AKEY: jobs-client or jq missing; nothing sent"; exit 3; }

# 1. The dedupe read, before anything else.
st=$(job_ledger_get archie_tg "$AKEY" 2>/dev/null); rc=$?
case "$rc" in
  0) if [ "$st" = sent ]; then log "tg $AKEY already sent; nothing to do"; exit 0; fi ;;
  2) ;;
  *) log "tg $AKEY: the jobs ledger did not answer; nothing sent, retried"; done_rc 3 ;;
esac

# 2. The target: the settings row, else the operator's DM.
TGT=""
if command -v lane_knob >/dev/null 2>&1; then
  TGT=$(lane_knob archie ARCHIE_TELEGRAM_TARGET 2>/dev/null)
else
  TGT="${ARCHIE_TELEGRAM_TARGET:-}"
fi
if [ -n "$TGT" ] && ! [[ $TGT =~ ^-?[0-9]{5,20}(/[0-9]{1,12})?$ ]]; then
  log "warn: ARCHIE_TELEGRAM_TARGET=$TGT is not <chat_id> or <chat_id>/<thread_id>; using the operator's DM (lib.lane-alert.lane_alert_dm_chat)"
  TGT=""
fi
if [ -z "$TGT" ]; then
  if command -v lib_env_apply >/dev/null 2>&1; then
    TGT=$(lib_env_apply lane-alert >/dev/null 2>&1; printf '%s' "${LANE_ALERT_DM_CHAT:-}")
  else
    TGT="${LANE_ALERT_DM_CHAT:-}"
  fi
  if [ -n "$TGT" ] && ! [[ $TGT =~ ^-?[0-9]{5,20}$ ]]; then
    log "warn: LANE_ALERT_DM_CHAT=$TGT is not a chat id; no target"
    TGT=""
  fi
fi
if [ -z "$TGT" ]; then
  command -v _lg_alert_once >/dev/null 2>&1 && _lg_alert_once archie-tg-target \
    "archie: no Telegram target (lane.archie.archie_telegram_target and lib.lane-alert.lane_alert_dm_chat both empty); Archie messages stay queued"
  done_rc 2
fi
CHAT=${TGT%%/*}
THREAD=""
if [[ $TGT == */* ]]; then
  if [[ $CHAT == -100* ]]; then
    THREAD=${TGT#*/}
  else
    log "warn: ARCHIE_TELEGRAM_TARGET=$TGT names a thread on a chat that is not a supergroup; sent without it"
  fi
fi

# 3. The token.
# BH-8953: the bot token lives on the hub only (the fleet:telegram envelope), so
# a send from a box is a placement bug. Say the cause and the fix on stderr and
# in archie.log, never quietly; the line names the variable, never a value.
TOK="${TELEGRAM_BOT_TOKEN:-}"
if [ -z "$TOK" ]; then
  why="archie-tg-send: no TELEGRAM_BOT_TOKEN on $(hostname); the bot token lives on the hub only (BH-8953); run this send from a hub lane (cron/boxes/hub.d or # @box hub); nothing sent for $AKEY"
  printf '%s\n' "$why" >&2
  log "$why"
  command -v _lg_alert_once >/dev/null 2>&1 && _lg_alert_once archie-tg-token \
    "archie: TELEGRAM_BOT_TOKEN is not set on $(hostname); the bot token lives on the hub only (BH-8953), so run this send from a hub lane; nothing was sent"
  done_rc 2
fi

# 4. The send, chunk by chunk; any chunk not ok fails the whole call.
THREAD_ARG=()
[ -n "$THREAD" ] && THREAD_ARG=(--data-urlencode "message_thread_id=$THREAD")
REST="$TEXT"; TOTAL=$(( (${#TEXT} + 3999) / 4000 )); IDS="[]"; i=0
while [ -n "$REST" ]; do
  CHUNK="${REST:0:4000}"; REST="${REST:4000}"; i=$((i + 1))
  resp=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOK" | \
    curl -s --max-time 20 -K - \
      --data-urlencode "chat_id=$CHAT" ${THREAD_ARG[@]+"${THREAD_ARG[@]}"} \
      --data-urlencode "text=$CHUNK" --data-urlencode "disable_web_page_preview=true" 2>/dev/null)
  crc=$?
  if [ "$crc" != 0 ] || ! jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
    why=$(jq -r '.description // empty' <<<"$resp" 2>/dev/null)
    [ -n "$why" ] || why="curl rc=$crc"
    log "tg $AKEY: send failed (chunk $i/$TOTAL: $why)"
    CHUNKS=$((i - 1)); done_rc 1
  fi
  IDS=$(jq -c --argjson a "$IDS" '$a + [.result.message_id // null]' <<<"$resp")
done
CHUNKS=$i

# 5. The record. The message is out: a lost write is a warn line, not a failure.
detail=$(jq -nc --arg c "$CHAT" --arg t "$THREAD" --argjson m "$IDS" --argjson n "$CHUNKS" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{chat: $c, thread: (if $t == "" then null else $t end), message_ids: $m, chunks: $n, at: $at}')
job_ledger_put archie_tg "$AKEY" sent "$detail" >/dev/null 2>&1 \
  || log "warn: tg $AKEY was delivered but archie_tg could not be written; the caller's own sent write is the record"
done_rc 0
