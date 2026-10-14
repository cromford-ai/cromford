# The cost read-out is a rendered table, not a model turn

Doc: MODEL-ROUTES, COST

## What was wrong

`bin/cost-readout.sh` was the one-shot August read-out. It pulled every box's
`cost.csv` over ssh, summed it in awk, handed the sums to a review-model turn
through `agent-call.sh` for prose, and then deleted its own line from the root
crontab. The numbers were already computed by `bin/cost-rollup.sh` in
`state/cost/summary.json`, so the model turn bought nothing a table can't show.
It was also billed as `project=project-1`, `stage=review`, which made a fleet
lane look like project-1 review spend (C8, #2539).

## What changed

- `bin/cost-readout.sh` reads `$HARNESS/state/cost/summary.json` and renders
  one markdown table with jq: project, cost 24h, cost 7d, cash 7d, merged PRs
  7d, $/merged PR 7d and triage share 7d, sorted by project. Above it goes a
  fleet line (notional 7d, cash 7d, cash 7d total, unpriced calls 24h) and
  `cash_note` verbatim. It writes `logs/cost-readout-<YYYYMMDD>.md` and posts
  the same `cost_readout` beat as before (same kind, project and akey).
- A null in summary.json renders `unknown`, never 0. A summary older than 26h
  still renders, under a `STALE` line naming its `generated_at`.
- Missing, empty or non-object summary.json: rc 2, a reason on stderr, no file
  and no beat.
- Gone: the model call, the ssh fan-out, the build-quality scan and the crontab
  self-removal. `HARNESS` is now honoured, not pinned to `/root/harness`.
- The `cost-readout` site is removed from `catalog/llm-sites.json`, since the
  script no longer calls a model.

## Probe

```
bin/cost-readout.sh; echo rc=$?
cat /root/harness/logs/cost-readout-$(date -u +%Y%m%d).md
```

`tests/cost-readout.bh-2550-test.sh` pins it.
