# Pre-queue verdicts: reuse by impact set, adopt a run from any worker, seed the batch-fail suites (BH-6924)

Doc: MERGE-CONDUCTOR

## Why

1. Main moves many times an hour. `pq_resolve` reused an older main's verdict
   only inside `MC_PREQUEUE_FRESH_S` and `MC_PREQUEUE_FRESH_COMMITS`. Outside
   them, every READY head paid for another `prequeue-gate.yml` run, also when
   the new main commits touched nothing the PR's suites read.
2. A verdict lived only in `$MC_STATE_DIR/prequeue/` of the worker that
   dispatched the run. A lane-run machine (`MC_ON_MACHINE=1`) has its own state
   dir. The hub, or the next machine, saw a miss and dispatched the same
   (PR, head, main) again, and did not see the first green.
3. The learned list held only the suites counted from failed batches in the
   window. The suites the BH-6838 replay found in failed batches #6830 and
   #6829 were not on it.

## What changed

### Impact reuse (`bin/lib/mc-prequeue.d/impact-reuse.sh`)

`pq_resolve` asks `pq_impact_reuse` after the fresh rules found nothing and no
sibling run is pending. The veto and the dispatch come after it.

| Step | Condition | Answer |
|---|---|---|
| off | `MC_PREQUEUE_IMPACT_REUSE=0` or `MC_PREQUEUE_REUSE=0` | none (dispatch as before) |
| scope | the slug is not `HARNESS_REPO`, or no checkout with `bin/test-impact.sh` and `tests/` | none |
| candidate | the newest terminal entry for this (PR, head) on an older main, by mtime, dispatched at or after `PQ_MIN_AT` and less than `MC_PREQUEUE_IMPACT_MAX_S` ago | none when there is no entry |
| candidate state | red, conflict or could-not-run | none (a newer non-green is never stepped over) |
| main move | one `compare/<verdict-main>...<main>` read: not `ahead`, 0 files, or 300 files (GitHub's cap) | dispatch (`compare-unusable`) |
| PR files | `mc_pr_files` fails or is empty | dispatch |
| reach | `bin/test-impact.sh select --why` as a batch select (`TI_BATCH_SELECT=1`) for each list; `always` rows and a regression `*` row are excluded | |
| full | the main move is `full` / the PR is `full` | dispatch (`main-full` / `pr-full`) |
| overlap | a shared file, or a shared suite | dispatch (`impact-hit <item>`) |
| merge test | `pq_merge_test`: clean / conflict / no answer | reuse / rebase / dispatch |

A reuse writes the candidate's line as the entry for (head, current main), and a
`.reuse` sidecar beside it:

    reused-from main=<verdict-main> run=<run id> commits=<n> files=<k> reason=impact-disjoint

Both writes happen under the `pq_dispatch` lock, into an empty entry only, and
before the gate answers `proceed`. The next tick reads the entry as a plain cache
hit. A reused entry keeps the dispatch time of the run it came from, so a chain
of reuses (A to B, then B to C) is bounded by `MC_PREQUEUE_IMPACT_MAX_S` from
the first run. Each decision on a candidate writes one line:

    PREQUEUE reuse #<n> head=<h> verdict-main=<vm> current-main=<m> age=<s>s verdict=<v> -> impact-<reuse|rebase|dispatch|none> (<why>)

Known limit: a PR that adds a new suite is `full` under main's map (`unknown
reach`), so it is dispatched again on every main move. Main's map cannot say
what a new suite reads.

### Adopt a run by its title (`bin/lib/mc-prequeue.d/adopt.sh`)

On a miss, after the fresh rules and before the sibling hold, `pq_adopt_run`
reads the run list of `prequeue-gate.yml` (30 runs, memoised per tick and repo).
A run whose title is exactly `prequeue pr=<n> head=<h> main=<m>` is written to
this worker's cache as `pending <created epoch> <run id>`, under the
`pq_dispatch` lock and into an empty entry only. Then `pq_settle` reads it:

- completed with one verdict: that verdict (green and no-selection proceed, so
  the READY arm enqueues as for a run this worker dispatched);
- still running: hold, aged from the run's own created time, so
  `MC_PREQUEUE_DEADLINE_S` still bounds it;
- past the deadline or completed without a verdict: could-not-run, one warn
  alert, proceed (the existing rule).

A busy lock holds. One line per adoption:

    PREQUEUE adopt #<n> head=<h> main=<m> run=<id> -> <proceed|red|hold>

### Seed the learned list (`bin/prequeue-learned.sh`)

`--list` also reads `catalog/prequeue-learned-seed.d/*.txt`, one suite a line.
A seed suite is printed first and is not cut by `PREQUEUE_LEARNED_MIN` or
`PREQUEUE_LEARNED_TOP`. `--why` prints `seed<TAB><suite>` rows before the count
rows. A line that is not a `tests/*.sh` path is dropped, with one stderr line
that counts the dropped lines. The file check (the suite must exist) applies
only when the root has a `tests/` dir. A deployed harness (`/root/harness`) has
no `tests/`, so a file check there would drop every seed. There the gate's own
checkout decides: `bin/test-impact-gate.sh --also` drops a suite it does not
have, with one `impact-gate: also: dropped` line. The seed works with no run
records. The first
fragment, `bh-6924.txt`, holds `tests/route-keyed-merge.bh-5788-test.sh` and
`tests/worker-routes-render.bh-4607-test.sh`. operator-a5's `batch-fail-suites.txt`
is not readable from a build box: an operator adds it as one more fragment
(see the README in that directory).

## Knobs

Lane `merge-conductor`, settings row `lane.merge-conductor.<project>.<name>`:

- `MC_PREQUEUE_IMPACT_REUSE` 0-1, default 1.
- `MC_PREQUEUE_IMPACT_MAX_S` 0-604800 seconds, default 21600 (6 h). 0 means
  impact reuse never finds a candidate.

## Probes (after merge, on the hub)

0. The map root. Impact reuse needs a checkout ON main with
   `bin/test-impact.sh` and `tests/`: `MC_TI_ROOT`, else
   `<harness>/../harness-checkout` (`_fr_ti_root`, the root
   `bin/lib/mc-batch-impact.sh` uses). `/root/harness` has no `tests/`. Without
   such a checkout every candidate answers `none`, and nothing changes. Probe:
   `git -C /root/harness-checkout symbolic-ref --short HEAD && ls -d /root/harness-checkout/tests`.
   The build box that wrote this change has no `/root/harness-checkout`, so this
   is not known for the hub.
1. Impact decisions: `grep 'PREQUEUE reuse.*impact-' /root/harness/logs/merge-conductor.log | tail`
2. Adoptions: `grep 'PREQUEUE adopt' /root/harness/logs/merge-conductor.log | tail`
3. The learned list: `bash /root/harness/bin/prequeue-learned.sh --list --why | head`
4. Runs per merged PR over 24 h: count the Actions runs of `prequeue-gate.yml`
   whose title starts `prequeue pr=` created in the window, and divide by the PRs
   merged in the same window. The ticket's target is 1.5 or less.
5. Minutes with an empty queue: the number of conductor ticks in 12 h where
   READY rows exist and no PR is in the merge queue. The ticket's target is 0.

## Mac gate retirement

The Mac gate runs on operator-a5. It is not code in this repo, and this change does
not retire it. The Mac gate can retire when both of these are true:

1. Probe 2 shows `PREQUEUE adopt ... -> proceed` lines on the hub, and each of
   those PRs got an enqueue line (`enqueued in the mergify merge queue`) on the
   same or the next tick, with no Mac action.
2. Probe 5 reads 0 minutes over 12 h while the Mac gate is paused.

The date it retires goes in a later note, after both probes pass.
