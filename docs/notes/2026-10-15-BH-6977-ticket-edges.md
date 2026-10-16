# Ticket edges and holds are rows (BH-6977, BH-6547.1)

Doc: HARNESS-COORDINATION, DB-COORDINATION-SPEC

## What changed

Wave 1 of 4 of #6547. Dependency edges and HOLD/RESUME comments are now also
D1 rows. The text lines (`Blocked-by:`, `Needs:`, `DEPENDS:`, the comments)
stay exactly as they were. Nothing reads the rows for a dispatch decision in
this wave. Waves 2-4 (#6978-#6980) read them.

- Tables (`worker/jobs/schema.d/202610152135-bh-6977-ticket-edges.sql`):
  - `ticket_edges (project, parent, child, kind hard|soft, planned_files,
    source planner|decompose|dep-verify|human, verified_at, at)`, unique on
    `(project, parent, child)`. `parent` is the blocker, `child` the blocked
    ticket, both GitHub issue numbers.
  - `ticket_holds (project, ticket, state hold|resume, by, at, comment_id)`,
    unique on `(project, ticket, comment_id)`. `at` is the comment's
    created_at.
- Routes (`worker/jobs/src/routes/ticket-edges.js`, fragment
  `worker/jobs/test/route-table.d/797-ticket-edges.txt`, bearer-gated):
  - `POST /api/ticket-edges {project, parent, child, kind, source, planned_files?}`.
    `source=dep-verify` sets kind, source and verified_at. Any other source
    sets kind and source only while verified_at is NULL, so a re-plan does not
    undo a verdict. planned_files moves on every write that sends it.
  - `GET /api/ticket-edges?project=&parent=|child=` (LIMIT 500, ORDER BY id).
  - `POST /api/ticket-holds {project, ticket, state, by, at, comment_id}`.
    An edited comment changes its own row.
  - `GET /api/ticket-holds?project=&ticket=` (newest first, LIMIT 200).
  - A missing table answers 503.
- Shell client `bin/lib/ticket-edges.sh`: `te_edges_from_text`,
  `te_put_edges`, `te_put_verdict`, `te_holds_from_comments`, `te_put_holds`.
  Every `te_put_*` prints nothing, returns 0 and does not retry. A failure is
  one line in `logs/ticket-edges.log`.
- Writers:
  - `bin/run-preplan.sh` (block `# >>> ticket edges`): one `planner` edge per
    blocker of a new plan, planned_files from `planned-files.txt`.
  - `bin/run-decompose.sh` (block `# >>> ticket edges`, issues lane, not in a
    dry run): one `decompose` edge per blocker of each filed child,
    planned_files from its `Owns:` line.
  - `bin/dep-verify.sh` `RECORD`: a newly computed HARD or SOFT verdict. A
    cached verdict, UNKNOWN and a dry run send nothing. Its stdout line and
    exit code do not change.
  - Wake class `ticket-holds` (`bin/lib/wake-class-ticket-holds.sh`): on any
    wake for an issue (any event: wake rows dedupe per minute and the first
    event wins, so a HOLD can arrive as `issues.labeled`) it reads the thread
    (at most 1000 comments) and mirrors every person comment that `bin/lib/hold.sh`'s `decide` reads as a
    hold or a lift. A failed read is one line in `logs/ticket-holds.log`.
- Retention (`worker/jobs/src/routes/retention.js`): rules `ticket_edges.age`
  and `ticket_holds.age`, under the job's own `retention.dry_run`.

## Switches and knobs

| Name | Kind | Default | What it does |
|---|---|---|---|
| `flags/ticket-edges-off` | flag file | absent | every `te_put_*` sends nothing |
| `wake-lanes-ticket-holds` | D1 flag | off | arms the hold mirror wake class |
| `ticket_holds.wake_reads_max` | settings row | 20 | thread reads per wake drain; 0 = the class does nothing |
| `retention.ticket_edges.days` | settings row | 365 | days an edge is kept after its last write; 0 = off |
| `retention.ticket_holds.days` | settings row | 365 | days a hold row is kept after its comment; 0 = off |

## Notes

- A ticket id that is not an issue number (an in-app board key) sends no
  edge and no hold.
- A plain `Blocked-by: #N` with no DEPENDS line is stored `hard`.
- The hold mirror uses `decide` as it is today. It reads
  "RESUME once #12 merges" and "we will hold off on the copy" as lifts, the
  same as `hold_classify` does. The mirror and the classifier agree.

Test: `tests/ticket-edges.bh-6977-test.sh`,
`worker/jobs/test/ticket-edges.bh-6977.test.js`.

## For the wave 2 reader (#6978)

- No code removes an edge. A re-plan that drops a `Blocked-by:` line leaves
  the old row for `retention.ticket_edges.days`. That over-blocks (fail-closed).
  The wave 2 reader must compare the rows with the current plan, or wave 2
  must delete the edges that the new plan no longer declares for
  (child, source).
- `ticket_holds.age` deletes a hold row `retention.ticket_holds.days` after
  its comment, also when no later RESUME lifted it. Rows are not the source of
  truth for a hold older than that window. A reader that trusts rows alone
  must not read "no row" as "not held" for such a ticket.
