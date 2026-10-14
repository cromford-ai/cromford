# Merge-queue stage rows, bisect, the waiting line and the per-PR track (BH-5669)

Doc: MERGIFY, MERGE-CONDUCTOR

BH-5669 is child 3 of BH-5008. It fills four seams of the BH-5667 contract.

What changed:

- `worker/jobs/src/lib/merge-queue-intake-stages.js` (`stageStatements`). A
  signed delivery on a `mergify/merge-queue/<suffix>` ref writes a
  `pr_state_events` `state='queue'` row per member PR through `queueStageStmt`:
  `batched (#<draft>)` on draft open, `checking (#<draft>)` on a check run,
  `merging (#<draft>)` on a green check suite, `merged (#<draft>)` on a close
  with `merged === true`, and `dequeued (<check> failed on #<n> alone)` on a
  failed check of a 1-member bisect draft. `since` is `<stage>@<draft>`, so a
  redelivery under a new id writes no new row.
- GitHub sends one check suite per app and per workflow run. So a green suite
  writes `merging` only when every stored check of the draft is completed and
  none failed. A check or suite on a closed batch (`finished_at` set) writes no
  `checking` or `merging` row, so a late first delivery cannot move a PR back
  from `merged`.
- Bisect: on draft open, the newest failed or failing batch of the repo whose
  members are a strict superset of the new draft's is its parent. One UPDATE
  sets `bisect_parent`, `bisect_step` (parent step + 1) and `bisect_steps`
  (the parent's, else `ceil(log2(parent members))`), once.
- `worker/jobs/src/lib/merge-queue-live-stages.js` (`applyStages`).
  `GET /api/merge-queue/live` now sets each batch's `stage`, `failing` and
  `bisect`, the `prs` map (each PR's newest queue row of the last 24 h, with
  `key`/`project` from `pr_owners`) and `waiting` (the `queued (<n>)` rows, by
  position). It honours `?project=`. Past 500 PRs it answers `complete:false`.
- `console-ui/src/ui/merge-queue-waiting.js`: the waiting line on
  `/merge-queue`, a sortable table in position order.
- `console-ui/src/ui/pr-stage-track.js`: a six-station track in the JobsTable
  TICKET cell (`/jobs`, `/t/<key>`), with linked failure lines. All tracks on a
  page share one request per 5 s.
- `console-ui/src/ui/line.js`: `StationTrack` takes an optional `stations`
  prop. Without it the output is the same as before.

What it does not do: the intake writes no `queued` row (no delivery it accepts
carries a queue position) and no `deploy_verified` row. BH-5008 child 4 (#5670,
the Mergify reconciler, not built yet) is the intended writer of `queued (<n>)`
rows. Until a writer lands, the waiting line is empty in production.

`/merge-queue` now makes two live reads per 5 s for one project: the batch
table (BH-5668) and the waiting line each poll `GET /api/merge-queue/live`.
Both are D1 reads only. The per-PR tracks on `/jobs` and
`/t/<key>` share one read per project.
