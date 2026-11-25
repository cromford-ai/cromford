# BH-9558 (slice C1): the latest verdict wins

Doc: STATE-STORES, MCP

## Cause

A builder APPROVE (`PUT /api/jobs/:id/artifacts`, kind `verdict`) wrote a
`verdict_history` round. A lead BLOCK (`POST /api/verdicts`) wrote only the
`verdicts` row and the PR gate fact (`recordLeadVerdict`), and no round. The
console worker sets a kanban card's `verdict` from the builder's beat, and the
lead lane's beat carries none. So a PR the lead blocked read "review /
approved" on the kanban and in the MCP `pipeline` tool.

## What changed

- `POST /api/verdicts`: a standing row (source `lead`, `human`, `risk-tier`)
  also appends a round to the PR's ledger job in `verdict_history`
  (`recordLeadRound`, `worker/jobs/src/lib/verdict-rounds.js`). A `box` row, a
  BH-8349 advice row and a PR with no `pr_url` artifact append nothing. An
  exact replay of the job's newest lead round appends nothing. A failed append
  is one `console.error` line; the 201 does not change.
- `PUT /api/jobs/:id/artifacts`: the builder dedupe compares against the job's
  newest builder round, so a re-put of the same APPROVE after a lead BLOCK does
  not append the stale APPROVE again.
- `GET /api/route-shadow/bounce`: the first round per job is the first builder
  round. A lead round is not the first review of a build.
- New `POST /api/verdict/current`: the newest round per PR url, with `by` and
  `state`. Cap: settings row `verdict.current.max_prs` (seed 200). The url list
  binds as ONE JSON array (`json_each(?1)`), not one parameter per url: D1
  allows at most 100 bound parameters per statement.
- Kanban Pages Function: open build cards carry the current verdict
  (`console-ui/functions/_lib/verdict-overlay.js`). The badge says who decided
  (`console-ui/src/lib/verdict-badge.js`): "lead-blocked", "lead approved",
  "lead approved, notes".

## What did not change

The standing merge-gate verdict (`job_artifacts(kind=verdict)`) and the
`verdicts` table. Every merge lane reads the same rows as before. A lead
BLOCK card keeps its kanban column in this slice; the column from the custody
row is a later slice (it needs BH-9554).

## Retention

No new table. `verdict_history` keeps its BH-9076 `-- no-retention:` line;
retention is a later slice. This adds about one row per lead review.
