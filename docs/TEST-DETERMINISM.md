# Test determinism, and "main is red"

Two halves of one incident.

**2026-09-15.** `worker/jobs/test/cost-anchored.test.js` asked the route for a
rolling 24-hour window while its fixtures were pinned to `2026-09-14`. It was
green when it merged and green all night. At about 14:00Z the window slid past
the fixtures, tests 17 and 19 went red **on main**, every open PR (#355-#359)
inherited that red, four *"Harness CI failure"* alerts fired at the lanes that
had opened them — and no line anywhere said *main itself is red*. Four lanes
each spent time debugging a diff that was innocent. #360 fixed the test in three
lines by pinning `?day=2026-09-14`.

The cause was a test that picks its own red day: `bin/test-determinism-lint.sh`.
The symptom was a repo-level red that only ever spoke in PR-level alerts:
`bin/main-red-detector.sh`.

---

## 1. `bin/test-determinism-lint.sh`

Scans every test file (`tests/*.sh`, `**/test/*.js`, `*.test.*`, `*-test.sh`)
for clock reads, randomness and sleep-based races — plus whatever a `scope` line
hands to ONE rule (see **Per-rule scope** below; today that is `race-sigpipe`
over `bin/**.sh`). Runs strict once a night on main, in the `lints` job of
`.github/workflows/harness-nightly.yml`: a red lint makes the night red and
files a ticket. In Harness CI its own job (**Test determinism lint**) runs it
`--warn-only` since BH-6838: a finding is a `::warning::` on the PR and never
blocks a merge.

```bash
bin/test-determinism-lint.sh                 # the whole tree (the nightly lints job)
bin/test-determinism-lint.sh tests/foo-test.sh
bin/test-determinism-lint.sh --warn-only     # report, never fail (the CI job)
bin/test-determinism-lint.sh --list          # which files would be scanned
                                             # (test files AND scoped paths)
bin/test-determinism-lint.sh --rules         # the resolved conf and rule table
```

`error` findings exit 1. `warn` findings print and do not. No rule file at all
exits **2**: a lint that scans for nothing must never report green. On exit 1
the last line names the first finding, after the fix-or-waive footer:
`test-determinism-lint: first finding: <file>:<line>: <rule>`.

### The rules

| rule | severity | what it catches |
| --- | --- | --- |
| `clock-now-js` | error | `Date.now(` in a JS test |
| `clock-new-date` | error | `new Date()` with no argument |
| `clock-rolling-window` | error | a rolling window (`?window=`, `?days=`, `?since=`) asked for by a file whose fixtures are frozen in calendar time — **the #360 shape** |
| `clock-date-cmd` | warn | shell `date` rendering a calendar field in a file that pins no anchor |
| `race-wall-bound` | warn | an elapsed wall-clock capture in a shell test (`SECONDS=0`, `X=$((SECONDS - t0))`, `EPOCHSECONDS`). A bound on it goes red under load on PRs that did not touch the code (BH-6508, stuck-work-dispatch AT-1a). Assert the order of events with a marker instead. Warn only, until the 12 suites that still carry one are fixed |
| `rand-bash` | error | `$RANDOM` |
| `rand-js` | error | `Math.random` |
| `race-sleep` | error | a foreground `sleep` of `race_sleep_min_s` (2s) or more used as synchronisation |
| `race-sigpipe` | error | a short-circuiting consumer (`grep -q`, `grep -m`, `--max-count`, `--quiet`, `--silent`, `head`) on the right of a `git` pipe — **the BH-1232 shape** |
| `race-sigpipe-echo` | error | the same short-circuiting consumers on the right of a `printf` or `echo` pipe. With a big `$X`, `printf '%s\n' "$X" \| grep -q y` reads a TRUE match as a miss under pipefail (BH-6109, PR #6108). Read from a here-string: `grep -q y <<<"$X"`, or `grep -q y < <(printf …)` when the bytes must stay exact. Test files and `bin/*.sh` since BH-6657 swept bin/ and added its `scope` line ([rule note](notes/2026-10-12-BH-6109-sigpipe-echo-rule.md), [bin/ scope note](notes/2026-10-16-BH-6657-sigpipe-echo-bin-scope.md)) |
| `branch-arm-ungated` | error | a *"this branch must not touch X"* arm: a `git diff --name-only` against main asserted on with `bad`/`eq`/`fail`, in a block that never gates on whose branch it is |
| `date-empty-stamp` | error | `date -d "$VAR"` in a `bin/**.sh` script with no `[ -n ]` test (or `[ -z ] ||` test) on `VAR` in the call line or the `date_guard_lookback` (6) lines above it. GNU `date -d ""` exits 0 and prints today's midnight, so the `\|\|` fallback never runs. Waive a checked site with `# determinism: ok date-empty-stamp <why>` |

Three things keep it honest rather than merely loud:

- **A comment is never a finding.** A commented-out route call sleeps for nobody.
- **`clock-rolling-window` fires only when the file is frozen** — it has absolute
  date literals *and* no relative-time helper. A file that builds its fixtures as
  offsets from one captured `now` (`worker/jobs/test/dora.test.js`) is the
  *correct* pattern and stays quiet.
- **That rule's pin is checked PER LINE, not per file.** The broken file already
  carried a `?day=` pin in another test; a file-level pin would have read the
  whole file as safe and missed the bug that motivated the lint.

`clock-date-cmd` is `warn` on purpose. The repo has ~60 shell call sites today
and nearly all of them derive both the expectation and the actual from the same
read. Making them red on day one would teach people to blanket-waive, which is
worse than the warning. Flip `warn` to `error` on that line in the conf once the
call sites are converted.

### Making the lint quiet, in order of preference

1. **Fix it.** Pin the call (`?day=2026-09-14`), or build the fixtures relative
   to one captured `now`. This is what #360 did.
2. **Pin the file's clock** — `FAKE_NOW=`, `NOW=`, `vi.useFakeTimers`,
   `SOURCE_DATE=` (the full list is the `pin` lines in the conf). A pin covers
   the `clock-*` rules and nothing else: it says nothing about `$RANDOM` or a
   sleep, and it never covers `clock-rolling-window`.
3. **Waive it, with a reason:**

```bash
KEY="build-$RANDOM"   # determinism: ok the id only has to be unique inside one run
sleep 3               # determinism: ok elapsed time IS the assertion here
```
```js
// determinism: ok-file clock-now-js clock-new-date  fixtures are offsets from one captured now
// determinism: ok-file  everything below is fixture data for this suite's own lint
```

For `branch-arm-ungated` the first answer is a fourth one: **gate the block, or
declare what it owns.** A code line in the same block that greps the diff for the
ticket's spec directory (`.harness/specs/BH-N/`) or carries an `own-slice: <path>`
marker says whose branch the arm is judging, and the arm then skips itself on
everybody else's. A comment saying the same thing is not a gate — comments are
never findings and never gates. An arm that asserts nothing in its block is
reading a fixture TREE, not a branch, and never fires.

`ok` waives the line, `ok-file` the whole file; either may name one or more
rules to scope itself, and `//` works like `#`. **A waiver with no reason is
itself a finding** — the point of the escape hatch is the sentence, not the
silence.

### Per-rule scope

`race-sigpipe` is not only a test-file problem: the pipeline that flakes an
assertion flakes a lane the same way, and it did — `bin/test-tamper-scan.sh`
dropped a real `TEST-CHANGE:` justification, `bin/lib/mc/rebase.sh` took THEIRS
over a branch's own work, `bin/lib/wake-class-push.sh` read a `prompts/` push as
not one. So the conf has a fourth path directive:

```
scope <rule-name> <ERE>
```

A file matched **only** by `scope` lines runs only the rules that name it. A
test file still runs every rule (if both selectors match a path, it is read as a
test file). `--list` prints scoped paths too, and `--rules` prints the `scope`
lines. The shipped line is `scope race-sigpipe (^|/)bin/.*\.sh$`.
`date-empty-stamp` has its own `scope` line for the same `bin/**.sh` paths, but
unlike `race-sigpipe` it also skips test files: the script checks the scope
before judging any file, because suites plant stamps on purpose.

It is per rule and not a wider `file` line on purpose: widening the file
selector to `bin/` fires 24 `race-sleep`, 3 `rand-bash` and 5
`clock-rolling-window` errors plus 441 warnings that nothing asks anyone to fix,
and turns `race-sleep` red on every cron lane's bounded poll.

### A pipeline split over two lines is still one pipeline

The rules judge one line at a time, so `git log … |` with `grep -q …` on the
next line used to pass. Each line is now joined forward across a **pipe
boundary** — `|` at end of line, `| \`, or `\` with the next line starting `|` —
up to four continuation lines, and the finding is reported once, at the line the
pipeline starts on. `||` is not a pipe boundary. Put the waiver on any line of
the span; the consumer line is the readable place for it.

### The config

Every pattern, severity and threshold lives in
[`catalog/determinism-lint.conf`](../catalog/determinism-lint.conf), never in
the script. Resolution, first hit wins:

1. `$DETERMINISM_LINT_CONF` — the fixtures and one-off runs
2. `flags/determinism-lint.conf` — the box-local override (gitignored; the lever
   that needs no deploy)
3. `catalog/determinism-lint.conf` — the reviewed commit that reaches CI and
   every box on `harness-sync`
4. `/root/harness/catalog/determinism-lint.conf`

The shipped default lives under `catalog/` rather than `flags/` because `flags/`
is machine-local and gitignored — it could never reach CI, which is where this
lint actually runs. `catalog/size-thresholds.conf` is the same arrangement.

### What it does not catch

A call that takes its rolling window from the route's own default
(`call('/api/metrics/cost-anchored', …)` with no query at all — test 19 of the
original incident) looks like any other route call. Only the explicit window
(test 17) is detectable without knowing the route's defaults. Pin the day on
*both* when you touch a file like this.

---

## 1b. bin/test-date-bomb-lint.sh

**#3414.** `tests/triage-state-client-test.sh` carried
`next_recheck_at:"2026-09-29T10:00:00Z"`. At 10:00Z that day the real clock
passed it, the case went red on main, and `35657019b` moved it to 2099. The
determinism lint could not see it: the file read no clock itself, the code
under test did. This lint looks for the shape instead: a hard-coded ISO date on
a deadline-shaped key (`next_*`, `*_until`, `*expir*`, `deadline`, `*due*`,
`not_after`, `valid_to`, `retry_after`, `*_by`) in a test file.

```
bin/test-date-bomb-lint.sh [--base <ref>] [--all] [root]
```

By default it judges only lines added since the merge-base of `--base`
(default `origin/main`) and HEAD, working-tree edits included. `--all` judges
every line of every test file, as an inventory of what is already there. rc 0
clean, rc 1 findings (`<path>:<line>: fixture-timebomb: ...` on stdout, the
count on stderr), rc 2 bad args, no conf, not a git work tree, or an
unresolvable base.

A finding's year is in `[floor_year, max_safe_year)`, 2025 to 2098 today. To
quiet one:

- use a year of 2099 or later for "not due yet", or one before 2025 for
  "already due";
- pass the date to the code as its clock (`--now`, `--at`, `now=`, `NOW=`,
  `as_of`: the conf's `input_re`);
- pin the clock in the file (any `pin` line of `catalog/determinism-lint.conf`,
  judged against the file at HEAD);
- or waive the line with `# determinism: ok <reason>` (or `//`). A waiver
  with a reason under 3 characters is ignored and the line is still reported.

Patterns and thresholds are in `catalog/date-bomb-lint.conf`
(`$DATE_BOMB_LINT_CONF` > `flags/date-bomb-lint.conf` > the checkout's
`catalog/` > `$HARNESS/catalog/`). Which files are test files and what pins the
clock come from `catalog/determinism-lint.conf` (`file`, `skip`, `pin`), so
the two lints never disagree about either.

### What it does not catch

A date reaching the clock through a variable (`D=2026-...; ... "$D"`),
`new Date('...')` or any date with no deadline key right before it, key and
date on different lines, camelCase keys (`nextRecheckAt`), non-ISO dates
(epoch seconds, `09/29/2026`), and in diff mode a bomb that was already there
before the fork. Run `--all` for the last one.

---

## 2. `bin/main-red-detector.sh`

Hub cron (`*/10`). For each harness repo — `fleet.conf`'s rows plus
`$HARNESS_REPO` itself — it reads the latest runs on `main`
(`gh api repos/O/R/actions/runs?branch=main`), groups them by workflow, and
keeps the **required** ones (`e2e` / `nightly` / `smoke` / `publish` / `deploy`
names are skipped: a nightly suite red on main is `bin/pipeline-health.sh`'s
perma-red check, not a merge freeze).

A workflow whose newest `MAIN_RED_STREAK` (2) concluded runs are **both red**
makes the repo red. `cancelled` / `skipped` / `neutral` / in-progress runs are
not evidence: they neither break a streak nor make one.

**The tip arm (BH-629.4).** That streak is applied to a stream whose only
producer is a push to main, and in this harness a push to main is a merge — so
the second red run it waits for can only arrive from the very merge the red is
meant to prevent. On 2026-09-17 that read as "main green" for 7.5 hours while
every open PR inherited the red. So when the streak arm finds nothing, **one**
red completed run of a required workflow makes the repo red if it sits on main's
**tip** (its sha is the newest sha in the fetched page, across every workflow and
every status) and has stood there at least `MAIN_RED_TIP_MIN_AGE_MIN` minutes
with no newer run of its own workflow — a newer in-progress or cancelled run
means a re-run is in flight, and the wait is what stops a flake freezing the
fleet. It is an additional arm, never a lower threshold: the streak's flake
tolerance is untouched, and the flag's `reason=` line says which arm fired
(`tip` or `streak`). Both fields it needs come out of the runs page already
read, so the arm costs zero extra API calls. `tests/main-red-tip-red-test.sh`
drives it, negatives included.

| state | what happens |
| --- | --- |
| red, no flag yet | write `flags/main-red-<owner>-<repo>` (`sha`, `workflow`, `job`, `since`, `run`, `reason`) and fire **one** `--critical` alert naming the failing **job**, not just the workflow |
| red, flag already there | one log line. No second alert. |
| green again | remove the flag, fire **one** resolve alert |
| no evidence (API error, invisible repo, no completed runs) | **change nothing.** An existing flag is never cleared because a read failed — "we could not look" is not "it is fixed". |

Knobs (`env/global.env`, documented fallbacks): `MAIN_RED_DETECT=0` or
`flags/main-red-detector-off` (kill switch), `MAIN_RED_STREAK` [2],
`MAIN_RED_PER_PAGE` [20], `MAIN_RED_SKIP_RE`, `MAIN_RED_REPOS`, `HARNESS_REPO`,
`MAIN_RED_TIP_RED` [1] (`0` = the streak-only decision, byte for byte) and
`MAIN_RED_TIP_MIN_AGE_MIN` [15].
`MAIN_RED_PER_PAGE` is 20 rather than 5 because a repo with four workflows shows
barely one run each in five, and a streak you cannot see reads as green.

Log: `logs/main-red.log`. Alerts go through `bin/lane-alert.sh` (lane
`main-red`), so they reach the 10-minute medic like every other lane alert.

### The flag's contract (for every merge lane)

`flags/main-red-<owner>-<repo>` means **main is broken for everyone on that
repo**, so merging into it buys nothing: a green PR check on that base is either
stale or about to be red, and each merge adds a diff to the list of suspects.
While the flag exists **every automatic merge lane freezes merges for that
repo** — the merge conductor, the hub merge sweep, the box merge queue (all
three of its landing paths), the reviewer's APPROVE merge, the tier-2 sweep's
enqueue, the tier-1 merge inside a build, and the union merge train, which
builds no new train at all. One implementation, `bin/lib/main-red-gate.sh`,
sourced by `bin/lib/merge-conductor-lib.sh`. Exactly two exceptions:

- a PR labelled **`fix-main-red`** (`MC_MAIN_RED_LABEL`) — the fix itself must
  be able to land. Matched by exact name, so `fix-main-red-later` is not it;
- a PR whose diff is **only** test files, by the `MC_MAIN_RED_TEST_PATHS` globs
  (`tests/* worker/*/test/*`) — not by the flag's `path=`/`job=` evidence. A
  diff nobody can read is **not** exempt.

Everything else is deferred with a reason naming the flag, and picked up on the
tick after the resolve alert clears it. Nothing is parked, recorded or paged for
a held PR: it is waiting for main, not for a human.

**The flag is published, not just written.** Only the hub runs the detector, so
every raise and clear also goes through `flag_set` (`bin/jobs-client.sh`), which
writes the `pause_flags` row a box materialises into its own `flags/` directory
on the first `flag_active` read. Without that row a box could not see the freeze
even if it asked — which is how #931 and #942 merged into a red main on
2026-09-18 while the conductor logged the freeze every five minutes. The
detector republishes on every red tick, so a PUT that died self-heals, and a
green tick keeps publishing `active:0` until it lands (the hub keeps
`state/main-red/<name>.published` while the row is ON). A worker outage with no
local file is read as "no flag": an unreachable worker must not be able to
stall every merge in the fleet. The freeze is a repo fact, not a knob: a hand
`flag_set main-red-<slug> off` is re-raised within a tick while main is red;
stop detection first (`MAIN_RED_DETECT=0` / `flags/main-red-detector-off`),
then clear.

---

## 2b. `bin/main-red-pr-pair.sh`

Hub cron (`*/10`), and a separate script from the detector on purpose: own lock
(`locks/main-red-pr-pair.lock`), own log (`logs/main-red-pr-pair.log`), own
alert ids (`main-red-prs:<owner>-<repo>:<hash>`).

The streak above needs two consecutive red runs on `main` itself, which it only
gets once somebody merges into a red main. **The open PRs know first.** For each
repo in `MAIN_RED_PAIR_REPOS` it reads the open harness PRs
(`bin/lib/gh-pr-list.sh`), works out what each head sha's newest failing
**required** run failed on — job name plus the first error-shaped line of that
job's log — and groups them. For the **Test determinism lint** job that first
error is the lint's `first finding:` line, never its fixed footer, so two PRs
that fail the lint on different files do not pair (BH-6880).

| state | what happens |
| --- | --- |
| a (job, first error) shared by **2 or more** open PRs whose runs are within `MAIN_RED_PAIR_WINDOW_S` | **one** `--severity critical` alert naming the job **and** the first error, held open by `state/main-red/pairs/<owner>-<repo>/<hash>` |
| the same pair on the next tick | one log line. No second send. |
| the pair is gone, on a tick that read **every** open PR's head | **one** `--resolve` on the same id, marker removed |
| no evidence (no token, PR list unreadable or not JSON) | **change nothing.** One log line; open markers are left alone — "we could not look" is not "it is fixed". |
| partial evidence (the list loaded, but some head's runs/jobs/log would not read, or its runs are still in flight, or the grouping step failed) | alerts still fire on what *was* seen, but **no resolve is swept.** A rebased PR whose new head is unreadable would otherwise take its own open pair down with it, then page a second time when the read recovers. |

**It never writes `flags/main-red-*`.** The merge freeze stays bound to the
streak evidence above, because two PRs failing alike can also be one shared
flake, and a freeze is expensive to be wrong about.

Cost is bounded by a ledger: `state/main-red/pr-errors/<owner>-<repo>/<head>.tsv`
holds `job \t first_error \t run_created_at` for one head sha, written **only**
from a complete answer — every required run on that head has finished *and* the
reads describing the failure succeeded (`-` in every column = it finished and
nothing failed). A head sha is immutable, so a row that exists is terminal and is
never asked about again, which is exactly why it may not be written from a
half-answer. These get **no row**, and the next tick asks again:

- a required run still queued or in progress, even if a *different* required run
  on the same head already finished green — the one still running is the one that
  can go red, and the row would never be revisited;
- the runs list, the jobs list or the job log unreadable. A 5xx or a secondary
  rate limit is a transient fact about GitHub, never a verdict about the head;
  recording one would blind that head for `MAIN_RED_PAIR_LEDGER_DAYS`.

A job log that *reads fine* and holds no error-shaped line is the opposite case:
an immutable log will not grow one later, so that is a real answer, recorded as
`(unavailable)` (which groups with nothing) and never paid for twice. Rows are
pruned by age only (`MAIN_RED_PAIR_LEDGER_DAYS` [14]).

Three edges of that ledger, decided on purpose:

- **a head with no required run at all** (an empty runs list, or only
  `MAIN_RED_SKIP_RE` workflows — a PR based outside `main`/`ticket/**` gets no
  Harness CI run) is a terminal `-` once its PR has been quiet for
  `MAIN_RED_PAIR_WINDOW_S`. It can be part of no pair, and left as "no verdict"
  it would keep `unknown > 0` on every tick, which blocks every resolve in the
  repo for as long as it stays open. Younger than a window it is asked again.
- **the cap is a partial look too.** Heads past `MAIN_RED_PAIR_MAX_PRS` are not
  read, so while the cap bites an open marker resolves only once every PR it
  names has left the open list; a pair that merely fell out of the newest-N
  window is left standing and logged, not called fixed.
- **a re-run to green is not seen.** Re-running the same run id flips its
  conclusion on the same head sha, and the ledger never re-reads a head with a
  row. The failure row stands for `MAIN_RED_PAIR_LEDGER_DAYS`, and a pair it
  holds open resolves when its PRs merge or rebase to a new head, not when
  somebody re-runs a flake. Bounded cost was chosen over that edge.

The window is compared in **UTC**: GitHub's `created_at` carries a `Z` and the
grouping parses it as such. A naive parse would be read as hub-local time, and on
a DST-observing box two runs straddling the transition come out an hour apart.

Knobs (`env/global.env`, documented fallbacks): `MAIN_RED_PAIR=0` or
`flags/main-red-pr-pair-off` (kill switch), `MAIN_RED_PAIR_REPOS`
[`$HARNESS_REPO`], `MAIN_RED_PAIR_MAX_PRS` [15] (a cap that bites is logged,
never silent), `MAIN_RED_PAIR_WINDOW_S` [3600], `MAIN_RED_PAIR_LEDGER_DAYS`
[14], `MAIN_RED_ERR_RE`, `MAIN_RED_SKIP_RE`. `--explain` prints the groups it
would alert on and the ledger rows it would record, and is READ-ONLY (BH-997):
no lock, no ledger write, no prune, no marker, no send — so an `MAIN_RED_ERR_RE`
exported to test a matcher cannot land a terminal 14-day verdict the cron lane
then trusts. `bin/main-red-detector.sh --explain` follows the same rule: no
lock, no freeze flag written or cleared, no `pause_flags` row, no page.

---

## Both halves, tested

`tests/test-determinism-lint-test.sh` drives the lint over fixture trees
(leaks, pins, waivers, thresholds, the #360 shape before and after its fix) and
asserts the repo's own tree passes. `tests/main-red-detector-test.sh` drives the
detector against a fake `gh`: flag written once, cleared once, alert counts,
and the read-failure case that must change nothing.
`tests/main-red-box-freeze.bh-945-test.sh` drives the other half — the detector's
publish through a recording `curl`, and all seven merge lanes against a raised
flag, including the two exemptions and the adversarial near-misses.
`tests/main-red-pr-pair-test.sh` drives the PR-pair canary the same way — ten
negatives (different jobs, different errors, outside the window, a green head, a
head still running, an unreadable job log, an unreadable PR list with a marker
open, a nightly-only red, the kill switch) before the alert, the repeat tick and
the resolve.
