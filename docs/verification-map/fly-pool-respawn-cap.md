# Fly pool respawn cap / push-rejected terminal (BH-1075)

**What it is:** the part of `bin/fly-pool.sh` that decides whether a queued
ticket is allowed to spawn a Fly machine this tick. A ticket whose last pool
attempt ended in a *push rejected* (non-fast-forward) BUILD_DEFERRED is now
terminal for the pool lane, instead of being requeued and retried every tick.
New spawns are also gated on an existing open PR for the branch, a HOLD comment,
the terminal state, and a per-key spawn cap.

It exists because `BUILD_DEFERRED push of ticket/<key> rejected ...` was
re-queued like any other stand-down, so a branch that had drifted ahead on the
remote burned a new machine every two minutes until a human noticed
(BH-1075).

**How an operator reaches it:** `cron/hub.cron` `*/10` →
`bin/fly-pool-tick.sh` → one `bin/fly-pool.sh <project>` per
`flags/fly-pool-<project>`, each self-locking on `locks/fly-pool-<project>.lock`.

| region | what it does |
|---|---|
| `# >>> pool terminal / spawn cap / hold gate (BH-1075)` | `pool_spawn_decision` — HOLD, open PR, terminal state, `After:` hold (BH-5912), per-key spawn cap; `RB-*` rebase rows are exempt from all five |
| `# >>> push-rejected terminal (BH-1075)` | reaps a `BUILD_DEFERRED push of ticket/<key> rejected` as terminal instead of requeuing; since BH-6821 it first compares the built head with the remote (`bin/lib/pool-push-rejected.sh`): landed -> the hub opens the PR, diverged -> one requeue from the remote head |

There is **no UI route.** The operator surfaces are files and log lines:

- `logs/fly-pool.log` — `terminal BH-...: push rejected at <sha> — not requeued`,
  `push-rejected BH-...: landed at <sha> -> PR <url>`,
  `push-rejected BH-...: diverged -> requeue 1 from <sha>` (BH-6821),
  `skipping BH-...: HOLD`, `skipping BH-...: open PR exists`,
  `skipping BH-...: terminal head unchanged`,
  `skipping BH-...: After: <OTHER> <why> — no machine spawned; re-checked next tick` (BH-5912),
  `skipping BH-...: spawn cap reached (<n> of <cap> in <w>s) — retried after HH:MMZ, when the oldest counted spawn leaves the window`,
  `env bundle FAILED for BH-...: <the bundler's FATAL reason> — no machine spawned, job stays queued` (BH-4859),
  `terminal BH-...: reap-time head was unreadable — recording <sha>, not re-arming`,
  `terminal BH-...: an explicit human re-arm (<ts>) re-arms one attempt`,
  `RB-<pr>-<head8>: rebase row — the ticket spawn gates do not apply`.
- `state/pool/<project>/<key>.terminal` — JSON with `branch`, `head_sha`,
  `reason`, `created_at`, and `ticket_id` (BH-6821).
- `state/pool/<project>/<key>.push-diverged` — the one divergence requeue a key
  gets inside `POOL_PUSH_DIVERGE_TTL_S` (BH-6821).
- `state/pool/<project>/<key>.spawns` — one epoch timestamp per spawn that
  reached a machine and got its job (BH-4859: infra failures are never
  counted).
- `state/pool/<project>/<key>.defer-to-human` — sentinel written when the
  per-key cap is reached, so it pages once per episode. The name is legacy
  (BH-4859): nothing is deferred to a human any more.
- `state/pool/<project>/<key>.pr-noted` — sentinel preventing duplicate
  issue comments when an open PR blocks the spawn.
- `logs/ALERTS.log` — one `POOL_SPAWN_CAP_WAIT` line per key per cap episode,
  naming the HH:MMZ it spawns again (it was `POOL_DEFER_TO_HUMAN` before
  BH-4859).

**Knobs** (resolution order: D1-backed setting → env var → documented default):

| knob | resolves | default |
|---|---|---|
| max pool spawns per key per window | `pool_spawn_cap_per_key` (jobs-client setting-get) → `POOL_SPAWN_CAP_PER_KEY` → default | `2` |
| spawn-cap window in seconds | `pool_spawn_cap_window_s` (jobs-client setting-get) → `POOL_SPAWN_CAP_WINDOW_S` → default | `86400` |

**How to drive it:**

| what | how |
|---|---|
| push-rejected terminal, no requeue, build-dir sentinels | case `a:` of `HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-respawn-cap.bh-1075-test.sh` (the build-box reproduction script it was ported from is not in the repo) |
| HOLD gate, open-PR gate, terminal re-arm, spawn cap, and the non-push deferral negative case | `HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-respawn-cap.bh-1075-test.sh` |
| a pool REBASE row spawns although the PR-as-issue reads `held label-absent`, an open PR exists and the cap is spent | case `g:` of the same suite |
| the terminal skip KEEPS its queue row, and the kept row re-arms itself on the next tick's changed head | case `h:` |
| a terminal written with `head_sha=unknown` records the head instead of re-arming | case `i:` |
| harness prose does not re-arm, an explicit `RETRY` does, a negated one does not | case `j:` |
| the machine-reuse handoff runs the same gate (a terminal row is never handed to a reaped machine) | case `k:` |
| the open-PR comment goes over REST and names the PR — never `gh issue comment` (GraphQL) | case `c:` |
| bundle before spawn, its reason in the log and the row, infra exits un-recorded, the cap as a timed retry (BH-4859) | `HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-bundle-before-spawn.bh-4859-test.sh` |
| overlap / `After:` / not-before / file-overlap reaps un-record their spawn, `deferrals` still advances, wip-limit and mid-line matches still count (BH-5912) | cases `A1`-`A5` of `HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-overlap-defer-uncounted.bh-5912-test.sh` |
| a key with a live `After:` hold gets no machine, on the spawn loop and the reuse handoff; a never-deferred key is not asked (BH-5912) | cases `B1`-`B5` of the same suite (`B3` runs the real `bin/plan-after.sh`) |
| a legacy `pool spawn cap … deferred to a human` FAILED row is a resolver candidate (BH-5912) | `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-cap-park.bh-5912-test.sh` |
| determinism lint | `bin/test-determinism-lint.sh tests/fly-pool-respawn-cap.bh-1075-test.sh` |
| the gates stand down for a `gh` that cannot reach GitHub | case `f:` of the same suite — and note it only reproduces where `gh` is ON PATH, so an image without it (the repo's own `cromford-tests:trixie`) passes this vacuously |

**Preconditions / seed needs:** a project with `flags/fly-pool-<p>` AND
`flags/fly-pool-app-<p>` (the dedicated pool app), plus
`FLY_API_TOKEN_<P>` in `env/fly.env`. No new env var is required — both knobs
have documented fallbacks. Nothing to apply to a database.

**What must never regress:**

- **A push-rejected BUILD_DEFERRED must be terminal, not requeued.** Only the
  literal shape `BUILD_DEFERRED push of ticket/<key> rejected ...` is terminal;
  other deferrals (REFUSED box, ledger claim, etc.) still requeue.
- **The gates must run for every queued candidate** — HOLD, open PR,
  terminal state, `After:` hold, and spawn cap — in that order, on the spawn loop AND on
  `next_job_or_destroy`'s reuse handoff (that handoff is a build, metered like
  any other).
- **A `RB-*` rebase row is never gated.** Its `ticket_id` is a PR number, which
  `hold_check` reads as an issue and `hold_classify` answers `held label-absent`
  for; gating it stalls the merge conductor's pool-rebase lane fleet-wide. The
  reap side special-cases `RB-*` for the same reason.
- **The terminal skip keeps its queue row.** Removing it made the re-arm
  unreachable through the pool's own state — nothing here re-creates a queue
  file, so a changed head could only be noticed if the ledger watchdog happened
  to requeue the claimed row first.
- **`head_sha=unknown` is not a changed head**, and only an explicit,
  capitalised, un-negated `RETRY`/`REBUILD`/`RESUME`/`UNHOLD` comment re-arms —
  the harness's own PAT-posted comments are `user.type: "User"`.
- **The board comment is REST**, `gh api .../issues/<n>/comments -F body=@file`;
  `gh issue comment` is a GraphQL mutation on the exhausted bucket BH-709 moved
  this file off.
- **An unreadable GitHub read is a skip-this-tick, never a clear-to-spawn.**
- **Every gate read runs on the credential that can SEE the repo** — the
  BH-765 ladder (`bin/lib/gh-repo-token.sh`: app → default → admin), armed once
  per tick by `pool_slug_token_arm` and passed as the token argument into the
  applicability probe, the PR list, the branch head, the re-arm comment read and
  the comment POST. On the hub the default PAT 404s on `example-org/project-5`, so
  reading on the ambient identity turned every row of such a project into "PR
  check unreadable — will retry" on every tick, with nothing paging: a silent,
  project-wide spawn freeze. The reap-side PR verify in the same file has used
  the ladder since BH-765; the spawn gates now do too.
- **A repo no credential can see is a PAGE, not a frozen project.** When the
  ladder answers `none` there is no read to make, so the gates do not apply (the
  tick spawns as it did before BH-1075) and `gh_repo_invisible_alert` writes one
  ALERTS line per lane/repo per day naming what each rung answered.
- **The per-key cap is loaded BEFORE the reap loop**, because the reuse handoff
  in `next_job_or_destroy` runs the same decision: loaded after it, the handoff
  judged every row against the hardcoded 2/86400 instead of the operator's D1
  knob, in both directions.
- **A reuse handoff records against the cap**, on the same rule as `spawn_one`.
  `RB-*` rows record on neither path.
- **A removed queue file closes its ledger row** (`QROW failed`) on the open-PR
  arm and the reap's push-rejected terminal — a deleted file over a
  still-`claimed` row is two views of one row disagreeing until the watchdog
  requeues the claim into the same refusal.
- **The cap arm keeps its row queued** (BH-4859). No `QROW failed`, no
  `rm -f` of the queue file: the cap is a window timer and the row spawns again
  when the oldest counted entry ages out. Closing it `failed … deferred to a
  human` was a park no lane ever read.
- **The env bundle runs before `fly machine run`** (BH-4859), after the queue
  claim. A bundle failure buys no machine, records no spawn, removes the
  `/dev/shm` bundle dir and hands the row back queued with
  `env bundle failed: <reason>`.
- **A `held closed` / `held label-absent` verdict parks the row** instead of
  retrying it for ever: nothing in the pool's own state can ever lift either.
- **An overlap or `After:` deferral is not charged to the cap** (BH-5912). The
  reap un-records the spawn for the four `bin/lib/rb/gates.sh` shapes
  `BUILD_DEFERRED OVERLAP_DEFER …`, `After: …`, `plan overlap not-before …`
  and `file overlap …`, matched on the prefix only. Every other deferral
  (wip-limit, busy slots, stack-wait, push rejected) still counts. The
  deferral still advances `deferrals`, so `DEFER_MAX` bounds the loop.
- **A live `After:` hold spawns no machine** (BH-5912). Only for a row with
  `deferrals` > 0, and only on `bin/plan-after.sh check` rc 3 with output. The
  row stays queued with no QROW and no ALERTS line. Any other answer spawns.
- **The per-key cap counts only spawns that reached a build**, and ignores
  timestamps outside the configured window. Every infra exit after the record
  (no machine id, harness sync failed, env/job push failed) calls
  `pool_spawn_cap_unrecord` with its own timestamp (BH-4859), as the BH-1279
  refused-claim reap does.
- **The cache must be per-tick and per-key:** duplicate queue rows for one key
  must not produce duplicate REST calls.
- **Not configured is not unreadable.** All four gates read GitHub, so the gates
  apply only when there is a repo to read and a client that can reach it:
  `pool_gates_applicable` wants a `owner/repo` in `fleet.conf`, `gh` on PATH,
  and one cached probe read per tick that comes back with an HTTP status line at
  all. Any of those missing and the tick spawns exactly as it did before
  BH-1075, with one line saying so. A read that WAS made and came back 403 or
  404 still fails closed — that is the review fix, and it stays. Collapsing the
  two froze every spawn on any slug-less project
  (`tests/pool-autoscale-test.sh`, 12 of 29 red) and then, once a slug was
  present but the client was not logged in, every spawn on a configured one
  (`tests/gh-token-rotate-test.sh` on CI, 54 of 60).
