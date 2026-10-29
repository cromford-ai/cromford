# shellcheck shell=bash
# bin/lib/vendor/telegram.sh — the Telegram Bot API seam (BH-7939.0). Sourced
# only. Every call takes the NAME of the env variable that holds the bot token,
# never the token, so the token is in no argv and no log. curl reads its URL
# from stdin (`-K -`) through printf, a builtin, so the token is not in
# /proc/<pid>/cmdline either. In fake mode (HARNESS_VENDOR_FAKE=1) the answer
# comes from tests/fixtures/vendor-fake/telegram.json (bin/lib/vendor/seam.sh)
# and no call is made.
# shellcheck source=seam.sh
. "${BASH_SOURCE[0]%/*}/seam.sh" || return 1

# tg_call <token_var_name> <method> — print the raw answer of one Bot API GET.
# rc 2 bad variable name or vendor mode, rc 3 token not set, rc 1 curl failed
# (the error with the token cut), rc 70 an unseeded fake method.
tg_call() {
  local name="${1:-}" method="${2:-}" tok mode body rc
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "telegram: '$name' is not a variable name" >&2; return 2; }
  tok="${!name:-}"
  [ -n "$tok" ] || { echo "telegram: $name is not set" >&2; return 3; }
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    vendor_fake telegram "$method"
    return $?
  fi
  vendor_call_log telegram "$method"
  local tmo="${TELEGRAM_API_TIMEOUT_S:-20}"   # knob: catalog/lanes.d/_lib.vendor-telegram.knobs.d
  [[ $tmo =~ ^[0-9]+$ ]] && [ "$tmo" -ge 1 ] && [ "$tmo" -le 120 ] || tmo=20
  tok="${tok//\\/\\\\}"; tok="${tok//\"/\\\"}"
  body=$(printf 'url = "https://api.telegram.org/bot%s/%s?timeout=0"\n' "$tok" "$method" \
    | curl -sS --max-time "$tmo" -K - 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    body="${body//"${!name}"/<token>}"
    echo "telegram: curl rc $rc: ${body//"$tok"/<token>}" >&2
    return 1
  fi
  printf '%s\n' "$body"
}

# tg_latest_chat_id <token_var_name> — print the chat id of the newest
# `message`, `channel_post` or `my_chat_member` update (walked from the last
# element back). getUpdates is called with no offset, so no update is confirmed.
# rc 0 the id, rc 4 no such update yet, rc 1 a Telegram error (`description`,
# token cut), a bad answer or an id that is not an integer; rc 2/3/70 as tg_call.
# Errors go to stderr; stdout holds only an id.
tg_latest_chat_id() {
  local body rc res id
  body=$(tg_call "${1:-}" getUpdates) || return $?
  res=$(jq -r '
    if type != "object" then "bad"
    elif .ok != true then "err\t" + ((.description // "no description") | tostring)
    elif (.result | type) != "array" then "bad"
    else [ .result[] | (.message.chat.id // .channel_post.chat.id // .my_chat_member.chat.id // empty) ]
      | if length == 0 then "none" else "id\t" + (last | tostring) end
    end' <<<"$body" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ -n "$res" ] || res=bad
  case "$res" in
    none) return 4 ;;
    err*) res="${res#*$'\t'}"; echo "telegram: ${res//"${!1}"/<token>}" >&2; return 1 ;;
    id*)  id="${res#*$'\t'}"
          [[ "$id" =~ ^-?[0-9]+$ ]] || { echo "telegram: chat id is not an integer" >&2; return 1; }
          printf '%s\n' "$id"; return 0 ;;
  esac
  echo "telegram: bad answer" >&2
  return 1
}

# _tg_q <value> — the value as a quoted curl config string: backslash, quote,
# CR, LF and tab escaped, so a text line can never start a new config option.
_tg_q() {
  local v="${1//\\/\\\\}"
  v="${v//\"/\\\"}"; v="${v//$'\n'/\\n}"; v="${v//$'\r'/\\r}"; v="${v//$'\t'/\\t}"
  printf '"%s"' "$v"
}

# tg_send_message <token_var_name> <chat> <thread|""> <text> [<reply_markup_json>]
# — one sendMessage POST (BH-8650). Print the raw answer; the caller reads
# `.ok`. curl reads its whole config from stdin (`-K -`) through printf, so the
# token, the text and the markup are in no argv. The thread is sent only when
# given. rc 0 curl answered, rc 1 curl failed (the error with the token cut),
# rc 2/3/70 as tg_call.
tg_send_message() {
  local name="${1:-}" chat="${2:-}" thread="${3:-}" text="${4:-}" markup="${5:-}" tok mode body rc
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "telegram: '$name' is not a variable name" >&2; return 2; }
  tok="${!name:-}"
  [ -n "$tok" ] || { echo "telegram: $name is not set" >&2; return 3; }
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    vendor_fake telegram sendMessage
    return $?
  fi
  vendor_call_log telegram sendMessage
  local tmo="${TELEGRAM_API_TIMEOUT_S:-20}"   # knob: catalog/lanes.d/_lib.vendor-telegram.knobs.d
  [[ $tmo =~ ^[0-9]+$ ]] && [ "$tmo" -ge 1 ] && [ "$tmo" -le 120 ] || tmo=20
  body=$({
    printf 'url = %s\n' "$(_tg_q "https://api.telegram.org/bot$tok/sendMessage")"
    printf 'form-string = %s\n' "$(_tg_q "chat_id=$chat")"
    [ -z "$thread" ] || printf 'form-string = %s\n' "$(_tg_q "message_thread_id=$thread")"
    printf 'form-string = %s\n' "$(_tg_q "text=$text")"
    printf 'form-string = %s\n' "$(_tg_q "disable_web_page_preview=true")"
    [ -z "$markup" ] || printf 'form-string = %s\n' "$(_tg_q "reply_markup=$markup")"
  } | curl -sS --max-time "$tmo" -K - 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "telegram: curl rc $rc: ${body//"$tok"/<token>}" >&2
    return 1
  fi
  printf '%s\n' "$body"
}
