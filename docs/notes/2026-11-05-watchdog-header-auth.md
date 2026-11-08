# Watchdog authentication migration

The watchdog now requires `Authorization: Bearer <WATCHDOG_SECRET>` on every
protected route. The `s` query parameter and the jobs credential no longer
authenticate requests. Stamp requests use the same header with `STAMP_SECRET`.

Before deploying, provision a dedicated watchdog credential on the worker with
`wrangler secret put WATCHDOG_SECRET`. Keep the worker's existing
`HARNESS_SECRET` if jobs failover is enabled: it is still the outgoing jobs
bearer and must differ from the watchdog credential.

Distribute the dedicated credential to each caller, then deploy the updated
clients and worker together during a maintenance window. Existing clients
using query authentication will be refused by the new worker, and updated
clients will be refused by the old worker. Verify pings, fleet status, ticket
and cost snapshots, standby reports, progress pushes and command polling after
the change. Reconfigure any external console or automation not shipped in this
repository to send the header before relying on its watchdog reads.

Box clients prefer `env/.watchdog-secret` (mode 600), then `WATCHDOG_SECRET` in
their environment. The Mac burn publisher prefers
`~/.orgo/.watchdog-secret` (or `MACBURN_SECRET_FILE`), then `WATCHDOG_SECRET`.
It no longer reads the Mac's jobs secret. The shared shell helper passes the
header through a file descriptor so the credential appears in neither request
URLs nor curl's process arguments, while JSON payloads can still use stdin.

To verify the alert path from a configured box:

```bash
. /root/harness/bin/lib/watchdog-url.sh
watchdog_curl -X POST "$WATCHDOG_URL/api/test-alert"
```

The retained tests use header authentication for successful requests and keep
wrong or missing credentials denied. New regressions cover rejected query
authentication, jobs/watchdog separation and descriptor-based curl transport.
