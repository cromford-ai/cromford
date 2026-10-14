# Staff screen (BH-5567, wave 10 of #5556)

Doc: DB-COORDINATION-SPEC, CONSOLE

## What changed

The console has a new STAFF tab, `/staff`, before SETTINGS in the nav.

- `/staff`: one row for Archie and one row for each `staff_agents` row (8
  today). Columns: AGENT (mill name), ROLE, ACCOUNTABLE, AUTONOMY, CAP, STATUS,
  OPEN FINDINGS, PRECISION, SPEND $, KILL, ACTION. Every column except ACTION
  sorts.
- `/staff/<agent>`: the agent's open findings, newest first, capped at 500
  with a note when the cap cut the list.
- `/staff/finding/<id>`: every column of one finding, with links to its
  source, its ticket (or "no ticket filed yet") and back to the agent.

Three new worker reads in `worker/jobs/src/routes/staff-screen.js`, at the end
of `ROUTES` (fragment `worker/jobs/test/route-table.d/745-staff-screen.txt`):

- `GET /api/staff/roster`: `{agents, sources, as_of}`. Archie is first, then
  the staff by name. Each row has `open_findings`, and `precision: null` and
  `spend_usd: null`. `sources` names the ticket that builds each one.
- `GET /api/staff/findings?agent=`: `{agent, findings, truncated, as_of}`.
  400 `agent` on a bad name, 404 `agent not found`.
- `GET /api/staff/finding?id=`: `{finding}`. `source_labels` is parsed; if it
  is not valid JSON, the raw text is returned with `labels_invalid: true`.
  400 `id`, 404 `finding not found`.

"Open" is any status other than `merged`, `rejected`, `noise` or `closed`.
A missing table answers 503 and names the table.

Schema fragment `worker/jobs/schema.d/0021-bh-5567-staff-screen.sql` adds two
settings rows, `INSERT OR IGNORE`: `staff.archie.role` = `overlooker` and
`staff.archie.accountable` = `operator@example.com`. An absent row shows "n/a".

## The kill switch flag names

The screen writes through the existing flags API. It adds no write route and
no proxy row.

- `staff-kill-<agent>`: one staff agent. Scope `fleet`, value empty.
- `staff-kill-all`: every staff agent. It does not stop Archie.
- Archie has no staff-kill flag. Its KILL cell links to `lane-off-archie`,
  which already stops Archie.

These names are not in the ported families, so each one is a `pause_flags`
row that boxes reconcile into `flags/<name>` (BH-1370). Nothing reads them at
this commit. The staff heartbeat (BH-5561) must read exactly these names. Until
it does, a set flag stops nothing, and the screen says so.

## Not built here

- PRECISION needs the outcomes record (BH-5563). SPEND needs spend per agent
  (BH-5561). Both columns show "n/a" with that reason as the tooltip.
- No route writes `staff_findings.status` or `ticket_url` yet.

## How to check it

- `cd worker/jobs && node --test test/staff-screen.test.js`
- `cd console-ui && node --test tests/staff-screen.bh-5567.test.js`
- `HARNESS_TEST_SANDBOX=1 bash tests/staff-screen.bh-5567-test.sh`
- With playwright and a browser: `cd console-ui && npm run build && npm run drive:staff`
