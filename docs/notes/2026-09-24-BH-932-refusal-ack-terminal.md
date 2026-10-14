# A refused console merge acks as a terminal refusal, never as a merge

Doc: MERGE-CONDUCTOR

Belongs with [merge-rest](../verification-map/merge-rest.md).

## What changed

`bin/poll-commands.sh`'s `merge_pr` handler now acks a merge GitHub refused with
`{ok:false, outcome:"refused", result:"refused: …"}`. Before, BH-892 sent the same
`ok:false` and text with no `outcome`.

| `gh_pr_merge_rest` rc | what GitHub said | ack `ok` | ack `outcome` | ack `result` |
|---|---|---|---|---|
| 0 | merged | `true` | — | `merged <url> at <sha>` |
| 2 | no verdict, gh fallback ran | whatever `gh pr merge` did (unchanged) | — | `merged` / `queued` / `merge failed: …` |
| 3 | 405 park | `false` | `refused` (new) | `refused: GitHub would not merge — <reason>` |
| 4 | 409 head moved | `false` | `refused` (new) | `refused: head moved since sha <8> — <reason>` |
| 5 | 422 / other 4xx | `false` | `refused` (new) | `refused: GitHub would not merge — <reason>` |
| anything else | no verdict (a lib crash, a killed subshell) | `false` | — | `merge failed: no merge verdict (rc N)` (was a `refused:`) |

`outcome` is only sent when it is set. Every other ack body is unchanged.

The ack POST sits between `# >>> command ack` / `# <<< command ack` markers, so
`tests/poll-commands-refusal-ack.bh-932-test.sh` can run the real payload builder.

## Why

The `/api/commands/<id>/ack` handler lives in `example-org/cromford-console`,
in `src/index.js`. Before its BH-932 change, it did `status = ok ? 'done' : 'failed'`,
and neither door was right for a refusal:

- **`ok:false`** means `failed`. The next claim re-leases the row. The merge
  re-runs up to 3 times and then goes to `dead_letter`, so a 405 park that clears
  would merge a PR on a stale click.
- **`ok:true`** means `done`, and on a `merge_pr` it also runs
  `UPDATE builds SET merged=1, stage='pr_merged'`. The PR is still open, but it
  loses its Merge button on Needs You and drops off `/api/builds/unmerged`, the
  list `bin/reconcile-prs.sh` corrects from. The first cut of this PR did this,
  and review blocked it.

The console now has a third status, `refused`, and it is **terminal**. The claim
sweeps never touch it, and the ack never stamps its build as merged. The console
reads it from the explicit `outcome:"refused"` field, or from the `refused:`
result prefix that boxes already send. It also shows the reason on the PR's Needs
You card, in `/history`, and in `/api/dash/commands` (`refused` count, per-row
`refusal`). A new Merge click re-arms a refused row.

The box keeps `ok:false` on purpose. A console that predates `refused` reads a
plain retry: it re-runs and eventually dead-letters, which is today's behaviour.
It never records a false merge.

## Deploy order

1. Merge and deploy the cromford-console PR (BH-932) first.
2. Then merge this one.

In the other order, nothing breaks. The box sends `ok:false`, and an old console
retries as it does today.

## Still owed

Nobody has driven a live refused row yet. Once both are deployed, on the hub:

1. Issue a console merge on a PR whose head moved after its review.
2. Read the row back from `/api/dash/commands`.
3. Quote its `status` and `refusal`.

Expected: `status` is `refused`, `refusal` starts with `head moved`, and the build
row for that PR still has `merged=0`.
