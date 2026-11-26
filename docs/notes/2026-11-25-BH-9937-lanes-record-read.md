# BH-9937: lanes with no record read, slice C0

Part of #9926 (wave 5 of 7). This slice moves two hub lanes to the PR record
and adds the per-PR wake gate. Refs #9937.

## What changed

- `bin/lib/prr-seen.sh` (new): the per-PR wake gate. In step `record`, a lane
  does not read a PR that had no wake since its last read. A wake is a `pr`
  wake keyed on the PR number, or a `checks` wake keyed on the PR's head sha
  (CI, status and lead-verdict events). The feed is `prs_wake_seen`, through
  `wb_due`.
- `bin/pr-state-reconcile.sh`: the open list and the closed sweep's state read
  go through `prr_read`. The seam is `bin/lib/prr-shadow.d/pr-state-reconcile.sh`.
- `bin/main-red-pr-pair.sh`: the open list goes through `prr_read`. The seam is
  `bin/lib/prr-shadow.d/main-red-pr-pair.sh`. In step `record`, the gate runs
  before the runs read of a head with no verdict row and before the
  check-runs read of a named failure row.

## The three steps

One settings row per lane selects the step: `lane.pr-state-reconcile.gh_source`
and `lane.main-red-pr-pair.gh_source` (knob `GH_SOURCE`, default `shadow`).

| Step | Reads | Acts on |
|---|---|---|
| `off` | GitHub only | GitHub |
| `shadow` | the record and GitHub; every PR is read | GitHub. A difference writes 1 `PRR_SHADOW` line |
| `record` | the record (a miss reads GitHub and writes `PRR_MISS`), plus the wake gate | the record |

The gate runs in step `record` only. Shadow reads every PR, so its compare
stays complete.

## The wake gate

- State: `state/prr-seen/<lane>/<owner>_<repo>.tsv`, class `cache`. One row per
  open PR: `<number> TAB <epoch> TAB <head>`.
- A mark is written only after every read of the PR answered. The epoch is the
  start of the tick, so a wake during the read wakes the next tick.
- Retention: `prr_seen_keep` keeps only the PRs of the last complete open list.
- Backstop: the knob `PRR_SEEN_BACKSTOP_S` (settings row
  `lib.prr-seen.prr_seen_backstop_s`, default 1800, 0 = the gate is off). A
  mark older than this reads the PR again. This covers a lost webhook.
- A feed outage (`no-feed`) reads every PR.

What a quiet PR does in `pr-state-reconcile`:

- It makes 0 GitHub reads. Its head is the list head.
- `held` is not judged. A HOLD or RESUME comment is a `pr` wake.
- The builder and lead verdicts are still judged. They are jobs reads.
- CI is judged from the record's checks (`prr_ci_state`, green only, no guard
  read).
- The live probe and the console QA reset wait for the next read of the PR.
  The next read comes on a wake or at the backstop (30 minutes at most).

What a quiet head does in `main-red-pr-pair`:

- It is not read, and it counts in `unknown`. So no pair resolves and no freeze
  clears on that tick (the BH-997 rule).
- A named failure row stands, as for "no newer run attempt".
- The stale-freeze re-read (BH-9890) still reads GitHub on every tick.

## The 48-hour shadow count (owed after the deploy)

Both rows stay at `shadow` in this PR. After the deploy, let the lanes run in
`shadow` for 48 hours. Then run these on the hub:

```bash
grep -c 'PRR_SHADOW lane=pr-state-reconcile' /root/harness/logs/prr-shadow.log
grep -c 'PRR_SHADOW lane=main-red-pr-pair' /root/harness/logs/prr-shadow.log
```

Count only the lines of the 48 hours after the deploy. Post each count on
#9937. An operator sets `lane.<id>.gh_source=record` only when that lane's
count is 0. To read the misses too:

```bash
grep 'PRR_MISS lane=pr-state-reconcile' /root/harness/logs/prr-shadow.log | awk '{print $5}' | sort | uniq -c
grep 'PRR_MISS lane=main-red-pr-pair' /root/harness/logs/prr-shadow.log | awk '{print $5}' | sort | uniq -c
```

In step `record`, the pr-state-reconcile summary line ends with
`quiet=<n> step=record`. main-red-pr-pair writes one
`<slug>: record step: quiet=<n> read=<n>` line per repo.

## Not in this slice

- C1: `bin/blocked-resolver.sh` discovery reads, and the discovery skip of a
  row whose record says merged or closed. Seam:
  `bin/lib/prr-shadow.d/blocked-resolver.sh`.
- C2: `bin/unblock.sh` with `bin/lib/unblock/`. Seam:
  `bin/lib/prr-shadow.d/unblock.sh`.

Both reuse `bin/lib/prr-seen.sh`.
