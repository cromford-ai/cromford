# Landing contract and shadow decisions (BH-6744, wave 1 of #6541)

**What it is:** `bin/lib/mc/landing.sh` decides whether a READY PR WOULD be
eligible to land directly instead of through the merge queue. Wave 1 only
records the decision. The conductor merges or enqueues exactly as before.

- Lib: `bin/lib/mc/landing.sh`, sourced by `bin/merge-conductor.sh` (optional
  source, like `bin/lib/mc/external-enqueue.sh`).
  - `landing_mode <project>`: `queue` | `shadow` | `optimistic`.
  - `landing_eligible <repo> <pr> <head> [project] [labels-csv]`: rc 0 and
    `ok`, or rc 1 and one reason token.
  - `landing_shadow <project> <repo> <pr> <head> <key> <labels-csv>`: the
    hook in `pr_worker`'s READY arm, after the queue enqueue's `case` (step
    `landing-shadow`). Always rc 0.
- Knobs (`catalog/lanes.d/merge-conductor.knobs.d/`):
  - `MC_LANDING_MODE`, default `queue`. Row
    `lane.merge-conductor[.<project>].mc_landing_mode`. `queue` is the kill:
    no read, no row, no line. Any other value reads as `queue`, with one
    `LANDING_MODE_BAD` line per project per UTC day.
  - `MC_LANDING_PQ_AGE_MIN`, default 60 (1..1440). Row
    `lane.merge-conductor[.<project>].mc_landing_pq_age_min`.
- Routes (harness-jobs, `worker/jobs/src/routes/landing-decisions.js`,
  fragment `worker/jobs/test/route-table.d/bh-6744-landing-decisions.txt`):
  - `POST /api/landing-decisions {repo, number, head, mode, would, reason}`:
    201 `{ok, id}` on a new (repo, number, head, mode); 200
    `{ok, existing:true}` on a repeat, stored row untouched; 400 on a bad field.
  - `GET /api/landing-decisions?repo=<owner/name>[&number=<n>][&limit=1..200][&before_id=<id>]`:
    `{rows, truncated, as_of}`, newest first. `repo` is required.
    `before_id` (BH-6748, a positive integer, else 400) keeps only ids below
    it: the next page of `bin/lib/landing-sources.sh` `ls_fetch`.
- Table `landing_decisions`
  (`worker/jobs/schema.d/202610151539-bh-6744-landing-decisions.sql`):
  unique (repo, number, head, mode); indexes `idx_landing_decisions_repo_id`
  and `idx_landing_decisions_at`.
- Retention: rule `landing_decisions.age` in
  `worker/jobs/src/routes/retention.js`, window row
  `retention.landing_decisions.days` (90). The hourly `bin/d1-retention.sh`
  runs it under `retention.dry_run`, one `retention_runs` row per run.

**The reason tokens**, in check order (the first refusal wins):

| # | condition | refusal token |
|---|---|---|
| 1 | no main-red freeze flag for the project or slug | `main-red`; no `main_red_flag` on the box: `unreadable-freeze` |
| 2 | no `queue-solo` label | `solo` |
| 3 | no `fix-main-red` label (`MC_MAIN_RED_LABEL`) | `fix-main-red` |
| 4 | a pre-queue verdict `green` or `no-selection` for this head | `prequeue-missing` |
| 5 | the newest such verdict dispatched at most `MC_LANDING_PQ_AGE_MIN` minutes ago | `prequeue-stale` |
| 6 | the `risk_tiers` row for this exact head is `low` or `medium` | `tier-high`, `tier-unknown`, `unreadable-tier` |
| 7 | `lead-verdict` commit status `success` on the head | `lead-verdict`, `unreadable-status` |
| 8 | every `.mergify.yml` admission check run (status contexts removed) is `completed/success`, latest run per name | `fast-checks`, `unreadable-checks` |
| 9 | no PR file or rename source matches a lead-protected glob | `protected-path`, `unreadable-paths` |

All true: `ok`, and the line says `would=direct`.

**How to drive it:**

| what | how |
|---|---|
| the contract, the shadow hook and a real conductor tick | `HARNESS_TEST_SANDBOX=1 bash tests/landing-eligible.bh-6744-test.sh` |
| the routes, the indexes and the retention rule | `cd worker/jobs && node --test test/landing-decisions.bh-6744.test.js` |
| turn shadow on for one project | `bin/jobs-client.sh setting-set lane.merge-conductor.<project>.mc_landing_mode shadow` |
| the lines on the hub | `grep ' LANDING ' /root/harness/logs/merge-conductor.log \| tail -5` |
| the rows on a live worker | `curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/landing-decisions?repo=example-org%2Fcromford&limit=5"` |

**What must never regress:**

- Mode `queue` adds no GitHub read, no jobs call, no ledger line and no log line.
- The enqueue arms (rc 0/2/3/4/other) and their label POSTs are byte-equal with
  shadow on and off; the hook runs after the enqueue and never returns from the
  READY arm.
- One row and one `LANDING` line per (PR, head, mode). The ledger mark is
  written before the POST; a failed POST is one `LANDING_ROW_FAILED` line and
  is not retried.
- An unreadable input is a refusal, never `ok`.
