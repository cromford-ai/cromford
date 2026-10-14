# The coord proxy stamps `actor` and allowlists fields on every write

Doc: harness-control-plane, mission-control-settings

Before BH-2405, `console-ui/functions/api/coord/[[path]].js` stamped `actor` only on
POST `hub/*` and the job RETRY/REQUEUE actions. Every other write (PUT flags,
PUT settings, PUT model-routes, POST model-routes/reset, POST lanes/all-off|all-on)
went to the jobs worker with the browser's body verbatim, so a browser-typed
`actor` landed in the audit rows and any unknown field rode along. Query strings
on writes were forwarded too.

Now every write the proxy admits is one row of a `WRITES` table that names the
body fields (and, for the one DELETE, the query fields) that may travel. Each
forwarded write gets `actor: 'console'` stamped by the proxy. Nothing outside
the row is forwarded, including a query string on a body write. A body that
is not a JSON object answers 400 and sends nothing. Anything not in the table
is still 405.

| Write | Forwarded fields |
|---|---|
| PUT flags | name, active, reason |
| PUT settings | key, value, note |
| PUT model-routes | role, project, ladder, expected_version, expected_hub_version, reason, confirm |
| POST model-routes/reset | role, project, expected_version, expected_hub_version, reason |
| POST lanes/all-off, lanes/all-on | reason |
| POST hub/promote | target, expected_epoch, reason, confirm |
| POST hub/restore-lab | box, snapshot, confirm |
| POST jobs/<id>/retry, requeue | detail (string only) |
| POST alerts/actions | id, akey, action, reason, snooze_s, note (strings or finite numbers; `action` string only) |
| DELETE call-guard | query: project, stage, fp, reason (no body) |

`hub/promote` no longer forwards `ttl_s`, `override_live_lease` or the
`holder`/`expect_epoch` aliases from a browser. On main, `alerts/actions` still
reaches a 501 stub. The worker-side refusal of a non-string `action` belongs
with the PR that implements that route (#2430); this change only makes sure the
proxy never forwards one.

Tests: `console-ui/tests/coord-write-allowlist.bh-2405.test.js`.
