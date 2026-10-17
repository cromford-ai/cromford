# Direct merge in optimistic landing mode (BH-6745, wave 2 of #6541)

**What it is:** with `MC_LANDING_MODE=optimistic`, the merge conductor merges
an eligible READY PR on a Mergify repo directly, bound to its head, with no
queue label. Modes `queue` (default) and `shadow` do not change
([landing-shadow.md](landing-shadow.md)).

- Lib: `bin/lib/mc/landing.sh`.
  - `landing_direct_on <project> <provider>`: rc 0 for mode `optimistic`,
    provider `mergify`, not `MC_ON_MACHINE=1`.
  - `landing_direct <project> <repo> <pr> <head> <key> <labels-csv> <url>`:
    prints the outcome token. rc 0 `merged` (line 2 = merge sha), rc 1
    `queue`, rc 2 `budget`, rc 3 `lock`, rc 4 `405|409|422|error`.
  - `landing_direct_path <key> <head>`: rc 0 for a direct landing.
- Hook: `bin/merge-conductor.sh` `pr_worker` READY arm, inside `QUEUE=1`,
  before the Mergify `mc_enqueue` (step `landing-direct`).
- Attempts ledger lines: `landing <key> <head> optimistic` (the decision),
  `landingdirect <key> <head>` (written under the merge lock, before the merge
  PUT), `landingfail <key> <head> <code>` (a refused merge).
- Ledger: the `kind=merge` row's detail is `merge-conductor path=direct` for a
  direct landing, `merge-conductor` for every other landing.
- Route: `PUT /api/landing-decisions/outcome {repo, number, head, mode,
  outcome}` (`worker/jobs/src/routes/landing-outcome.js`, fragment
  `worker/jobs/test/route-table.d/bh-6745-landing-outcome.txt`). 200 `{ok}`,
  404 `no decision row`, 400 on a bad field. `GET /api/landing-decisions` rows
  carry `outcome` and `outcome_at`.
- Knob: `MC_DIRECT_MERGE_BUDGET` (default 6, 0..50, 0 = off). Row
  `lane.merge-conductor[.<project>].mc_direct_merge_budget`.

**How to drive it:**

| what | how |
|---|---|
| the arm, the budget, the fallback and a real conductor tick | `HARNESS_TEST_SANDBOX=1 bash tests/landing-direct.bh-6745-test.sh` |
| the outcome route and its index | `cd worker/jobs && node --test test/landing-outcome.bh-6745.test.js` |
| turn optimistic on for one project | `bin/jobs-client.sh setting-set lane.merge-conductor.<project>.mc_landing_mode optimistic` |
| roll back | `bin/jobs-client.sh setting-set lane.merge-conductor.<project>.mc_landing_mode queue` |
| the lines on the hub | `grep 'LANDING_DIRECT' /root/harness/logs/merge-conductor.log \| tail -5` |
| the rows on a live worker | `curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/landing-decisions?repo=example-org%2Fcromford&limit=5"` |

**What must never regress:**

- Modes `queue` and `shadow` make no merge PUT. Their label POSTs are
  byte-equal to before.
- An ineligible PR enqueues exactly as in mode `queue`.
- A direct merge is bound to the head sha and runs under `mc_merge_locked`.
- Outcome `merged` is written only after `mc_merge` returned 0.
- A refused direct merge is no `mergefail` strike, and the next tick enqueues.
- A lane-run machine never merges directly.
