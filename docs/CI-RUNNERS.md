# CI runners — the `CI_RUNNER` switch and the Fly pool

Where Harness CI runs is a **repo variable, not a code edit**. Every job in
`.github/workflows/harness-ci.yml` reads it:

```yaml
runs-on: ${{ fromJSON(vars.CI_RUNNER || '"ubuntu-latest"') }}
```

So moving CI between runner fleets is one API call and a re-run — no PR, no
deploy, and a rollback that is the same call with the old value (BH-1209,
BH-1206).

| | |
|---|---|
| Current value | `"monkci-ubuntu-24.04-4"` — MonkCI hosted runners (since 2026-09-22 ~04:47Z, BH-1323) |
| Fallback fleet | `["self-hosted","linux","bh-ci"]` — the Fly pool |
| Fly pool state | **STOPPED since 2026-09-23 ~22:35Z** (the operator: "stop them so we don't pay"). All 13 `performance-16x` machines in `bh-ci-runners-example-org` were idle after the MonkCI switch but still billed. `CI_RUNNERS_ALERT_HOLD_MIN` is set to 0 on testhost-tick so the cold pool does not page. |
| Fallback when unset | `"ubuntu-latest"`, and the lint job goes red |
| Any other value | red on the lint job's `CI_RUNNER names a known fleet` step (`bin/ci-runner-known.sh`) |
| Format | JSON: a **string** for a hosted image, an **array** for a label set |

`publish-cromford.yml` is deliberately out of scope and stays on `ubuntu-latest`.

## Known fleets

The variable may only hold one of these. Anything else — a typo, a hosted image
nobody has run the corpus on, an unset variable — is refused by
`bin/ci-runner-known.sh` on the `lint` job, because the fallback expression above
would otherwise swallow it and the whole run would go green on a fleet nobody
chose.

| Value | Fleet | When to use it |
|---|---|---|
| `"monkci-ubuntu-24.04-4"` | MonkCI hosted runners, one 4 vCPU VM per job | the default, and what CI runs on today |
| `["self-hosted","linux","bh-ci"]` | the Fly `bh-ci-runners-example-org` pool | fallback: MonkCI down, out of minutes, or a billing stop |

**Adding a third fleet is two edits in one PR:** a line in
`bin/ci-runner-known.sh` and a row in the table above.
`tests/harness-ci-runners.bh-1323-test.sh` runs the guard over every value in
this table, so a list and a table that disagree is a red suite rather than a
surprise the next time somebody flips the switch.

## Bringing the stopped Fly pool back (fallback)

The pool is stopped, not destroyed. Each machine keeps its config and runner registration image, so falling back takes two steps:

```bash
# 1. start the 13 machines (runners re-register on boot)
for id in $(fly machines list -a bh-ci-runners-example-org --json | jq -r '.[]|select(.state=="stopped")|.id'); do
  fly machine start "$id" -a bh-ci-runners-example-org
done
# 2. point CI at them
gh api -X PATCH repos/example-org/cromford/actions/variables/CI_RUNNER \
  -f name=CI_RUNNER -f value='["self-hosted","linux","bh-ci"]'
# 3. re-arm the empty-pool page: set testhost-tick CI_RUNNERS_ALERT_HOLD_MIN back to its registry default
```

Stopped machines bill only for their root filesystem. Stop them again (same loop with `fly machine stop`) when CI returns to MonkCI.

## Flipping the switch

```bash
# to MonkCI (current)
gh api -X PATCH repos/example-org/cromford/actions/variables/CI_RUNNER \
  -f value='"monkci-ubuntu-24.04-4"'

# back to the Fly pool
gh api -X PATCH repos/example-org/cromford/actions/variables/CI_RUNNER \
  -f value='["self-hosted","linux","bh-ci"]'

# what is it now?
gh api repos/example-org/cromford/actions/variables/CI_RUNNER --jq .value
```

Those are the only two values that work. Any other — including a GitHub-hosted
image such as a larger `ubuntu` runner — is refused by the guard on the `lint`
job until it is added as a known fleet above. The bytes matter: a trailing space
inside the quotes is a label GitHub has nothing registered for, so every job
queues forever, and the guard compares exactly rather than normalising the JSON
so that it can say so.

A change takes effect on the **next run**, not on runs already in flight. To move
a PR that is already open, flip the variable and re-run it:

```bash
gh api -X POST repos/example-org/cromford/actions/runs/<run-id>/rerun
```

### No job may name a runner

Point eight of the nine `runs-on` lines at the variable and hard-code the ninth
and the gate **splits**: most of the run on one fleet, one job on another, still
green. `tests/harness-ci-runners.bh-1206-test.sh` asserts every job reads
`vars.CI_RUNNER`, that `"ubuntu-latest"` appears only inside the fallback, and
that no hosted image name and no pool label appears in the workflow's executable
text. The literal is the bug, whichever fleet it points at.

## The MonkCI fleet (current)

CI moved to MonkCI hosted runners on **2026-09-22 ~04:47Z**, by flipping
`CI_RUNNER` from the Fly pool's labels to `"monkci-ubuntu-24.04-4"` — no PR, no
image rebuild. The label says what you get: **one 4 vCPU VM per job**, not a
slice of a shared machine.

An A/B on the same tree (`c8b3bb64`, the full 592-suite run) is why:

| | Fly bh-ci pool | MonkCI 4 vCPU |
|---|---|---|
| wall | 23.7 min | 17.5 min |
| job-minutes | 157 | 80 |
| slowest / fastest shard | 23 / 14 min | 15 / 6 min |
| per-suite timeouts | 2 shards lost to 120 s kills | none |

**The cause is contention, not the image.** The Fly pool runs 8–12 runner slots
per 16-vCPU machine, so shards compete for CPU exactly when the drain is busiest
— which is also why the per-suite 120 s kills only ever showed up under load.
MonkCI gives each job its own VM, and the job-minutes halving says the work was
the same; the waiting was the difference. It is the same measurement the
ShellCheck section below made on one step, at the scale of the whole run.

**Cost:** about **$0.002 per vCPU-min**, so roughly **$0.64 per full run** and
**~$20/day at 30 runs**. The 14-day trial carries 5,000 minutes, which is about
30 full runs at the 4-vCPU 2x rate; a Pro plan after that. The Fly pool is the
fallback for all three of the ways this ends — MonkCI down, minutes exhausted,
or a billing stop: flip the variable back and re-run.

### Watching the minutes (K1, 2026-09-24)

By 2026-09-24 the account was billing overage at ~120K minutes a day, and the
invoice was the only place that said so. MonkCI exposes no usage API any fleet
credential can reach, so `bin/ci-minutes-watch.sh` (hub, `23 */6 * * *`)
measures it from GitHub. Per `fleet.conf` repo it reads the completed runs of
the last 24h (at most `CI_MINUTES_MAX_PAGES` pages of 100) for their wall
minutes (unique by run id), reads the jobs of `CI_MINUTES_SAMPLE_RUNS` (10) of
them spread across the list sorted by workflow, and bills each job whose runner
labels contain `CI_MINUTES_RUNNER_MATCH` (`monkci`) at `ceil(minutes) x
CI_MINUTES_BILL_MULT` (2, the 4-vCPU rate; decimals allowed). Each workflow's
wall minutes take that workflow's sampled billed/wall ratio, and when the pages
held fewer runs than the endpoint's `total_count` the estimate is extrapolated
by `total_count / runs read`. Budget: repos x (pages + sample) GitHub reads a
tick, about 150, and none while `bin/lib/gh-budget.sh` says the bucket is low.
Every tick writes `logs/ci-minutes-watch.log` and
`state/ci-minutes/latest.json`; over `CI_MINUTES_DAY_MAX` (25,000) it pages
critical once a day through `bin/lib/page-critical.sh`. All five are settings
rows on the `ci-minutes-watch` lane. Tests: `tests/ci-minutes-watch.k1-test.sh`.

### Merge-queue batch size (BH-8047, 2026-10-22)

The MonkCI invoice for the period to 2026-10-22 was $9,284 for 1,160,553
4-vCPU minutes. The merge queue ran about 54 batches a day, most of them one
PR, each 7 to 18 shards of 20 minutes, so every merged PR paid a full impact
run. The cromford `default` queue now holds up to 6 PRs and waits up to
2 min to fill, which gives about 12 batches a day. The union impact set of 6
PRs is smaller than 6 separate sets. A red batch of 6 costs more than a red
batch of 1: Mergify does not split it (`batch_failure_attempts=0`), and the
merge conductor ejects the culprit and re-queues the rest. The pre-queue gate
ticket lowers the red rate. The hotfix, flake-fix and solo queues stay at 1 PR
and 0 s. Two knobs turn it back, both in
`config/mergify/repos/cromford.conf`: `batch_size` and
`batch_max_wait_time` (4 / 3 min was the last value; 1 / 0 s turns batching
off). After either edit, edit `.mergify.yml` to match and run
`bin/mergify-template.sh --check`. Tests: `tests/mergify-template.bh-8047-test.sh`.

### Re-running the A/B

The workflow has `workflow_dispatch`, so both halves run on the same sha and
nothing has to be merged to measure:

```bash
# 1. dispatch a run on the current fleet
gh workflow run harness-ci.yml --ref main

# 2. read its id back
gh run list --workflow harness-ci.yml --limit 1 --json databaseId

# 3. per-job durations (wall is the max completed_at minus the min started_at;
#    job-minutes is the sum of the per-job spans)
gh api repos/example-org/cromford/actions/runs/<id>/jobs --paginate \
  --jq '.jobs[] | [.name, .started_at, .completed_at] | @tsv'
```

Then flip `CI_RUNNER` to the other fleet, dispatch again on the **same sha**, and
compare. Comparing two different shas measures the diff, not the fleet.

### publish-cromford.yml

The public-copy publisher hard-codes `runs-on: ubuntu-latest` and is left that
way on purpose (BH-1323): it does not run the corpus, so it is not part of the
gate and has nothing to gain from either fleet. The old mirror workflow this
section used to name was retired 2026-10-06 (BH-4834). `tests/harness-ci-runners.bh-1323-test.sh`
pins that non-change, so a well-meaning sweep cannot quietly fold it in.

## The Fly pool

The fallback fleet since 2026-09-22.

| Thing | Value |
|---|---|
| Fly app | `bh-ci-runners-example-org` |
| Fly org | `board-builders` |
| Machines | `ci-1` … `ci-7`, `performance-16x` |
| Runners per machine | 8 or 12, set by `RUNNERS_PER_MACHINE` |
| Labels | `self-hosted, linux, x64, bh-ci` (`RUNNER_LABELS`) |
| Registered to | this repo, `example-org/cromford` |
| Credential | the `GH_TOKEN` Fly secret |

At boot the entrypoint mints a registration token per runner with
`POST /repos/example-org/cromford/actions/runners/registration-token` using
`GH_TOKEN`, and configures the runner against it. Each runner is **ephemeral**:
one job per registration, a fresh work directory, then it re-registers.

**Ephemeral is not the same as a fresh machine, and the difference is #1216.**
What the next job cannot inherit is the *work directory*. The machine underneath
persists, and eight or twelve runners share it — so anything a job writes
outside its work directory is still there for whoever lands on that machine
next. A GitHub-hosted runner hides this by throwing the whole VM away. See the
HOME section below before assuming otherwise.

### The image, and what it had to learn

Debian trixie with the CI toolset baked in: jq 1.7, shellcheck, age, zstd, gawk,
actionlint, **NodeSource node 22**, and **codegraph 1.5.0 + semgrep 1.176.1**
preinstalled per runner. These properties are not cosmetic — each one answers a
way the first runs on the pool failed, and none of them was a code bug.

PyYAML is **not** baked into this image (it is built outside this repo). The
two shard jobs install `python3-yaml` at job time behind
`bin/ci-tool-present.sh --python-module yaml`, through the serialised apt
wrapper below, and then run that check unguarded, so a runner still without
PyYAML is a red job rather than the mergify-template suites skipping (BH-1741).
Baking it into the image is the image owner's follow-up.

1. **Runners run as an unprivileged `runner` user** (uid 1001, passwordless
   sudo) — the same shape as a GitHub-hosted runner — and since v4 each runner
   has **its own home**, `/home/runner/homes/rN`, wiped between jobs. codegraph
   1.5.0 and semgrep 1.176.1 live in those per-runner homes (`~/.npm-global`
   and `~/.local`, both hard-linked from the canonical copies under
   `/home/runner`), so `bin/ci-tool-present.sh` finds the pins and every
   install step skips. Read the HOME section below before writing anything that
   touches a home directory; this one matters more than it looks, and it is
   #1216.
2. **`apt` is serialised.** Several runners share one machine, so concurrent
   jobs collided on the dpkg lock and `apt-get install` exited 100. The image
   carries `/usr/local/sbin/apt-get`, first on sudo's `secure_path`: a no-op
   when every requested package is already installed, and otherwise a flock with
   `DPkg::Lock::Timeout`.
3. **Node 22, not Debian's 20.** `tests/repro-gate-test.sh` shells out to
   `node --experimental-strip-types`, which needs >= 22.6. Every hosted image
   happened to have a new enough node, so the corpus had an undeclared runtime
   dependency that nothing in the workflow stated. It is now pinned on both
   shard lanes with `actions/setup-node@v4` as well, so the next image cannot
   decide the question silently.

### A job must never assume a clean HOME — the image wipes it

This is the subtlest thing about a self-hosted runner, and it cost a day
(#1216). A GitHub-hosted runner is a fresh VM per job; a Fly machine is
**persistent**, and eight or twelve ephemeral runners share it. The registration
is thrown away after each job. The filesystem outside the work directory is not.

What happened: the v2 image ran its runners as **root**, so `HOME` was `/root`.
A suite in the `decisions` lane — which sets `HARNESS_TEST_SANDBOX=1` by design,
one of the two sanctioned places (#463) — created `/root/harness` on the
machine. It was a test fixture, it was correct, and it was gone from the work
directory the moment the job ended. But it stayed on the machine. Every later
job landing on that runner then saw a live harness root sitting next to a root
process, and the trace-safety lane refused:

```
refusing to run the suite as root next to the live harness /root/harness
```

So a test wrote a file in one job and broke a *different* job, hours later, on a
different PR. Nothing in the diff, nothing in the log of the job that did it.

**The corpus's two root guards did exactly their job.** They are what stopped
the 2026-09-15 hub wipe (#388), where a test re-derived a harness root it did
not own and deleted the live install. The right response was never to silence
them.

The fix is the image, and it took two turns:

- **v3**: runners run as an unprivileged `runner` user with sudo, the same shape
  as a GitHub-hosted runner. That is why hosted CI never saw this — its jobs run
  as `runner` too — and with the process no longer root, neither guard can fire
  on either fleet.
- **v4 (live)**: each runner gets **its own home**, `/home/runner/homes/rN`,
  wiped between jobs. Cross-job leakage through the home directory is now
  impossible rather than merely unlikely.

### The ENOSPC that v4 also had to solve

Per-runner homes are not free, and the first attempt at them filled the disk.
The rootfs is **7.8 GB**; a runner's home carries its own copy of the toolset
(`~/.npm-global` for codegraph 1.5.0, `~/.local` for semgrep 1.176.1) at about
**678 MB**, and twelve runners on a machine is **8.1 GB** of copies. Jobs died
with ENOSPC, which surfaces as a scatter of unrelated-looking failures across
every lane rather than as one legible error.

v4 **hard-links** each runner's copies from the canonical
`/home/runner/.npm-global` and `/home/runner/.local` instead of duplicating
them: the whole pool of homes comes to roughly **770 MB**, and a machine runs
with about 6 GB free. The tools still resolve per runner, so
`bin/ci-tool-present.sh` finds the pinned versions and every install step skips.

The operational consequence is the same rule as the HOME leak, for a second
reason: **a job may write under `$RUNNER_TEMP` or inside the checkout, and
nowhere else.** A few hundred megabytes left in a home directory is now a
machine-wide outage rather than one job's mess.

**The rule for anyone writing a test or a step: a job must never assume a clean
`HOME`, and must never leave anything in it.** Write under `$RUNNER_TEMP` or the
scratch tree (`tests/lib/scratch.sh`), which is what every suite here already
does. On a hosted runner a stray write is invisible because the VM dies; on a
Fly machine it is a message to the next job.

**And never resolve that refusal by setting `HARNESS_TEST_SANDBOX=1` on the
`Tests cannot touch a real harness` lane.** It would look like a one-line fix,
turn the red green, and hand every test in the corpus root next to a live
install. If the refusal ever appears again, fix the runner user and the HOME.

## The tool steps are guarded, not deleted

`CI_RUNNER` can point at the Fly image, which bakes the toolset in, or at a
hosted image, which carries almost none of it — between one run and the next. So
every install step is wrapped in `bin/ci-tool-present.sh <command> [<pin>]`
rather than deleted:

```bash
bin/ci-tool-present.sh codegraph 1.5.0 || npm install -g @colbymchenry/codegraph@1.5.0
```

It exits 0 only when the command is on PATH **and**, given a pin, reports exactly
that version as a whole token — `1.5.0` is not satisfied by `1.5.01`. A tool on
PATH whose `--version` fails counts as **absent** (the 2026-09-10 broken-semgrep
wheel), so a half-installed tool is installed over rather than trusted. It skips
on the fleet that has the tool and installs on the fleet that does not; neither
is assumed. Skipping saves about a minute per job.

The same rule applies to PEP 668. An externally-managed python refuses a bare
`pip install`; an older pip refuses `--break-system-packages` itself. So the
semgrep step **asks**:

```bash
if python3 -m pip install --help 2>/dev/null | grep -q -- --break-system-packages; then
  python3 -m pip install --quiet --break-system-packages "semgrep==1.176.1"
else
  python3 -m pip install --quiet "semgrep==1.176.1"
fi
```

Deleting the installs instead of guarding them would have been shorter, and it
would break the hosted fleet outright and the first Fly image rebuilt without a
tool silently.

## Is the pool up?

```bash
bin/ci-runners-status.sh            # human: counts plus a line per runner
bin/ci-runners-status.sh --json     # {"total":…, "online":…, "idle":…, "busy":…, "offline":…}
```

It reads `GET /repos/<slug>/actions/runners` over REST through `gh_ci_api`
(`bin/lib/gh-ci-read.sh`): the default token answers first and only a failure
retries once with a read-only App token. Never GraphQL — the accounts here hit
GraphQL rate limits that kill a session mid-run — and never a Fly-side machine
list, because a machine that is up with a runner that failed to register is
exactly the outage worth knowing about, and only GitHub can see it.

Three outcomes, never two:

| rc | meaning |
|---|---|
| 0 | at least one runner is online (idle or busy) — the pool can take work |
| 1 | the pool answered and **nothing is online** — this is the alert |
| 2 | the read failed or did not parse — nothing is known |

A 403 parses as perfectly good JSON, so "could not ask" must never collapse into
"zero runners": one of those pages someone and the other one is a broken token.
`tests/ci-runners-status.bh-1206-test.sh` drives all three against a fake `gh`.

**Read it when idle, not mid-burst.** Ephemeral runners consume their
registration on each job and re-register, so a snapshot taken while a run is
landing shows a chunk of the pool `offline` for a few seconds. That is churn, not
an outage — which is why the alert below requires the condition to hold for ten
minutes rather than trusting one read.

## When the pool is down, jobs queue

If the Fly machines are down, jobs **queue**. They do not fail, and there is no
automatic fallback to a hosted image: queueing is recoverable and loses nothing,
where a silent fallback would run the gate somewhere nobody chose. The recovery
is deliberate — flip `CI_RUNNER` to MonkCI (`"monkci-ubuntu-24.04-4"`) and
re-run. That is a known fleet; a hosted image the corpus has never run on is not,
and the guard on the `lint` job says so rather than letting an outage pick the
gate's machine.

The cost is that an outage is invisible: a queued job looks exactly like a slow
one, and the drain just stops merging with no PR red. That is what
`ci-runners-status.sh` answers, and the `testhost-tick` lane
(`cron/lanes/245-testhost-tick.cron`, hub, `*/5`) is what asks it: every tick
runs `bin/ci-runners-status.sh --json` before it touches the test host, and
turns the rc into one alert through `bin/lane-alert.sh`.

| the read says | the lane does |
|---|---|
| rc 0 | nothing, beyond a line in `logs/testhost-tick.log`. If an alert was open it sends one `--resolve` and clears the clock. |
| rc 1 held for `CI_RUNNERS_ALERT_HOLD_MIN` minutes (default 10) | ONE `--severity critical --id ci-runners-empty`, however long the outage then lasts. |
| rc 2 held for the same window | ONE `--severity warn --id ci-runners-unreadable`, and never the "no runners" alert — a token that cannot read the endpoint is the failure that hides the failure, not an empty pool. |

The hold is why a machine restart is not a page: one empty read starts a clock,
a green read throws it away in silence, and only a streak that survives the
whole window says anything. The clock is two settings rows —
`ci_runners.empty_since` and `ci_runners.unreadable_since`, `0` / `<epoch>` /
`<epoch>:fired` — so it survives a hub-lease move, and an unreadable tick never
clears an open `ci-runners-empty` (a read we could not make is not evidence the
pool came back). Tune the window with
`bin/harness-ctl.sh set testhost-tick CI_RUNNERS_ALERT_HOLD_MIN <n>`; `0` turns
the pool check off entirely. `tests/ci-runners-alert.bh-1210-test.sh` drives all
of it against a fake status script.

## Adding a machine

```bash
flyctl machine run <image> \
  --app bh-ci-runners-example-org \
  --vm-size performance-16x \
  -e RUNNERS_PER_MACHINE=8 \
  -e RUNNER_LABELS=bh-ci
```

Those runners register at boot. Removing a machine is `flyctl machine
stop`/`destroy`: the in-flight job finishes or is re-queued by GitHub, and the
ephemeral registrations expire on their own.

### Warm minimum, and scaling back up

Now that MonkCI runs the gate, a pool sized for the whole corpus is billed to sit
idle. The target is **two warm machines**: enough to take a run if MonkCI is down
or out of minutes, and enough to prove the fleet still works before a flip.
Which two is the operator's call.

This needs the `board-builders` org token, which is the operator's — there is no `flyctl`
and no Fly credential on a watcher box, so **the shrink is an ops step and has
not been run.** The `Machines` row above describes the pool as it stands until
someone runs these commands:

```bash
# what is up right now
flyctl machine list --app bh-ci-runners-example-org

# stop every machine but the two you are keeping warm
flyctl machine stop <id> --app bh-ci-runners-example-org

# and back up, when the pool is needed again
flyctl machine start <id> --app bh-ci-runners-example-org
```

A **stopped** machine keeps its rootfs and stops billing CPU and RAM, which is
why this is `stop` and not `destroy`: starting one back is a single command with
the image and the baked-in toolset already on it. Destroying them means a fresh
`flyctl machine run` per machine and an image pull before the first job.

Runners register at boot, so scaling up needs nothing else — but prove it rather
than assuming it: `bin/ci-runners-status.sh` must show
machines × `RUNNERS_PER_MACHINE` runners online before the variable is flipped
back. A machine that is up with runners that failed to register is exactly the
outage that looks like success from the Fly side.

Two warm machines keep `bin/ci-runners-status.sh` at rc 0, so the `testhost-tick`
lane's critical `ci-runners-empty` page does **not** fire on a pool shrunk to the
warm minimum. It fires when the pool is stopped the rest of the way down. If that
is deliberate, turn the check off with `bin/harness-ctl.sh set testhost-tick
CI_RUNNERS_ALERT_HOLD_MIN 0` rather than letting a known-cold pool page every
tick.

## Rotating `GH_TOKEN`

Today `GH_TOKEN` is a **user OAuth token**, which is more reach than this needs.
Rotate it to one of:

1. a **fine-grained PAT** scoped to `example-org/cromford` only, with
   `Administration: write` (what `actions/runners/registration-token` requires)
   and nothing else; or
2. a **GitHub App installation token** minted by the hub, same repo scope.

Then, per the fleet's key-rotation rule, update **every** place the value lives —
the Fly secret and any local env file that holds it:

```bash
printf 'GH_TOKEN=%s\n' "$NEW" | flyctl secrets import --app bh-ci-runners-example-org
```

`secrets import` reads `NAME=VALUE` lines on stdin. **Do not reach for
`flyctl secrets set GH_TOKEN=- …`** hoping the `-` means "read stdin": `set`
takes `NAME=VALUE` literally, so that stores a token whose value is the single
character `-`. Every runner then fails to mint a registration token at boot and
the pool empties itself — with `bin/ci-runners-status.sh` reporting the outage
correctly and nothing saying why.

Setting the secret restarts the machines, which re-registers every runner, so do
it when the drain is quiet. Then prove it: `bin/ci-runners-status.sh` must show
the pool back at full count. A rotation that was not verified against the runner
count is a rotation that has not happened — the symptom of a dead token here is
not an error anywhere, it is jobs that queue forever.

## The lint job's ShellCheck is pinned and cached (BH-1200)

After the CI shards (#1197) the whole run's critical path was **"Syntax +
shellcheck + config integrity" at ~12 minutes**, and on run 35593567939 the
ShellCheck step alone was **11m42s of an 11m50s job**, emitting nothing the
entire time.

The obvious suspect was `apt-get install shellcheck`, and it was wrong. The same
367-file corpus takes **3m17s on an idle M-series laptop with `user` time equal
to `real`** — ShellCheck is single-threaded, and a vCPU shared between twelve
runners turns three minutes into twelve. Caching the *binary* would have saved
seconds. Worse, handing ShellCheck all 367 files in **one invocation is itself
about four times more CPU** than invoking it per file: 3m13s of user time as one
call, 47s as 367 calls.

So `bin/ci-shellcheck.sh` attacks the work rather than the install:

- **Per-file findings cache.** Each file's verdict is keyed on the ShellCheck
  version **the binary reports** (not the pinned constant — a cache keyed on a
  constant is reused across a binary that reports something else), the flags,
  the path, and the sha256 of the contents. An unchanged file is never re-linted.
  A single whole-corpus key would have been easier and useless: every PR touches
  a script, and one touched script would invalidate all 367.
- **Misses run in parallel**, capped at 4 — `nproc` is the machine's cores, not
  this job's share of them.
- **The binary is pinned, never apt-installed.** It comes from PATH when the
  image already has the pin, otherwise from the koalaman release tarball with
  its sha256 verified in the script. Neither fleet is assumed, and nothing waits
  on the dpkg lock twelve runners used to serialise on.

Measured on the real corpus:

| run | wall clock |
|---|---|
| before, one invocation | 3m17s |
| cold, empty cache | 17.8s |
| one file changed | 2.3s |
| unchanged corpus | 2.4s |

Two things keep it honest. **`--format=gcc`**, because the default tty format
ends each *invocation* with a "For more information:" footer — one footer per
file is not the same bytes as one per run, so per-file results could never be
replayed faithfully. And **rc >= 2 is never cached**: ShellCheck failing to run
is not a verdict, and caching it would pin a fake "clean" until someone edited
the file.

Per-file caching is only sound at `--severity=error` because no error-level
ShellCheck check depends on definitions imported from a sourced file. That is an
assumption about somebody else's program, so `tests/ci-shellcheck-cache.bh-1200-test.sh`
**measures it** on the real binary: a corpus linted in one invocation and again
file-by-file must produce identical output. `tests/ci-shellcheck-cross-file.bh-1246-test.sh`
keeps a sourcer+lib canary that goes red if a future severity bump makes the
per-file key unsound.

The cache persists through `actions/cache` under `$RUNNER_TEMP`, not a directory
on the machine — the runners wipe their homes between jobs and share a 7.8 GB
rootfs. The save key carries the commit sha so each run writes a fresh entry;
`restore-keys` is what makes it hit. A cache miss is slow, never wrong.

## Test tiers: batch, nightly, guard (2026-09-28)

`catalog/test-tiers.tsv` says where each suite runs. A suite with no row runs in
every merge-queue batch, and so does any row `bin/test-tiers.sh` cannot read.

- **nightly**: slow suites with no failure in the sampled batch history. The
  batch skips them. `.github/workflows/harness-nightly.yml` runs them on main
  every night. It is traced, sharded and judged by `bin/ci-verdicts.sh`. A red
  night opens or updates one issue (`bin/nightly-ticket.sh`).
- **guard**: safety and leak guards. The nightly run includes them. A batch
  runs a guard only when its diff (`TI_BASE..HEAD`) touches a path in the
  guard's `paths` column, the guard itself, the tier file or
  `bin/test-tiers.sh`. If the diff can't be computed, the guard runs.

Only the merge-queue batch is tiered. A push that bypassed the queue, the `full`
label and a dispatch still run the whole corpus. The builder's pre-push gate
(`bin/test-impact-gate.sh`) runs every nightly suite a diff reaches first,
outside its cap. Any nightly suite its time budget can't start is listed as left
to the nightly run, not to CI. No batch runs it, so it reaches main untested
until that night. Suites that `bin/test-impact.sh always` selects are never
nightly, and neither are ratchet or merge-safety suites. To put a suite back in every batch, delete
its row. To run tonight's set by hand, dispatch "Harness nightly tier".
