# The main-red freeze (a red main stops every merge lane)

> **The merge-queue arm (2026-09-24).** Since each tree is tested only in the
> Mergify batch draft, a push to main carries no test corpus. The detector's
> fifth arm reads the batches instead: for repos in `MAIN_RED_QUEUE_REPOS`,
> `MAIN_RED_QUEUE_STREAK` (3) red batches that share no PR number, with no green
> batch since, freeze merges with `reason=queue`. See
> [ci-cost-lanes.md](ci-cost-lanes.md); `tests/main-red-queue-arm-test.sh` pins it.

**What it is:** one shared gate, `bin/lib/main-red-gate.sh`, that answers "is
this repo's main red, and may this PR merge anyway" immediately before a merge.
`bin/main-red-detector.sh` on the hub raises `flags/main-red-<owner>-<repo>`
when a required workflow is red on main, and PUBLISHES it as a `pause_flags`
row so every box materialises the same flag (BH-945). Since BH-1451 there is a
SECOND writer of the same flag: `bin/main-red-pr-pair.sh` raises it
(`reason=pr-pair-suspected`, `owner=main-red-pr-pair`) when two open PRs fail
alike AND the detector's own `state/main-red/<owner>-<repo>.verdict` says
`decision=none` — the merge-burst case where main's history cannot answer yet.
That lane clears only what it raised; see
[main-red-pr-pair.md](main-red-pr-pair.md). Nothing downstream changes: the
flag's NAME, its publish and every lane's read are identical whoever raised it.
While the flag is up no
automatic lane merges into that repo, with exactly two ways through: a PR
labelled `fix-main-red` (`MC_MAIN_RED_LABEL`, matched by exact name; one knob
since BH-1770, resolved by `bin/lib/main-red-label.sh` for the builds' priority
rank too, with `MAIN_RED_LABEL` a deprecated alias), or a PR
whose whole diff is test files (`MC_MAIN_RED_TEST_PATHS`). A diff nobody can
read is NOT exempt. The test-path match is a `case` glob against the pattern
list with pathname expansion OFF, so it answers the same from any cwd (BH-987 —
before that fix a cwd containing `tests/` expanded the patterns to its own
files and a NEW test file was never exempt).

| lane | where the gate is called | what it does on a hold |
|---|---|---|
| merge conductor | `bin/merge-conductor.sh` project tick + `READY` arm | row stays `READY`, one dedupe line, no budget spent |
| tier-2 merge sweep (hub) | `bin/merge-sweep.sh` (`# >>> main-red gate`) | logs, `continue` — NOT claimed, NOT `sweep_record`ed |
| box merge queue | `bin/merge-queue.sh` `mr_queue_hold` (`# >>> main-red gate`), all three landing paths | logs, entry stays queued, never `.blocked`, no `MQROW`, no beat |
| union merge train | `bin/batch-resolve.sh`, next to `flags/batch-resolve-off` | no NEW train is built; a train already pushed is still settled |
| tier-1 gate in a build | `bin/run-build.sh` (`# >>> tier-1 merge gate`) | `CONDUCTOR_OWNS_MERGES=1`, stands down to `PR_CREATED` |
| reviewer | `bin/review-prs.sh` `hold_main_red` | APPROVE posted, merge withheld, `MERGED=no`, no box-queue entry |

The console `merge_pr` command (`bin/poll-commands.sh`) is deliberately NOT
gated: it is a human at Mission Control giving an explicit order.
`bin/review-autopilot.sh` never merges, so it has nothing to gate.

**How an operator reaches it:** there is no UI. The detector is
`cron/hub.cron` (it also runs from the conductor tick, `MC_MAIN_RED_DETECT`);
the lanes are `bin/merge-conductor.sh` every 5 minutes and `bin/merge-sweep.sh`
every 10 on the hub, plus the per-box crons for `bin/merge-queue.sh`,
`bin/review-prs.sh`.
`docs/TEST-DETERMINISM.md` § "The flag's contract" is the contract, and
`docs/notes/2026-09-19-BH-945-main-red-every-lane.md` says what BH-945 changed.

**How to drive it:**

| what | how |
|---|---|
| the detector's publish (`PUT /api/flags`) on raise, new sha, still-red and green, plus the read-failure case that publishes nothing, plus a dead OFF PUT republished by the next green tick | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-box-freeze.bh-945-test.sh` § D, § D5 |
| the box merge queue run WHOLE against a raised flag — plain PR held, `fix-main-red` and test-only PRs landed, entry not `.blocked`, nobody paged | same suite § Q |
| the BOX case: no local flag file, an active `pause_flags` row → held, and the file materialised | same suite § Q2 |
| fail-open: 404 + no file, worker down + no file, and a stale file cleared by a newer `active:0` row | same suite § Q3 |
| the merge train's member and landing loops | same suite § Q4 |
| the tier-2 sweep, the reviewer (merge step and the approved-head retry, which spends no budget on the freeze), the hub sweep (both flag spellings), the tier-1 gate, the union train | same suite § T, § R, § R2, § S, § S2, § G, § B |
| the exemption negatives (`fix-main-red-later`, a mixed diff, an unreadable diff, a flag for another repo) | same suite § N |
| the test-only exemption from a cwd that CONTAINS test files (it was cwd-dependent before BH-987), and the tier-1 gate driven from that cwd | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-gate.bh-987-test.sh` § E, § E3, § N |
| a freeze raised (or cleared) BETWEEN batch assembly and the train landing pass, and the one-read-per-pass budget the memo keeps | same suite § L, § S |
| the conductor's own freeze, unchanged | `HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-test.sh` |
| the detector's flag/alert behaviour, unchanged | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-detector-test.sh`, `… tests/main-red-detector.bh-636-test.sh`, `… tests/main-red-tip-red-test.sh` |
| the burst back-walk: main's tip still in flight, the red two commits behind it, and every negative that must NOT freeze | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-burst-backwalk.bh-1451-test.sh` |
| the re-test hold's upper bound: two merges past the held sha freeze on the held failure, one merge (BH-1281's own shape) still holds, `MAIN_RED_HOLD_OVERRUN=0` never ends a hold | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-hold-overrun.bh-1475-test.sh` |
| a stale GitHub runs page (lower `total_count`, older runs) between two fresh ones raises nothing and clears nothing; a first red call is re-read and raised only when the re-read agrees; a real red confirmed on the re-read still freezes; `MAIN_RED_STALE_GUARD=0` is the old detector | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-stale-page.bh-1927-test.sh` |
| the second writer — a pair-raised freeze, the verdict file it hangs off, the clear, and the handover when the detector confirms it | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-pair-suspected.bh-1451-test.sh` |
| what this tick WOULD do, changing nothing — no lock, no flag written or cleared, no row, no page | `HARNESS=<tree> bin/main-red-detector.sh --explain` |
| that `--explain` really is read-only (lock, flag bytes, `pause_flags` row, alerts) | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-detector.bh-997-test.sh` |

**Files on a live box:**

- `flags/main-red-<owner>-<repo>` — presence is the freeze. On the HUB it also
  carries the body; on a box it is an empty file materialised from the row, and
  box lanes read presence only. A detector-raised body is `sha=`, `workflow=`,
  `path=`, `job=`, `since=`, `streak=`, `run=`, `detected=`, `reason=`, plus
  `head=` and `depth=` on `reason=burst` and `reason=held-overrun` — the two
  arms that judge a sha the head has already moved past (the sha it judged is
  `sha=`, the head it is behind is `head=`, and `depth=` is how far). A pr-pair-raised body is
  `reason=pr-pair-suspected` first, then `owner=main-red-pr-pair`, `job=`,
  `first_error=`, `prs=`, `since=`, `detected=` — and NO `sha=`, because that
  lane judged no run on main. The detector reads that absence: a flag with no
  `sha=` means its own red is a FIRST red call, so it pages `--critical` and
  rewrites the body with its own `sha=` rather than sending the non-critical
  "still red on a new sha" (BH-1451).
- `state/main-red/<owner>-<repo>.verdict` (hub only) — the detector's decision
  on its last tick, rewritten whole every time: `decision=red|green|held|none`,
  `reason=`, `sha=`, `at=`. A last-write cell, not a watermark; nothing dedupes
  on it. Its only reader is `bin/main-red-pr-pair.sh`, and an ABSENT file reads
  as "do not act", so a hub running an older detector cannot freeze a repo.
  `held` is a LOOK, not a non-decision: the streak arm is waiting on a re-test
  (BH-1281), so the pair lane stands down there as it does on red and green —
  freezing during a re-test is how the flag comes back with a fresh mtime and
  the merged fix falls outside the window `bin/batch-resolve.sh` lifts on.
- `state/main-red/main-red-<owner>-<repo>.published` (hub only) — present
  while the row is known to be ON; a green tick with no flag file but this
  marker republishes `active:0` until the PUT lands.
- `logs/main-red.log` — the detector's own line per repo per tick, plus
  `… could not be published to the coordination DB …` when a PUT failed.
- `logs/merge-queue.log`, `logs/pr-reviews.log`,
  `logs/merge-sweep.log`, `logs/batch-resolve.log`, a build's `pipeline.log` —
  one `… HELD by the main-red freeze …` line per lane per pass, naming the flag.

**What must never regress:**

- **`--explain` is READ-ONLY (BH-997).** The dry run and the live `*/5` tick
  share one code path, and everything that arm does is fleet-visible: the flag
  IS the merge freeze, the `pause_flags` row carries it off this hub, and the
  alert pages. So `--explain` takes no lock, creates no `flags/` or `locks/`
  dir, writes and clears no flag, publishes no row and sends nothing — it logs
  `WOULD WRITE` / `WOULD UPDATE` / `WOULD CLEAR` / `WOULD PUBLISH` /
  `WOULD ALERT` instead. Its only write is its own lines in `logs/main-red.log`.
  An operator asking what the detector would say must never freeze or unfreeze
  a repo by asking.
- **Fail CLOSED on the exemption, fail OPEN on the flag.** A diff nobody can
  read is not test-only; a worker outage with no local file is "no flag".
  Inverting either is the difference between one stuck PR and a fleet-wide
  merge stall.
- **A held PR leaves no trace.** No `.blocked` file, no ledger row, no beat, no
  comment. The hold has to end by itself when main goes green.
- **The flag BODY survives publishing.** `flag_set` only `touch`es the file; if
  it ever wrote content, the conductor's `MAIN_RED_WHY` line and the tip-arm
  tests would read an empty flag.
- **The green tick publishes `active:0`, and keeps publishing it until it
  lands.** A raise that is published and a clear that is not leaves every box
  frozen for ever; the `.published` marker is what prompts the republish once
  the flag file is gone.
- **Nothing is read when main is green.** The flag read comes first, so a green
  repo costs zero extra GitHub calls per PR per lane pass.
- **A freeze is never judged last, and never silently.** A scheduled pass
  judges the repos with a flag up before all others (BH-6352). A flagged repo
  that a pass does not decide gets one `decision=none reason=<why>` line in
  `logs/main-red.log`, and each pass ends with one `pass end:` line.
- **A freeze is re-checked every 5 minutes, not once an hour (BH-6502).** The
  `main-red-recheck` hub lane runs `bin/main-red-detector.sh --flagged-only`
  every `main_red_recheck_min` minutes (settings row
  `lane.main-red-recheck.main_red_recheck_min`, default 5, 0 = off). It uses the
  same decision code as the hourly pass. A repo with no flag is never read by
  it, and with no flag up it makes no GitHub read at all.
