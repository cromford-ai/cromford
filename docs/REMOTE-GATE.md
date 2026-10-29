# Remote gate — run the suite on the shared Fly test host

`bin/remote-gate.sh` runs this repo's suites, or one command, on a shared Linux
machine on Fly instead of on the laptop or box you are sitting at. The machine
is owned by the `testhost-tick` lane, which starts it when a run needs it and
stops it once nobody has used it for half an hour.

Measured on the host this was built against: one suite 9 s end to end, sixteen
heavy suites concurrently 28 s.

## Why it exists

The Mac drain of 2026-09-20/21 ran its suites in local docker. Past about ten
containers they SIGKILLed each other (load 120), which is what forced the
five-agent limiter that #1193 was filed about. GitHub Actions is the merge gate
and runs the full corpus on every PR, which is minutes, not seconds — too slow
to be the loop a builder or a reviewer runs while working.

`bin/run-tests-in-docker.sh` stays exactly where it is. It is what somebody
without Fly access uses, and it is still the right answer for reproducing a
container-only failure. The remote gate is the faster path when `TESTHOST_APP`
is reachable.

## Using it

```sh
bin/remote-gate.sh <dir> tests/a.sh tests/b.sh      # suites, in parallel
bin/remote-gate.sh <dir> -- bin/checks-run.sh --tree .   # one command, one copy
bin/remote-gate.sh --full --tail 200 -P 16 <dir> tests/a.sh
```

`<dir>` is a worktree — the gate uploads it as it stands on disk, so uncommitted
work is included and nothing is pushed anywhere.

| exit | meaning |
| --- | --- |
| 0-124 | the number of failing suites, or the command's own exit in `--` mode |
| 125 | **the run could not happen** — no `flyctl`, no route to Fly, a refused upload, ssh's own rc 255, or a copy that failed on the host |
| 2 | your command line was wrong (bad flag, no such directory, no suites) |

The split matters in both directions, and both halves were wrong at some point
in this PR's own history. A gate that cannot reach its host must never print
`0 suites, 0 failing` and exit 0, because every caller reads that as a green
branch. And a runner that filled the host's disk must not report ten red
suites, because a human reads that as a broken branch — the first whole-corpus
run did exactly that. 125 is what docker uses for the same thing and sits above
anything a suite count can reach.

`rc 127` from a suite means that suite is not on this branch. The run says so
rather than counting it as a failure of the code under test.

## Where runs live, and what keeps the disk from filling (#1597)

Runs live under `/srv/tmp/runs`. `/` on each of the four machines
(`testhost-1..4`) is a 7.8 GB overlay shared with the image and everything else,
and a dozen ~50 MB copies of the tree do not fit there when eight agents are
draining. **Until #1597 this section said `/srv/tmp` was a 20 GB tmpfs. It was
not, on any machine: nothing provisioned the mount, every run landed on the root
disk, and under load every builder's gate died with ENOSPC.** What happens now:

- **The prep job makes the tmpfs real.** Before the upload the gate sends a small
  prep job. It sweeps (below), then, under a lock outside `/srv/tmp`
  (`/srv/tmp.mount.lock`) that every run's prep takes, it mounts a
  `REMOTE_GATE_TMPFS_SIZE` tmpfs on `/srv/tmp` **only** when `/srv/tmp` is not a
  tmpfs already, holds nothing but an empty `runs/`, and no live process
  references it. The run's own directory is created under the same lock, so no
  other run can slip a tree in between the check and the mount. A tmpfs mounted
  over a non-empty `/srv/tmp` would hide every live run in it, so anything else
  is one line, and the run goes on on the root disk:
  `remote-gate: WARNING — /srv/tmp is on the root disk (N GB free): <why>`.
  The prep never fails a run. A busy host is mounted the first time it drains;
  a rebooted one is mounted at boot (see the image, below).
- **The host cleans up when a run dies.** The run job traps `EXIT` (remove the
  run tree) and `HUP`/`INT`/`TERM`/`PIPE` (kill every process under the suite
  workers first, then exit 125). The suites run in the background and are waited
  for, because bash holds a trap until a foreground child returns. An ssh that
  drops, a `bash -s` that is killed or times out: the tree goes with it.
- **Suite scratch stays in the run.** `TMPDIR` is the run's `tmp/`, and each
  suite gets `tmp/<n>`, removed with its copy. Suites `mktemp` and
  `tests/lib/scratch.sh` builds `$TMPDIR/scratch.XXXXXX`, so before this all of
  it went to `/tmp`, outside the tree, and a suite that died left it forever
  (805 MB for one share-mirror leakcheck).
- **Nothing runs without room.** Before the first `cp -a base` the job needs
  `max(REMOTE_GATE_MIN_FREE_MB, copies × du(base) × REMOTE_GATE_FREE_FACTOR)` MB
  free on the run root's filesystem (`copies` = the smaller of `-P` and the suite
  count; 1 in `--` mode). Short, it sweeps and measures again. Still short, it
  exits **125**:
  `remote-gate: RUNNER FAILURE — the test host has N MB free on <fs>, need M; nothing ran`,
  plus the host's memory and disk. That is never reported as red suites.
- **The sweep is sooner and wider.** Every prep and every run removes, once they
  are older than `REMOTE_GATE_SWEEP_MIN` (was a hardcoded six hours): run roots
  under `/srv/tmp/runs` and `/srv/runs`; loose `/srv/tmp/{rc,log,cperr,runner}-*`
  and `/srv/tmp/<epoch>-<pid>*` trees from older runners; and `/tmp/tmp.*` and
  `/tmp/scratch.*`. A candidate stays when anything inside it is newer than the
  age, or when a live process has it (or a path under it) as its cwd, holds a
  file under it open, or names it in its cmdline (the live
  `leakcheck.py /tmp/scratch.X/mirror` case has its cwd somewhere else).
  Nothing outside those patterns is touched.
- Each per-suite copy still goes back the moment its suite finishes.
- **The upload is what the gate needs.** From a checkout the gate uploads
  `git ls-files -co --exclude-standard`: the tracked files as they stand on
  disk, plus untracked files git does not ignore (the uncommitted work), with
  deleted tracked files left deleted. Ignored bulk never goes up — the lead's Mac
  checkout carried 100 MB of ignored `refs/`, a 154 MB base and a 5.5 GB need
  for `-P 12` under the free-space rule, which measures `du` of the base that
  actually landed. A plain directory still goes up whole.
- **One lock for everything that decides the mount.** `/srv/tmp.mount.lock` is
  taken by the prep (bounded by `REMOTE_GATE_LOCK_WAIT_S`), by the run-dir mkdir
  that follows it, and by the image's boot wipe and mount. Without `flock` on
  the host the prep never mounts. Runs from checkouts older than #1597 do not
  take it: in the millisecond window between a prep's emptiness check and its
  mount, such a run's dir can be hidden, which that run sees as a loud 125.

Suites that write to `/tmp` by absolute path instead of `$TMPDIR` are not
confined by this. The ones found are listed in the #1597 PR as a follow-up; the
sweep and the disk alert cover them meanwhile.

## Configuration

| variable | default | what it is |
| --- | --- | --- |
| `TESTHOST_APP` | `bh-testhost-example-org` | the Fly app (org `board-builders`) |
| `TESTHOST_PORT` | `10022` | the local port `flyctl proxy` binds |
| `TESTHOST_KEY` | `$HOME/.fly/testhost-key` | the ssh key and its `-cert.pub` |
| `TESTHOST_ORG` | `board-builders` | the org that issues the certificate |
| `TESTHOST_TARGET` | unset (Fly picks) | one machine's 6PN address, passed to `flyctl proxy` as its remote host, when the app runs several and a port should pin one |
| `REMOTE_GATE_BASE` | `main` | the branch CI diffs against; `origin/<it>` goes up with the tree |
| `REMOTE_GATE_P` | `12` | suites in parallel (`-P`) |
| `REMOTE_GATE_TAIL` | `80` | log lines per suite (`--tail`) |
| `REMOTE_GATE_FULL` | `0` | print passing suites' logs too (`--full`) |
| `REMOTE_GATE_PROXY_WAIT_S` | `25` | how long to wait for the proxy's port |
| `REMOTE_GATE_CERT_MIN_H` | `2` | reissue the cert with fewer hours left than this |
| `REMOTE_GATE_SUITE_TIMEOUT` | `1500` | seconds one suite may run on the host |

The four host-side thresholds (#1597) are **settings rows**, not literals:
registered in `catalog/lanes.d/_lib.json` (lib `remote-gate`, rows
`lib.remote-gate.<env lowercased>`) and resolved by the gate on the machine that
runs it, through `bin/lib/lane-gate.sh`'s `lib_env_apply` (row, cached row, env,
registry default). The values are baked into the jobs; the host never reads a
row. A knob that resolves to something unusable is exit 125 before anything
reaches the host.

| variable | registry default | what it is |
| --- | --- | --- |
| `REMOTE_GATE_TMPFS_SIZE` | `20g` | size of the tmpfs the prep mounts on `/srv/tmp` (`<digits>[kKmMgG]` only) |
| `REMOTE_GATE_MIN_FREE_MB` | `1500` | floor of the pre-run free-space check, MB (0 = no floor) |
| `REMOTE_GATE_FREE_FACTOR` | `3` | headroom multiplier: need `copies × du(base) × this` MB (0 = the floor alone) |
| `REMOTE_GATE_SWEEP_MIN` | `30` | age in minutes before the sweep may remove litter (was a hardcoded 360). The gate also floors it **in code** at the suite cap plus a fifth (`REMOTE_GATE_SUITE_TIMEOUT` 1500 s → 30), because a caller's env bypasses the registry clamp |
| `REMOTE_GATE_LOCK_WAIT_S` | `30` | how long the prep and the run-dir mkdir wait for `/srv/tmp.mount.lock`; past it the prep warns and does not mount, so a wedged holder cannot stall every gate on the host |
| `REMOTE_GATE_CERT_ISSUE_TIMEOUT_S` | `60` | seconds `flyctl ssh issue` may run when the gate reissues its cert (TERM past it, KILL 5 s later); resolved and used on the gate's own machine, not the host (BH-1836) |

And one on the tick (lane `testhost-tick`, `bin/harness-ctl.sh set testhost-tick …`):

| variable | registry default | what it is |
| --- | --- | --- |
| `TESTHOST_DISK_ALERT_PCT` | `85` | alert `testhost-disk-<machine>` when a machine's ROOT disk is above this percent (0 = off) |

The certificate Fly issues lives at most 72 hours. The gate reissues it when the
key is missing, when the certificate cannot be read, or when it has less than
`REMOTE_GATE_CERT_MIN_H` hours left — not on every run (an API call per gate
run) and not only once it has expired (every run in the gap fails).

The reissue cannot hang the gate (BH-1836; `--overwrite` onto the live key hung
for 37 and 52 minutes on 2026-09-23). flyctl writes into a fresh temp dir beside
the key, never with `--overwrite`, with stdin on `/dev/null` and bounded by
`REMOTE_GATE_CERT_ISSUE_TIMEOUT_S`. The new key, then the cert, are moved into
place only once both exist. If the issue times out, fails, or writes nothing,
the gate keeps using the current cert while it has any time left, with one
`remote-gate: WARNING: could not reissue …` line, and exits 125 only when the
cert is missing or expired. Reissues are serialized by `flock` on
`<TESTHOST_KEY>.issue.lock`: a gate whose cert is still valid never waits for it,
and a gate with none waits at most the timeout plus 15 s, then re-reads the cert,
so concurrent gates issue once. Without `flock` (a Mac, where lead agents run
several gates at once) the same lock is a `mkdir` of `<TESTHOST_KEY>.issue.lock.d`
with the same two modes (BH-1854): unlocked, two issuers finishing together
could leave one's key beside the other's cert, a pair that reads valid for 72 h
and fails every auth. Its `owner` file holds `<pid> <epoch>`; a lock whose pid
is gone, or that is older than twice the timeout plus 15 s, is stale and reclaimed
(one `note — reclaimed a stale cert reissue lock` line). An owner line that does
not parse counts as live until the lock dir is that old, reclaims are serialized
by `<TESTHOST_KEY>.issue.lock.d.reclaim`, and INT/TERM end the gate with 130/143
after it releases the lock and signals the issue's process group (BH-1918).
The watchdog signals
the issue's whole process group, so no helper flyctl started outlives it.
flyctl's output goes through `head -c 1048576` into the temp dir, never to an
unbounded file, and the one WARNING line ends with `flyctl said: <its last
line>` (BH-5210).

### Issuing a cert by hand (BH-5210)

Never run `flyctl ssh issue` directly. Use the wrapper:

```sh
bin/issue-testhost-cert.sh [--key PATH] [--org ORG] [--hours N] [--force]
```

It defaults to `TESTHOST_KEY`, `TESTHOST_ORG` and 72 hours, and runs
`bin/remote-gate.sh --issue-cert`: the gate's own lock, temp dir, timeout row
(`REMOTE_GATE_CERT_ISSUE_TIMEOUT_S`) and process-group kill, and then it stops,
with no proxy and no job. A cert that is still fresh is left alone unless you
pass `--force`. Exit 0 means a cert is in place (issued, or still fresh), 1
means the issue failed but the current cert is still valid (one WARNING line
says why), 125 means there is no valid cert or flyctl or a knob is missing, and
2 means a bad command line.

Why it exists: on 2026-10-05 a hand issue with `--overwrite`, into a scratch
path that already held a non-fly file, looped on `File exists, but isn't a
fly.io ed25519 private key` for 44 hours into a redirect. The file reached
596 GB and filled the disk. Through the wrapper the same loop stops at 1 MiB
of output, or at the timeout. `tests/flyctl-issue-guard.bh-5210-test.sh` fails
on any doc, skill or script that spells the raw issue with `--overwrite`, or
any other script in `bin/` that runs the issue itself.

## The git context a suite sees (BH-1527)

CI checks out with `fetch-depth: 0`, so `git merge-base HEAD origin/main` and
`git diff origin/main...HEAD` work there. The upload excludes `.git`, and until
BH-1527 the host snapshotted it as a fresh one-commit repo with no `origin/main`:
every test arm that diffs the branch against main printed `no merge base`, or
diffed against nothing, and passed. #1496 was green on the host and red on CI
(`tests/priority-rank-test.sh` A10) for exactly that reason.

When `<dir>` is the top of a git checkout the gate now sends a **shallow bare
repo** beside the tree: the branch's `HEAD` and `origin/$REMOTE_GATE_BASE`, deep
enough that their merge base is inside it (about 18 MB for this repo, packed:
the blobs stay in because content diffs need them; full history is 25 MB). On the host the tree sits on that `HEAD`, detached as on CI, with
`refs/remotes/origin/main` beside it; uncommitted work in the upload is committed
on top, as the one-commit snapshot always carried it. The run prints what it
used, so a review can cite it:

```
remote-gate: git context — HEAD <sha>, base origin/main <sha>, merge base <sha>
remote-gate: host git context — HEAD <sha>, base origin/main <sha>, merge base <sha>
```

Both lines name the branch's REAL `HEAD`. When the upload carried uncommitted
work, the snapshot commit made for it on the host is labelled rather than
printed as `HEAD`, so a report never cites a sha that exists on no branch:

```
remote-gate: host git context — HEAD <sha> (+ uncommitted work as <sha>), base origin/main <sha>, merge base <sha>
```

- The base is whatever `origin/main` is in your checkout: `git fetch origin main`
  first if it is stale. No base, or no merge base (a shallow clone), is exit 125.
- When main has moved on since the branch forked, CI tests the merge and the
  host tests the branch as it stands. Three-dot diffs agree; a two-dot diff
  against `origin/main` also sees main's newer files. The run says so; rebase for
  an exact match.
- **A suite that prints `no merge base` (at the start of a line, `note:` allowed)
  fails the run whatever it exited** — in suites mode and in `--` mode. That line
  means an arm CI runs did not run here. A plain directory (not a checkout) keeps
  the old one-commit snapshot, so any such arm fails there by design.
- In `--` mode the command's **stderr comes back as stderr** and stdout stays
  clean, so `bin/remote-gate.sh . -- <cmd> 2>/dev/null` reads only the command's
  own stdout. stderr is replayed after the command finishes, so the two streams
  are correct but not interleaved; the `no merge base` rule reads both.

## Running it from the Mac

The lead's scratch wrapper (`remote-test.sh`, session-local) proxied ports
10022-10025 to four named machines of `bh-testhost-example-org` and read a session
key. `bin/remote-gate.sh` covers it with env alone:

```sh
FLY_API_TOKEN=$(cat <fly token file>) \
TESTHOST_KEY=<key whose -cert.pub sits beside it> \
TESTHOST_PORT=10023 TESTHOST_TARGET=<that machine's 6PN address> \
  bin/remote-gate.sh <worktree> tests/a.sh tests/b.sh
```

The key needs its cert beside it. Get one with
`TESTHOST_KEY=<key> bin/issue-testhost-cert.sh` (or `--key <key>`), never with a
raw `flyctl ssh issue`. The gate also reissues on its own when the cert is close
to expiry.

Leave `TESTHOST_TARGET` unset to let Fly pick a machine. What the wrapper did that
the gate does not: choose the least-loaded of its four ports on its own. Pin a
port per caller instead. The gate's other differences are deliberate: exit 125
for a run that could not happen (the wrapper said 2), runs under `/srv/tmp/runs`
(a tmpfs once the prep has mounted it), host-side cleanup, and the git context
above, which the wrapper never sent.

From a Mac session, use `bin/gate.sh` (BH-6736). `bin/gate.sh <dir> [suites…]`
calls this gate with the same arguments and returns its exit code. On rc 125 it
prints the exact `bin/gate.sh --local …` command and does not fall back by
itself. `--local` runs the tree's `bin/run-tests-in-docker.sh` under a slot
lock in `$TMPDIR/bh-gate-slots`, at most `GATE_LOCAL_SLOTS` (default 2) at once
on one machine. `--impacted` computes the suites from the diff against the
merge-base with `origin/main`. `skills/harness/SKILL.md` ("Run the gate from
the Mac") is the session-facing text.

## The lane

`bin/testhost-tick.sh` is the lane `testhost-tick`, hub cron `*/5`, registered in
`catalog/lanes.json` and gated by `lane_gate_or_exit` like every other lane:

```sh
bin/harness-ctl.sh show testhost-tick
bin/harness-ctl.sh off testhost-tick "a drain is running all night"
bin/harness-ctl.sh set testhost-tick TESTHOST_IDLE_STOP_MIN 60
```

| verb | what it does |
| --- | --- |
| `tick` (default) | report every started machine's disk (and alert above `TESTHOST_DISK_ALERT_PCT`), then stop the host once it has been idle `TESTHOST_IDLE_STOP_MIN` minutes |
| `ensure` | stamp the use and start the host if it is stopped — `bin/remote-gate.sh` calls this before connecting; `--route-until <epoch>` first holds the idle stop (below) |
| `used` | stamp the use and nothing else |
| `state` | print the machine's Fly state, change nothing |

State lives in D1 settings rows, not in a file on one box: `testhost.last_used`
(epoch), `testhost.machine_state`, and optionally `testhost.machine_id` to pin
which machine in the app the lane owns.

### The stop needs two witnesses

This is the part to understand before changing anything here.

1. **`testhost.last_used` is advisory.** It says when somebody last told us a
   run was starting. It is written by a gate run that has a worker credential,
   and a Mac does not have one — so a full Mac drain can leave that row hours
   old while sixteen suites a minute run on the host. A lane that stopped on
   that row alone would kill the drain, be restarted by the next `ensure`, and
   kill it again a window later, for ever. That is not a hypothetical: it is
   the steady state this design was reviewed into existence to avoid.
2. **The busy probe is the evidence.** Before any stop the tick asks the
   machine what is running, over `flyctl ssh console`: run roots under
   `/srv/tmp`, `/srv/tmp/runs` and `/srv/runs` with an mtime inside
   `TESTHOST_BUSY_WINDOW_MIN` (all three roots, because different runners on
   this host have used different ones), plus live `bash tests/…` and `bash -s`
   processes. Anything at all means no stop — **and the row is refreshed**, so
   the lane repairs the bookkeeping for the runners that cannot write it.

Both must agree before the machine is stopped. Every way of not knowing is
treated as busy: an unreachable worker, an unreadable machine state, a probe
that fails or answers something unparseable. The cost of not stopping is a
machine that bills until the next tick; the cost of stopping wrongly is
somebody's drain.

With **no row at all** the tick writes one and stops nothing that tick — the
clock starts, and the stop is still a full window plus a live probe away. The
older behaviour (do nothing for ever) meant the machine the lane exists to stop
was never stopped and the cost promise quietly did not happen.

`ensure` is the deliberate exception to "the worker must answer": there the
start is what a human just asked for and the stamp is only bookkeeping, so a
silent worker costs a loud warning rather than the run.

### A pool route holds the stop (BH-8659)

A pool machine reaches the host with an app-scoped SSH token
(`bin/lib/pool-testhost-route.sh`, BH-8335). That token cannot start a
machine. So before each route ship (the spawn push and the reuse refresh),
the hub runs `bin/testhost-tick.sh ensure --route-until <route expiry>` with
its own Fly credential. It writes the settings row `testhost.route_until`
(the latest route expiry, never lowered, at most the registry max of
`POOL_TESTHOST_TOKEN_HOURS` from now), then starts the host if it is stopped,
and ends with one `ensure-result: was-started|started-now|unknown|start-failed`
line. A `started-now` puts one line in `logs/fly-pool.log`; any other answer
puts one "did not confirm" line there, and the route still ships. While
`testhost.route_until` is in the future, the tick does not stop the host and
`idle` answers `0`, so `bin/fly-idle-reaper.sh` does not stop it either. A row
that cannot be read is treated as live. When the newest route has expired, the
stop needs its two witnesses again, as above. The call is bounded by
`lane.fly-pool[.<project>].pool_testhost_ensure_timeout_s` (120 s).

### A pre-minted route token (BH-8677)

The hub's `FLY_API_TOKEN` is deploy-scoped, so `flyctl tokens create ssh`
answers `Not authorized` on the hub. So `ptr_build` first reads a token that a
person minted, from `<env dir>/testhost-route.env` (`/etc/harness/env` on the
hub, as `harness_env_dir` resolves it). The file is mode 600 and has two lines:

```
TESTHOST_ROUTE_TOKEN=FlyV1 <...>
TESTHOST_ROUTE_EXPIRES=<epoch seconds>
```

Mint and install it:

1. On a workstation with org access, run
   `flyctl tokens create ssh -a bh-testhost-example-org -x 720h -n hub-testhost-route`.
2. Write the two lines to a local file. Set the expiry to the mint time plus 720 h (`date -d '+720 hours' +%s`).
3. Copy the file to the hub and install it atomically:
   `install -m 600 testhost-route.env /etc/harness/env/testhost-route.env`.

The token is one credential that every pool machine shares for up to 30 days.
Its scope is the same as a minted one: the test-host app only. The hub holds
no org token on purpose: an org token can mint for any app.

The pool ships the file's token and expiry only when the file is a regular
file (not a symlink), its mode is 600, the token starts with `FlyV1 `, and the
expiry is more than `ptr_hours` away. The last line of each key wins. A 644
file, a symlink, an expired file or a bad line is ignored, and the mint runs as
before. A mint that answers `Not authorized` writes the reason
`testhost route: not shipped (hub token cannot mint tokens; put a pre-minted token in env/testhost-route.env)`.

Rotation: when fewer than `lane.fly-pool[.<project>].pool_testhost_route_warn_hours`
(48 h) are left, or the file is expired, the pool writes one ALERTS line per
UTC day for the whole hub (`alert:pool-testhost-route-token`). The day marker
is `state/testhost-route/alerted-testhost-route-token-<YYYYmmdd>` (classed box-local in `catalog/state-paths.json`). When the alert
fires, mint a new token and replace the file with `install -m 600`, as above.
The route expiry the pool ships is the build's own window (now + `ptr_hours`),
never the file's expiry, so `--route-until` holds the test host for one build,
as a minted route does. The file's token outlives that route by design.

### One machine per run, and the could-not-run reason (BH-8725)

On fly-ssh, `bin/remote-gate.sh` sends every call to ONE test-host machine.
Before the prep it runs one probe, `flyctl ssh console -a <app> -q -C hostname`
(a Fly machine's hostname is its id), and then passes `--machine <id>` on every
`bash -s` call and in the rsync wrapper (`RG_FLY_MACHINE`). Set
`TESTHOST_MACHINE=<id>` to choose the machine yourself. A probe that prints no
machine id is exit 125, `could not pick one test-host machine`, with flyctl's
last stderr line (for example `get app: … Forbidden` for a token that cannot
read the app), and nothing is sent. Without `--machine`, flyctl writes `No machine specified, using <id> in
region <r>` on stdout. rsync reads that line as protocol bytes and stops with
`protocol version mismatch -- is your shell clean?`. A failed upload now says
`the upload to the test host failed (rsync rc <n>: <rsync's last stderr line>)`.

A could-not-run selection gate carries the runner's reason in `gate.txt`:
`why: runner-rc-125: remote-gate: <the line>`. The line is the
`pool test-host route incomplete:` line when there is one, else the last
`remote-gate:` line, cut to `SELECTION_GATE_WHY_MAX` (160) characters. The
`SELECTION-GATE rc=` line in pipeline.log and the could-not-run alert print the
same why. A pool build's record carries `gate.txt` and `gate-run.tail.txt` (the
last `SELECTION_GATE_RUN_TAIL_LINES`, 40, lines of run.txt, token lines
dropped) to the hub's `builds/pool-<project>-<KEY>-<ts>/`.

### The host run matches CI: compose, and host notes (BH-8725)

The suites job composes the git-ignored catalogs before any suite copy. CI's
`tests-shard` job runs the same three commands in the step "render the lane
registry and the llm-sites catalog the worker imports":
`bin/lanes-build.sh --write`, `bin/llm-sites-build.sh --compose` and
`bin/context-budgets-build.sh --compose`. The job (`rg_compose_catalogs`) runs
them once in `$R/base`, with `HARNESS_TEST_SANDBOX=1`, in that order. A script
the tree does not carry is skipped. On success the job prints
`remote-gate: composed the catalogs CI composes before the suites (<names>)`.
A failed compose prints one line,
`remote-gate: compose-<name> failed (rc <n>): <last line of its log>`, then
the host resources, and exits 125 with no suite run. The selection gate then
writes `why: compose-<name>: <that line>` (could-not-run, never a red). The `--`
command mode does not compose. `tests/selection-gate-host-run.bh-8725-test.sh`
H4 pins the host list to CI's step.

Some suites are red only on the test host, for a reason CI does not have. The
selection gate reads `catalog/selection-gate-host-notes.d/*.tsv` from the tree
under test, one file per ticket. A row is
`<suite path>TAB<class>TAB<ERE>TAB<reason>`. The classes are a closed set:
`shallow-context` (the host's git context is shallow, so `git log` names the
graft root) and `host-timing` (a wall-clock bound on a shared, loaded host). A
red suite moves to `noted:` only when a row names it, its run.txt section holds
at least one failure line (`FAIL` at the line start or after a space, then `:`
or a space), and every failure line in that section matches the row's ERE. A
row with another class, fewer than 4 fields or a bad ERE is skipped with one
`selection-gate: host-notes: skipped <file>:<line> (<why>)` line, and the suite
stays red. `gate.txt` gains a last line, `host-noted: <suite>=<class>,…` (or
`-`), and the pipeline.log `SELECTION-GATE rc=` line adds `host-noted=<n>`. The
notes change only the gate's record: the merge-queue batch still runs and
gates those suites, and the flaky quarantine is not touched.

### Every machine's disk (#1597)

Each tick (once the worker has answered) lists the app's machines and runs one
`df` on every **started** one over `flyctl ssh console --machine <id>`, not only
the machine the lane owns: the gate can be pinned to any of them. Each gets a
line in `logs/testhost-tick.log`:

```
disk testhost-2 (83d499a7ded448): root 87% /srv/tmp 87% (none)
```

`(none)` is `/srv/tmp`'s filesystem type when it is not a mount of its own (on
the root disk); `(tmpfs)` once the gate's prep has mounted it. A root above
`TESTHOST_DISK_ALERT_PCT` raises `testhost-disk-<name>` (warn) through
`bin/lane-alert.sh`, the lane's existing alert path, and the condition resolves
once that machine is back at or under the threshold. A stopped machine is not
probed. An answer that does not parse is logged and raises nothing.

`TESTHOST_SIZE` is reported, never applied. A machine that is not the size the
lane expects gets a line in `logs/testhost-tick.log`; resizing a machine other
agents are connected to is not a decision a `*/5` cron gets to make.

## Credentials, and what is live on merge

**The lane is live the moment the hub's cron syncs.** The hub's `env/fly.env`
already holds `FLY_API_TOKEN` and `FLY_API_TOKEN_TESTHOST`, and both see this
app, so the `*/5` tick acts from its first run. There is no "inert until
somebody mints a token" period. To hold it:

```sh
bin/harness-ctl.sh off testhost-tick "a long drain is running on the host"
bin/harness-ctl.sh on  testhost-tick
```

Token resolution is `FLY_API_TOKEN_TESTHOST`, then `FLY_API_TOKEN`, then
whatever `flyctl` session the box has — the order `bin/fly-pool-rollout.sh`
uses. From a laptop or a builder that last one is what signs the gate's own
certificate.

**Recording a run from a laptop needs a worker credential.** `HARNESS` defaults
to `/root/harness` and, when that does not exist, to the checkout the script
lives in — so a Mac will read `<checkout>/env/global.env` for `HARNESS_SECRET`
and `JOBS_URL`. Without them the run is not written to `testhost.last_used` and
the gate says so in a three-line warning. Nothing breaks: the lane's live probe
is what protects an unrecorded run, and the tick repairs the row itself. The
warning is there because a run nobody recorded used to be the difference
between "the host went away for no reason" and being told why.

## Deploying the test host image (#1597)

The image lives in the repo now: `fly/testhost/Dockerfile`, `fly/testhost/fly.toml`
and `fly/testhost/entrypoint.sh`. Before #1597 it existed only in one agent
session's scratch directory. The entrypoint wipes `/srv/tmp` and `/tmp`'s
`tmp.*`/`scratch.*` at boot (nothing can be live then) and, when the machine env
carries `REMOTE_GATE_TMPFS_SIZE`, mounts the tmpfs at boot. Without it, the
wipe alone means the first gate run after a boot finds `/srv/tmp` empty and
mounts it.

**None of this is needed for the gate-side fix.** `bin/remote-gate.sh` runs from
the caller's checkout, so the prep, the trap, `TMPDIR`, the free-space check and
the wider sweep reach every host on the first gate run after a caller has the
merge. The image only moves the mount to boot time.

Rolling the image restarts a machine, which ends every run on it. So build once,
then move one machine at a time when its busy probe says idle:

```sh
. bin/lib/gitleaks-pin.sh   # sets GITLEAKS_PIN_VERSION and GITLEAKS_PIN_SHA256 (BH-7317)
flyctl deploy -c fly/testhost/fly.toml -a bh-testhost-example-org --build-only --push \
  --image-label testhost-1617 \
  --build-arg NODE_VERSION=<the bake.node.version row> \
  --build-arg CODEGRAPH_VERSION=1.5.0 --build-arg SEMGREP_VERSION=1.176.1 \
  --build-arg ACTIONLINT_VERSION=1.7.7 \
  --build-arg GITLEAKS_VERSION="$GITLEAKS_PIN_VERSION" --build-arg GITLEAKS_SHA256="$GITLEAKS_PIN_SHA256"
# per machine, when `bin/testhost-tick.sh busy` (pinned to it) reads idle:
flyctl machine update <machine-id> -a bh-testhost-example-org \
  --image registry.fly.io/bh-testhost-example-org:testhost-1617 \
  --env REMOTE_GATE_TMPFS_SIZE=<the lib.remote-gate.remote_gate_tmpfs_size row, 20g by default> --yes
```

The gitleaks pin is not repeated here: the block sources it from
`bin/lib/gitleaks-pin.sh`, and the layer refuses a tarball with another sha256
or a binary that reports another version (BH-7317). A gitleaks pin bump in
`bin/lib/gitleaks-pin.sh` needs a test host rebuild and roll with the lines above.

`NODE_VERSION` is the `bake.node.version` settings row (BH-1617): `bin/bake-seed.sh`
on the hub prints it on its `bake.node.version=<v>` line. It is the same row
`fly/Dockerfile` bakes into the builder image, so the test hosts, the pool
builders and CI all run one node 22. `fly/testhost/node-install.sh` refuses to
build an image whose node lacks `node:sqlite` or `--experimental-strip-types`.
The other three versions are what the machines were built with on 2026-09-20.
Since BH-1741 the apt block also installs `python3-yaml`, which the
mergify-template suites need. Machines built before that change do not have it
until they are rebuilt and moved with the lines above; check with `-C "python3
-c 'import yaml'"`, which should exit 0.
Check afterwards with `flyctl ssh console -a bh-testhost-example-org --machine <id> -C
"findmnt /srv/tmp"`, which should print a `tmpfs` line, and with `-C "node
--version"`, which should print `v` plus the row's value.

## What this deliberately does not do

Point 3 of #1205 — registering the same machine as a self-hosted GitHub Actions
runner, so the PR shard jobs and the builder's gate run share one set of sixteen
cores — is **not** built here. It is the bigger win and it changes where CI runs,
which is the operator's call.

## The four things the prototype learned the hard way

1. Fly's SSH server execs argv without a shell, so the job cannot be passed as a
   command string. It travels over stdin to `bash -s`.
2. `rsync` must be `-rlptD`, not `-a`. `-a` carries ownership, and a root-owned
   tree makes git refuse the repo ("dubious ownership") inside any suite that
   isolates `HOME` — which reads as a broken branch rather than a broken upload.
3. The upload is snapshotted as a real git repo on the host, because `.git` is
   not uploaded and the `check-attr` and `git archive` suites need one.
4. `rc 127` is a missing suite, not a red one.

## Proving it, not assuming it

`tests/remote-gate-test.sh` captures the job the gate composes and **executes
it** against fixture suites, because a grep for "the job mentions xargs" passes
on a job that runs nothing — the same shape as the nine lane wirings in #1136
that every grep-based check called wired while none of them gated.
`tests/testhost-tick-test.sh` drives the real lane against a stubbed `flyctl`
and a stubbed worker. Neither suite talks to Fly.

`tests/remote-gate.bh-1597-test.sh` executes the prep and run jobs the gate
composes against fixture roots (with `mount`, `findmnt` and `df` stubbed, so
nothing is ever mounted). It kills a running job with TERM and HUP and checks
that no run dir and no suite is left. It runs a suite that `mktemp`s and checks
the caller's `TMPDIR` stays empty. It starves a run of space and checks for 125
with nothing copied or run. It pins every sweep pattern and every liveness arm
(cwd, fd, cmdline, a fresh file inside), and every tmpfs outcome.
`tests/testhost-tick.bh-1597-test.sh` runs the tick's real disk probe against a
per-machine `df` shim and pins the alert, its threshold, its resolve and the
stopped-machine skip.

Both suites are mutation-checked rather than assumed: pretending the host is
always idle, dropping the first stamp, deleting the worker-unreachable branch,
not refreshing the row on a busy host, folding the two exit codes back
together, counting a suite that never ran as a red one, dropping the unrecorded
warning and moving the runs back to the root disk each turn a specific named
assertion red.
