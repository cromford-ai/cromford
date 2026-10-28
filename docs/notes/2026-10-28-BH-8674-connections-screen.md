# The /connections console screen and PROBE NOW (BH-8674, slice C1 of BH-7924)

Doc: connecting-a-board, guide/03-connectors

## What changed

- The console has a `/connections` screen. The settings shell shows the same
  screen at `/settings/fleet/connections`. It has one row per project, with
  7 columns: PROJECT, TRACKER, CREDENTIAL, LAST PROBE, WEBHOOK, ROUTE and
  ACTIONS. Each data column sorts. The table scrolls inside its own wrapper,
  so the page works at 375 px.
- A row whose last probe failed shows the error and the names of the missing
  env vars as text under the project name.
- EDIT opens an in-app modal that writes the tracker rows through
  `PUT /api/coord/connections`. A token-shaped value is refused, and the
  modal names the env var to set instead. A worker refusal (400, or a 409
  for a route row that another project's repo owns) stays in the open modal
  as text. The console never sends `route_override`.
- PROBE NOW sends a `run_script connection-probe.sh <project>` command. The
  Pages proxy queues it as one `commands` row per project per UTC minute. It
  admits only that script with the project as its one argument. The note says
  "probe queued" only when the answer carries a command id.
- Entry points: the Settings menu row "Tracker connections", and the
  CONNECTION button on the project page (`/connections?project=<p>`, with the
  row highlighted).
- New settings row `connections.probe_stale_min` (seed 120, fallback 120): the
  age in minutes after which LAST PROBE shows a probe age as stale. The screen
  reads it in parallel with the list. A failed read uses the fallback.
- The Jira and Linear setup steps in both connector pages name `/connections`,
  EDIT and PROBE NOW beside the CLI path.
- No OAuth flow and no billing surface.
- `tests/vendor-budget.bh-7939-test.sh` case B5 now names each key of `api`
  on the merge base that HEAD does not have. Before, it compared the key
  count, so a PR that added a key failed it.

## Assumptions

- A 409 for a route row that another project owns is shown, not overridden.
  An operator who means it sets the row in `/settings`, or sends
  `route_override: true` from the box.
- The one-minute dedup bucket of PROBE NOW is an idempotency key, not a knob.
- The knob is `connections.probe_stale_min`, not `connection.probe_stale_min`
  as the plan named it. A `connection.` key falls inside the worker's
  `GET /api/connections` range read, which only the box status rows and the
  status bound belong to. The worker never reads this knob.

## Operator steps

None. The seed row is applied by the schema step of the next jobs-worker
deploy.

## How to check

```bash
cd console-ui && node --test tests/connections.bh-8674.test.js
HARNESS_TEST_SANDBOX=1 bash tests/connections-console.bh-8674-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/docs-connectors.bh-7924-test.sh
```
