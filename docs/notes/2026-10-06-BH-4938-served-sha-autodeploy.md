# 2026-10-06 — BH-4938: opt-in auto-deploy of main HEAD (child 3 of #4916)

Doc: OPERATOR-SETUP, ALERTS-STATE-MACHINE

**Why.** project-3 #467 merged as 2b2272a4 and Vercel never created a deployment
for it. The fix was a human clicking "Redeploy" for main HEAD. The served-sha
watch (BH-4936) now notices that state; this hook makes the click.

**What changed.** A new hook file, `bin/lib/served-sha-watch.d/20-autodeploy.sh`,
loaded by `bin/served-sha-watch.sh`. No tracer file changed. With
`SERVED_SHA_AUTODEPLOY=1`, verdict `alert` and deployment state exactly `none`,
it POSTs one production deployment of main's full HEAD sha
(`gitSource.ref = main`) to `/v13/deployments`, named like the deployment prod
serves. The POST carries `Content-Type: application/json`, which `ssw_vapi`
cannot send, so the hook has its own small poster that keeps the token on
curl's stdin config.

**The ledger.** `.deploy {sha, at, rc, id?, alerted?}` in the lane's
`state/served-sha-watch/<project>.json`. `pending` is written before the POST,
and a failed write means no POST. The outcome is `requested`, `requested-empty`
(2xx with no id: billed, terminal) or `failed:<http>` (`000` = no answer). Any
entry for the sha blocks another POST for it, so a crash between the two writes
or a timed-out POST is never retried. A new HEAD gets its own request.

**Alerts.** Id `served-autodeploy:<project>:<sha12>`, critical, through
`bin/lane-alert.sh`. Either the POST failed, or prod still doesn't serve the sha
`SERVED_SHA_LAG_MIN` after the request. At most one per sha. When prod serves it,
the hook logs `confirmed: prod serves it` and resolves the alert if one was sent.

**Policy.** Off by default. The knob gates only the POST: follow-up and
confirm run on an existing entry with the knob off, so turning it off never
strands an open page. Turning it on is the operator's call.

Suite: `tests/served-sha-autodeploy.bh-4938-test.sh`.
