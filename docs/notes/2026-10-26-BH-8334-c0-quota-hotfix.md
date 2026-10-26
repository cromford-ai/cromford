# BH-8334 C0: the verdict lands under a 403, the ledger names endpoints, one rate_limit a minute

Slice C0 of BH-8334 (body items 1, 4 and 5). Slices C1-C3 are separate builds.

## What C0 changes

1. **The verdict post under a rate limit (item 5).** `bin/lead-verdict.sh post`
   read the PR head with `head=$(_gh_rest_field ...)`. The command substitution
   lost `GH_REST_REASON`, and any failure stopped the post. On a drained bucket
   31 finished lead reviews did not post. Now the read goes to a file in the
   same shell. When the reason is `rate-limit` or `quota-reserve`,
   `lv_record_head` reads the PR record (`pr_record_peek`, one jobs GET, no
   GitHub call). It uses the record's `head_sha` only when the record is at
   most `PR_RECORD_HEAD_FALLBACK_MAX_AGE_S` old and the sha is 40 hex. It
   prints one stderr line:
   `lead-verdict: GitHub refused the head read of R#N (<reason>); using the PR record's head <sha12> (age <n>s)`.
   Any other failure (network, 401, 404, a permission 403) stops the post as
   before, and the die line now names the reason and why the record was not
   used. The head compare after it is unchanged (another head = exit 3). The
   status publish is unchanged: on a drained bucket it fails and post exits 4,
   which `bin/lead-review-land.sh` counts as promoted.
2. **The ledger names endpoints (item 1).** `logs/gh-calls/<hour>.log` lines of
   the `gh api -i -X M P` shape get a 5th field, `<METHOD>:<template>`
   (`GET:repos/{o}/{r}/pulls/{n}`). The templater is pure bash, no fork.
   `gh_calls_top_endpoints merge-conductor.sh 10 3600` prints the top 10.
3. **One rate_limit read a minute per process (item 4).** `_ghb_rl_read` in
   `bin/lib/gh-budget.sh` memoizes the last good `gh api rate_limit` body in
   shell variables. `gh_budget_exhausted`, `gh_budget_ratelimit_alert` and the
   fresh read of `gh_budget_refresh` share it. A failed read is never kept. The
   box cache file is not reused by `gh_budget_exhausted` (the premise of
   tests/gh-budget-test.sh section 12 holds).

## Knobs

| knob | default | 0 means | fragment |
|---|---|---|---|
| `GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S` | 60 | every call reads rate_limit | `catalog/lanes.d/_lib.gh-budget.knobs.d/` |
| `PR_RECORD_HEAD_FALLBACK_MAX_AGE_S` | 900 | never use the record head | `catalog/lanes.d/_lib.pr-record.knobs.d/` |

## Tests

- `tests/lead-verdict-record-head.bh-8334-test.sh` (the repro; L1 drives `bin/lead-review-land.sh`)
- `tests/gh-calls-path.bh-8334-test.sh`
- `tests/gh-budget-memo.bh-8334-test.sh`

## What C1-C3 still owe

- C1: the list route `GET /api/pr-records?repo=&state=&since=` with `title`,
  `author`, `body`, `created_at`, `url` and an index on `(repo, state, updated_at)`.
- C2: the verdict-status, review and Mergify queue fields, read first by the
  merge conductor, pipeline-health, dequeue-watch and pr-owner-sweep. The
  acceptance "a conductor tick over 50 PRs makes at most 10 calls" is C2's.
- C3: the quota-floor reserve (item 6).
- The live proof (24 h with the quota never at 0, the conductor under 1,500
  calls an hour) needs C1-C3. C0 does not claim it.
