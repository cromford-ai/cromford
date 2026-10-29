# PM brief: Telegram Approve and Reject buttons (BH-8650)

Doc: CONSOLE, PROJECT-LANES

Follow-up of #7654 (BH-7261). The weekly PM brief goes to Telegram with one
Mission Control link per move. Now a second message follows it, with an
Approve and a Reject button for each proposed move. A press runs the same
decide handler as the Mission Control action (`POST /api/pm/moves/decide` in
`worker/jobs/src/routes/pm-brief.js`). The links stay in the brief text as the
fallback.

## The message

`bin/pm-groom.sh` `send()`: after `bin/archie-tg-send.sh` delivered the text and
`POST /api/pm/briefs/sent` answered, it calls `pmtb_send <project> <week>`
(`bin/lib/pm-tg-buttons.sh`). The settings row `pm.tg_buttons_enabled`
(0..1, seed and code fallback 0) gates that call. At 0 the lane logs
`buttons=skip disabled (settings pm.tg_buttons_enabled=0)` and makes no
keyboard read. The row stays 0 until cromford-console forwards `pm:`
callbacks to `POST /api/pm/moves/tg`; turn it on in that change set, so no box
sends a button that does nothing. That function:

1. Stops with `buttons=skip not-configured` when TELEGRAM_BOT_TOKEN is not set.
2. Reads the ledger row `pm_tg_buttons/<project>:<week>`. `sent` is
   `buttons=skip already-sent`. A failed read is `buttons=skip
   ledger-unreadable` (no send without the dedupe read).
3. Reads `GET /api/pm/moves/tg-keyboard?project=&week=`. The worker builds the
   text and the signed `reply_markup`.
4. Reads the chat and thread of the brief text from `archie_tg/pm-brief:<project>:<week>`.
5. Sends ONE message through the seam `tg_send_message` (`bin/lib/vendor/telegram.sh`).
   On `.ok == true` with a number `message_id` it writes `pm_tg_buttons`
   `sent` with `{chat, message_id, moves, at}`.

The lane logs the outcome line. `buttons=failed ...` is also one ALERTS line:
"the <week> brief went out, but its Telegram buttons did not (...); the Mission
Control links still work". `buttons=sent <id> ledger-write-failed` is also
one ALERTS line, because a rerun the same week can send a second keyboard. No outcome changes the lane's rc or `sent_tg`.

The weekly cron never resends. A manual `bin/pm-groom.sh <project>` rerun in
the same ISO week sends the keyboard only on the existing resend path
(`sent_tg` still 0).

## The callback

`callback_data` is `pm:<a|r>:<move_id>:<sig12>`. The move id is
`<brief uuid>.mNN` or `.mNNN`. `sig12` is the first 12 base64url characters of
HMAC-SHA256(key = HARNESS_SECRET, message = `pm-tg-v1|pm:<a|r>:<move_id>`).
The longest form is 59 bytes; Telegram allows 64.

`POST /api/pm/moves/tg` with the forwarded update `{callback_query: {data, from}}`:

| Status | reason | When | text |
|---|---|---|---|
| 200 changed:true | approved | the idea moved | Approved. <title> moved from <from> to <to>. |
| 200 changed:true | rejected | the move is rejected | Rejected. <title> stays in <from>. |
| 200 changed:true | stale | the idea left from_col first | Not applied. <title> is no longer in <from>. Nothing changed. |
| 200 changed:false | already | the move was decided before | Already <status> by <decided_by>. Nothing changed. |
| 400 | bad_form | not a `pm:` callback in this format | This is not a PM brief button. Nothing changed. |
| 404 | unknown | no such move, or a bad signature (one answer) | This button is not a known move. Nothing changed. |
| 410 | expired | the move's brief is not the project's newest brief | This move is from the <week> brief. A newer brief replaced it. Nothing changed. |

The actor is `tg:<from.username>`, else `tg:<from.id>`, else `tg:unknown`.
Anyone in the target chat can press, the same rule as the web-task Done
button. The route never calls fetch or Telegram.

## Knob

`pm.tg_buttons_max` (settings row, 1..50, seed and fallback 25): the proposed
moves that get buttons. The rest are named in the message text and keep their
Mission Control link. The text is kept at or under 4000 characters (a format
bound under Telegram's 4096, not a knob): titles are cut evenly when needed.

## Operator steps

The Telegram webhook belongs to the console backend (`/api/telegram/webhook`,
cromford-console). Until it forwards `pm:` callbacks, a press shows a
spinner and nothing else, and the Mission Control link still works.

1. In the console webhook, forward every update whose `callback_query.data`
   starts with `pm:` verbatim to `$JOBS_URL/api/pm/moves/tg`, with the jobs bearer.
2. Call answerCallbackQuery with the answer's `.text`, on every status.
