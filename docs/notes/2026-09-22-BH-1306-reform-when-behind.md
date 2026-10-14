# A merge train that is BEHIND the tip is re-verified there, or it is closed

Doc: merge-trains

## Why

BH-1270 put N merge trains in flight at once on disjoint planned-file sets, and
the review of #1297 found the hole in it (Important + probe P7). The partition's
premise is TEXTUAL disjointness: two unions cut from the same base only meet if
they touch the same files. That is true about merging, and it says nothing about
verification.

After train A lands, train B's union still merges cleanly — its merge base is
the OLD tip — so GitHub reports `MERGEABLE` / `CLEAN`, and `settle_train`'s
re-form trigger was `*CONFLICTING*|*DIRTY*` and nothing else. On this repo
nothing downstream re-verifies A+B together either: the merge provider is none
(no `.mergify.yml`, no ruleset), `bin/merge-queue.sh` lands a train PR without
reading any CI, and `branches/main/protection` has `required_status_checks:
null`. So B lands on a tip its own `verify_union` never saw.

The reviewer's probe: a verification contract that goes red only when BOTH
feature files exist. Two trains, each green alone, main RED after both land.

## What changed

**`bin/batch-resolve.sh`**

- `train_behind <file>` — rc 0 when the union branch on the remote does not
  contain the current base tip. Asked of git (`fetch` + `merge-base
  --is-ancestor`), not of GitHub: `mergeStateStatus=BEHIND` is only reported
  under strict required status checks, which is exactly what this repo does not
  have. An unreadable answer (no auth, no fetch, branch gone) is rc 1 with a log
  line — absent is never read as behind.
- The settle trigger is now `dirty` OR `behind`, and `reform_train` takes a
  third argument saying which, so every line it writes names the real trigger.
  A DIRTY train's behaviour is unchanged. The behind arm fires only when
  `gh pr view` answered `OPEN`: a train that has in fact MERGED reads as behind
  by construction (the tip contains the union, not the reverse), so an unread
  state would re-form — or close — a train that is already landed. The dirty
  arm needs no such guard, because `CONFLICTING` cannot be read out of a failed
  call.
- `abandon_train <file> <url> <log-why> <alert-why> [row-detail]` — the tail of
  the age-budget arm (close, release + exclude every member, delete the branch,
  mark the record and its `merge_trains` row abandoned, one alert), factored out
  because it has a second caller now. The TTL path reads the same as before.
- `reform_failed` splits the outcome by trigger. A DIRTY train that cannot be
  re-formed is left to its age budget, exactly as before — nobody can merge a
  union that does not merge. A BEHIND one is CLOSED: it is landable right now,
  and the queue lander reads no CI. That covers a red re-verify on the tip, a
  spent `BATCH_REFORM_MAX`, and too few surviving members. An unbuildable union
  and a refused push still just retry next pass on both triggers — they are
  "could not do the work", not a verdict.
- The `reform_ready` comment no longer claims the settle pass never pays for a
  checkout. It does now: one auth plus two fetches per tick per open non-dirty
  train, memoised per pass. A GATED pass still pays nothing, because the behind
  check sits inside the `GATED != 1 && REFORM_MAX > 0` guard.

**`bin/lib/mc/train.sh`**

- `mrt_planned_files` reads the DIFF first, then the pre-plan, then the build
  record. The plan is a prediction of the patch; the patch is what the review
  was of. A diff that is empty once the repo's declared generated files are
  subtracted is not an answer, so a regen-only PR still falls back to its plan
  and only a candidate with no readable answer anywhere is UNJUDGED.
- `MC_TRAIN_MODULE_DIRS` gains `bin/lib/`, `bin/` and `worker/jobs/src/lib/`.
  Those were in no module at all, so two PRs editing the shared libraries every
  lane sources could ride two trains at once. Order matters: the first pattern
  that matches wins, so the `*/` child pattern precedes its plain parent and
  `bin/lib/mc/` still beats both `bin/lib/` and `bin/`.

**`catalog/lanes.d/batch-resolve.json`** — the `BATCH_MODULE_DIRS` default and
its note, and `BATCH_REFORM_MAX`'s note now saying the trigger is behind or
dirty. Both are settings-row-driven knobs and neither behaviour adds one:
`BATCH_REFORM_MAX=0` is the off switch for the whole re-form, behind included.

## Tests

`tests/batch-resolve-trains.bh-1306-test.sh` — ten cases against a real bare
origin and the shipped lane, with a contract stub that is red only when every
path in `$T/red-when-all.txt` exists (probe P7 exactly): P7a (behind + red →
closed, members released and excluded, branch deleted, one alert), P7b (behind +
green → re-formed onto the tip, same PR, and the pushed union CONTAINS the sha
that landed under it), N1/N2/N3/N4 (nothing moved / gated / `BATCH_REFORM_MAX=0`
/ an unread PR state all spend nothing), B1 (budget spent → closed, not left
landable), D1 (plan and
diff disagree → the diff wins), D2 (regen-only diff → the plan still answers),
M1/M2 (the module map, and two `bin/` PRs riding one train).

Two changes to `tests/batch-resolve-trains.bh-1270-test.sh`:

- the shared-setup `bin/lanes-build.sh` failure was `echo … ; exit 0`, which
  greened 44 assertions whenever the registry could not be composed. It is a
  loud `exit 1` now, the way `tests/jobs-worker-test.sh` handles the same
  builder.
- `ticket/tk-13` now really carries `src/feature-a.ts`. T2 and T7 are about two
  candidates that claim the SAME file, and that claim was made by tk-13's
  pre-plan alone while its patch touched only `src/feature-c.ts`. With the diff
  read first, a fixture whose overlap exists only in the prediction stopped
  expressing what those cases assert. No assertion changed.

## Not done

`bin/merge-queue.sh` lands queued PRs in FIFO order, several per tick, with no
CI read, so two batch trains queued together can both land before any
batch-resolve settle tick sees the second one as behind. The fix here is on the
settle side, which is where the ticket scopes it, and the BH-945 main-red freeze
is the backstop. The queue-side follow-up — land at most one `batch/` train per
tick, or require the union to contain the tip at `mq_land` — is not built.
