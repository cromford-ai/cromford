# Operating the factory

What we learned running the factory every day, and the defaults that came out
of it. Each lesson says what goes wrong, what the factory does about it, and the
knob or file that controls it. Where the fix is still being built, the knob says
so. The defaults a fresh install starts with are in the table at the end, each
with its trade-off.

Settings rows are read and written with `bin/jobs-client.sh setting-get <key>`
and `setting-set <key> <value>`. Lane knobs are declared, with their defaults
and ranges, in `catalog/lanes.d/<lane>.json`. A NEW knob on an existing lane goes
in its own file, `catalog/lanes.d/<lane>.knobs.d/<ENV>.json` (BH-4987). A code constant is only ever the
fallback for a key with no row, and it always equals the seeded default.
One exception: `LEAD_REVIEW_WORKER_MEM_MB` is 700 in the registry (required,
so it is exported with no row) and 2048 in `bin/lib/review-pool.sh`. The code
value is used only when the registry cannot be read, and it gives a smaller
cap there.

## Merge throughput

### The queue tests only what a batch can affect
- **What goes wrong.** A merge batch that runs the whole test corpus takes most
  of an hour, so a busy day merges a handful of PRs and the rest wait.
- **What the factory does.** Each merge-queue batch runs the suites its combined
  diff can affect (`bin/ci-plan.sh`, from `bin/test-impact.sh`), plus the
  always-run set. The `full` label on a PR, or a manual run of the workflow,
  runs the whole corpus.
- **Knob.** None. Impact CI is always on for merge-queue batches
  (`.github/workflows/harness-ci.yml`).

### Independent PRs merge in separate lanes
- **What goes wrong.** One serial queue means a PR touching docs waits behind a
  PR touching the build lane, even though neither can break the other.
- **What the factory does.** With lanes switched on, PRs whose files do not
  overlap go into separate queue lanes and merge side by side.
- **Knob.** `queue_partition.mode` (`off | shadow | enforce`, fallback
  `shadow`) and `queue_mode=` in `config/mergify/repos/<repo>.conf`. Flip a repo
  with the checklist in `docs/MERGIFY.md`, and probe that the CI key answers
  before you do.

### A failed batch drops the culprit, it does not bisect
- **What goes wrong.** Bisecting a red batch re-runs CI on halves of it. With
  long suites that costs hours, and every innocent PR in the batch waits.
- **What the factory does.** The fix being built drops only the PR whose files
  the failing suite reads, and sends the rest straight back in.
- **Knob.** None yet (in progress).

### Main red: the fix goes first and alone
- **What goes wrong.** When main is red, every batch inherits the red and gets
  ejected, so the fix itself can sit behind PRs that cannot land.
- **What the factory does.** While main is red, every merge lane freezes except
  for the PR labelled `fix-main-red`, so the fix goes first and alone. A new
  always-run suite with no timing row was a common cause. The timing rows are
  now composed by CI from its own runs and never committed, so a missing row
  can no longer turn a batch red (docs/ci-durations.md).
- **Knob.** `MC_MAIN_RED_LABEL` (default `fix-main-red`; `bin/lib/main-red-label.sh`).

### Optimistic landing: measure, then flip
- **What goes wrong.** Every READY PR waits for a merge-queue batch, even a
  low-risk PR whose checks are already green on its head. The conductor can
  merge such a PR directly (`MC_LANDING_MODE=optimistic`, BH-6745), but a flip
  with no evidence can land a PR that the queue would have stopped.
- **What the factory does.** In `shadow` mode the conductor records what it
  would have done (`landing_decisions`, `GET /api/landing-decisions`). The
  `landing` lines of the daily DORA digest and `bin/landing-replay.sh` turn
  those rows into the evidence for the flip (docs/DORA.md, "Landing block").
- **Knob.** `MC_LANDING_MODE`: `queue` (default) | `shadow` | `optimistic`.
  The per-project row is `lane.merge-conductor.<project>.mc_landing_mode`.
  The global row `lane.merge-conductor.mc_landing_mode` changes every project
  at once. Do not use the global row for the flip.

The flip procedure. An operator does each step and records it on the flip
ticket. The order of the projects for this fleet is in
`docs/notes/2026-10-26-BH-6748-landing-report.md`.

1. Run `bin/landing-replay.sh --days 7` on the hub. Paste its
   `LANDING_REPLAY` lines on the flip ticket. They are the last lines of the
   output.
2. Start with the harness's own project. Run
   `bin/jobs-client.sh setting-set lane.merge-conductor.<project>.mc_landing_mode optimistic`.
3. Watch that project for 24 h: its `landing <project>:` line in the digest,
   and the `LANDING_DIRECT` lines in `logs/merge-conductor.log`.
4. If it stays green, set the row of the second internal project and watch
   24 h.
5. Then set the row of each client repo, one repo per day, each with its own
   per-project row.
6. Rollback: set the same per-project row back to `queue`:
   `bin/jobs-client.sh setting-set lane.merge-conductor.<project>.mc_landing_mode queue`.

Notes for the flip:
- Optimistic mode merges directly only on a Mergify repo, and never on a
  lane-run machine (`MC_ON_MACHINE=1`). On any other repo or machine the PR
  enqueues as before (`landing_direct_on`, `bin/lib/mc/landing.sh`).
- `MC_DIRECT_MERGE_BUDGET` caps the direct merges per project per tick
  (default 6; 0 turns direct merging off).
- `MC_LANDING_PQ_AGE_MIN` bounds the age of the pre-queue verdict a direct
  merge needs (default 60 minutes; an older verdict is `prequeue-stale`).

## Review throughput

### Lead reviews run in parallel
- **What goes wrong.** One review at a time means a wave of twenty PRs takes
  most of a day to get its first verdict.
- **What the factory does.** Each tick starts up to K reviews at once, each in
  its own worker with its own claim and scratch dir. When an agent call hits a
  rate limit, new starts back off and the wait doubles. A box can spill over and
  take another box's waiting requests.
- **The box cap.** `rpool_init` (`bin/lib/review-pool.sh`) caps K on each box.
  `LEAD_REVIEW_BOX_MAX` overrides the cap. When it is 0, the cap is the
  smallest of three terms (a tie names the earlier term):
  - cpu: vCPUs / `LEAD_REVIEW_WORKER_CPUS` (default 1). A 4 vCPU box runs at
    most 4 workers, whatever its RAM.
  - memory: MemAvailable / `LEAD_REVIEW_WORKER_MEM_MB` (default 700: the
    545 MB peak of one worker measured on a pool box, plus 25%;
    `REVIEW_WORKER_MEM_MB` default 2048, not measured). When
    `/tmp` is tmpfs, its use is RAM: (MemAvailable - tmpfs used) /
    (`LEAD_REVIEW_WORKER_MEM_MB` + `LEAD_REVIEW_WORKER_TMP_MB`).
  - tmp: (free `/tmp` - `LEAD_REVIEW_TMP_MIN_MB`) / `LEAD_REVIEW_WORKER_TMP_MB`
    (defaults 1536 and 256).

  The tick logs `concurrency capped at N by cpu|memory|tmp (<inputs>)`. Builder
  reviews use the same terms with the `REVIEW_` prefix. Ten workers with a
  tmpfs `/tmp` froze a 16 GB pool box on 2026-10-08. The ticket
  records 4 vCPU at the freeze; since its 00:23Z restart that day the box
  reports 8 vCPU (`nproc`), and the 700 MB measurement ran on 8 vCPU.
- **Knob.** `LEAD_REVIEW_CONCURRENCY` and `REVIEW_CONCURRENCY` (default 10;
  0 means unlimited within the box guardrails and the spend cap),
  `LEAD_REVIEW_BOX_MAX`, `LEAD_REVIEW_WORKER_CPUS`, `LEAD_REVIEW_WORKER_MEM_MB`,
  `LEAD_REVIEW_WORKER_TMP_MB`, `LEAD_REVIEW_TMP_MIN_MB` (and the `REVIEW_`
  twins), `LEAD_REVIEW_RATE_BACKOFF_S`, `LEAD_REVIEW_SPILLOVER`.

### Review by risk, narrowly at first
- **What goes wrong.** Sending every PR to a lead review spends the lead's time
  on docs and new tests that cannot break anything.
- **What the factory does.** In `enforce` mode, a rule-based risk tier signs
  off low-risk PRs without a lead review. Low starts narrow: docs, UI screens and new test files
  only, and never a PR the lead wrote.
- **Knob.** `risk_tier.mode` (global) and `risk_tier.mode.<owner>.<name>` (per
  repo): `off`, then `shadow`, then `enforce`. `risk_tier.low_globs` can narrow
  low, never widen it. The mode rows are honoured only for the repos listed in
  `RT_MODE_REPOS`, a code constant in `bin/lib/risk-tier.sh` that today names
  only the harness's own repo. Any other repo stays off whatever its rows say,
  until it is added to that list.

### The lane dismisses its own stale CHANGES_REQUESTED
- **What goes wrong.** A review that asked for changes stays on the PR after the
  fix lands, and GitHub keeps the PR blocked on it.
- **What the factory does.** The fix being built has the lane dismiss its own
  older CHANGES_REQUESTED reviews when a new head passes review.
- **Knob.** None. On by construction once it lands (in progress).

### Paginate review request lists
- **What goes wrong.** A list read capped at 100 entries silently drops
  everything past the cap. New review requests starved for hours behind old ones.
- **What the factory does.** Read every page of a list before acting on it. A
  lane that reads only the first page and treats it as the whole list is a bug.
- **Knob.** None. A rule for code.

## Builds

### Lint before push
- **What goes wrong.** A lint failure that only shows in the merge batch ejects
  the batch and every PR riding with it.
- **What the factory does.** A pre-push lint gate runs the fast always-run lints
  in the PR lint job and in the builder gate, before a batch ever sees them.
- **Knob.** `bin/fast-lints.sh` and `catalog/rules-pack.tsv`.

### Reused pool machines carry stale state
- **What goes wrong.** A pool machine that is reused instead of rebuilt can hold
  a stale slot lock or an ETag cache from its last job, and the next build
  either refuses to start or reads an old answer.
- **What the factory does.** Before warm-up, a reused machine's slot locks are
  probed. A machine still holding a slot from its last build is cleaned, or
  destroyed when it cannot be.
- **Knob.** `bin/pool-slot-clean.sh` (runs on the machine).

### PR size gate
- **What goes wrong.** Big PRs get slow, shallow reviews and conflict with
  everything in flight.
- **What the factory does.** A plan over the size gate is split before it is
  built.
- **Knob.** `size_gate.lines` and `size_gate.files` (default 700 and 20), with
  `size_gate.<axis>.<project>` per project.

## Conflicts

### Measure the hotspots first
- **What goes wrong.** Parallel builds collide on the same few files, and each
  collision costs a rebase, a re-review or a rebuild.
- **What the factory does.** The hotspot tool ranks files by how many PRs hit a
  conflict or a rebase on them. Fix the top of that list, in this order: split
  append-only registries into fragments (one file per entry, and a generator
  joins them), use a generated module map for big scripts, sequence plans whose
  files overlap, and move stacked children onto their landed parent.
- **Knob.** `bin/conflict-hotspots.sh --markdown` (output in
  `docs/CONFLICT_HOTSPOTS.md`), and `bin/stack-launch.sh` for stacks.

### No changelog headers, and use the closure helper
- **What goes wrong.** A file that every PR edits (a changelog, a contract doc, a
  hand-kept list of libs a test copies) is a guaranteed conflict on a hunk no
  ticket is about.
- **What the factory does.** What changed goes in a dated note under
  `docs/notes/`, one new file per change. A test installs a lane's libs with the
  closure helper instead of copying them by hand.
- **Knob.** `scratch_install_closure` in `tests/lib/scratch.sh`, and
  `bin/render-doc-index.sh` for the notes index.

## Gates vs reports

### A harmless metric is reported, not gated
- **What goes wrong.** A hard limit on something that is not itself harmful (a
  suite's run time, a file's line count, a PR's size in lines) blocks good
  changes and teaches builders to game the number.
- **What the factory does.** Those metrics are reported, not gated: no
  source-file line limit, and a fast-lint time budget that reports instead of
  failing (that switch is in progress). Money and safety caps stay hard gates.
- **Knob.** `FAST_LINTS_BUDGET_S` (report-only once that change lands; in
  progress). Spend caps are separate and always enforce.

## Tests

### Fixture secrets carry a marker
- **What goes wrong.** A realistic fake credential in a test trips the leak guard
  and makes a reader wonder if it is real.
- **What the factory does.** A fixture secret has a visible marker inside the
  value itself, a word like fixture or example, so the guard and a reader both
  know.
- **Knob.** `bin/share/leakcheck.py` (the marker list lives next to it).

### No $RANDOM
- **What goes wrong.** A test that draws a random value passes or fails by luck,
  and a red run cannot be reproduced.
- **What the factory does.** The determinism lint is red on `$RANDOM` in a
  test. Use a fixed value or the test's name.
- **Knob.** `bin/test-determinism-lint.sh`.

### Don't name a variable D, DIR or ROOT and pass it to find
- **What goes wrong.** The test-impact scanner reads `find "$DIR"` as a scan of
  the whole tree, so the suite runs on every diff and needs a timing row.
- **What the factory does.** It classes such a suite as always-run.
- **Knob.** `bin/test-impact.sh always-why <suite>` shows why a suite is
  always-run. Point `find` at a scratch dir with a different name.

### The trace gate cannot see through eval or declare
- **What goes wrong.** A path built inside `eval` or `declare -a X="(...)"` is
  invisible to the trace gate, so a test could touch a real path unseen.
- **What the factory does.** Keep paths out of both. A fix for the blind spot is
  in progress.
- **Knob.** `bin/test-trace-safety.sh`.

## Operations

### Keep /tmp free on review boxes
- **What goes wrong.** A full `/tmp` broke every lead review on a box at once.
  A small or cluttered `/tmp` caps the review pool at 1 worker.
- **What the factory does.** No new review worker starts while `/tmp` is under a
  floor, and one alert line goes out per low episode. Each lead-review worker
  keeps its `/tmp` files in its own `lr<tickpid>-<id>` dir, removed on every exit
  path. The tmp sweep removes old `rv`, `wt`, `bh<N>`, `pr<N>` and `lr<N>` dirs.
  `bin/tmpfs-ensure.sh` sizes a tmpfs `/tmp` from RAM and persists it in fstab.
  A cap by `/tmp` or memory below the configured concurrency for 30 min sends
  one warn (`lead-review-capped-<box>`).
- **Knob.** `LEAD_REVIEW_TMP_MIN_MB` and `REVIEW_TMP_MIN_MB` (default 1536);
  `LEAD_REVIEW_CAP_ALERT_AFTER_MIN` (30); `TMPFS_RAM_PCT` (50).

### DNS after a reboot
- **What goes wrong.** A box image ships `/etc/resolv.conf` as a symlink to
  `../run/systemd/resolve/stub-resolv.conf`. The boxes run no systemd, so after
  a reboot the link dangles and the box has no DNS.
- **What the factory does.** `bin/dns-guard.sh` runs first in
  `bin/update-runners.sh` and in `bin/bootstrap-machine.sh`. It replaces that
  dangling link with a static file (`nameserver 1.1.1.1`, `nameserver 8.8.8.8`)
  when `/run/systemd/resolve` does not exist. It never writes a regular file or
  any other link. When `getent hosts api.github.com` fails, it writes one
  `dns: dead` line to ALERTS.log.
- **Knob.** `DNS_GUARD_NAMESERVERS` (default `1.1.1.1 8.8.8.8`).

### Every box has its own identity
- **What goes wrong.** Boxes cloned from one image share a hostname, and rows
  keyed on the hostname from two boxes overwrite each other.
- **What the factory does.** Give every box a distinct hostname, and key every
  row on `box-id`, never on the hostname. A lane with no box id writes nothing.
- **Knob.** `bin/lib/box-id.sh`.

### Orchestrator replies reach the console
- **What goes wrong.** A reply that only goes to a chat app is lost to anyone
  watching the console or driving the factory through MCP.
- **What the factory does.** Every orchestrator turn that answers a console
  command ends with one reply row in the console's reply ledger, whatever
  transport carried it, and then acks the command. Chat is still sent too.
- **Knob.** `bin/lib/orc-reply-ledger.sh`.

### A WIP limit of 1 is a hotfix-only mode
- **What goes wrong.** During an incident, new builds compete with the fix for
  slots and review time.
- **What the factory does.** Set the project's WIP limit to 1, and only one build
  runs at a time.
- **Knob.** `flags/wip-limit-<project>` (`bin/concurrency-plan.sh` shows it).

### HOLD and RESUME
- **What goes wrong.** A person or another session takes a ticket over, and the
  factory keeps building it underneath them.
- **What the factory does.** A `HOLD` comment parks the ticket and a later
  `RESUME` releases it. The newest decisive comment wins.
- **Knob.** `bin/lib/hold.sh`.

### Don't kill processes by pattern on a shared machine
- **What goes wrong.** A kill by pattern matches another session's lane on the
  same machine and kills work that had nothing to do with yours.
- **What the factory does.** Kill by the pid you started or the lock you hold,
  never by a name pattern.
- **Knob.** None. A rule for operators and scripts.

### A missed main-red needs a detector check
- **What goes wrong.** Main went red and nothing said so. Every PR inherited the
  red and each lane debugged its own innocent diff.
- **What the factory does.** The main-red detector checks main itself. When a
  regression slips past it, add a check for that case to the detector, not just
  a fix.
- **Knob.** `bin/main-red-detector.sh`.

## Defaults

| Setting | Default | Where it lives (row or knob, and the code fallback) | Trade-off |
|---|---|---|---|
| Lead and builder review concurrency | 10 | `LEAD_REVIEW_CONCURRENCY` and `REVIEW_CONCURRENCY` lane knobs; fallback 10 in `bin/lead-review.sh` and `bin/review-prs.sh` | Faster verdicts for more vCPU, memory, `/tmp` and agent rate limit. Each box caps it by vCPU, memory and `/tmp` (`*_WORKER_CPUS`, `*_WORKER_MEM_MB`, `*_TMP_MIN_MB`). 0 removes the lane cap, not the box cap. |
| Fast-lint time budget | report-only | `FAST_LINTS_BUDGET_S` on the `fly-pool` lane (report-only in progress) | A slow lint never blocks a PR, so a slow suite is only noticed if someone reads the report. |
| Size gate | 700 lines / 20 files | `size_gate.lines` and `size_gate.files` rows; fallback `DEF_LINES=700` and `DEF_FILES=20` in `bin/size-threshold.sh` | Smaller PRs review better and conflict less, but a ticket over the line is split, which adds a plan and a build. |
| Risk tier | off | `risk_tier.mode` row (off) and `risk_tier.mode.<owner>.<name>` per repo; no row also reads off in `bin/lib/risk-tier.sh`. The rows are honoured only for repos in `RT_MODE_REPOS` (a code constant in `bin/lib/risk-tier.sh`, today the harness's own repo); any other repo stays off until it is added there, then opts in to `shadow`, then `enforce` | Off means every PR gets a lead review. Watch a repo in shadow before enforce, because enforce merges low-risk PRs without one. |
| Merge queue | serial (separate lanes recommended, off until a repo opts in) | `queue_partition.mode` row (not seeded; fallback `shadow`, which logs lanes and uploads nothing) plus `queue_mode=` per repo in `config/mergify/repos/<repo>.conf` | Independent PRs land side by side. Needs a CI key and a per-repo flip; a repo that has not flipped stays serial. |
| Impact CI | on | always on in `.github/workflows/harness-ci.yml` (`bin/ci-plan.sh`) | Batches run in minutes, not an hour. A suite the impact map misses runs only in the scheduled full run on main. |
| `/tmp` floor for review workers | 1536 MB (1.5 GB) | `LEAD_REVIEW_TMP_MIN_MB` and `REVIEW_TMP_MIN_MB` lane knobs; fallback 1536 in `bin/lib/review-pool.sh` | Reviews pause instead of failing on a full disk. Too high a floor idles a small box. |
| Stale-review dismissal | on | no knob, on by construction (in progress) | A fixed PR is not held by its own old review. A reviewer who wants the block kept re-reviews. |
