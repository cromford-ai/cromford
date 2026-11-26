# One status comment per ticket, edited in place (BH-9503)

Doc: OPERATING, MCP

Slice C1 of #8973 (item 3, T5). C0 (#8981) built the live ticket state
(`worker/jobs/src/routes/ticket-status.js`, `loadTickets` / `ticketState`).
This slice puts that state on the ticket's GitHub issue as ONE comment that the
harness edits at each state change: claimed, spawned, hold released, reaped
with its outcome code, resumed, PR opened, merged.

## The mechanism

The six events have many writers (`bin/fly-pool.sh`, `bin/run-build.sh`, the
reaper, a `pool_holds` delete). This slice hooks none of them. It reads C0's
derived state and edits the comment when the rendered body changes.

1. `GET /api/ticket-status-comments/due?project=<p>` (worker,
   `worker/jobs/src/routes/ticket-status-comment.js`). It loads the candidate
   tickets through `loadTickets`, renders each body, hashes it, and answers the
   tickets whose hash differs from the last recorded write. Format
   `ticket-status-comment v1`: `{project, repo, fresh_at, due: [{key, issue,
   comment_id|null, fingerprint, state, final, body}], scanned, deferred,
   truncated, window_cut}`. `truncated` = the batch cut or the open-set cut
   dropped a ticket that comes on a later call. `window_cut` = set (b) or (c)
   below read more rows than the scan limit, so its oldest rows were left out.
2. `POST /api/ticket-status-comments` records one write:
   `{project, ticket_key, issue, comment_id, fingerprint, state, final}`.
   The upsert keeps `created_at`. A bad field is 400 `{error: <field>}`.
3. `bin/ticket-status-comment.sh`, a hub lane every 5 minutes
   (`cron/lanes/781-ticket-status-comment.cron`, registry
   `catalog/lanes.d/ticket-status-comment.json`). Per due ticket: PATCH the
   known comment (only rc 44, comment deleted, goes on; any other failed PATCH
   is `failed` and the lane moves to the next ticket); else adopt our App's newest comment whose first non-blank
   line is the marker; else POST one comment. Then POST the record.
4. The marker `<!-- harness-status: ticket-status -->` is registered in
   `catalog/plan-thread-status-markers.txt`. Without it, every edit of the
   comment would be a new turn to `ptg_classify` and the pool would reap the
   build PLAN_STALE (the BH-8804 incident).

The table `ticket_status_comments` (PK project, ticket_key) is a delivery
ledger: which comment, which fingerprint was last written. The state is never
stored there.

## Candidates (each bounded at `ticket_status.stuck_scan_limit` + 1, indexed)

- (a) the open queue rows (C0's `SQL.candidates`, `idx_build_queue_status`);
- (b) the watched comment rows: `final = 0`, written inside
  `ticket_status_comment.watch_days` (`idx_ticket_status_comments_watch`);
- (c) the queue rows that are no longer open and changed after both
  `ticket_status_comment.not_before` and the watch window start
  (`idx_build_queue_project_updated`, a new added index in
  `worker/jobs/src/lib/core.d/bh-9503-ticket-status-comment.js`).

Sets (b) and (c) read NEWEST first (`ORDER BY updated_at DESC`). cromford
finishes about 100 tickets a day, so in a 14-day window (c) holds far more
rows than the scan limit (200). Oldest first would read only the 201 oldest
rows and never see a ticket reaped today. Test C12 pins the order.

The plan named the knobs `ticket_status.comment_*`. The build named them
`ticket_status_comment.*`: C0's suite (`ticket-status.bh-8973.test.js` S1)
pins the exact set of `ticket_status.*` rows, and a new prefix leaves that
test as it is.

The plan named the spread knob `TICKET_STATUS_COMMENT_DISPATCH_SPREAD_S` (the
`stuck-work` shape). Its settings key, `lane.ticket-status-comment.ticket_status_comment_dispatch_spread_s`,
is 66 chars, and `worker/jobs/test/lanes-control.test.js` caps a key at 64.
So the knob is `TICKET_STATUS_COMMENT_SPREAD_S`.

Set (c) is not in the plan. The build added it. Without it, a ticket with no
comment row whose attempt ended (claimed and reaped between two ticks, or an
attempt the deploy guard deferred) is in neither (a) nor (b), and never gets
its comment. Test C10 pins it.

## The body and the fingerprint

```
<!-- harness-status: ticket-status -->
**Build status: running** (stage: execute)

- Machine: <machine>, started <YYYY-MM-DD HH:MMZ>
- Last attempt: <OUTCOME_CODE or status>, ended <YYYY-MM-DD HH:MMZ>
- PR: #<n> (<open|merged|closed>)
- Held: <ticket hold | sibling hold on <KEY> | spawn hold>, released ...
- Waiting on: blocker <KEY> (<state>), lead verdict (<state>), merge queue (<state>), fix round (<stage>)

Updated <YYYY-MM-DD HH:MMZ>. The harness edits this comment at each state change.
```

Each bullet shows only when it applies. Only enumerated fields and ids go in.
Each value must match `^[A-Za-z0-9][A-Za-z0-9._:/#+-]{0,79}$`, else it shows
as `?`. An outcome must be an UPPER_CASE code, else the attempt's status shows.
Free text (`pool_holds.why`, `build_queue.reason`, `ticket_events.reason`) is
never rendered. This is the "carries no secret" guarantee (T5).

The fingerprint is the first 16 hex of SHA-256 over the body without the
`Updated` line. A heartbeat or a stage event alone does not change it. A
change of state, stage, rung, machine, attempt outcome, PR, hold or wait does.

## The deploy guard

The first due call stamps `ticket_status_comment.not_before` once
(`INSERT OR IGNORE`). A ticket with no comment row whose attempt started
before the stamp (running: the newest job's start; spawning: the claim) is not
due. It is counted in `deferred`. It becomes due when the attempt ends (set c).
A builder that started on a snapshot without the catalog line never sees the
comment edited under it.

## Knobs

| Knob | Where | Default |
|---|---|---|
| `ticket_status_comment.batch_max` | settings row | 20 due tickets per project per call |
| `ticket_status_comment.watch_days` | settings row | 14 |
| `ticket_status_comment.not_before` | settings row, written by the route | first call time |
| `retention.ticket_status_comments.days` | settings row | 90 |
| `TICKET_STATUS_COMMENT_ENABLED` | lane knob | 1 |
| `TICKET_STATUS_COMMENT_PROJECTS` | lane knob, env/global.env only (not settable: check 17a) | `self` (cromford) |
| `TICKET_STATUS_COMMENT_SPREAD_S` | lane knob | 240 |
| `TICKET_STATUS_COMMENT_ADOPT_PAGES` | lane knob | 3 pages of 100 comments read by the adopt step |

## Failure modes

- Not watched, not a GitHub-issues board, off, disabled, or `GH_TOKEN` not an
  App installation token (`ghs_`): exit 0, one log line, no request. A PAT
  comment counts as a person to the plan-thread gate, so the lane never posts
  with one.
- The worker answers anything but 200: one log line, no GitHub call.
- GitHub rc 75 (rate limit, quota reserve, 5xx, auth) on any call: the tick
  stops, nothing is recorded for that ticket, `stopped=rc75-<step>:<key>` in
  the summary. An unreadable thread never leads to a POST.
- The record POST fails after a GitHub write: `failed` counts it. The next
  tick finds the ticket due again and PATCHes the same comment (stored id or
  adopt), never a second POST.
- Retention deletes a row: the next change adopts the comment by its marker.

Summary line, `logs/ticket-status-comment.log`:
`<ts> project=<p> due=N patched=N adopted=N posted=N failed=N truncated=0|1 [stopped=...]`.

## Cost

One due call: 1 settings read (when the settings cache is cold), 1 batch of
6, C0's batch of 10, and at most 3 more. The count does not grow with the
number of tickets (test C9). GitHub writes per project per tick are capped by
`ticket_status_comment.batch_max`.

## Tests

- `worker/jobs/test/ticket-status-comment.bh-9503.test.js` (C1-C12).
- `tests/ticket-status-comment.bh-9503-test.sh` (L1-L13).
