# A build of cromford runs the suites its diff can reach before it pushes

Doc: test-impact, RUN-BUILD-GRAPH

## What changed

**`bin/test-impact.sh select`** takes three flags, all select-only:
`--why` prints `<suite>\t<kind>\t<path>` rows (self, reads, named, source,
closure, always, full), `--changed <file>` takes the changed paths as a list
instead of a range, and `--map-only` answers the map's own picks even when CI
would run the corpus (the reason line still names what CI will do). Plain
`select` output is unchanged, so CI's `--only-file` reads what it always read.

The selection gained one kind of row: **named**. A suite that names a function
defined in a changed script, at the head or at the base, is selected. The base
half is what catches a caller-count pin after a rename or a delete. Only names
with an underscore and at least six characters count. Over the last 30 merged
PRs this added 0 to 34 suites to a selection (median 0).

**`bin/test-impact-gate.sh`** (new) is the builder's gate. It runs
`select --map-only --why` from the merge-base and ranks each suite by its
strongest reason (self > reads > always > named > source > closure). It runs
that list one suite at a time until it reaches the cap
(`TEST_IMPACT_GATE_CAP`, default 80) or the time budget
(`TEST_IMPACT_GATE_BUDGET_S`, default 900 s; no suite is started after it).
Both are settings rows on the `fly-pool` lane, resolved by `lane_knob`. It
names everything past either bound as left to CI. `--table <file>` writes the
PR body's gate table from the run. Runner: `isolated` when it is root beside a
live harness (HEAD snapshotted into a scratch tree, run as `nobody` via
setpriv, the switch probed with the exact flags before any suite runs),
`local` elsewhere, `remote` (bin/remote-gate.sh) by name, `plan` to list
without running.

**`HARNESS_SUITE_RUN`** in `bin/run-build.sh` (and its copy in
`bin/lib/rb/gates.sh`) calls the gate for a checkout that has
`bin/test-impact-gate.sh` and no package.json. Before this, a pool build of
cromford recorded `HARNESS_EXIT: no-test-script` and pushed having run no
suite. A gate whose runner cannot start (rc 125), or that the stage's
`timeout 1500` kills (124, with the completed suites listed), is recorded as
`HARNESS_EXIT: could-not-run`. `LIVE_SUITE` and the three review prompts
treat that as not green and not a red suite.

**`prompts/build-discipline.md` D38** tells a builder in a repo with a
test-impact selector to gate on it, not on a hand-picked list, and to read the
left-to-CI list, because the gate is bounded.

## Why

BH-1524 read four extra review rounds (#1478, #1481, #1496, and the gh-rest-lib
ceiling raise) as the selector missing pinned-contract suites. The replay says
otherwise. On main's map, and on the map each PR's own tree built, every one of
those diffs selected the suite that went red. The suites went red in CI, which
is CI doing its job. The miss was the builder: the Mac gate table was
hand-picked, and the pool ran nothing at all.
