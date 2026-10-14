# The main-red re-test hold ends when main runs away from the sha it is holding

Doc: main-red-freeze, main-red-tip

BH-1281 taught the streak arm of `bin/main-red-detector.sh` to HOLD rather than
raise while the same workflow is being re-tested. Two completed reds plus a
newer run of that workflow still in flight means a fix is probably on its way,
and re-raising would page a second time and give `flags/main-red-<owner>-<repo>`
a new mtime — the lower bound `mrt_main_red_fixed` reads for "has a fix merged
since the freeze went up". That was right, and it had no upper bound.

While a streak is held there is NO flag on disk. Every merge lane reads the
flag, not a verdict, so every one of them reads "not frozen" and keeps merging
— onto a main whose last COMPLETED evidence is two reds. A re-test can sit in
flight for an hour while PRs land behind it.

## What changed, in `bin/main-red-detector.sh`

**A fourth arm, after the burst back-walk.** When the streak arm has HELD a row
and main has advanced by at least `MAIN_RED_HOLD_OVERRUN` distinct shas past
that row's sha, the hold ends: the freeze goes up on the HELD sha's failure with
`reason=held-overrun`, and `HELD` is cleared so "a held streak" and "a raised
freeze" are never both true in one tick. An unreadable depth decides nothing,
the same doctrine as the unparseable `created_at` guard the arms above carry.

Depth is verdict column 12 — how many distinct main shas in the runs page are
newer than the row's sha, ranked by the newest run each sha carries. A merge to
main produces a run, so "main advanced N commits past the held sha" is
`depth >= N`, measured off the page the tick already has. No extra API call, and
a sha with no run yet is not counted, so the measure errs toward holding.

**`MAIN_RED_HOLD_OVERRUN`**, `env/global.env`, default 2. `0` disarms the arm,
which is byte-for-byte the pre-BH-1475 decision. A non-numeric or negative value
falls back to 2, not to off — a typo must not silently disarm a freeze.

2 is the default because depth 1 is exactly BH-1281's own shape: the fix merged,
its own run in flight. At 1 this arm would re-open that fight. At 2 a SECOND PR
has landed on a main whose only completed evidence is red, and freezing is the
right answer even though it costs that fix its `batch-resolve` lift — the freeze
still clears the ordinary way when the in-flight run concludes green.

**Verdict column 15**, the shas newer than a row's sha, newest first, comma
joined, capped at 10. Same ordering depth counts from, same page, no extra call.
It is what the `hold ended after N merge(s) … (<shas>)` log line names. Adding it
also required the trailing `_` on the `read` that unpacks `$WORST`: the last
variable of a `read` takes the rest of the line, so without it column 15 would
have been swallowed into `RTIP` and the burst arm's `head=` field would have
carried `<tip-sha><tab><shalist>`. That is the bug BH-1281's own comment on that
line records, arriving a second time.

**A hold that is KEPT now says how close it is.** The BH-1281 line keeps its
`in flight on <sha>` wording byte-for-byte (three cases of
`tests/main-red-detector.bh-1281-test.sh` assert it) and gains
`; N merge(s) have landed on main since, the hold ends at <N>`. A disarmed arm
advertises no bound, because there is none, and an unreadable depth — the one
input that decides nothing above — says so in words rather than printing an
empty merge count.

## What did not change

`reason=` is inert outside the flag body and the log: every merge lane reads
flag PRESENCE through `bin/lib/main-red-gate.sh` and switches on no reason
string. The hold is still computed only when NO flag is on disk, so the
still-red republish, the new-sha notice and the green clear are untouched.
`bin/main-red-pr-pair.sh` raises its suspected freeze only against
`decision=none`; an overrun now records `red/held-overrun`, so that lane stands
down there instead — one freeze flag, one writer per tick.

`--explain` reaches the same `WOULD WRITE` / `WOULD PUBLISH` / `WOULD ALERT`
branches and writes nothing, including no verdict file.

## How to drive it

```
HARNESS_TEST_SANDBOX=1 bash tests/main-red-hold-overrun.bh-1475-test.sh
```

H1 is the ticket's first test (two-red main + hold + two merges → freeze set),
H2 its second (two-red main + hold + no merges → hold kept). K1 pins that the
default leaves BH-1281's depth-1 shape holding, K2 that the knob is read and the
arm fires AT the bound, K3 that `0` disarms, K4 that garbage falls back to 2.
N1-N5 are the negatives: a skip-listed workflow is never held so can never
overrun, a flag already on disk takes the unchanged path, `--explain` writes
nothing, an in-flight run belonging to ANOTHER workflow raises as the ordinary
`reason=streak` — the arm cannot claim a hold it never had — and an unreadable
depth decides nothing and logs an honest line.
