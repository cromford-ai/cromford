# Corrections to the BH-1036 record: 120 assertions, six kinds, and what section H actually does

Doc: DB-COORDINATION-SPEC

BH-1036 (the row twin of the file-only idempotency markers) merged as PR #1118
on 2026-09-22T06:19Z, head `39dfd330`, merge commit `01e21f99`. Three numbers in
the record it left behind are wrong, and one line in the verification map points
at a script that never sourced the library. This note is the correction. Per
D37 the merged note `docs/notes/2026-09-19-BH-1036-no-twin-ledgers.md` is not
edited; it stays as the record of what we believed on 2026-09-19, and this is
the later note.

Everything below was re-measured on 2026-09-22 against main at `42c0c7c`, with
the command that measured it.

## "Eight sections, 96 assertions" is 120, and section H drives nothing

The 2026-09-19 note says, under "How it is proven": "Eight sections, 96
assertions" and "Sections B–H each drive the REAL shipped lane".

Eight sections is right. The count and the range are not:

```bash
HARNESS_TEST_SANDBOX=1 bash tests/no-twin-ledgers.bh-1036-test.sh
# PASS=120 FAIL=0   (rc 0, 2026-09-22, main 42c0c7c)
```

The suite is **120 assertions**, not 96. Round 2 added the fixture self-checks
(A0), the two root-rewrite assertions in section C and the section H block.

Section A drives the library against the real `bin/jobs-client.sh` with a curl
shim. Sections **B through G** drive the real shipped lane: `review-autopilot.sh`,
`lander.sh`, `batch-resolve.sh`, `postmerge-qa.sh`, and for `run-build.sh` the
shipped regions read through `tests/lib/rb-all.sh` (the BH-568 seam rule).

**Section H drives nothing, and it is not a lane test.** It lifts the
`# >>> overlap not-before` region and the `PM_HOLD_STATUS()` body out of the
flattened pipeline text (`$RB_ALL`) and out of `bin/lib/rb/gates.sh` and
`bin/lib/rb/plan.sh`, and compares them **byte for byte with `cmp -s`**, plus a
`bash -n` on each module. That is deliberate: the `rb/*` slices are BH-478's
copies of the driver and they are dark, so there is no behaviour to exercise.
What they promise is textual, and a byte comparison is the only honest way to
hold them to it until BH-478 flips those stages to module calls.
`docs/verification-map/no-twin-ledgers.md` already described H this way; the
dated note was the one place that read it as a drive.

## "Seven markers" is six ledger kinds

PR #1118's body and the PR_CREATED comment on issue #1036 (2026-09-20T02:14Z)
both say the library "gives the seven file-only idempotency markers a row twin".
The head that merged twins **six ledger kinds**. Counted off every `lt_put` and
`job_ledger_put` call site in `bin/` on `42c0c7c`:

| kind | lane that writes it |
|---|---|
| `review_autopilot` | `bin/review-autopilot.sh` (hourly at :17, `cron/lanes/490-review-autopilot.cron`) |
| `review_autopilot_cap` | `bin/review-autopilot.sh`, the per-project daily cap |
| `lander` | `bin/lander.sh`, one attempt per PR head |
| `batch_member` | `bin/batch-resolve.sh`, train membership |
| `postmerge_qa` | `bin/postmerge-qa.sh` (`cron/lanes/600-postmerge-qa.cron`) |
| `plan_malformed` | `bin/run-build.sh`'s plan-malformed hold region, mirrored dark in `bin/lib/rb/plan.sh` |

Two things sit outside that table and are why the count read as seven:

- The `# >>> overlap not-before` region in `bin/run-build.sh` (dark copy in
  `bin/lib/rb/gates.sh`) is a seventh READ site, but it reads back an
  `overlap_defer` **artifact**, not a ledger row, and it writes nothing. Its own
  comment says so: "Read only: nothing below writes an artifact".
- The seventh file store the BH-1036 ticket named,
  `state/migration-prs-alerted.txt` behind `bin/check-migration-prs.sh`, was
  deliberately left alone. BH-1040 already moved that lane onto
  `ledgers(kind=migration)` with its own three-way read and a write-after-send,
  and a second kind over the same fact would be two dedups with two write
  orders. `bin/lib/ledger-twin.sh`'s header says this too.

Read as stores rather than kinds the number is the same six: six file stores got
a row twin, one artifact read-back got no row, one store stayed with BH-1040.

## The map entry named a script that never sourced the library

`docs/verification-map/entries/BH-1036.md` listed `bin/check-migration-prs.sh`
in the "sourced by" cell of its row. It never sourced it:

```bash
grep -n 'ledger-twin' bin/check-migration-prs.sh   # no output
grep -rln 'ledger-twin.sh' bin/                    # the library itself, plus batch-resolve.sh,
                                                   # lander.sh, postmerge-qa.sh, review-autopilot.sh,
                                                   # run-build.sh and lib/rb/gates.sh
```

That sourcer was dropped in round 1 and the row was not updated. This PR removes
it from the row.

## Lander fixtures copy `bin/lib/jobs/*.sh`, and now something goes red if they stop

Since #1118 `bin/lander.sh` sources `bin/jobs-client.sh` for the `lander` twin.
The client is a shim over `bin/lib/jobs/*.sh` (BH-1194) and it refuses to
half-load: a copy with no modules beside it writes one ALERTS line and exits 1.
A source runs in the same shell, so that exit is the lane's exit. The lane dies
at its source line, before the flags, before `gh pr view`, before any marker.

So the refusal now reaches one more lane, and any fixture that copies the real
`bin/lander.sh` into a scratch harness has to copy the modules beside the client
or it drives nothing.

The audit on `42c0c7c`: fourteen suites name `bin/lander.sh`
(`grep -ln 'lander\.sh' tests/*.sh tests/mc/*.sh`). Exactly one drives the real
script, section C of `tests/no-twin-ledgers.bh-1036-test.sh`, and it already
copies the modules through its `copy_jobs_client` helper. The other thirteen
stub the lane with `printf '#!/bin/bash\nexit 0\n'`, extract a marker block, or
read the file as text. There was no missing copy to add.

`tests/lander-fixture-modules.bh-1330-test.sh` is what keeps that true. It
drives the real `bin/lander.sh` three ways and asserts on artifacts, not source
text: client without modules (dies on the source line, one ALERTS line, never
reaches `gh pr view`, writes no attempt marker), client with modules (gets past
the source and calls `gh pr view`), and no client at all (the `[ -r … ] &&`
guard, today's fail-open path, unchanged).

## Rollout: the first real twin row. A HAND STEP, not done by this PR

The library ships dark. Nothing writes a row until the `no-twin-ledgers` flag is
up, and flipping it is a fleet-wide production change through the coordination
DB, so a build box does not do it. For whoever runs the first cycle, on the hub:

```bash
bin/jobs-client.sh flag-set no-twin-ledgers on "BH-1036 cycle 1"
# wait for the next review-autopilot tick: hourly at :17, cron/lanes/490-review-autopilot.cron
bin/jobs-client.sh ledger-list review_autopilot 5
```

Paste one real row (kind, key, status) into the #1036 thread before widening.

Two things to know before the flip:

- **The flag has no per-project scope.** `flag_set` writes `flags/no-twin-ledgers`
  on the calling box and then the DB row, and `flag_active` reconciles every
  other box from that row. So "try it on one project" is really "one lane tick
  after the flip", fleet-wide. The first lane to run after a flip on the hub is
  `bin/review-autopilot.sh`.
- **The write order under the flag is file first, then row**, and the read order
  is file first, row only when the file has nothing. The file stays the
  write-through cache for one cycle, per the epic. A ledger outage therefore
  costs nothing, and a row is never read as "already done" when the read itself
  failed.
