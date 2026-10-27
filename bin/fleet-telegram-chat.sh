#!/bin/bash
# bin/fleet-telegram-chat.sh — store the hub bot's Telegram chat id as settings
# rows (BH-7939.0). Usage: bin/fleet-telegram-chat.sh   (no arguments)
#
# The token is TELEGRAM_BOT_TOKEN from the environment, else the one line of
# env/global.env (never exported, never printed). tg_latest_chat_id
# (bin/lib/vendor/telegram.sh) gets it by NAME and answers the newest chat that
# wrote to the bot. The rows go through PUT /api/settings, actor
# fleet-telegram-chat, in order, and the first non-2xx stops the sequence:
#   seam rc 0   telegram.chat_id=<id>, telegram.bot_present=1, telegram.state=ok,
#               then GET /api/settings/telegram.chat_id must answer the same id;
#   seam rc 4   telegram.state=waiting_for_message only, never a chat id;
#   otherwise   no row.
# It prints exactly one line:
#   TELEGRAM_CHAT ok <id> | TELEGRAM_CHAT waiting <what to do> | TELEGRAM_CHAT failed <why>
# Exit: 0 ok or waiting, 1 failed, 2 an argument was given (nothing sent).
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
ACTOR=fleet-telegram-chat

[ $# -eq 0 ] || { echo "usage: bin/fleet-telegram-chat.sh"; exit 2; }

fail() {
  local why="$1"
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || why="${why//"$TELEGRAM_BOT_TOKEN"/<token>}"
  printf 'TELEGRAM_CHAT failed %s\n' "$(printf '%s' "${why:-unknown error}" | tr '\n\t' '  ')"
  exit 1
}

# settings_write <readback-key> <want> <key=value>... — ONE subshell sources the
# jobs client (the bin/factory-stop.sh shape), PUTs each row in order, then
# reads <readback-key> back when it is set. Prints why on a failure.
settings_write() (
  local rkey="$1" want="$2" kv body got
  shift 2
  [ -r "$HARNESS/bin/jobs-client.sh" ] || { echo "jobs not configured"; exit 3; }
  # shellcheck disable=SC1091
  . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || { echo "jobs not configured"; exit 3; }
  command -v _jobs_req >/dev/null 2>&1 && [ -n "${JOBS_URL:-}" ] || { echo "jobs not configured"; exit 3; }
  for kv in "$@"; do
    body=$(jq -nc --arg k "${kv%%=*}" --arg v "${kv#*=}" --arg a "$ACTOR" --arg r "$REASON" \
      '{key:$k, value:$v, actor:$a, reason:$r}')
    _jobs_req PUT /api/settings "$body" >/dev/null 2>&1
    case "${JOBS_HTTP:-}" in 2*) ;; *) echo "PUT ${kv%%=*} answered http=${JOBS_HTTP:-unreachable}"; exit 1 ;; esac
  done
  [ -n "$rkey" ] || exit 0
  _jobs_req GET "/api/settings/$rkey" >/dev/null 2>&1
  case "${JOBS_HTTP:-}" in 2*) ;; *) echo "read-back GET $rkey answered http=${JOBS_HTTP:-unreachable}"; exit 1 ;; esac
  got=$(jq -r '.setting.value // empty' <<<"${JOBS_BODY:-}" 2>/dev/null)
  [ "$got" = "$want" ] || { echo "read-back of $rkey is '$got', not '$want'"; exit 1; }
)

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  # shellcheck source=lib/env-path.sh
  . "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || fail "bin/lib/env-path.sh missing"
  tok=$(sed -n 's/^\(export \)\{0,1\}TELEGRAM_BOT_TOKEN=//p' "$(harness_env_dir "$HARNESS")/global.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  unset TELEGRAM_BOT_TOKEN
  TELEGRAM_BOT_TOKEN="$tok"; unset tok
fi

# shellcheck source=lib/vendor/telegram.sh
. "$HARNESS/bin/lib/vendor/telegram.sh" 2>/dev/null || fail "bin/lib/vendor/telegram.sh missing"
out=$(tg_latest_chat_id TELEGRAM_BOT_TOKEN 2>&1); rc=$?
case "$rc" in
  0)
    [[ "$out" =~ ^-?[0-9]+$ ]] || fail "chat id '$out' is not an integer"
    REASON="chat id of the newest update to the bot"
    why=$(settings_write telegram.chat_id "$out" "telegram.chat_id=$out" telegram.bot_present=1 telegram.state=ok) || fail "$why"
    echo "TELEGRAM_CHAT ok $out"
    ;;
  4)
    REASON="the bot has no update yet"
    why=$(settings_write "" "" telegram.state=waiting_for_message) || fail "$why"
    echo "TELEGRAM_CHAT waiting no update yet: send any message to the bot, then check again"
    ;;
  *) fail "${out:-tg_latest_chat_id rc $rc}" ;;
esac
exit 0
