# Alert actions: the contract slice (BH-2368)

Doc: DB-COORDINATION-SPEC

This is the first of three children of BH-2324 (ACK / SNOOZE / RESOLVE / NOTE on the console's alert rows). It adds the interface the other two import. It changes no behaviour.

- `worker/jobs/schema.sql` has a new `alert_actions` table and `idx_alert_actions_alert (alert_id, at)`. The table is append-only: nothing updates or deletes a row. `bin/harness-sync.sh` applies it before deploy, and `CREATED_TABLES.alert_actions` in `worker/jobs/src/lib/core.js` lets `ensureTable` self-create it. Nothing has to be done by hand.
- `worker/jobs/src/routes/alerts.js` now exports `ALERT_ID_RE`, `ALERT_ACTOR_RE` and `alertKnobs`. Nothing else in that file changed.
- `POST /api/alerts/actions` and `GET /api/alerts/actions` (`worker/jobs/src/routes/alert-actions.js`) are registered right after the alerts routes. For now both answer `501 {error:"not implemented"}`, and neither touches the table.
- `console-ui/src/api.js` has `api.alertAction(id, action, note)` and `api.alertActions(id, limit)`. `alertAction` rejects any action other than `ack`, `snooze`, `resolve` or `note` before it sends a request.

Two things are still missing. The console proxy (`console-ui/functions/api/coord/[[path]].js`) forwards every GET, so `api.alertActions` reaches the worker and gets the 501. It does not allow a POST to `alerts/actions` yet, so `api.alertAction` is refused there with a 405 and never reaches the worker. No screen calls either helper. The sibling tickets add the handlers, the proxy and the UI.

Pinned by `worker/jobs/test/alert-actions-schema.bh-2324.test.js`, `worker/jobs/test/route-table.d/525-alert-actions.txt` and `console-ui/tests/api-urls.test.js`.
