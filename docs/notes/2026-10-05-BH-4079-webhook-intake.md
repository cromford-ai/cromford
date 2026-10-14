# Jira and Linear webhooks ring the wakes doorbell; every delivery wakes once (BH-4079)

Doc: EVENTS

## What changed

- The jobs worker has two new open routes beside `POST /webhooks/github`:
  `POST /webhooks/jira` and `POST /webhooks/linear`. Each checks its own HMAC
  on the raw body and writes an ordinary `kind=issue` row to `wakes`, keyed on
  the ticket key (`CROM-12`, `ENG-5`). Nothing downstream of `wakes` changed:
  `bin/wake-loop.sh` claims these rows and launches the project's triage
  exactly as it does for a GitHub issue wake. With no deliveries, nothing is
  claimed and no triage or model call runs; the cron gate and its daily sweep
  stay the polling fallback.
- Only real changes wake (`worker/jobs/src/lib/tracker-webhooks.js`):
  - Jira: `jira:issue_created`, `jira:issue_deleted`, `comment_created`,
    `comment_updated`, and `jira:issue_updated` only when a changelog item's
    `field`/`fieldId` is in the edge list. An update with no changelog still
    wakes. Rank, Sprint, time tracking, worklogs, links and board events do not.
  - Linear: `Issue` create/remove, `Comment` create/update, and `Issue`
    update only when a key of `updatedFrom` is in the edge list. Sort-order
    moves, reactions, cycles, projects, labels and attachments do not.
  - A delivery whose actor is one of our own ids is dropped.
- One wake per delivery. The vendor's delivery id (`X-GitHub-Delivery`,
  `X-Atlassian-Webhook-Identifier`, `Linear-Delivery`) goes into the new D1
  table `webhook_deliveries` in the same batch as the wake, and the wake insert
  runs only when the delivery row was new. A redelivery in a later minute now
  answers `duplicate: true` with no second row. That includes GitHub, whose
  route otherwise answers exactly what it did. A delivery with no id keeps the
  old per-minute dedupe. Delivery ids older than the retention window are
  pruned, 100 rows per delivery.
- `worker/jobs/schema.sql` adds the table; `bin/harness-sync.sh` applies it
  before `wrangler deploy`, as it does for `wakes`.

## Responses

| case | status |
|---|---|
| not POST | 405 |
| vendor secret unset | 503 |
| bad signature (or Jira without `sha256=`) | 401 |
| Linear `webhookTimestamp` missing or older than the window | 401 |
| not a JSON object, no ticket key, ignored event, not an edge change | 202 `ignored` |
| no route row / route row not an `owner/repo` slug | 202 `unrouted` / `route row malformed` |
| recorded / already recorded | 200 `duplicate:false` / `duplicate:true` |
| the D1 write threw | 500 (nothing committed, the vendor retries) |

## Settings rows

All optional except the route row. The code value is the fallback.

| key | default | meaning |
|---|---|---|
| `webhook_route.jira.<project key, lowercase>` | none | `owner/repo` the wake is filed under, i.e. the fleet repo `bin/wake-loop.sh` maps to a project |
| `webhook_route.linear.<team key, lowercase>` | none | same, for a Linear team |
| `webhook_edge_fields.jira` | `status,labels,summary,description,resolution` | changelog fields that count as a real change |
| `webhook_edge_fields.linear` | `stateId,labelIds,title,description` | `updatedFrom` keys that count as a real change |
| `webhook_self.jira` | no row = nobody | comma-separated Atlassian accountIds of our own actor |
| `webhook_self.linear` | no row = nobody | comma-separated Linear user ids of our own actor |
| `webhook_max_age_s` | `300` | Linear replay window, seconds |
| `webhook_delivery_keep_s` | `604800` | how long a delivery id is remembered, seconds |

## Arming a receiver (operator, per vendor)

Both receivers are inert until armed. Arming one on a client tracker is the operator's
call (BH-3979 guardrail); the receiver only reads deliveries and never writes
to the tracker.

Jira Cloud:
1. `cd worker/jobs && npx wrangler secret put JIRA_WEBHOOK_SECRET`
2. Jira admin → System → WebHooks → Create: URL `https://<jobs-host>/webhooks/jira`,
   the same secret, events Issue created/updated/deleted and Comment created/updated,
   JQL scoped to the project.
3. `PUT /api/settings` with body `{"key":"webhook_route.jira.<key>","value":"<owner/repo>","actor":"<you>"}`.

Linear:
1. `cd worker/jobs && npx wrangler secret put LINEAR_WEBHOOK_SECRET`
2. Linear → Settings → API → Webhooks → New: URL `https://<jobs-host>/webhooks/linear`,
   resource types Issues and Comments, then copy Linear's signing secret into step 1.
3. `PUT /api/settings` with body `{"key":"webhook_route.linear.<team key>","value":"<owner/repo>","actor":"<you>"}`.

Probe: `curl -s -o /dev/null -w '%{http_code}' -X POST https://<jobs-host>/webhooks/jira`
answers `503` before step 1 and `401` after it.

## Not in this change

Sentry and PagerDuty intake. No other `/webhooks/*` path is open.
