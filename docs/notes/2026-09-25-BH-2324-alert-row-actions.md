# Alert row actions: the worker route and the proxy (BH-2369, BH-2324 child 2)

Doc: worker/jobs/README.md

This fills in the two routes BH-2368 stubbed and opens one write in the console's coord proxy. The route list and `test/route-table.d/525-alert-actions.txt` are unchanged. No screen calls the routes yet. Child 3 of BH-2324 adds the UI.

## POST /api/alerts/actions

Body `{id, action, actor, note?}`, behind the `HARNESS_SECRET` bearer.

- **400, nothing written.** `id` must be a string matching `ALERT_ID_RE`. `action` must be one of `ack|snooze|resolve|note`. `actor` is required and must match `ALERT_ACTOR_RE`. `note` must be a string when present, and it is trimmed. A `note` action needs 1..1000 characters. For the other actions a note is optional, and a note that is empty after the trim is stored as NULL. Over 1000 is a 400. Nothing is clamped.
- **404 `{error:"no such alert", as_of}`** for an unknown id, plus one `refused:no-such-alert` row (before/after state NULL).
- **409** for every refusal, plus exactly one `refused:<why>` row. Its before and after state are both the state the decision was made on. The alerts row is not changed.
- **200 `{alert, action, as_of}`**: the alerts row re-read after the write, and the `ok` audit row.

Every state-changing action is ONE `env.DB.batch([INSERT INTO alert_actions … SELECT … FROM alerts WHERE <cas>, UPDATE alerts … WHERE <cas>])`. The audit INSERT comes first and carries the same predicate and binds as the UPDATE, so both statements match the same row or neither does.

| action | writes | CAS | refusals |
|---|---|---|---|
| `ack` | `state='triaged'` | `id=? AND state=<read> AND <read> IN ('new','quarantined')` | any other state: 409 `{error:"disallowed edge", from}`, `refused:disallowed-edge`. A lost race: 409 `{error:"contended"}`, `refused:contended` |
| `snooze` | `claimed_by=<actor>, claimed_at=t`; the audit row's `until = t + lease` | `id=? AND state<>'resolved' AND (claimed_by IS NULL OR claimed_at<=t-lease OR claimed_by=<actor>)` | resolved: 409 `{error:"resolved"}`, `refused:resolved`. A live claim held by someone else: 409 `{error:"claimed", claimed_by}`, `refused:claimed:<claimed_by>`. A CAS miss is re-read and classified the same way, and otherwise it is `refused:contended` |
| `resolve` | `state='resolved'` | `id=? AND state<>'resolved'` | already resolved: 409 `{error:"already resolved"}`, `refused:already-resolved`, never a 200 |
| `note` | the audit row only (outcome `ok`, before = after = the current state) | none | none beyond 400/404 |

`lease` is `alertKnobs(env).claim_lease_s`, which is the `alert_claim_lease_s` settings row (seeded 900). There is no constant for it in this route. A snooze by the actor who already holds the claim re-arms it. A claim exactly one lease old counts as expired (`<=`), the same boundary `/api/alerts/claim` uses.

`note` never calls `POST /api/alerts/note`. That route is a producer sighting, and it would bump the incident's count and last_seen.

## GET /api/alerts/actions?id=&limit=

`id` is required and must match `ALERT_ID_RE`, otherwise 400. `limit` defaults to 50 when it is absent or below 1, and clamps to 200 because it is a page size. The route selects `limit+1` rows ordered `at DESC, id DESC` and answers `{actions, truncated, as_of}`.

## A snooze delays the lanes and the flush for one lease

A snooze writes `claimed_by`/`claimed_at`, the same lease `/api/alerts/claim` and `/api/alerts/flush` skip through their `unclaimed` predicate. So `alert-triage` and `alerts-medic` skip a snoozed row until the lease runs out, and a snoozed quarantined row's TTL flush waits one lease too. A lane holding a live claim makes the snooze refuse. The snooze never steals the claim.

## Proxy

`console-ui/functions/api/coord/[[path]].js` allows `POST alerts/actions` and nothing else under `alerts/`. It stamps `actor` as `console` over whatever the browser sent, and it refuses a body that is not a JSON object with a 400 before any fetch. `PATCH alerts/state` and `POST alerts/resolve|claim|note|flush` stay 405.

Pinned by `worker/jobs/test/alert-actions.bh-2369.test.js` (node:sqlite D1 shim), `worker/jobs/test/alert-actions-schema.bh-2324.test.js` and `console-ui/tests/alert-actions-proxy.bh-2369.test.js`. The worker is deployed with `cd worker/jobs && npx wrangler deploy` after merge. This PR does not deploy it.
