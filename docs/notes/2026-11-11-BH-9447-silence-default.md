# BH-9447: a safe recommended lever runs when nobody answers a Tackler card

Doc: docs/verification-map/entries/BH-9447.md

the operator's decision, 2026-11-10: when the recommended option of a Tackler card is
a safe lever, silence means "run it". It starts with cromford only.

## The rule

A card runs its recommended option on silence only when all of these are true:

1. The project row `unblock.silence_auto.<p>` is exactly `on`. No row, or any
   other word, is off.
2. The recommended option's lever (the card's `levers` array, checked by
   `_unblock_card_levers` in `bin/lib/unblock/card.sh`) is in the safe list.
3. The card's class is not a never-auto class.
4. The silence sweep can build an act.sh record for the lever and the subject
   (`unblock_silence_record`, `bin/lib/unblock/silence.sh`).
5. the operator was shown the card: it went to the operator direct (`card.route operator`), or it
   was routed to the operator and paged (`routed_to operator`, `paged_at` set).
6. The card is open for `unblock.silence_auto_after_min` minutes, and the time
   the card text promised (`card.silence_at`) has passed.
7. The worker claim succeeds: the card was not claimed before, and the
   project is under its day cap.

The card text says what happens. A card that meets 1 to 4 at compose time
says `DEFAULT: option <n> runs at <UTC time> if you do not answer. Reply
"Tackler <id> hold" to stop it.` Every other card keeps `DEFAULT: it stays as
it is now; nothing runs on silence.` A card composed before this change has no
`silence_at` and never runs on silence.

The lever runs through `ub_act` (`bin/lib/unblock/act.sh`), so every gate of
the writer stays: never-auto, the `unblock.project.<p>.mode` opt-in, the head
re-read and the GitHub marker `<!-- tackler:silence:<card id> -->`.

- `done`: the worker records the card as answered: `answer` = the
  recommendation, `answered_by` and `answer_source` = `silence-default`.
- `failed`, `refused` or `would`: the card stays open with its deadline. No
  second page. The claim stops a second attempt.
- Every run sends one info line, never critical:
  `Tackler <id>: no answer in <n> min, ran <lever>: <outcome>`.

A `hold` answer moves the row to `answered`, so the sweep never sees it. A
moved head ends `refused head-moved` at the act.sh head gate.

## The settings rows

Seeded by `worker/jobs/schema.d/202611110700-bh-9447-unblock-silence.sql`.

| Row | Seed | Code fallback | Range |
|---|---|---|---|
| `unblock.silence_auto.cromford` | `on` | off (no row) | on, off |
| `unblock.silence_safe_levers` | `lead_rerequest,update_branch,fix_round,rebuild,requeue` | the same list | act.sh actions |
| `unblock.silence_auto_after_min` | 120 | 120 | 5..4320 |
| `unblock.silence_auto_day_cap` | 10 | 10 | 1..1000 |
| `unblock.silence_rereview_priority` | 5 | 5 | 1..9 |

No other project is seeded. The reader of the safe list drops every never-auto
name (spend, production, live-probe, client-board, merge, deploy, governance,
force_push, pause_project, plus act.sh's own lists) and sends one warn alert,
id `unblock-silence-never-auto`. It drops a name that act.sh does not know
with one log line.

Over the day cap the worker refuses the claim (409 `day_cap`). The sweep sends
one warn alert, id `unblock-silence-cap-<p>-<UTC day>`, and the cards wait for
an answer as before.

## How to turn it off

1. Set the row `unblock.silence_auto.cromford` to `off`.
2. The next sweep runs nothing. New cards keep the old DEFAULT line.

## The ledger columns

`worker/jobs/src/lib/core.d/bh-9447-unblock-silence.js` adds
`silence_claimed_at`, `silence_lever`, `silence_outcome` and `silence_detail`
to `unblock_decisions`, and the partial index `idx_unblock_decisions_silence`
on `(project, silence_claimed_at)`. The routes are
`POST /api/unblock/silence/:id/claim` and `POST /api/unblock/silence/:id/result`
(`worker/jobs/src/routes/unblock-silence.js`). The columns ride the table's
existing retention.

## The 7-day report

Run this 7 days after the merge and post the result on the PR:

```sql
SELECT date(silence_claimed_at) AS day, silence_lever, silence_outcome, count(*) AS n
  FROM unblock_decisions
 WHERE project = 'cromford' AND silence_claimed_at IS NOT NULL
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3;
```

A reversal is a silence run that the operator undid by hand. The ledger does not
record it; count it from the PR threads that carry the
`<!-- tackler:silence:` marker.
