#!/bin/bash
# bin/lib/web-human/telegram.sh — BH-7598: the Telegram seam of the web-task
# human step (bin/lib/web-human.sh). Sourced, never run; functions only. The
# one place this lane calls the Telegram Bot API.
#
#   wht_send <chat> <kind> <text> <step_id> <nonce> [<png>]
#     ONE send to <chat>: sendPhoto (the png, <text> as the caption) when a png
#     is given, else sendMessage. The inline keyboard is "Done" and "Cancel"
#     for kind approve and "Cancel" for kind code (a code is a reply to the
#     message); each button's callback_data is wt:<step_id>:<nonce>:d|c, the
#     format routes/web-task-human.js parses. <text> carries the ref: line.
#     Prints ONE outcome on stdout:
#       sent <message_id>                  rc 0, only for .ok == true and a message id
#       not-configured: TELEGRAM_BOT_TOKEN rc 1, no request
#       not-configured: chat               rc 1, no request
#       failed <http> <description>        rc 1
#     The bot token, the chat, the text and the buttons go to curl in a -K
#     config from printf (a builtin), so none of them is on a process argv.
#
# Reads TELEGRAM_BOT_TOKEN and WEB_HUMAN_TG_API (the Bot API base URL, default
# https://api.telegram.org; a test points it at a local fake) from the
# environment, and the timeouts WEB_HUMAN_TIMEOUT_S / WEB_HUMAN_CONNECT_TIMEOUT_S
# (lib knobs of web-human, catalog/lanes.d/_lib.web-human.json). Needs curl and jq.

# A curl config value inside double quotes: \ " and newlines escaped.
_wht_q() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s//$'\n'/\\n}"
}

# _wht_cfg <method> <chat> <text-field> <text> <markup> [<png>] — the curl config of one send.
_wht_cfg() {
  printf 'url = "%s/bot%s/%s"\n' "$(_wht_q "${WEB_HUMAN_TG_API:-https://api.telegram.org}")" "$(_wht_q "$TELEGRAM_BOT_TOKEN")" "$1"
  printf 'form-string = "chat_id=%s"\n' "$(_wht_q "$2")"
  printf 'form-string = "%s=%s"\n' "$3" "$(_wht_q "$4")"
  printf 'form-string = "reply_markup=%s"\n' "$(_wht_q "$5")"
  [ -z "${6:-}" ] || printf 'form = "photo=@%s;type=image/png"\n' "$(_wht_q "$6")"
}

wht_send() {
  local chat="${1:-}" kind="${2:-}" text="${3:-}" step="${4:-}" nonce="${5:-}" png="${6:-}"
  local method=sendMessage field=text markup out code body mid
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || { echo "not-configured: TELEGRAM_BOT_TOKEN"; return 1; }
  [ -n "$chat" ] || { echo "not-configured: chat"; return 1; }
  if ! [[ $step =~ ^[1-9][0-9]{0,15}$ && $nonce =~ ^[A-Za-z0-9_-]{22}$ ]]; then echo "failed 000 bad step or nonce"; return 1; fi
  local cancel="{\"text\":\"Cancel\",\"callback_data\":\"wt:$step:$nonce:c\"}"
  if [ "$kind" = approve ]; then
    markup="{\"inline_keyboard\":[[{\"text\":\"Done\",\"callback_data\":\"wt:$step:$nonce:d\"},$cancel]]}"
  else
    markup="{\"inline_keyboard\":[[$cancel]]}"
  fi
  [ -z "$png" ] || { method=sendPhoto; field=caption; }
  out=$(curl -sS -m "${WEB_HUMAN_TIMEOUT_S:-15}" --connect-timeout "${WEB_HUMAN_CONNECT_TIMEOUT_S:-5}" -w $'\n%{http_code}' \
          -K <(_wht_cfg "$method" "$chat" "$field" "$text" "$markup" "$png") 2>/dev/null) \
    || { echo "failed 000 unreachable"; return 1; }
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  mid=$(printf '%s' "$body" | jq -r 'if .ok == true and (.result.message_id | type) == "number" then .result.message_id else empty end' 2>/dev/null)
  if [ "$code" = 200 ] && [ -n "$mid" ]; then echo "sent $mid"; return 0; fi
  echo "failed $code $(printf '%s' "$body" | jq -r '.description // empty' 2>/dev/null | head -c 120)"
  return 1
}
