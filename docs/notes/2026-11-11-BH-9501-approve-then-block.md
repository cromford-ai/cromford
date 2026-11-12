# Lead review after an in-build APPROVE, in the daily digest (BH-9501, BH-9441.4)

## What changed

The daily digest has a new last line, `Lead review after in-build APPROVE`. It
gives the share of PRs that the builder's own review approved during the build
and that the lead review then blocked. Three pieces:

- `GET /api/metrics/approve-then-block?day=YYYY-MM-DD[&days=N]` on the jobs
  worker (`worker/jobs/src/routes/approve-then-block.js`; the params, the SQL
  and the fold are in `worker/jobs/src/lib/approve-then-block.js`). Bearer auth,
  read-only. A bad `day` or a `days` outside 1..60 is a 400, never clamped.
- `bin/daily-digest.sh` step 7e reads it and merges the answer into
  `state/daily-digest/<D>.json` as `.approve_then_block`. A 404 leaves the key
  out with one note line. Any other failure, or a body off the contract, is
  `{ok:false, error}` and renders `n/a`. It never alerts and never makes an
  empty day not empty.
- `bin/lib/daily-digest-render.sh` prints the line only when the key is there.

Tests: `worker/jobs/test/approve-then-block.bh-9501.test.js` (the route over
node:sqlite and the composed schema) and
`tests/daily-digest-approve-block.bh-9501-test.sh` (the shipped lane and the
real renderer).

## The definition

The facts are gate rows in `pr_state_events` (`state='gate'`), written by
`worker/jobs/src/lib/pr-gate-intake.js`:

- in-build APPROVE: a row with `builder_approved_sha` set
  (`recordBuilderApprove`, reason `builder-verdict:<job>`);
- lead BLOCK: a row with `reason='verdict:lead'` and `lead_verdict_word='BLOCK'`
  (`recordLeadVerdict`). Human (`verdict:human`) and risk-tier
  (`verdict:risk-tier`) BLOCKs do not count.

The window is the N days that end at the end of the digest day D (UTC):
`[D+1 - N days, D+1)`.

- cohort: the distinct (repo, number) with an APPROVE row in the window;
- blocked: the cohort PRs with a lead BLOCK row in the window whose `id` is
  greater than the PR's first APPROVE row `id` in the window. The BLOCK can be
  on any head sha: a fix round moves the head, and the metric counts PRs;
- share: blocked / cohort, `null` when the cohort is 0. Per repo and in total.

A lead BLOCK before the only APPROVE does not count. An APPROVE before the
window start puts the PR out of the cohort, even with a BLOCK inside it.

## The knob

`DAILY_DIGEST_APPROVE_BLOCK_DAYS` (lane `daily-digest`, settings row
`lane.daily-digest.daily_digest_approve_block_days`): the window in days,
default 14, 1..60. A value outside 1..60 is one warn line in
`logs/daily-digest.notes.log` and the default 14.

## The line

- `Lead review after in-build APPROVE, 14d to <D>: blocked 2 of 4 PRs (50.0%). <repo> 2/3, <repo> 0/1. <console>/`
  The repos are sorted by cohort (largest first), then by name, and cut at
  `DAILY_DIGEST_MAX_ITEMS` with `+N more`.
- `Lead review after in-build APPROVE: no in-build APPROVE in 14d to <D>. <console>/`
- `Lead review after in-build APPROVE: n/a (read failed: ...) <console>/`

## The query (for a baseline by hand)

One range read on `idx_pr_state_events_state_at (state, at)`, with no
correlated subquery. `?1` is the window start and `?2` is the window end:

```sql
SELECT repo, number,
       MIN(CASE WHEN builder_approved_sha IS NOT NULL THEN id END) AS approve_id,
       MAX(CASE WHEN reason = 'verdict:lead' AND lead_verdict_word = 'BLOCK' THEN id END) AS block_id
  FROM pr_state_events
 WHERE state = 'gate' AND at >= ?1 AND at < ?2
 GROUP BY repo, number
HAVING approve_id IS NOT NULL
```

A row is blocked when `block_id > approve_id`. The 14-day baseline window for
the PR is `2026-10-28T00:00:00Z` to `2026-11-11T00:00:00Z`.
