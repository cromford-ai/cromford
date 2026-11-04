# BH-8817: Tackler cards go to Archie first; the operator is paged only for a decision only he can make

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## Why

Every act-mode Tackler card went to the operator as a critical DM. Nothing in the
harness read an escalated card. From 10-26 to 10-30 ALERTS.log held 347
TACKLER CARD lines (200 on 10-27). Of the 7 cards the operator forwarded by hand, 4
were false or already handled.

## What changed

1. **Route.** `unblock_card_send` (`bin/lib/unblock/card.sh`) reads the
   settings row `unblock.route_to` (seed `archie`). Route `archie`: no
   `lane-alert.sh` call, the send line is `ROUTED_ARCHIE <id>`, and the ledger
   row stays `escalated`. Route `operator`, no row, an unreadable row or any other
   word: the direct critical DM, as before. The card JSON now carries `route`
   and `class`.
2. **Archie's lane.** `bin/archie-cards.sh tick` (cron
   `cron/lanes/778-archie-cards.cron`, every 10 minutes at 2-52/10) takes each
   archie-routed open card of an act-mode project. It claims the row
   (`POST /api/unblock/decisions/<id>/archie-claim`) before any spend, then
   makes ONE call (role `stage.archie`, stage `archie-card`, no tools, prompt
   `catalog/prompts/archie-card.md`). The answer is `hold`, `none` (false),
   `act` with one lever, or `needs-operator`, plus a reason. The lane answers
   through `bin/unblock-reply.sh archie <card-id> <answer> <reason> [lever]`.
3. **The levers.** With `act`, the lane builds the `ub_act` record from the
   ledger row (repo, PR number from the subject, head, ticket key, class),
   never from the model, and pulls the lever through Tackler's one writer,
   `bin/lib/unblock/act.sh`, with every gate of it (never-auto class, the
   project's `unblock.project.<p>.mode` row, head moved, the GitHub marker
   `<!-- tackler:archie:<card-id> -->`). The levers: `requeue`, `fix_round`,
   `re_review` (lead re-request), `rebase` (GitHub update-branch with
   `expected_head_sha`), `rebuild` (act.sh's BH-8736 `rebuild` arm: the
   ticket's lifecycle phase to `planned`, then launch-fastpath), `re_offer`
   (launch-fastpath of the ticket key, no phase write), `ticket_comment` (the PR thread, or the harness ticket
   `BH-<n>` = issue n) and `file_ticket` (one `ai-build` issue on
   `HARNESS_REPO`). `done` = the answer `acted` with the lever, and the note
   carries the writer's answer (the probe). A lever that does not fit the
   subject, or `would`, `refused`, `failed` = `needs-operator`, and the reason says
   what Archie tried.
4. **The answer.** The worker accepts `answered_by: "archie"` only with
   `source: "archie"`, only on a card whose `card.route` is `archie`, and only
   `hold`, `none` or `acted` (with a `lever`, stored in `archie_lever`). It
   stores `answer_source='archie'`. A person cannot answer `none` or `acted`. `needs-operator` is
   not an answer: `POST /<id>/route` sets `routed_to='operator'` and the row stays
   `escalated`, so the operator answers it with the Telegram grammar of today.
5. **The page.** Tackler's own tick (`bin/unblock.sh`, act mode, whatever
   `UNBLOCK_ACT` says) runs `unblock_card_sweep` after its decisions. It pages
   the operator once (`lane-alert.sh --id unblock-<key12>`, the BH-8766 severity
   rule) for a row routed to the operator, and routes then pages a card that is open
   past `unblock.archie_answer_max_min` with no Archie claim inside
   `unblock.archie_claim_lease_min`. `paged_at` is stamped only after
   lane-alert rc 0. The tick line adds `sweep_paged=<n>`.
6. **The digest.** `bin/unblock-metrics.sh daily` writes one more line per
   project: `tackler <p> <day> cards: received <n>, archie <n>, operator <n>,
   false <n>, acted <n>` (`GET /api/unblock/cards/daily`, one SELECT on
   `idx_unblock_decisions_created`). `operator` counts every card the operator got:
   routed back by Archie or the timeout, and every card sent to the operator direct
   (a card with route `operator`, or with no route, such as a legacy card or
   BH-8736's `ask` card).
7. **The rule miner.** `bin/rule-miner.sh` source (g) reads
   `GET /api/unblock/cards/repeats` (`bin/lib/unblock/archie-repeats.sh`): each
   project, stall class, answer and lever that Archie gave
   `RULE_MINER_ARCHIE_MIN` (3) times in `RULE_MINER_ARCHIE_DAYS` (30) is one
   incident, a candidate rule for `catalog/unblock-rules.d`.
8. **A lost record pages.** When the record POST fails after `ROUTED_ARCHIE`,
   no ledger row carries the card. Tackler then pages the operator direct
   (`unblock_card_page_direct`, the same alert id). A `/route` 404 (a worker
   with no route yet) also pages.

New ledger columns (additive, `worker/jobs/src/lib/core.d/bh-8817-unblock-cards.js`):
`answer_source`, `routed_to`, `routed_at`, `route_reason`, `paged_at`,
`archie_claimed_at`, `archie_lever`. No new table; the `unblock_decisions` retention rule
covers the rows.

## Combined with BH-8736 (#8851)

BH-8736 changed the same writer first (`bin/lib/unblock/act.sh`: the arms
`rebuild` and `ask`, `requeue {ticket_key}`, and the lifecycle collector). This
change keeps those arms as they are on main and adds its own on top (the operator,
comment 6578964868):

- `UB_ACTIONS` is the union: main's `rebuild` and `ask`, plus
  `update_branch`, `ticket_comment` and `file_ticket`.
- Archie's `rebuild` lever calls main's `rebuild` arm, because the queue
  refuses an abandoned key unless its phase moved first (#8734). A refused
  phase move (`phase-moved:<p>`, `no-row`) goes to the operator with that detail.
  `bin/archie-cards.sh` loads `bin/lib/jobs/lifecycle.sh` the way
  `bin/unblock.sh` does.
- A lever's ticket key comes from both subject formats: `ticket:<p>:<KEY>`
  (the infra collector) and `<p>:<KEY>` (the lifecycle collector), and only
  when `KEY` matches act.sh's `UB_TICKET_RE`.
- Main's `ask` card keeps its direct critical DM to the operator. It carries no
  `route`, so Archie's lane and the timeout sweep never touch it, and the
  digest counts it under `operator`.
- Archie's `requeue` lever passes no `ticket_key`, so main's requeue arm makes
  no phase write for it.

## Knobs

| Knob | Where | Default |
|---|---|---|
| `unblock.route_to` | settings row | `archie` (code fallback `operator`) |
| `unblock.archie_answer_max_min` | settings row | 60 (5..1440) |
| `unblock.archie_claim_lease_min` | settings row | 15 (1..240) |
| `budget.stage.archie-card.day_usd` | settings row (agent-call stage-day cap) | 10 |
| `UNBLOCK_CARD_SWEEP_PAGES` | lane knob, unblock | 5 pages of 100 (1..20) |
| `ARCHIE_CARDS_ENABLED`, `_MAX_PER_TICK`, `_CALL_TIMEOUT_S`, `_TICK_TIMEOUT_S`, `_PROMPT_MAX_BYTES`, `_NOTE_MAX` | lane knobs, archie-cards | 1, 5, 120, 540, 8192, 500 |
| `ARCHIE_CARDS_ACT` (0 = every lever answers `would`), `ARCHIE_CARDS_REREVIEW_PRIORITY` | lane knobs, archie-cards | 1, 5 |
| `RULE_MINER_ARCHIE_MIN`, `RULE_MINER_ARCHIE_DAYS`, `RULE_MINER_ARCHIE_LIMIT` | lane knobs, rule-miner | 3, 30, 50 |
| `LLM_LANE_ENABLED`, `LLM_RUNNER_ALLOWED`, `LLM_USD_CAP_DAY` | lane knobs, archie-cards (read by `bin/lib/llm-gate.sh`) | 1, every rung, 0 (no lane cap; the stage-day row still caps) |

## Off switches

- `unblock.route_to=operator` sends every new card to the operator as a direct DM at once.
  Cards already routed to Archie still page through the sweep.
- `ARCHIE_CARDS_ENABLED=0`, `flags/lane-off-archie-cards`,
  `bin/harness-ctl.sh off archie-cards` or `staff-kill-all` stop Archie's lane.
  Its open cards then page the operator after `unblock.archie_answer_max_min`.

## Levers off

`ARCHIE_CARDS_ACT=0` keeps Archie's triage and stops every lever: the writer
answers `would`, and the card goes to the operator with the lever Archie picked. The
project's `unblock.project.<p>.mode` row other than `act` refuses every lever.

## Tests

`tests/archie-cards.bh-8817-test.sh` (the shipped `bin/unblock.sh`,
`bin/archie-cards.sh`, `bin/unblock-reply.sh`, `bin/unblock-metrics.sh` and
`bin/rule-miner.sh` over a fake jobs API, 0 vendor calls),
`tests/unblock-act-levers.bh-8817-test.sh` (the three new writer arms over a
local `gh` fake, and main's `rebuild` and `ask` arms through the union) and
`worker/jobs/test/unblock-cards.bh-8817.test.js` (the real worker over the
composed schema; EXPLAIN at 50 000 rows).
