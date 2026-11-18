# BH-9446: Tackler levers no longer fail on unread inputs

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## Why

On 2026-11-10 the operator got 7 Tackler cards for cromford. 4 of them came from
a lever that could not read its inputs, not from a decision only a person can
make: `rebuild` refused `phase-moved:unknown` (BH-9340, BH-9284), `fix_round`
did "not fit" a ticket whose PR #9372 was open (BH-9335), `re_review` failed
`head-unreadable` once (#9345), and U12 made one card for a PR whose 4 GitHub
inputs were null (#8908).

## What changed

1. `bin/lib/unblock/act.sh` `_ub_to_planned`: a 409 from the planned
   transition whose body names no current phase is an unread phase. The
   transition is sent again, at most `UNBLOCK_PHASE_REREADS` more times
   (default 1). Still no phase: outcome `failed phase-unreadable`. The string
   `phase-moved:unknown` is no longer made.
2. `bin/lib/unblock/ticket-pr.sh` (new) `ub_ticket_pr_enrich`, run by
   `bin/unblock.sh` after the collect and before the rules. A ticket-subject
   record (`ticket:<p>:<KEY>` or `<p>:<KEY>`) gets its open PR: the newest
   `pr_url` artifact of the ticket in the jobs ledger, then one GitHub read by
   branch `ticket/<key>`. Found: `pr`, `head`, `pr_url`, `pr_source`,
   `has_pr: true`. None open: `has_pr: false`. Unread: `has_pr: null`, named
   in `unknown`.
3. `bin/archie-cards.sh` `lever_record`: `fix_round` and `re_review` also fit
   a ticket subject whose evidence record carries `has_pr: true`, a numeric
   `pr` and a 40-hex head. `fix_round` gets `ticket: <KEY>`. `requeue` and
   `rebase` still need a PR subject.
4. `bin/lib/unblock/unreadable.sh` (new) `ubu_fold`, run by `bin/unblock.sh`
   after the rules. A U12 escalation whose record has an unread GitHub input
   (`mergeable_state`, `checks` or `changes_requested_open` null, or a PR
   subject with no 40-hex head) is held: no claim, no card, one
   `wait inputs-unreadable <repo>` line. After
   `UNBLOCK_UNREADABLE_CARD_AFTER_TICKS` ticks in a row (default 3), ONE card
   per repo, subject `source:pr-inputs:<repo>`. The tick line adds
   `unreadable_wait=<n>`.
5. `bin/archie-cards.sh`: a lever outcome `failed` writes
   `state/archie-cards-retry/<card id>.json` and sends no reply. Later ticks
   pull the same lever again (no claim, no model call), at most
   `ARCHIE_CARDS_LEVER_RETRY_MAX` times (default 3), one log line per retry.
   Then `needs-operator` with "<n> times: failed <detail>". `refused`, `would`,
   rc 1 and a lever that does not fit still go to the operator at once. The lane line
   adds `retried=<n>`.
6. `bin/lib/unblock/collectors/queue.sh`: a `pr-verdict-old-head` record
   carries `lead_request_id`, the id of the matched open lead request (null
   when none matched, the list was unread, or the match has no id).
   U13-RESTAMP also matches `lead_request_open == true` with
   `lead_request_id == null`. The tick logs one `lead-request-noid` line when
   it claims that decision.

## Knobs

| Knob | Lane | Default | Range |
|---|---|---|---|
| `UNBLOCK_PHASE_REREADS` | unblock, archie-cards | 1 | 0..3 |
| `UNBLOCK_PR_URL_FEED_LIMIT` | unblock | 200 | 1..500 |
| `UNBLOCK_UNREADABLE_CARD_AFTER_TICKS` | unblock | 3 | 1..100 |
| `ARCHIE_CARDS_LEVER_RETRY_MAX` | archie-cards | 3 | 0..10 |

Each is a settings row `lane.<lane>.<env lowercased>`, read through
`lane_env_apply`. To turn the Archie retries off, set
`ARCHIE_CARDS_LEVER_RETRY_MAX=0`.

## State

Two box-local classes (`catalog/state-paths.d/9446-tackler-retry.json`):
`state/archie-cards-retry/` (deleted on a terminal outcome, or when the card
is no longer open or is routed) and `state/unblock-unreadable/` (deleted on
the first tick with no unread input for that repo).

## Tests

`tests/unblock-act-phase-unreadable.bh-9446-test.sh`,
`tests/unblock-ticket-pr-resolve.bh-9446-test.sh`,
`tests/unblock-inputs-unreadable.bh-9446-test.sh`,
`tests/archie-cards-lever-retry.bh-9446-test.sh`,
`tests/unblock-restamp-noid.bh-9446-test.sh`.
