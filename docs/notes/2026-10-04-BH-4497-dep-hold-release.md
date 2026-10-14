# BH-4497: a dependency-held READY PR says when it is released, and its STUCK page reads the gate live

Doc: MERGE-CONDUCTOR

## What changed

- `pdg_hold` in `bin/lib/pr-dep-gate.sh` takes an opt-in `PDG_SAY_PASS=1`. With it, a
  pass also prints the reason its log line carries, without the `<slug>#<n> dep gate: `
  prefix and the ` — pass` suffix (`dependency landed, closed unmerged #31`,
  `no declared dependency in the PR body; issue #20, lower Order siblings #19 not
  waiting`), or `dep gate OFF` for the kill switch. Without it, a pass prints nothing,
  as before. Only the conductor sets it. `bin/merge-sweep.sh`, the run-build tier-1
  gate and `bin/merge-queue.sh` are unchanged.
- The READY arm of `bin/merge-conductor.sh` (`# >>> dep gate`):
  - every held tick rewrites the `dep-hold` ready-why note
    (`state/merge-conductor/ready-why/<id>`), not only the tick the hold comment posts;
  - the first passing tick on a head this gate held logs ONE line,
    `<key> READY and RELEASED by the PR-dependency gate on <head8>: read this tick — <reason>; it goes on to the merge checks this tick`,
    deduped on the attempts-ledger key `depwaitrelease <key> <head>`. It does not say
    "enqueued": a ticket hold, merges-off or the budget can still stop the row, and each
    of those logs its own line.
- `mc_stuck_waiting_on` in `bin/lib/mc/classify.sh`: for a READY row whose note is
  `dep-hold` on this head (or whose last logged reason is the gate's HELD line), the
  STUCK page calls the new `mc_dep_live`, which runs the gate again and says
  `the PR-dependency gate, read this tick: still open — …`, `released — …` or
  `could not read the dependency (held, fail closed)`. Every other READY reason reads
  as before.

## Why

On 2026-10-04 #4415 was held READY at 21:33Z behind `Order 6 behind #4075 (PR #4242
QUEUED)`. #4242 merged at 21:38 and #4075 closed. At 21:57 the STUCK page still said
`#4242 QUEUED`. It read the `dep-hold` note `mc_hold_comment` writes once, after its
comment posts, and nothing logged the release.

## How to check it on the hub

`grep 'RELEASED by the PR-dependency gate' logs/merge-conductor.log` shows one line per
(PR, head) on the first tick after a dependency closes. A STUCK READY line for a
dependency-held row contains `read this tick`.

Suite: `tests/mc/dep-hold-release.bh-4497-test.sh`.
