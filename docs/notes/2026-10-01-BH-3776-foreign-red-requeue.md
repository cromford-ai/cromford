# A PR ejected from a red Mergify batch it did not break is re-queued once (BH-3776)

Doc: MERGE-CONDUCTOR, MERGIFY, FLAKY-TESTS

## Why

#3759 sat on `WAIT_CI queue-ejected — push a fix` for more than 14 hours. Its
head was green and approved. Mergify had ejected it because batch draft #3767
went red on `tests/fleet-propagate-test.sh`, a suite #3759 never touched, and
#3768 on the same main passed that suite minutes later.

BH-636's re-entry arm exists for exactly this, and it never fired. After a real
ejection Mergify leaves its own check runs on the head: `Rule: queue on the
harness label (queue)` with `failure`, and `Mergify Merge Queue` neutral
"Dequeued — checks failed". GitHub then reports the PR `UNSTABLE`. The classifier
already discounted that (`mc_discount`), so the row was READY, but the arm
re-tested the RAW merge state for `CLEAN`. The BH-636 suite never saw it because
its fixture listed the PR as `CLEAN`.

## What changed

1. **`bin/lib/mc-foreign-red.sh`** (new, sourced by the conductor).
   - `fr_mergify_only_unstable <slug> <head>`: rc 0 when every check run NOT
     from the `mergify` app is completed `success|neutral|skipped`, a Mergify
     check is what is non-green, and every commit status is `success`. A failed
     read, or a check-runs page with `total_count` above the rows it holds, is
     not clean.
   - `fr_dequeue_batch`: the newest `mergify[bot]` comment (by `created_at, id`)
     whose payload state is `dequeued`. Its ``Left the queue … at `<sha>` `` must
     be THIS head, otherwise the verdict is `unknown`. It yields the draft
     number and the `/actions/runs/<id>` links under `Failing checks:`.
   - `fr_attribute`: for each run, `GET actions/runs/<id>` (head branch
     `mergify/merge-queue/*`) and `flaky_run_tests_strict` for the failing
     names (rc 2, never `job:` names, when the log fails to read, is empty, is
     over `FLAKY_LOG_MAX` or names more than `FLAKY_TESTS_MAX` tests; `job:`
     names only for a log that was read and named no test). A name touches the
     PR when it equals a line of `mc_pr_files`, or, for the harness's own repo,
     when `bin/test-impact.sh select --why --map-only --changed` lists the
     suite with a kind other than `always`/`full`. An `always`/`full` suite is
     never "untouched": it blocks the all-paths `foreign` and is never
     ledgered. A failed `select` (or a missing map) is `unreadable`. One
     `actions/runs?event=pull_request` read finds a later green merge-queue run
     of the same workflow path on the same main short sha.
     - `own`: a failing name touches the PR. Final: a later batch does not
       contain this PR, so its pass never upgrades `own`.
     - `foreign`: nothing touches the PR, and every name is a path or a later
       batch passed every failing workflow (later-batch evidence only lifts
       an `unknown` with no `job:` name in it).
     - `unknown`: nothing to attribute (no comment for this head, no run,
       test-title names with no later pass, or any `job:` name at all).
     - `unreadable`: an HTTP read failed, the test-impact select failed, or
       ANY failing run's path, base or head could not be read, its log could
       not be read in full, or it is not a merge-queue run (fail closed;
       never cached).
     `foreign` and `own` are cached per (PR, head) under
     `state/merge-conductor/foreign-red/` (pruned after 3 days); `unknown` is
     cached with the dequeue comment's `<id>@<updated_at>` and the runs it was
     judged on (path, base, created_at), the sentence and the ledger-eligible
     rows. On the same comment the next tick reads the comments and the one
     `event=pull_request` list, never the runs, logs or files, and turns
     `foreign` when a later batch passed: Mergify does not edit the dequeue
     comment when another batch passes, so the comment key alone would freeze
     the row. Only an untouched path (not `always`/`full`) is ever written to
     `ci_flakes`.
   - `fr_reentry_gate` replaces the raw `MSTATE != CLEAN` test in the arm:

     | raw state | verdict | result |
     |---|---|---|
     | `CLEAN` | `own` | not re-queued, `FOREIGN_RED_OWN` once (new veto) |
     | `CLEAN` | `foreign` / `unknown` | re-queued once, as BH-636 always did |
     | `CLEAN` | `unreadable` | not re-queued this tick, reason says so, asked again next tick |
     | `UNSTABLE`, Mergify-only | `foreign` | re-queued once (the fix) |
     | `UNSTABLE`, Mergify-only | `own` / `unknown` | not re-queued, `push a fix`, one `FOREIGN_RED_OWN` / `FOREIGN_RED_UNKNOWN` line |
     | `UNSTABLE`, Mergify-only | `unreadable` | not re-queued this tick, reason says so, asked again next tick |
     | `UNSTABLE` with a real red | — | not re-queued, no attribution read |

   - `fr_requeue_note`, after a requeue that was asked (rc 0 or 3): the
     `fqattr <key> <head>` mark BEFORE the post, one PR comment through
     `gh_rest_comment` (`re-queued: batch #3767 failed tests/fleet-propagate-test.sh,
     which this PR does not touch; #3768 on the same main passed it`, each
     clause only when proven), one `REQUEUE_ATTRIBUTED <key> <head>` log line,
     and the ci_flakes rows (docs/FLAKY-TESTS.md).
2. **`bin/merge-conductor.sh`** sources the lib, with a fallback gate that is
   exactly the old test when the lib is absent, splits the arm's `elif`, and
   calls `fr_requeue_note` on rc 0 and 3. The observe line `would REQUEUE`
   carries the attribution.
3. **`bin/lib/mc/queue.sh`**: `MC_WITNESS_FRESH=1` makes `mc_mergify_witness`
   drop failure-concluded and `Dequeued…` Mergify lines before deciding. It is
   set by `mc_requeue_mergify`, and by `mc_mergify_inqueue` for a head that
   carries a `requeued` mark. Without it the leftover failure reads as an
   acknowledgement, the row goes QUEUED, and the next settle pass counts the
   same failure as a second ejection (`queue-ejected-twice`, a false strike).
   Plain enqueues are unchanged.

The strike counter is untouched: a second ejection on the same head still goes
`BLOCKED_HUMAN queue-ejected-twice` before any attribution read.
`MC_QUEUE_REENTRY=0` still switches the whole arm off. No new knob.

## Round 3 (#3798 re-review of 4cbe3956)

- N1: `test-impact.sh select --map-only` lists only the map's picks even when
  CI ran the whole corpus (catalog/, tests/lib/, .github/workflows/,
  test-impact itself). Its reason line (fd 3, routed to stderr) is now read:
  `map-only: CI runs the corpus, …` or any `full` row makes every failing
  suite the PR's own. No reason line is `unreadable`.
- N2: per-job attribution, above.
- N3: every bullet under "Failing checks:" must link an Actions run; a Vercel
  build or a commit status in that list makes the batch `unreadable`.
- The merges-on log mark is `fqlog <key> <head> <word>`, so an `own` line after
  an `unknown` one on the same head is still written.

## Known limits

- Closed in round 3 (N2): a lint, build or syntax job red next to a test red
  in the same run used to read as "the batch failed that test". Now every
  failed job must name a test in its own `--log-failed` section, or be a
  fan-in (`bin/ci-verdicts.sh pure`'s "shard i/N: k of m tests failed. Open
  '<shard job>'") pointing at failed jobs that did; anything else is
  `unreadable`. A run whose whole log names no test still falls back to
  `job:<name>`, and a verdict holding any `job:` name stays `unknown` even
  after a later green batch: a job name cannot be checked for touch, and a
  later pass may lift only an unknown the PR is known not to touch (the operator,
  16:02Z). Raw CLEAN + unknown keeps BH-636's plain requeue.
- Product repos report test titles, not paths. A title cannot be checked
  against the PR's files, so it is never lifted by a later batch (round 4,
  F1): a batch red on titles stays `unknown` (raw CLEAN still re-queues by
  BH-636). Jest/vitest FAIL file lines are read without gh's
  `<job>\t<step>\t<ts>` prefix (F3), so a file path is still checked.
  Round 5: a name is a path by PROVENANCE, not shape. flaky_run_tests_strict
  tags each name P (a harness `--- tests/<x>.sh` line, a `FAIL <file>`
  token), T (any other runner name: `works`, `api/health`) or J (job:);
  only P can be an untouched path, the ledger or the "does not touch"
  sentence. The `nomap` read is anchored to test-impact's reason line.
- Where the conductor runs without a test tree (the hub: `MC_H` has no
  tests/, harness-sync never ships it), test-impact answers `full: the map
  could not be built`. That is `nomap`: no attribution, BH-636 exactly (raw
  CLEAN re-queues, nothing else), one `FOREIGN_RED_NOMAP` line per head (F2).
  Follow-up: point `--root` at a real checkout so the hub can attribute.
- Outside cromford, "touches the PR" is file overlap only (a failing test
  path that is in the PR's diff). The test-impact map exists for the harness's
  own repo, so a product PR that breaks a test it does not edit reads as not
  touching it; a later green batch then makes it `foreign`, bounded by the
  once-per-head requeue and the two-ejection strike.
- The BH-3719 dequeue-watch lane, when it lands, shares BH-636's
  `requeued <key> <head>` mark; it should read it so a head is re-queued at most
  once whichever arm gets there first.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/mc/requeue-after-foreign-red.bh-3776-test.sh`
drives the real conductor through #3759's shape (R1) and the negatives. On the
hub after deploy: the next foreign-red ejection logs exactly one
`REQUEUE_ATTRIBUTED <key> <sha> — re-queued: …` line and the PR carries one
matching comment.
