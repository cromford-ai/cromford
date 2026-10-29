# shellcheck shell=bash
# bin/lib/pm-tg-buttons.sh — BH-8650: the Telegram Approve/Reject keyboard for
# the moves of a PM grooming brief. Sourced only (bin/pm-groom.sh send()); no
# output at source time. The caller provides _jobs_req and the job_ledger_*
# functions (bin/jobs-client.sh). Every send goes through the vendor seam
# bin/lib/vendor/telegram.sh (tg_send_message); this file makes no request to
# Telegram itself.
#
# pmtb_send <project> <week> — after the brief text went out, send ONE more
# message to the same chat and thread: the text and reply_markup that the
# worker builds and signs (GET /api/pm/moves/tg-keyboard). Prints ONE outcome
# line, always rc 0:
#   buttons=skip not-configured     no TELEGRAM_BOT_TOKEN (no request of any kind)
#   buttons=skip already-sent       ledger pm_tg_buttons/<project>:<week> is sent
#   buttons=skip ledger-unreadable  that ledger read failed (no send without it)
#   buttons=failed keyboard-read    the keyboard GET failed or is not a keyboard
#   buttons=skip no-moves           no proposed move has a button
#   buttons=skip no-chat            no archie_tg/pm-brief:<project>:<week> chat
#   buttons=failed <code> <desc>    Telegram refused (desc cut to 120), or
#                                   `seam rc=<n>` when the seam failed
#   buttons=sent <message_id>       sent; the ledger row is written after the ok
#   buttons=sent <id> ledger-write-failed  sent, but the ledger row did not land
#                                   (a manual rerun this week can send it again)
# The caller writes the ALERTS line for a `buttons=failed` outcome. The Mission
# Control links in the brief text stay the fallback in every case.
# Note: docs/notes/2026-10-27-BH-8650-pm-tg-buttons.md.
# shellcheck source=vendor/telegram.sh
. "${BASH_SOURCE[0]%/*}/vendor/telegram.sh" || return 1

pmtb_send() {
  local p="${1:-}" w="${2:-}" key st rc pe kb row chat thread ans mid detail code desc
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then echo "buttons=skip not-configured"; return 0; fi
  key="$p:$w"
  st=$(job_ledger_get pm_tg_buttons "$key" 2>/dev/null); rc=$?
  case "$rc" in
    0) if [ "$st" = sent ]; then echo "buttons=skip already-sent"; return 0; fi ;;
    2) ;;
    *) echo "buttons=skip ledger-unreadable"; return 0 ;;
  esac
  pe=$(jq -rn --arg p "$p" '$p | @uri')
  kb=$(_jobs_req GET "/api/pm/moves/tg-keyboard?project=$pe&week=$w" 2>/dev/null) \
    && jq -e '(.text | type) == "string" and (.reply_markup.inline_keyboard | type) == "array"' <<<"$kb" >/dev/null 2>&1 \
    || { echo "buttons=failed keyboard-read"; return 0; }
  if [ "$(jq '.reply_markup.inline_keyboard | length' <<<"$kb")" = 0 ]; then echo "buttons=skip no-moves"; return 0; fi
  # The chat and thread the brief text went to (bin/archie-tg-send.sh step 5).
  row=$(job_ledger_row archie_tg "pm-brief:$key" 2>/dev/null) || row=""
  chat=$(jq -r '(.detail // "") | fromjson? | .chat // empty | tostring' <<<"$row" 2>/dev/null)
  thread=$(jq -r '(.detail // "") | fromjson? | .thread // empty | tostring' <<<"$row" 2>/dev/null)
  [ -n "$chat" ] || { echo "buttons=skip no-chat"; return 0; }
  ans=$(tg_send_message TELEGRAM_BOT_TOKEN "$chat" "$thread" "$(jq -r '.text' <<<"$kb")" "$(jq -c '.reply_markup' <<<"$kb")" 2>/dev/null); rc=$?
  if [ "$rc" != 0 ]; then echo "buttons=failed seam rc=$rc"; return 0; fi
  if mid=$(jq -er 'select(.ok == true) | .result.message_id | numbers' <<<"$ans" 2>/dev/null); then
    detail=$(jq -nc --arg c "$chat" --argjson m "$mid" --argjson n "$(jq '.moves | length' <<<"$kb")" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{chat: $c, message_id: $m, moves: $n, at: $at}')
    if job_ledger_put pm_tg_buttons "$key" sent "$detail" >/dev/null 2>&1; then echo "buttons=sent $mid"
    else echo "buttons=sent $mid ledger-write-failed"; fi
    return 0
  fi
  code=$(jq -r '.error_code // "none"' <<<"$ans" 2>/dev/null) || code=none
  desc=$(jq -r '.description // "no description"' <<<"$ans" 2>/dev/null) || desc="the answer is not JSON"
  # 120 is a format bound for one log line, not a knob (BH-7945).
  echo "buttons=failed ${code:-none} ${desc:0:120}"
  return 0
}
