# BH-10215: the conductor serves idle PR state until the base moves

Doc: EVENTS, GH-REST

Second round of #9926. Two GitHub reads of `bin/merge-conductor.sh` move onto
the PR record. Both act only in step `record` of lane `merge-conductor`
(settings row `lane.merge-conductor.gh_source`). Steps `off` and `shadow` make
the same GitHub calls as before.

## Before numbers

Hub, 2026-11-26 10:00Z to 10:29Z, all lanes in step `record`:

| Read | Spent in 30 min | Spent per hour | Refused in 30 min |
|---|---|---|---|
| `pulls/N` (the merge-state read of an idle open-list row) | 74 | 148 | 58 |
| `git/matching-refs/heads/ticket` (the branch lookup) | 17 | 34 | 42 |

`merge-conductor.sh` spent 317 GETs in the window (about 630 per hour).

## 1. The merge state: the base sequence

GitHub sends no event when a merge state changes. The state changes only when
the base branch moves or the PR changes, and both reach `POST /webhooks/github`.

- The worker keeps `pr_base_seqs (repo, base_ref, seq, last_sha, pushed_at,
  updated_at)`. Each `push` webhook to the default branch, or to the base of an
  open record, adds 1 to `seq` (`worker/jobs/src/lib/pr-base-seq.js`). The same
  `after` sha changes 0 rows. The statement runs in the wake batch under the
  delivery claim guard, so 20 deliveries of one id make 1 raise.
- `GET /api/pr-base-seqs?repo=` gives `{rows:[{base_ref, seq, pushed_at}]}`.
- A record row stores `mergeable_base_seq`: the sequence at which its
  `mergeable_state` was read from GitHub. `prr_serve_note` writes it in the same
  PUT as the state, from the sequence the tick read BEFORE the GitHub read.
- In step `record`, `prr_serve_state` first runs today's checks: the repo,
  the number, state open, the head equals the list head, and a state GitHub
  computes. Then it applies three rules, in this order:
  1. SEQ-MATCH: the row's sequence equals the repo's sequence for the row's
     base, and `fields_at.mergeable_state == fields_at.mergeable_base_seq`.
     The row serves while its STATE is at most `PR_RECORD_SERVE_SEQ_MAX_AGE_S`
     old (default 3600, the backstop for a lost push webhook). Older: rule 3.
     The state's age is `age_s + (refreshed_at - fields_at.mergeable_state)`.
     All three are worker times, so no box clock is compared (round 6).
     Rule 1 serves only `clean`, `dirty`, `behind` and `draft` (round 5).
     A check run, a status or a review moves `blocked`, `unstable` and
     `has_hooks` with no base push and no `mergeable_state` write. Those
     states fall to rule 3, so a WAIT_CI row sees its CI go green within
     `PR_RECORD_SERVE_MAX_AGE_S`, as in BH-8457. This is the split
     `_hpl_state_get` uses (BH-1486 F1).
  2. SEQ-MOVED: both sequences are known and differ. A miss at any age.
  3. AGE: every other row uses today's rule. It serves only while it is at
     most `PR_RECORD_SERVE_MAX_AGE_S` old (600 on the hub).
- A sequence that cannot be read (a jobs error, a bad answer, no row for the
  base, no sequence on the row) never counts as "not moved". The row gets no
  age extension, so it falls to rule 3.
- Round 3 change: rounds 1 and 2 made the sequence the only rule in step
  `record`. A record with no sequence then missed at any age, and
  `tests/mc-record-tick.bh-9938-test.sh` AT1 read 54 `pulls/N` (want 10 or
  less). Rule 3 keeps today's serves.
- Round 5 change (refute F1): rounds 1 to 4 let rule 1 serve every state,
  `blocked` included, for 3600 s. A PR read BLOCKED while its CI ran stayed
  WAIT_CI for up to 1 hour after CI went green. `tests/mc-serve-base-seq`
  S13 pins the split: `blocked`/`unstable`/`has_hooks` at 3000 s are a miss,
  `clean`/`dirty`/`behind`/`draft` at 3000 s are served.
- Round 6 change (Mac finish): rounds 1 to 5 timed rule 1 with `age_s`, the
  age of the ROW. Any webhook write of another field (checks, labels, a
  review) moves `refreshed_at`, so an idle `clean` row that gets such writes
  stayed young, and the 3600 s backstop for a lost push webhook never ran
  out. Rule 1 now times the state itself (the BH-10257 slice 2 rule for the
  QUEUED view). `tests/mc-serve-base-seq` S14 pins it.
- The sequences are one jobs GET per repo per tick (`tick_memo_file baseseq`).
- Round 4 change: a failed or malformed base-sequence read writes a negative
  tick memo (`tick_memo_file baseseq-miss`, an empty marker). The next rows of
  the same tick miss with no new request. So a jobs error costs 1 GET per repo
  per tick, not 1 per row (round 3 made 10 GETs for 10 rows). The next tick
  asks again. The marker is a miss, never "not moved".
- The tick log line is `<slug> PR-RECORD served=<n> miss=<n>`. It ends with
  ` seq_miss=<n>` when some misses came from the sequence.

## 2. The branch lookup

`prs_branch_tip` (`bin/lib/pr-snapshot-refs.sh`) under
`PRS_OPEN_PRR=merge-conductor` reads through `prr_read merge-conductor
"<slug>#refs:<prefix>"` and the seam (`mc_refs_record`, `mc_refs_github`,
`mc_refs_norm`). The record answer is the open rows of `pr_records` with
`head_ref` under the prefix and a `head_commit.sha` (the tip of the last push
webhook), from `GET /api/pr-records?repo=&state=open&with=head_commit`. Any
miss (stale or untrusted list, the branch not in it) reads GitHub. A record
answer is never written into the shared refs cache. `prs_refs_pin` pins the
answer it used, so the tick's workers read the pin.

In step `shadow`, a `PRR_SHADOW lane=merge-conductor key=<slug>#refs:<prefix>`
line with `changed=0 only_record=0` is a match: the GitHub side also holds
branches with no open PR (`only_github`).

## The flip

1. Deploy the worker (the push upsert, the route and the column).
2. Wait 1 hour, so each repo with open PRs has a base-sequence row.
3. Set the step:

   ```bash
   bin/jobs-client.sh setting-set lane.merge-conductor.gh_source record "BH-10215: base-sequence serve"
   ```

4. To undo it, set the same row to `shadow`.

## Round 3 red and its fix (round 4)

Round 3 was red on a fresh checkout. `tests/mc-serve-base-seq.bh-10215-test.sh`
ran `node --test` on the worker, but it did not compose the git-ignored
catalogs (`catalog/lanes.json`, `catalog/llm-sites.json`, BH-1247). Its own
case N1 failed with `ERR_MODULE_NOT_FOUND`. The guards
`tests/worker-node-catalog-compose.bh-6452-test.sh` and
`tests/worker-node-lanes-build.bh-6540-test.sh` named the suite as an offender.
Round 4 sources `tests/lib/worker-catalogs.sh` and calls `worker_catalogs "$DIR"`
on the two lines after `DIR=`.

## Owed after merge

After 24 hours on the hub in step `record`, post on #10215: the `pulls/N` and
`matching-refs` spent calls per hour, and the conductor calls per merged PR for
each repo (from the gh-ledger).

## Knobs and rows

- `PR_RECORD_SERVE_SEQ_MAX_AGE_S` (catalog `_lib.pr-record`): 3600, 0 = never serve in step record.
- `pr_base_seqs.read_limit` (settings row): 500 rows per read.
- `retention.pr_base_seqs.days` (settings row): 30. A deleted row costs one GitHub read per row.
