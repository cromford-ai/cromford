# BH-10218: small lanes read the PR record list, a repo metadata memo and a Mergify config cache

Doc: GH-REST, EVENTS

Refs #9926 (second round). Ticket #10218.

## Before

The hub ledger, 2026-11-26 10:00Z to 10:33Z, counted these spent GETs by lanes
that read data the hub already holds. Before: about 450 spent GETs per hour for
the 3 rows.

| Read | Callers (spent in 33 min) | Per hour |
|---|---|---|
| Open PR list (`pulls`) | `overlap-guard.sh` 21, `reconcile-prs.sh` 20, callers behind `timeout` 21, `scheduler.sh` 15, `utilization-push.sh` 14, `review-autopilot.sh` 7 | about 180 |
| Repo metadata (`repos/<owner>/<repo>`) | `main-red-pr-pair.sh` 31, `pr-owner-sweep.sh` 17, callers behind `timeout` 16, `fly-pool.sh` 12, `overlap-guard.sh` 6, `ci-shard-watch.sh` 6 | about 160 |
| `contents/.mergify.yml` and `rulesets` | `dequeue-watch.sh` 48 and 11 | about 110 |

## W1: the callers behind `timeout`

The ledger shim (`bin/gh-ledger/gh`, `_ghl_caller`) and the REST shim
(`bin/gh-rest-shim`, `gshim_caller`) name the program of `$PPID`. A lane that
runs `timeout 30 gh ...` made `timeout` that parent. Both now step past a
wrapper program (`timeout gtimeout nice ionice setsid flock env stdbuf nohup
chrt`) to its own parent, at most 3 hops, and print the script name. They never
print an argument. A hop that cannot read `/proc` prints the wrapper, as before.

A static scan of `bin/` names these callers. The hub has the ledger, this pool
box does not, so the post-merge ledger confirms the list.

- `overlap-guard.sh --refresh` under `bin/fly-pool.sh` (`pool_overlap_refresh`,
  `GH_REST_TIMEOUT_S` exported). It reads the open `pulls` list and runs the
  `repos/<slug>` token ladder. This is the strongest match for both `timeout`
  rows. W2 and W4 cover both of its reads.
- Raw `timeout ... gh` sites that read neither `pulls` nor `repos/<slug>`:
  `bin/post-merge-verify.sh`, `bin/lib/post-merge-verify.sh`,
  `bin/cost-local-brake.sh`, `bin/cost-rollup.sh`, `bin/lib/revdep-lib.sh`,
  `bin/lib/tracker/gh-issue-create.sh`, `bin/hotfix-migrate.sh`,
  `bin/lib/hotfix-migrate-workflow.sh`, `bin/triage-map.sh`, `bin/lib/hold.sh`,
  `bin/lib/gh-session-token.sh`, `bin/lib/gh-per-pr-daily.sh`,
  `bin/lib/gh-app-default.sh`, `bin/fly-pool-probe-pull.sh`,
  `bin/dora-digest.sh`, `bin/alert-triage.sh`.
- `gh_rest` calls under `GH_REST_TIMEOUT_S`: gh_rest writes its own ledger row
  from the caller's shell (`$0` is the script), so these rows never said
  `timeout`.

## W2: repo metadata memo

The five callers of the `repos/<owner>/<repo>` row use one field: the token
ladder's visibility verdict (`gh api repos/<slug> -q .id`, one GET per rung,
`bin/lib/gh-repo-token.sh`).

- `bin/lib/repo-change-mark.sh` (new): `rcm_mark <slug>` prints the repo's
  change mark, the highest worker wake id the wake mirror
  (`bin/lib/pr-snapshot-wakes.sh`) read for the repo. `rcm_moved <slug> <kinds>
  <mark> <stamp-epoch>` answers moved (rc 0), quiet (rc 1) or cannot tell
  (rc 2). It compares wake ids, never clock times. The stamp epoch only proves
  the mirror still holds every row since the stamp (coverage start, and the
  3-day row horizon less one hour). It reads the mirror and never acks.
- `bin/lib/repo-meta.sh` (new): `repo_meta_arm` points the ladder's memo at
  `state/repo-meta/probe/` with the age `REPO_META_BACKSTOP_S` and defines two
  hooks. A memo row then carries the mark (`<epoch>\t<word>\t<mark>`), taken
  before the probe's GET, and the row is void after a `push` or `repo` wake.
  `repo_meta_get <slug> default_branch` serves the BH-9938 default-branch memo
  (`state/prr-default-branch/`) with a stamp `<memo>.meta`, and reads
  `repos/<slug>` once when the stamp is old, moved or unknown.
- `bin/lib/gh-repo-token.sh`: the hooks. With no hooks (the merge conductor and
  every other lane), the 2-column row and the 300 s TTL are as before. The memo
  dir is separate from the conductor's `state/gh-repo-probe/`.
- Callers: `bin/main-red-pr-pair.sh`, `bin/pr-owner-sweep.sh`,
  `bin/overlap-guard.sh` (both paths), `bin/ci-shard-watch.sh` and
  `bin/fly-pool.sh` call `repo_meta_arm` once, fail-open. `fly-pool.sh`'s
  liveness probe of `repos/<slug>` and its 404 check before a relabel stay live
  reads: a memo there would hide an outage or relabel a real PR.
- Worker: `wakeOfRepository` (`worker/jobs/src/lib/wake-of-repository.js`,
  called by the GitHub receiver after `wakeOf`) maps a `repository`
  delivery to kind `repo`, keyed on the numeric repository id, for `edited`
  with `changes.default_branch`, `renamed` and `transferred`. Every other
  action is dropped. `bin/wake-loop.sh` drops kind `repo` with its existing
  "unknown kind" line; nothing in the wake loop needs it.
- Knob: `REPO_META_BACKSTOP_S` (`catalog/lanes.d/_lib.repo-meta.json`, row
  `lib.repo-meta.repo_meta_backstop_s`), default 86400, 0 = no memo.

A feed that cannot tell (no jobs client, a failed or incomplete read, a repo
with no wake inside `PR_SNAPSHOT_FEED_STALE_S`) reads GitHub, as before. A
failed GitHub read writes nothing.

## W3: dequeue-watch provider store

- `bin/lib/dequeue-watch/provider-memo.sh` (new): `dqw_provider <slug>` serves
  the stored provider word (`state/dequeue-watch/provider/<owner_repo>`,
  `<word>\t<epoch>\t<mark>`) until a `push` wake (default branch only) arrives
  above the mark, or until `DQW_PROVIDER_BACKSTOP_S`. Otherwise it calls
  `mc_queue_provider`. It stores the word only when that call made a real read
  (the provider file was rewritten in the call). A last-known-good answer after
  a failed read is used and not stored.
- `bin/dequeue-watch.sh` calls `dqw_provider`; with no lib, `mc_queue_provider`
  as before.
- Knob: `DQW_PROVIDER_BACKSTOP_S` (row `lane.dequeue-watch.dqw_provider_backstop_s`),
  default 21600, 0 = no store.
- Conditional request: the reads under the store go through `gh_policy_read` ->
  `gh_rest`, which sends `If-None-Match` with the stored ETag. An unchanged
  `.mergify.yml` answers 304, and the ledger counts it 0. The ETag key is the
  resource, not the token, and lives in `state/gh-etag/`, so it survives
  between runs. A 404 (no `.mergify.yml`) has no ETag: the store is what saves
  that read. The change mark is the wake id until #10215 gives a base sequence;
  the store format does not change then.

## W4: open PR list from the record

`overlap-guard` (`--refresh` list and check path), `scheduler` (stack parent
lookup), `utilization-push` (open heads) and `review-autopilot` (open list) read
through `prr_read` with a seam in `bin/lib/prr-shadow.d/<lane>.sh`. The step
rows are `lane.scheduler.gh_source`, `lane.utilization-push.gh_source`,
`lane.review-autopilot.gh_source` and, because overlap-guard is a lib and not a
lane, `lib.overlap-guard.gh_source`. All default to `shadow`.

What the record cannot answer is a miss word, and the miss reads GitHub:

- overlap-guard check path: it asks for `files` with additions and deletions.
  The record holds no such field, so `og_check_record` answers `field:files`.
  Only the `--refresh` list saves reads.
- scheduler: a branch not in the trusted open list is `field:head`. Merged or
  closed parents are known only to GitHub's `state=all` read.
- review-autopilot: a null `draft` or `created_at` is a field miss.
- utilization-push: a list of `UTIL_TICKETS_PAGES` x 100 rows or more is
  `truncated`, the cap at which GitHub's read fails today.

`reconcile-prs.sh` stays on GitHub. Its read is `rcr_page`
(`bin/lib/reconcile-read.sh`): the CLOSED `pulls` page with `closed_at`,
`merged_at` and `merge_commit_sha`. The record holds none of those fields and
has no full closed-list sync stamp, so a seam would miss on every tick. That
read already rides ETag.

## Operator steps

- The `repository webhook event` must be on in the GitHub App's event
  subscription for a default-branch change, a rename or a transfer to void the
  memo at once. Without it, the memo still voids on a `push` wake and on the
  24-hour backstop.
- Move a lane's `gh_source` row to `record` only after a 48-hour shadow count
  of 0 (the BH-9937 rule).

## After merge

24 hours after the merge, run on the hub and post the result on the ticket:

```
bin/gh-ledger-report.sh --per-merged-pr --by-repo --last 24h
```
