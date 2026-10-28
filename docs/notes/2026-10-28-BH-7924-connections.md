# Probe Linear and Jira connections, and the setup steps (BH-7924, slice C0)

Doc: connecting-a-board, guide/03-connectors

## What changed

- `bin/connection-probe.sh <project>` (and `--box`, `--dry-run <project>`)
  loads the project's tracker context and makes one read: Linear `viewer`,
  Jira `/rest/api/3/myself`, `tracker_list --state open` for the board and
  GitHub Issues adapters. It writes the settings row `connection.<p>.status`
  through `POST /api/connections/<p>/status`. The row holds `adapter`, `ok`,
  `checkedAt`, `error` and `credentialVars` (each variable `present` or
  `missing`, never a value). The worker adds `webhookRoute` and
  `webhookSecret`.
- The lane `connection-probe` runs `bin/connection-probe.sh --box` at minute
  17 of each hour on every box. Knobs: `CONNECTION_PROBE_TIMEOUT_S` (default
  60) and `CONNECTION_PROBE_ERROR_MAX` (default 300, in bytes of the JSON
  error string, 40..1500).
- A `run_script` command can run `connection-probe.sh` now. The allowlist
  fragment is `catalog/run-script-allowlist.d/bh-7924-connection-probe.json`.
- The worker refuses a status over the settings row
  `connection.status_max_bytes` with 413 (seeded 2048, valid 2048..16384,
  fallback 2048). Every status the probe can send fits the 2048 floor.
- The jobs worker serves `GET /api/connections` and `PUT /api/connections`.
  The PUT writes the tracker rows and one `config_changes` row of kind
  `connection`, which `/config` shows. It refuses an API key or a token in
  any field and names the env var to set instead.
- The route of a project is the `webhook_route` row of its Linear team or of
  its Jira WRITE keys only. A read key is never a route key, because it can
  be another project's write key. A PUT that would change or delete a route
  row that points at a repo other than the project's registry repo answers
  409 unless the body sets `route_override: true`.
- `bin/load-project.sh <owner/repo> --tracker linear|jira --prefix <KEY>`
  writes `tracker_adapter.<p>` and the key rows before the prompt step.
- `docs/guide/03-connectors.md` and `docs/connecting-a-board.md` lose their
  two "Not yet" paragraphs. Each has numbered "Set up Linear" and "Set up
  Jira" steps and one sentence on what runs today. `docs/quickstart.md`
  links them. The suite `tests/docs-connectors.bh-7924-test.sh` pins them.
- Not in this slice: the console `/connections` screen, its PROBE NOW
  button and its links from Settings and the project page.

## Why

The Linear and Jira adapters existed, but the docs said a Linear or Jira
board could not drive builds. A self-hoster had no way to connect one
without a fleet.conf or prompt edit, and no way to see if the connection
worked.

## Operator steps

These steps are not automatic. No new env var is needed for the probe.

1. If a project uses Linear webhooks, set the secret on the jobs worker. Run
   `npx wrangler secret put LINEAR_WEBHOOK_SECRET` from `worker/jobs` and
   paste the value at the prompt.
2. If a project uses Jira webhooks, do the same for `JIRA_WEBHOOK_SECRET`.
3. Until a secret is set, its webhook route answers `503`. The probe row
   shows `webhookSecret` as `missing`.
4. For each Linear project, put `LINEAR_API_KEY` in
   `/etc/harness/env/<project>.env` on the box that runs it.
5. For each Jira project, put `JIRA_BASE`, `JIRA_EMAIL` and `JIRA_API_TOKEN`
   (and optionally `JIRA_SITE`) in `/etc/harness/env/<project>.env` on the box
   that runs it.
6. Run `bin/connection-probe.sh <project>` on that box and read the settings
   row `connection.<project>.status`.

## How to check

```bash
HARNESS_TEST_SANDBOX=1 bash tests/docs-connectors.bh-7924-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/docs-guide-pages.bh-6507-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/connection-probe.bh-7924-test.sh
```
