# Pool supervisor off the hub: measured inventory and plan (BH-6896, part of #6881)

This note is a plan. It changes no code, no cron, no catalog and no schema.
No ticket was filed from it. Filing the slices below waits for approval.

## Summary

- Target for the later slices: hub runnable share of the pool supervisor from 19 percent to under 2 percent.
- One tick of `bin/fly-pool.sh` for one project costs 1.26 CPU s and 768 forks when there is nothing to do (median of 3 projects, 5 runs each, on a copy).
- Each reaped machine adds 1.22 CPU s, 761 forks and 30 Fly calls. 28 of the 30 calls pull one artifact file each.
- Each spawned job adds 2.15 CPU s, 796 forks, 7.3 Fly calls, 4.7 GitHub calls, one `ssh` to the owning box and a 20 s `sleep`. Each spawn also pushes a 6.49 MB harness tarball.
- At 13 projects and 6 ticks an hour, the hub spends 98 CPU s/h on the supervisor with zero builds, 142 at 13 builds/h and 360 at 78 builds/h. These are shell CPU only. `flyctl` CPU comes on top of them (see Limits).
- Option (a), one `lane_runs` row per project, leaves 3.5 to 5.1 CPU s/h on the hub. The modeled share is 0.3 to 0.8 percent. Option (a) reaches the target by itself.
- Option (b), the wait moves into the build machine, leaves 86 to 145 CPU s/h on the hub. The modeled share is 8.6 to 17.1 percent. Option (b) does not reach the target by itself, because the per-tick base of 1.11 CPU s stays on the hub.
- Recommendation: a mix. S1 is a quick win. S2 and S3 are the option (b) parts: they shrink the work. S4 and S5 are option (a): they move the rest off the hub. Each slice below has its metric.
- Quick win found: every tick sources `bin/lib/merge-conductor-lib.sh` (bin/fly-pool.sh:433-434). That costs 0.27 CPU s and 230 forks per tick. Only the REBASED reap arm (bin/fly-pool.sh:3156) uses it.

## Method

Host. The measurements ran on a Fly pool build machine, `pool-cromford-e820359b103668`, with 8 vCPU. They did not run on the hub. Absolute CPU and wall values are values for this machine, not for the hub. The ratios between options are what the plan uses.

The copy. `/tmp/bh6896-measure/bin/setup.sh` builds one scratch harness per project under `/tmp/bh6896-measure/<project>/h`. It uses the shape of tests/fly-pool-sibling-serial.bh-6374-test.sh and installs the real `bin/fly-pool.sh` closure with `scratch_install_closure`. The fleet.conf row, the Fly token, the GitHub token and the App key are fixtures. The box address is RFC 5737 (`192.0.2.10`). No real env file was copied. Every run used `env -i` and `HARNESS` under `/tmp`, so nothing from this machine's environment reached the tick. `run.sh` refuses a `HARNESS` outside `/tmp/bh6896-measure/`.

The shims. One script, `countshim`, is first on `PATH` as `fly`, `flyctl`, `gh`, `curl`, `ssh` and `sleep`. Each call appends `<tool> TAB <verb> TAB <detail>` to `calls.tsv` and gets a canned answer. No shim opens a network connection. Proof, run first: `curl -s https://example.com` through the shim printed `{}` with rc 0 and logged `curl example.com`. The real site answers HTML. `sleep` records its seconds and returns at once. The source is in Appendix A.

Fixture states, per project:

- idle: 0 queued jobs, 0 machines.
- reap: 2 tracked machines. Each answers `PR_CREATED` and `BUILD_DIR:` from `/run/harness/RESULT`, so the reap pulls every artifact and destroys the machine.
- spawn: 3 queued jobs, 0 machines. Each job passes the HOLD, open-PR and push-rejected gates (the issue has the `ai-build` label, no PR is open and no branch exists). Each job gets a machine.
- spawn-reaponly: the spawn fixture with `POOL_SPAWN=0` (bin/fly-pool.sh:4028). Spawn cost = spawn run minus spawn-reaponly run, divided by 3 jobs.

Projects: cromford, harness-console and project-5, each with its real repo slug.

Per run: wall is the `date +%s.%N` delta. CPU is user + sys of the whole waited process tree, from bash `times` (this machine has no `/usr/bin/time`). Forks are the `processes` line of `/proc/stat` before and after. Calls come from `calls.tsv`. Each state had 1 warm-up run and 5 measured runs. The warm-up fills the App token cache, as on a hub in steady state.

Noise floor. This machine forked 427 times in a 10 s window with no run, which is 42.7 forks/s. The fork values in the derived tables subtract 42.7 x wall. The raw table keeps the raw values.

Configuration: no jobs worker is configured (`JOBS_URL` unset). Every row read falls back to its file, as on a hub with an unreachable worker. A second pass with `JOBS_URL=https://jobs.fixture.invalid` counted the worker calls a tick makes: 10 for idle, 16 for reap and 27 for spawn. The shim answers `{}`, which the client reads as an outage, so that pass is a call count only, not a cost.

The file trace. This machine has no `strace`. `/tmp/bh6896-measure/bin/trace.sh` stamps a marker after the fixture reset, runs one tick and lists every file under the scratch tree newer than the marker, per state and per project. That shows every write. It does not show a read. The reads in the table come from the source.

## 1. Read/write inventory

The index does not parse shell (`codegraph node` on the tick wrapper answers "No indexed file matches"), so this table comes from the source by grep. The file trace confirms it, see below. A path pattern cell is a glob: `<x>` is any text. Columns (a) and (b) say how the path moves under each option. `.ro` = in a snapshot to the machine. `.rw` = in a write-back to the hub. `@rows` = moves to a D1 row. `jobs API` = a call to the worker.

| path pattern | group | R/W | access sites (file:line) | owner | option (a) | option (b) |
|---|---|---|---|---|---|---|
| `state/build-queue/<p>/<KEY>.json` | build queue | R/W | bin/fly-pool.sh:189, bin/fly-pool.sh:4052, bin/fly-pool.sh:4614, bin/fly-pool.sh:3349, bin/fly-pool.sh:1634, bin/fly-pool.sh:2759 | run-build.sh enqueue, hub materialise | .ro; `queue_list` rows stay primary | stays (hub): the hub decides the spawn |
| `state/build-queue/<p>/<KEY>.failed.json` | build queue | W | bin/fly-pool.sh:3869, bin/fly-pool.sh:4052 | the pool (death park, rows off) | @rows (`QROW failed`) | stays (hub) |
| `state/build-queue/<p>/.<KEY>.dispatched` | build queue | W | bin/fly-pool.sh:4518 | the pool (consume on spawn) | @rows (`queue_claim`) | goes away |
| `state/build-queue/<p>/<KEY>.json.bad` | build queue | W | bin/fly-pool.sh:4638 | the pool (malformed entry) | @rows (`QROW failed`) | stays (hub) |
| `<tmp>/poolq-<p>.<x>/*` (rows queue scratch) | build queue | R/W | bin/fly-pool.sh:344, bin/fly-pool.sh:358, bin/fly-pool.sh:361 | the pool, from `queue_list` | jobs API | stays (hub) |
| `state/fly-pool/<p>/<machine>.json` | fly | R/W | bin/fly-pool.sh:153, bin/fly-pool.sh:2920, bin/fly-pool.sh:4541, bin/fly-pool.sh:2776, bin/fly-pool.sh:2819, bin/fly-pool.sh:3827 | the pool (one record per machine) | .ro + .rw, after each spawn (see failure modes) | stays (hub) |
| `state/fly-pool/<p>/.<machine>.snapmt` | fly | R/W | bin/fly-pool.sh:3792, bin/fly-pool.sh:3795, bin/fly-pool.sh:4512 | the pool (deploy snapshot mtime) | .rw | entrypoint |
| `state/fly-pool/<p>/.sweep.json` | fly | W | bin/fly-pool.sh:3897, bin/fly-pool.sh:3900, bin/fly-pool.sh:4007 | the pool (orphan sweep summary) | .rw | stays (hub) |
| `state/fly-pool/legacy-caps.<p>` | fly | R/W | bin/fly-pool-tick.sh:55, bin/fly-pool-tick.sh:58 | the tick wrapper (one-shot) | stays (hub tick) | stays (hub tick) |
| `state/fly/<p>.json` | fly | R/W | bin/fly-pool.sh:78, bin/fly-pool-tick.sh:80 | fly onboard; the tick retires the builder record | .ro | stays (hub) |
| `state/fly/<p>.image` | fly | R | bin/fly-pool.sh:4118 | image bake lane | .ro, or the `fly_images` row (BH-2523) | stays (hub) |
| `fly/pool-caps.conf` | fly | R | bin/fly-pool.sh:43, bin/pool-cap.sh:82 | operator (in git) | .ro | stays (hub) |
| `fly/account-capacity.conf` | fly | R | bin/fly-pool.sh:494, bin/lib/pool-account.sh:141 | operator (in git) | .ro | stays (hub) |
| `fly/onboard-queue.conf` | fly | R | bin/fly-pool-tick.sh:140 | operator (in git) | stays (hub tick) | stays (hub tick) |
| `state/pool/<p>/<KEY>.spawns` | state | R/W | bin/fly-pool.sh:1088, bin/fly-pool.sh:1094, bin/fly-pool.sh:1119, bin/fly-pool.sh:1035, bin/fly-pool.sh:1063, bin/fly-pool.sh:1074 | the pool (per-key spawn cap) | @rows (`psr_spawn_add`) | stays (hub) |
| `state/pool/<p>/<KEY>.terminal` `state/pool/<p>/<KEY>.terminal-<x>` | state | R/W | bin/fly-pool.sh:693, bin/fly-pool.sh:699, bin/fly-pool.sh:1150, bin/fly-pool.sh:1200, bin/fly-pool.sh:1405, bin/fly-pool.sh:1421 | the pool (terminal verdict) | @rows (`psr_terminal_*`) | stays (hub) |
| `state/pool/<p>/<KEY>.held` `state/pool/<p>/<KEY>.hold-noted` | state | R/W | bin/fly-pool.sh:1275, bin/fly-pool.sh:1290, bin/fly-pool.sh:1304, bin/fly-pool.sh:1346, bin/fly-pool.sh:1383 | the pool (HOLD gate) | @rows (`psr_hold_put`) | stays (hub) |
| `state/pool/<p>/<KEY>.pr-noted` | state | W | bin/fly-pool.sh:1431, bin/fly-pool.sh:1447 | the pool (once marker) | .rw | stays (hub) |
| `state/pool/<p>/<KEY>.defer-to-human` | state | R/W | bin/fly-pool.sh:1885, bin/fly-pool.sh:1888, bin/fly-pool.sh:1897 | the pool (spawn cap wait) | .rw | stays (hub) |
| `state/pool/<p>/_spawn-hold` | state | R/W | bin/fly-pool.sh:248, bin/fly-pool.sh:260, bin/fly-pool.sh:273 | the pool (lane failure hold) | @rows | stays (hub) |
| `state/pool/<p>/<KEY>.after-<x>` | state | R/W | bin/fly-pool.sh:1511, bin/fly-pool.sh:1520, bin/fly-pool.sh:1581, bin/fly-pool.sh:1609, bin/fly-pool.sh:1635 | the pool (After: gate, BH-5967) | .rw | stays (hub) |
| `state/pool/<p>/hold-cache/<n>.json` | state | R/W | bin/fly-pool.sh:959, bin/fly-pool.sh:974 | the pool (hold cache, BH-6549) | machine-local cache | stays (hub) |
| `state/remote-results/<p>/<KEY>.json` | state | R/W | bin/fly-pool.sh:3579, bin/fly-pool.sh:3587, bin/fly-pool.sh:2352, bin/fly-pool.sh:2421, bin/fly-pool.sh:2526 | the pool (parked result) | .rw | goes away: the machine writes its result row |
| `state/build-notes/<p>/<KEY>.md` `state/build-notes/<p>/<KEY>.md.relayed-<ts>` | state | R/W | bin/fly-pool.sh:2168, bin/fly-pool.sh:2173, bin/fly-pool.sh:2177 | adjudication, re-plan | .ro + .rw, or the `build_note` row (BH-5003) | entrypoint reads the row |
| `state/preplan-files/<p>-<KEY>` | state | R | bin/fly-pool.sh:2136, bin/fly-pool.sh:2138 | overlap guard | .ro | entrypoint |
| `state/vercel-deploys/<p>.json` | state | R | bin/fly-pool.sh:3789, bin/fly-pool.sh:4510 | deploy snapshot lane | .ro | entrypoint |
| `state/auth-accounts.local.json` | state | R | bin/fly-pool.sh:4483 | operator | .ro | stays (hub) |
| `state/quota/<x>` | state | R/W | bin/fly-pool.sh:4438, bin/fly-pool.sh:2831, bin/lib/pool-account.sh:135, bin/lib/pool-account.sh:342 | the pool, fleet cooldown | @rows (leases are fleet-wide) | stays (hub) |
| `state/fly-cost/ledger.tsv` `state/fly-cost/ledger.tsv.lock` | state | R/W | bin/fly-pool.sh:2043, bin/lib/fly-cost-row.sh:104 | the pool (cost row, BH-4019) | @rows | entrypoint |
| `state/pool-tailnet/<box>.fails` | state | R/W | bin/fly-pool.sh:4198, bin/lib/pool-tailnet.sh:27 | the pool (env bundle failures) | .rw | goes away (no bundle on the hub) |
| `state/sibling-serial/<p>/<KEY>.sibling-since` | state | R/W | bin/fly-pool.sh:1722, bin/fly-pool.sh:1724, bin/sibling-serial.sh:632 | sibling-serial.sh (box-local) | machine-local | stays (hub) |
| `state/overlap-after/<p>/<x>` | state | R | bin/fly-pool.sh:1857, bin/plan-after.sh:81 | plan-after.sh | .ro | stays (hub) |
| `state/lane-gate/<x>.json` `state/lane-gate/.post-miss` `state/lane-gate/.settings-miss` | state | R/W | bin/lib/lane-gate.sh:159, bin/lib/lane-gate.sh:174, bin/lib/lane-gate.sh:329, bin/lib/lane-gate.sh:756 | lane-gate lib (pause and settings cache) | machine-local cache | stays (hub) |
| `state/gh-app-tokens/<owner>-<repo>.json` `state/gh-app-installations.json` | state | R/W | bin/gh-token.sh:133, bin/gh-token.sh:134, bin/fly-pool.sh:611 | gh-token.sh (App token cache) | machine-local; needs the App key on the machine | stays (hub) for the gates |
| `state/gh-rest-ledger/<day>T<hh>.tsv` | state | W | bin/lib/gh-rest-ledger.sh:84, bin/lib/gh-rest-ledger.sh:330 | gh-rest lib (REST quota ledger) | machine-local | stays (hub) |
| other lib state: `state/dispatch-mode/<x>` `state/hotfix-announced/<x>` `state/hold-ambiguous/<x>` `state/model-routes/<x>` `state/alert-line-sent/<x>` `state/blind-list/<x>` | state | R/W | bin/fly-pool.sh:167, bin/fly-pool.sh:100, bin/fly-pool.sh:447, bin/fly-pool.sh:4588, bin/fly-pool.sh:477 | the sourced libs | machine-local caches | stays (hub) |
| `builds/pool-<p>-<KEY>-<ts>/<x>` | builds | R/W | bin/fly-pool.sh:3041, bin/fly-pool.sh:3086, bin/fly-pool.sh:3103, bin/fly-pool.sh:3720, bin/fly-pool.sh:2382, bin/fly-pool.sh:2473 | the pool (reap pulls the artifacts) | .rw (the merge gate reads hub build dirs) | the machine pushes its record through the jobs API |
| `plans/<p>-<KEY>/<x>` | plans | R | bin/fly-pool.sh:2082, bin/fly-pool.sh:2091, bin/fly-pool.sh:2103, bin/fly-pool.sh:2106 | preplan lane | .ro, or `preplan_fetch` (the fallback at 2091) | entrypoint runs `preplan_fetch` |
| `locks/fly-pool-<p>.lock` | locks | W | bin/fly-pool.sh:138, bin/fly-pool.sh:146, bin/fly-pool-tick.sh:34 | the pool (dedupe flock, fd 8) | jobs API: `lane_runs_live` replaces the flock | stays (hub) |
| `locks/gh-app-token-<owner>-<repo>.lock` | locks | W | bin/gh-token.sh:417, bin/gh-token.sh:857 | gh-token.sh (mint lock) | machine-local | stays (hub) |
| `flags/fly-pool-<p>` | flags | R/W | bin/fly-pool.sh:36, bin/fly-pool.sh:37, bin/fly-pool-tick.sh:59, bin/fly-pool-tick.sh:99, bin/pool-cap.sh:81 | operator, rollout | .ro, or the routing row | stays (hub) |
| `flags/fly-pool-app-<p>` | flags | R | bin/fly-pool.sh:184 | operator, `routing_pool_app` | .ro | stays (hub) |
| `flags/paused-<p>` `flags/pool-halt-<p>` | flags | R | bin/fly-pool.sh:4073, bin/fly-pool.sh:4101 | operator | @rows (pause and routing rows) | stays (hub) |
| `flags/all-off` `flags/lane-off-fly-pool-<p>` `flags/hotfix-lane-off` `flags/dispatch-mode-<p>` `flags/pool-account-routing-off` | flags | R | bin/fly-pool.sh:60, bin/fly-pool.sh:68, bin/fly-pool.sh:100, bin/fly-pool.sh:167, bin/fly-pool.sh:494 | operator, harness-ctl.sh | @rows (the `pause_flags` row lane-gate reads) | stays (hub) |
| `flags/alerted-pool-<x>-<p>-<date>` `flags/alerted-gh-app-profile-owner-<x>` `flags/alerted-extra-read-missing-<x>` | flags | R/W | bin/fly-pool.sh:599, bin/fly-pool.sh:1984, bin/fly-pool.sh:2873, bin/fly-pool.sh:3682, bin/fly-pool.sh:3990, bin/fly-pool.sh:4346 | the pool (once-a-day alert markers) | .rw, or alert dedupe in the jobs API | stays (hub) |
| `flags/alerted-model-route-<role>-<p>-<date>` | flags | R/W | bin/lib/model-route.sh:93, bin/fly-pool.sh:4588 | model-route lib (spawn bundle) | machine-local | entrypoint |
| `flags/alerted-jobs-client-<date>` `flags/alerted-jobs-not-configured-<date>` | flags | R/W | bin/lib/jobs/req.sh:91, bin/lib/jobs/req.sh:116 | jobs client | machine-local | stays (hub) |
| `flags/alerted-verdict-window-<date>` | flags | R/W | bin/lib/verdict-parse.sh:106 | verdict-parse lib | machine-local | stays (hub) |
| `flags/alerted-fly-onboard-gaveup-<p>` `state/fly-onboard/<p>.<x>` | flags | R/W | bin/fly-pool-tick.sh:187, bin/fly-pool-tick.sh:190, bin/fly-pool-tick.sh:219, bin/fly-pool-tick.sh:225 | the tick wrapper (onboard drain) | stays (hub tick) | stays (hub tick) |
| `logs/fly-pool.log` | logs | W | bin/fly-pool.sh:81, bin/fly-pool.sh:87, bin/fly-pool.sh:4191, bin/fly-pool-tick.sh:60, bin/fly-pool-tick.sh:92 | the pool and the tick | .rw (log bytes appended on apply) | stays (hub) |
| `logs/ALERTS.log` `logs/alerts-state.log` | logs | W | bin/fly-pool.sh:601, bin/fly-pool.sh:1404, bin/fly-pool.sh:3356, bin/alert-line.sh:87, bin/lib/alert-state.sh:189 | the pool, 31 `alert-line.sh` sites | jobs API (the alert beat) | stays (hub) |
| `logs/gh-rate.log` `logs/gh-calls/<date><hh>.log` | logs | W | bin/gh-token.sh:135, bin/lib/gh-limit-logger.sh:81, bin/fly-pool.sh:444 | gh-token.sh, gh-limit-logger lib | machine-local | stays (hub) |
| `logs/jobs-client.log` | logs | W | bin/lib/jobs/req.sh:78 | jobs client (outage lines) | machine-local | stays (hub) |
| `logs/lane-gate.log` `logs/fly-onboard.log` `logs/fly-image-build.log` `logs/remediation.log` | logs | W | bin/fly-pool.sh:60, bin/fly-pool.sh:102, bin/fly-pool.sh:2799, bin/fly-pool-tick.sh:229 | lane-gate, fly-image-row, beat.sh, the tick | machine-local | stays (hub) |
| `env/fly.env` `env/global.env` | env | R | bin/fly-pool.sh:51, bin/fly-pool.sh:76, bin/fly-pool.sh:77 | operator (/etc/harness/env) | .ro secret: every pool app token on the lane app | stays (hub) |
| `env/<p>.env` (through the env bundle) | env | R | bin/fly-pool.sh:4191, bin/fly-envbundle.sh:102, bin/fly-envbundle.sh:122 | operator, on the owning box over ssh | .ro secret, plus tailnet ssh from the lane machine | entrypoint (Fly secrets or a jobs API mint) |
| `env/github-app.env` `env/github-app-<profile>.env` `env/github-app.pem` `env/gh-pat` | env | R | bin/fly-pool.sh:545, bin/fly-pool.sh:570, bin/fly-pool.sh:611, bin/fly-pool.sh:4292, bin/lib/gh-app-auth.sh:57, bin/lib/gh-repo-token.sh:97 | operator | .ro secret: the App key on the lane app | stays (hub): the hub mints, or a jobs API mint |
| `env/tokens.d/<x>` | env | R | bin/fly-pool.sh:4438, bin/lib/pool-account.sh:133 | operator (Claude account tokens) | .ro secret | stays (hub) |
| `fleet.conf` | other | R | bin/fly-pool.sh:531, bin/fly-pool.sh:2416, bin/fly-pool.sh:2523, bin/fly-envbundle.sh:82 | operator (in git) | .ro | stays (hub) |
| `/root/harness-checkout/<x>` (tarball source) | other | R | bin/fly-pool.sh:4236, bin/fly-pool.sh:4238, bin/fly-pool.sh:4240 | fleet propagate | .ro | goes away: the image or a git fetch carries the harness |
| owner box over ssh: `root@<box>:/root/harness/state/merge-queue/<p>/<pr>` and `.../state/remote-results/<p>/<KEY>.json` | other | W | bin/fly-pool.sh:2311, bin/fly-pool.sh:2342, bin/fly-pool.sh:2347, bin/fly-pool.sh:3733 | the pool (ssh relay fallback) | jobs API (the lane machine has no tailnet) | goes away (the machine writes rows) |

### Trace confirmation

The find-newer trace over 9 ticks (3 projects x 3 states) touched 65 distinct paths after normalisation (`/tmp/bh6896-measure/trace-paths.txt`). Every one matches a row above. The check loop is in Appendix C and printed nothing. The trace found 16 paths the first grep pass missed: the lane-gate cache, the gh-rest ledger, the gh-calls log, the jobs-client log and flag, the model-route alert flags, the verdict-window flag, `alerts-state.log`, the App token lock and `ledger.tsv.lock`. All of them are written by sourced libs, not by bin/fly-pool.sh itself. They are in the table now.

Rows that no fixture reached: the death park (`.failed.json`), the malformed entry, `.snapmt`, the HOLD and After: markers, `.defer-to-human`, `_spawn-hold`, the hold cache, build notes, preplan files, the deploy snapshot, `state/quota`, `pool-tailnet`, the sibling clock and the owner-box ssh relay. They come from the source only.

### Catalog cross-check

`catalog/state-paths.json` has 15 rows. Six of them touch the pool: `pool`, `fly-pool`, `build-queue`, `build-notes`, `sibling-serial` and `merge-queue` (written on the owner box, bin/fly-pool.sh:2311).

Disagreements:

1. The pool writes `state/` paths with no catalog row: `remote-results/`, `fly/<p>.json` and `.image`, `fly-cost/`, `quota/`, `pool-tailnet/`, `preplan-files/`, `auth-accounts.local.json`, `vercel-deploys/`, `overlap-after/`, `fly-onboard/`, `lane-gate/`, `gh-app-tokens/` and `gh-rest-ledger/`.
2. The `pool` row names `*.spawns`, `*.held` and `_spawn-hold` only. The pool also writes `*.terminal`, `*.terminal-noted`, `*.terminal-alerted`, `*.hold-noted`, `*.pr-noted`, `*.defer-to-human`, `*.after-*` and `hold-cache/`. Only `.terminal` has a row twin.
3. The `fly-pool` row covers `<machine>.json`. It does not cover `.<machine>.snapmt`, `.sweep.json` or `legacy-caps.<p>`.
4. The `build-queue` row says `rows`. With `ROWS_ONLY=0` the pool still writes `<KEY>.json`, `.failed.json`, `.<KEY>.dispatched` and `.json.bad` there (bin/fly-pool.sh:3349, 3869, 4518, 4638).

Slice S4 must close items 1 to 4 before option (a), because a path with no catalog row has no snapshot class.

### Outbound call sites (bin/fly-pool.sh)

| kind | sites |
|---|---|
| Fly, direct | `agent start` bin/fly-pool.sh:137; `machine run` bin/fly-pool.sh:4216; `machines list` bin/fly-pool.sh:2855, bin/fly-pool.sh:4109; `machine status` bin/fly-pool.sh:2993; `machine destroy` bin/fly-pool.sh:1972, bin/fly-pool.sh:2815; `ssh sftp put` bin/fly-pool.sh:4243 |
| Fly, `ssh console` | `mexec` bin/fly-pool.sh:1942 (11 callers); `mput` bin/fly-pool.sh:1945 (18 callers, base64 through the console) |
| GitHub | `gh api -i` bin/fly-pool.sh:683, bin/fly-pool.sh:684; comment reads bin/fly-pool.sh:1003, bin/fly-pool.sh:1005; comment posts bin/fly-pool.sh:1345, bin/fly-pool.sh:1420, bin/fly-pool.sh:1446; `gh_rest` bin/fly-pool.sh:3509, bin/fly-pool.sh:3525; App mint through `pool_gh_token` bin/fly-pool.sh:611 |
| ssh to an owner box | env bundle bin/fly-envbundle.sh:133; relay bin/fly-pool.sh:2311, bin/fly-pool.sh:2342, bin/fly-pool.sh:2347 |
| sleep and wait | `sleep 20` bin/fly-pool.sh:4230 (one per spawn); `wait` bin/fly-pool.sh:4695 (joins the spawn subshells) |

## 2. Per-tick measurements

### Raw, per project and state (median of 5 runs, max in brackets)

forks here are raw `/proc/stat` deltas, noise included. gh_calls counts `gh` and `curl` to api.github.com. fly_calls counts `fly`, `flyctl` and `curl` to the Machines API.

| project | state | wall_s | cpu_s | forks | gh_calls | fly_calls | sleep_s |
|---|---|---|---|---|---|---|---|
| cromford | idle | 1.13 (1.14) | 1.25 (1.26) | 831 (912) | 1 | 2 | 0 |
| cromford | reap | 3.28 (3.45) | 3.77 (3.98) | 2469 (2788) | 1 | 62 | 0 |
| cromford | spawn | 4.15 (4.23) | 7.39 (7.81) | 3359 (3386) | 15 | 24 | 60 |
| cromford | spawn-reaponly | 1.03 (1.15) | 1.13 (1.27) | 794 (902) | 1 | 2 | 0 |
| harness-console | idle | 1.16 (1.20) | 1.28 (1.32) | 809 (1127) | 1 | 2 | 0 |
| harness-console | reap | 3.14 (3.37) | 3.63 (3.88) | 2384 (2463) | 1 | 62 | 0 |
| harness-console | spawn | 4.23 (4.35) | 7.68 (7.71) | 3294 (3375) | 15 | 24 | 60 |
| harness-console | spawn-reaponly | 1.06 (1.13) | 1.18 (1.24) | 794 (901) | 1 | 2 | 0 |
| project-5 | idle | 1.12 (1.16) | 1.24 (1.28) | 809 (809) | 1 | 2 | 0 |
| project-5 | reap | 3.20 (3.51) | 3.67 (4.04) | 2390 (2463) | 1 | 62 | 0 |
| project-5 | spawn | 4.22 (4.54) | 7.56 (7.94) | 3294 (3401) | 15 | 24 | 60 |
| project-5 | spawn-reaponly | 0.92 (1.01) | 1.01 (1.11) | 794 (795) | 1 | 2 | 0 |

The spawn state also made 3 `ssh` calls to the owning box (one env bundle per job) in every run. All 15 measured spawn runs made 15 GitHub calls. One extra cromford spawn run, made later for the call mix below, made 17: two `curl` calls minted a new App token.

One raw line per project, from `/tmp/bh6896-measure/runs.tsv` (project, state, wall_s, cpu_s, forks, gh_calls, fly_calls, sleep_s, box_ssh, other_curl):

```
cromford	spawn	3.94	7.06	3383	15	24	60	3	0
harness-console	spawn	4.33	7.68	3294	15	24	60	3	0
project-5	spawn	4.26	7.50	3294	15	24	60	3	0
```

Call mix of one cromford reap tick (2 machines): 56 `ssh console` artifact pulls, 2 `ssh console` RESULT reads, 2 `machine destroy`, 1 `machines list`, 1 `agent start`, 1 `gh api repos/<slug>`.

Call mix of one cromford spawn tick (3 jobs): 12 `ssh console` file pushes (`mput`), 3 `ssh console` exec, 3 `ssh sftp` (the harness tarball), 3 `machine run`, 2 `machines list`, 1 `agent start`, 3 `sleep 20`, 3 `ssh root@<box>` (env bundle). GitHub: 8 `gh api -i` (repo probe, issue list, pulls and branches per job), 3 paginated comment reads, 3 issue reads, 1 repo read.

### Derived unit costs (mean of the 3 project medians, forks net of 42.7/s)

| unit | cpu_s | forks | gh_calls | fly_calls | other |
|---|---|---|---|---|---|
| tick base, nothing to do | 1.26 | 768 | 1 | 2 | 1.14 s wall |
| tick base with `POOL_SPAWN=0` | 1.11 | 752 | 1 | 2 | |
| per reaped machine | 1.22 | 761 | 0 | 30 | |
| per spawned job | 2.15 | 796 | 4.67 | 7.33 | 20 s sleep, 1 box ssh, 6.49 MB pushed |
| per spawned job, up to and including `machine run` | 0.74 | 410 | 3.67 | 1.33 | the 1.33 includes the per-tick image lookup (bin/fly-pool.sh:4109) |
| per spawned job, after `machine run` | 1.40 | 385 | 1.00 | 6.00 | |

The split at `machine run` comes from a sixth variant: the `fly` shim fails `machine run` (`BH_FAIL_RUN=1`), so `spawn_one` stops at bin/fly-pool.sh:4221 ("machine run FAILED", 3 lines in fly-pool.log per run). Median 3.34 CPU s for 3 jobs.

Component costs, 5 runs each, median (`/tmp/bh6896-measure/components.tsv`):

| component | cpu_s | forks | note |
|---|---|---|---|
| harness tarball, bin/fly-pool.sh:4240 | 0.73 | 11 | 6,492,558 bytes, from a checkout of this branch |
| env bundle, bin/fly-pool.sh:4191 | 0.03 | 31 | `ssh` shimmed: no ssh crypto in this number |
| one `lane_runs` row, one process (`lp_enqueue`) | 0.04 | 31 | option (a) per project |
| 13 `lane_runs` rows, one process | 0.33 | 284 | option (a) with the #6881 S7 batch shape: 0.025 CPU s per row |
| snapshot publish proxy: tar + base64 + jq + 2 `curl` | 0.02 | 18 | 997 bytes for the fixture inputs; a lower bound for the BH-6128 publisher |
| `. bin/lib/merge-conductor-lib.sh` alone | 0.27 | 230 | 0.20 user + 0.065 sys |
| bin/fly-pool.sh up to line 79 (env, lane gate) | 0.15 | 137 | measured with no `state/fly/<p>.json` |

Where the idle base goes (one xtrace with `EPOCHREALTIME`, 1.23 s wall): bin/fly-pool.sh lines 400-499 take 0.38 s, almost all at line 434, which sources merge-conductor-lib.sh. lane-gate.sh takes 0.22 s, gh-repo-token.sh 0.08 s, gh-app-auth.sh 0.06 s, lane-switch.sh 0.06 s.

### The #6882 sampler on the copy

`bin/hub-load-sample.sh` ran once in its own scratch tree (`/tmp/bh6896-measure/sampler/h`, seams `HUB_LOAD_SAMPLES=20`, `HUB_LOAD_INTERVAL_S=1`, `HUB_LOAD_FORK_WINDOW_S=5`). During its window the spawn tick for project-5 ran in a loop (7 ticks). Its tsv line:

```
2026-10-15T16:37:31Z	runnable=0.85	steal=0	forks_s=741.0	cpu=us:9,sy:14,id:77,wa:0	samples=20/20	fly-pool.sh=100.0
```

All runnable samples of the tick's children (`jq`, the shims, `tar`, `base64`) went to `fly-pool.sh`. So on the hub the sampler counts the `flyctl` and `gh` children under `fly-pool.sh` too. The ledger push answered `not-loaded` (no worker in the scratch env), as planned.

### Scale to the hub

Cadence: `cron/lanes/240-fly-pool-tick.cron` runs the tick wrapper `*/10`. The wrapper header (bin/fly-pool-tick.sh:2) still says `*/2`; the cron line wins. 13 projects x 6 ticks = 78 project ticks per hour.

| builds per hour | hub shell CPU s/h, today | forks/h, today | Fly calls/h, today | GitHub calls/h, today |
|---|---|---|---|---|
| 0 | 98 | 59,900 | 156 | 78 |
| 13 | 142 | 80,100 | 641 | 139 |
| 78 | 360 | 181,400 | 3,068 | 442 |

One build = one spawn + one reap: 3.37 CPU s, 1,557 forks, 37.3 Fly calls, 4.67 GitHub calls, 20 s of sleep and 6.49 MB pushed.

Next to the hub evidence (ticket, 2026-10-15): `fly-pool.sh` had 446 of 2358 runnable samples (19 percent), and one `ps` snapshot showed 13 runs at about 235 s elapsed. A waiting process is not runnable, so the 235 s is mostly network wait, not CPU. A modeled wall at 3 s per Fly call and 0.5 s per GitHub call gives: idle tick 7.6 s, plus 91 s per reaped machine (the 30 calls run in sequence), plus 43 s per spawned job (the spawns run in parallel). One project with 2 reaps and 1 spawn is about 233 s, near the 235 s in the snapshot. The tick wrapper header gives "~40-60s" per spawn. These wall values are MODELED, not measured.

## 3. Option comparison

- Option (a): the supervisor runs unchanged as one `lane_runs` row per project on a lane machine, as #6881 does for the conductor. The hub enqueues (`lp_enqueue`, bin/lib/lane-placement.sh:108), publishes the inputs and applies the write-backs (the BH-6128 path).
- Option (b): the hub keeps the reap and the spawn decision. It runs one `machine run` per job and stops. The 20 s sleep, the harness push, the env bundle and the job push move into the machine entrypoint. The machine pushes its own result and artifacts, so the reap reads a row instead of 30 `ssh console` calls.

Per project tick, "busy" = 1 reap + 1 spawn in the tick. Hour totals use 78 project ticks.

| measure | today (hub supervisor) | (a) lane_runs row per project | (b) wait in the build machine, hub only enqueues |
|---|---|---|---|
| hub CPU seconds per tick | 1.26 idle, 4.63 busy | 0.045 idle, 0.065 busy | 1.11 idle, 1.86 busy |
| hub forks per tick | 768 idle, 2,325 busy | 40 idle, 58 busy | 752 idle, 1,162 busy |
| hub process-seconds alive per tick (modeled) | 7.6 idle, 142 busy | 0.3 for all 13 projects in one batch process | 7.5 idle, 13 busy |
| GitHub calls from the hub per tick | 1 idle, 5.67 busy | 0 | 1 idle, 4.67 busy (the gates stay) |
| Fly calls from the hub per tick | 2 idle, 39.3 busy | 0 | 2 idle, 3.33 busy |
| hub CPU s/h at 0, 13, 78 builds/h | 98, 142, 360 | 3.5, 3.8, 5.1 | 86, 96, 145 |
| machine-side cost | none beyond the build; the build machine idles about 43 s per spawn while the hub pushes (modeled) | 78 lane runs/h at the full tick cost (1.26 CPU s idle, 3.37 CPU s per build) plus snapshot fetch; one lane machine on all the time (BH-6126) | about 1.40 CPU s per build moves into the entrypoint; no new machine |
| latency, queue to machine with job (modeled) | tick wait (300 s mean at `*/10`) + about 45 s | today + the lane claim latency (not measured) | tick wait + `machine run` + entrypoint fetch, about 300 s + 20 s; no fixed 20 s sleep |
| bytes moved per build | 6.49 MB tarball hub to machine; artifacts back in 28 console round trips, base64 | as today, plus a 1 KB input snapshot per project tick and a 25 to 85 KB record write-back per build | 0 hub to machine (image or git); the record (25 to 85 KB) machine to the jobs API |
| coordination needs | flock `locks/fly-pool-<p>.lock` (bin/fly-pool.sh:138); build-queue claim; per-key spawn cap (`.spawns` or `pool_spawns` rows) | `lane_runs_live` replaces the flock; every `state/pool/` and `state/fly-pool/` file needs a write-back class or a row (S4); the spawn cap must be a row | the hub keeps the flock, the claim and the cap; the machine claims its job row by id |
| failure: machine dies mid-wait | today's dead path (listing, `deaths`, requeue at the second death) | a dead LANE machine: the lease expires and the next tick runs again; a spawn record not yet written back leaves a live build machine untracked, and the next tick's orphan sweep destroys it | today's dead path, unchanged |
| failure: hub restart | the spawn subshells die after `machine run` and before the job push; the machine idles until the sweep | no effect on in-flight lane runs | no push window: the machine pulls its own job |
| hub runnable share of the pool supervisor (modeled) | 19 percent | 0.8, 0.6, 0.3 percent at 0, 13, 78 builds/h | 17.1, 13.7, 8.6 percent |

How the share is modeled: the supervisor's hub runnable samples scale with its hub CPU, and the other 81 percent of samples stay as they are. Then new share = 19r / (19r + 81), where r = new hub CPU / today's hub CPU. Under 2 percent needs r < 0.088, a cut of more than 91 percent. With `flyctl` CPU added at a modeled 0.3 CPU s per call, today's hub cost grows (145, 334 and 1,281 CPU s/h). The (a) share then falls to 0.6, 0.3 and 0.1 percent. The (b) share is 17.7, 9.3 and 3.8 percent. Neither model changes the verdict.

Recommendation, with the numbers:

1. Option (a) is the only option that reaches under 2 percent by itself: 3.5 to 5.1 CPU s/h left on the hub, against 98 to 360 today.
2. Option (b) alone stays over the target at every build rate (8.6 to 17.1 percent). The tick base of 1.11 CPU s x 78 ticks/h = 86 CPU s/h stays on the hub.
3. Option (a) alone moves the waste onto a lane machine: 20 s of sleep per spawn, 6.49 MB per spawn and 30 console round trips per reap. It also puts every pool app's Fly token, the GitHub App key and tailnet ssh to every owner box on the lane app.
4. So the plan is a mix. Do the option (b) parts first (S2, S3). They need no #6881 dependency, they shrink what option (a) moves, and they remove the env bundle ssh, which a lane machine cannot do. Then do option (a) (S4, S5). S1 goes first because it is one session and cuts 21 percent of the idle tick.

## 4. Slices

Metric target for the later slices: hub runnable share of the pool supervisor from 19 percent to under 2 percent.

No ticket was filed for these slices. Filing waits for approval.

### S1. Lazy-load merge-conductor-lib in the pool tick

- **Why:** every tick sources `bin/lib/merge-conductor-lib.sh` at bin/fly-pool.sh:433-434 for `mc_pool_rebase_apply`, which only the REBASED reap arm calls (bin/fly-pool.sh:3156). That costs 0.27 CPU s and 230 forks per project tick, which is 21 percent of the idle tick's CPU and 30 percent of its forks.
- **Scope:** source the lib inside the REBASED arm, just before the call, with the same `command -v` guard. Nothing else changes.
- **Creates:** `tests/fly-pool-lazy-mc-lib.<key>-test.sh` (a REBASED reap still applies the rebase; an idle tick never sources the lib).
- **Modifies:** `bin/fly-pool.sh`.
- **Acceptance:** the REBASED reap case of the existing pool rebase suite stays green; an idle tick on the scratch copy does not open merge-conductor-lib.sh (trace); the idle tick costs at most 1.00 CPU s on the copy.
- **Metric:** idle tick 1.26 to at most 1.00 CPU s and 768 to at most 540 forks on the copy; hub share 19 to about 16 percent (modeled).
- **Blocked-by:** none.
- **Estimate:** 1 AI session.

### S2. The machine pushes its own result and build record

- **Why:** a reaped machine costs the hub 1.22 CPU s and 30 Fly calls. 28 of the calls pull one artifact each through `ssh console` and base64 (bin/fly-pool.sh:3080-3103). A machine that is stopped cannot answer at all.
- **Scope:** the runner posts its RESULT and the 28 record files to the jobs API before it exits (the pool-result row, BH-2643, already carries RESULT). The reap reads the row and writes the hub build dir from it. The ssh pull stays as the fallback for a machine with no row.
- **Creates:** a worker route and schema fragment for the build record (`worker/jobs/schema.d/<n>-bh-<key>-pool-record.sql` with its indexes and a retention rule), a runner-side push helper, and its suite.
- **Modifies:** `bin/fly-pool.sh` (reap), the runner entrypoint, `catalog/state-paths.json` (`remote-results` row).
- **Acceptance:** on the scratch copy a reap of 2 machines with rows makes at most 4 Fly calls (listing, 2 destroys, agent start) and writes the same files into `builds/pool-<p>-<KEY>-<ts>/` as today; a machine with no row still goes through the ssh pull.
- **Metric:** Fly calls per reaped machine 30 to at most 2; hub CPU per reaped machine 1.22 to at most 0.15 CPU s on the copy.
- **Blocked-by:** none (the pool-result row exists).
- **Estimate:** 2 AI sessions.

### S3. Harness, env and job go into the machine entrypoint; no fixed sleep

- **Why:** each spawned job costs the hub 1.40 CPU s after `machine run`. That covers the 0.73 CPU s harness tarball, 6.49 MB over `ssh sftp`, 12 `mput` console pushes for 3 jobs, a fixed 20 s `sleep` (bin/fly-pool.sh:4230) and, before `machine run`, an `ssh` to the owning box for the env bundle (bin/fly-envbundle.sh:133).
- **Scope:** the image or a pinned git fetch carries the harness (the image bake lane, BH-2523). The env bundle comes from Fly app secrets or a jobs API mint, not from the hub. The machine claims its job row by id (`psr_claim_machine`) and polls for readiness itself. The hub's spawn ends at `machine run` plus the machine record.
- **Creates:** an entrypoint fetch helper and its suite; a secrets sync note for each pool app.
- **Modifies:** `bin/fly-pool.sh` (`spawn_one`), the runner entrypoint, `bin/fly-envbundle.sh` callers.
- **Acceptance:** on the scratch copy a spawn of 3 jobs makes 3 `machine run` calls, 0 `ssh sftp`, 0 `mput`, 0 box ssh and 0 `sleep` from the hub; a machine started this way runs a fixture job to RESULT on a test app (probe in the PR body).
- **Metric:** hub CPU per spawned job 2.15 to at most 0.80 CPU s; hub sleep per spawn 20 to 0 s; bytes pushed per spawn 6.49 MB to 0.
- **Blocked-by:** none for the code; the secrets sync needs an operator step per pool app.
- **Estimate:** 2 AI sessions.

### S4. Every pool input has a snapshot class or a row

- **Why:** option (a) needs every path in the section 1 table to be `.ro`, `.rw`, `@rows` or machine-local. Section 1 lists 4 catalog disagreements and 14 `state/` paths with no catalog row.
- **Scope:** add the missing rows to `catalog/state-paths.json`. Move the `state/pool/<p>/` markers that gate a spawn (`.terminal*`, `.held`, `.after-*`, `.defer-to-human`) to `pool_*` rows behind `pool_state_rows`, as BH-5001 did for `.spawns`. Give the rest a write-back class in the lane snapshot lists.
- **Creates:** a schema fragment for the new `pool_*` rows (with indexes, an EXPLAIN test and a retention rule), the snapshot list for lane `fly-pool`.
- **Modifies:** `catalog/state-paths.json`, `bin/lib/pool-state-rows.sh`, `bin/fly-pool.sh` readers.
- **Acceptance:** a lint fails on a `state/` path that bin/fly-pool.sh writes and no catalog row or snapshot list names; the find-newer trace of this note (Appendix C loop) passes against the new lists.
- **Metric:** pool `state/` paths with no class 14 to 0.
- **Blocked-by:** #6881 S2 (`@rows`); the BH-6128 snapshot path (merged).
- **Estimate:** 2 AI sessions.

### S5. The pool tick runs as one lane_runs row per project

- **Why:** after S1 to S3 the hub still spends about 0.85 CPU s per project tick (the base). 78 ticks/h is about 66 CPU s/h, about 13 percent share (modeled). Only a move off the hub cuts it under 2 percent.
- **Scope:** `bin/fly-pool-tick.sh` enqueues one `lane_runs` row per project (`lp_enqueue`) when `lane_placement.fly-pool` is `fly`, in one batch call per tick. The lane machine runs `bin/fly-pool.sh <p>` through `bin/lane-run-worker.sh`. Each spawn record is checkpointed (`lri_checkpoint`) right after `machine run`, so a lost lane machine cannot leave a build machine for the orphan sweep. The hub keeps a `hub_only` override.
- **Creates:** the placement fragment (unset by default), the lane app's secret list (pool app Fly tokens, App key), its suite.
- **Modifies:** `bin/fly-pool-tick.sh`, `bin/fly-pool.sh` (checkpoint after spawn), a `catalog/lanes.d/` fragment.
- **Acceptance:** with placement `fly`, a tick on the scratch copy makes 0 Fly and 0 GitHub calls and forks at most 300 times for 13 projects; the lane worker runs the fixture tick to the same files as a hub tick; a lane run killed after `machine run` leaves the machine tracked.
- **Metric:** hub CPU per project tick about 0.85 to at most 0.05 CPU s; hub runnable share of the pool supervisor to under 2 percent (24 h of #6882 samples after the flip).
- **Blocked-by:** S4; #6881 S1 (project lease); #6881 S7 (batch enqueue); the BH-6126 lane fleet live, with a probe that shows a live claimer.
- **Estimate:** 2 AI sessions.

### S6. The autoscale read and the one-shots leave the tick wrapper

- **Why:** after S5 the hub still runs `bin/fly-pool-tick.sh` every 10 min: `fly-lock-guard.sh`, `pool-cap.sh --autoscale`, the legacy cap retire, the builder record retire and the onboard drain (bin/fly-pool-tick.sh:34-229). This note did not measure it.
- **Scope:** measure the wrapper on the copy first. Move the autoscale decision to the #6881 S6 autoscaler. Delete the one-shots that have run on every project.
- **Creates:** the wrapper measurement in the PR body; a suite for the trimmed wrapper.
- **Modifies:** `bin/fly-pool-tick.sh`.
- **Acceptance:** the wrapper's own cost per tick is in the PR body before and after; the onboard drain still runs.
- **Metric:** hub processes per pool tick 14 to 1.
- **Blocked-by:** S5; #6881 S6 (autoscaler).
- **Estimate:** 1 AI session.

## Limits

- `flyctl` and `gh` are Go binaries. Their own CPU is not in any number here, because the shims replace them. `flyctl ssh console` also does a WireGuard handshake per call. Today's hub cost is therefore higher than the shell numbers, and every option that removes Fly calls (S2, S3, option (a)) saves more than shown. The section 3 share model uses 0.3 CPU s per call as a bracket. That value is an assumption, not a measurement.
- Network latency is not in any wall value. The 3 s per Fly call and 0.5 s per GitHub call in section 2 are assumptions.
- The jobs worker was not configured. With a worker, a tick also makes 10 to 27 worker calls (counted in a second pass). Their cost was not measured.
- The fixture artifacts are 17 bytes each, so the bytes in section 3 come from this build's own record directory at plan time (4 of the 26 listed record files, 25,000 bytes; the whole directory 84,503 bytes). A finished record is larger.
- The tarball came from this branch's checkout, linked at `/root/harness-checkout` on the build machine for the measurement. The hub's checkout holds the same five paths, so the size is close but not equal.
- The find-newer trace shows writes, not reads.
- The hub evidence does not give the window of its 2358 samples. The share model uses ratios only, so it does not need the window.
- `bin/fly-pool-tick.sh` itself was not measured (see S6).

## Appendix A: the counting shim

`/tmp/bh6896-measure/shims/countshim`, linked as `fly`, `flyctl`, `gh`, `curl`, `ssh` and `sleep`:

```bash
#!/bin/bash
# countshim — BH-6896 measurement shim. Symlinked as fly, flyctl, gh, curl,
# sleep. Appends "<tool>\t<verb>\t<sub>" to $BH_CALLS and answers locally.
# It never opens a network connection.
tool=$(basename "$0")
: "${BH_CALLS:?BH_CALLS unset}"
log() { printf '%s\t%s\t%s\n' "$tool" "$1" "$2" >> "$BH_CALLS"; }
case "$tool" in
  sleep)
    log sleep "${1:-0}"; exit 0 ;;
  fly|flyctl)
    [ -n "${BH_DEBUG:-}" ] && printf "%s\n" "$*" >> "$BH_DEBUG"
    case "$*" in
      *"machines list"*)
        log "machines list" "-"
        # every tracked machine reads as started
        ids=$(for f in "$BH_POOLDIR"/*.json; do [ -f "$f" ] && jq -r .machine "$f"; done)
        if [ -z "$ids" ]; then echo '[]'; else
          printf '%s\n' $ids | jq -R '{id:.,state:"started",config:{image:"registry.fly.io/fixture:deploy-01"}}' | jq -s .; fi ;;
      *"machine status"*) log "machine status" "-"; echo "State: started" ;;
      *"machine run"*)
        log "machine run" "-"
        [ -n "${BH_FAIL_RUN:-}" ] && exit 1   # components: stop spawn_one right after machine run
        n=$(grep -c 'machine run' "$BH_CALLS"); printf 'Machine ID: %014x\n' "$((0xabc0000000000 + n))" ;;
      *"machine destroy"*) log "machine destroy" "-" ;;
      *"ssh sftp"*) log "ssh sftp" "-" ;;
      *"ssh console"*)
        all="$*"; c="${all##*-C }"; c="${c//\\/}"
        case "$c" in
          *"head -1 /run/harness/RESULT"*)
            log "ssh console" "read-result"
            m="${all##*--machine }"; m="${m%% *}"
            if grep -qx "$m" "$BH_DONE" 2>/dev/null; then
              printf 'PR_CREATED https://github.com/%s/pull/101\nBUILD_DIR: /data/harness/builds/fixture-build\n' "$BH_SLUG"; fi ;;
          *"base64 -w0"*) log "ssh console" "pull-artifact"; printf 'Zml4dHVyZSBhcnRpZmFjdAo=' ;;
          *"base64 -d"*) log "ssh console" "put-file" ;;
          *) log "ssh console" "exec" ;;
        esac ;;
      *) log "other" "$1 $2" ;;
    esac
    exit 0 ;;
  gh)
    path=""; for a in "$@"; do case "$a" in repos/*|/repos/*|orgs/*|user*|app/*|installation*) path="$a";; esac; done
    log "${1:-} ${2:-}" "${path:-$3}"
    case "$1 $2" in
      "auth status"|"auth token") echo "tok-fixture-gh"; exit 0 ;;
    esac
    hdr=0; for a in "$@"; do [ "$a" = -i ] && hdr=1; done
    case "$path" in
      */branches/*) code=404; body='{"message":"Branch not found"}' ;;
      */pulls*) code=200; body='[]' ;;
      */issues/*/comments*) code=200; body='[]' ;;
      */issues/*) n="${path##*/issues/}"; n="${n%%[!0-9]*}"
                  code=200; body="{\"number\":${n:-1},\"state\":\"open\",\"body\":\"\",\"labels\":[{\"name\":\"ai-build\"}]}" ;;
      */issues\?*|*/issues) code=200
                  body=$(for n in 8001 8002 8003 9001 9002; do printf '{"number":%s,"updated_at":"2026-10-15T00:00:00Z","comments":0,"state":"open","labels":[{"name":"ai-build"}]}\n' "$n"; done | jq -sc .) ;;
      *) code=200; body="{\"full_name\":\"${BH_SLUG}\",\"permissions\":{\"pull\":true}}" ;;
    esac
    [ "$hdr" = 1 ] && printf 'HTTP/2.0 %s OK\r\n\r\n' "$code"
    printf '%s\n' "$body"
    [ "$code" = 200 ] ; exit $? ;;
  curl)
    url=""; for a in "$@"; do case "$a" in http*) url="$a";; esac; done
    host="${url#*://}"; host="${host%%/*}"
    log "${host:-none}" "$(printf '%s' "${url#*://*/}" | cut -c1-60)"
    case "$url" in
      *api.github.com/app/installations/*/access_tokens)
        printf '{"token":"tok-fixture-app","expires_at":"%s"}' "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" ;;
      *api.github.com/app/installations) printf '[{"id":12345,"account":{"login":"example-org"}}]' ;;
      *api.github.com/rate_limit) printf '{"rate":{"remaining":4999,"limit":5000}}' ;;
      *) printf '{}' ;;
    esac
    exit 0 ;;
  ssh)
    # bin/fly-envbundle.sh's env extract from the owning box
    log "box-ssh" "$(for a in "$@"; do case "$a" in root@*) printf '%s' "$a";; esac; done)"
    printf '===GLOBAL===\nCLAUDE_CODE_OAUTH_TOKEN=tok-fixture-oauth\nGH_TOKEN=tok-fixture-gh\n===PROJECT===\nFIXTURE_VAR=1\n'
    exit 0 ;;
esac
```

## Appendix B: the fixture recipe

`setup.sh` builds one scratch harness per project. `run.sh` resets one fixture state and runs one measured tick. `measure-all.sh` ran 3 projects x 3 states x (1 warm-up + 5 runs) and the reap-only variant, then the 10 s noise floor. All are under `/tmp/bh6896-measure/bin/`. During the run, `/root/harness-checkout` was a link to this branch checkout, so the tarball step had a source.

```bash
#!/bin/bash
# setup.sh <project> <owner/repo> — one scratch harness under /tmp/bh6896-measure/<p>/h,
# the shape of tests/fly-pool-sibling-serial.bh-6374-test.sh, with the real
# closure of bin/fly-pool.sh installed by scratch_install_closure.
set -uo pipefail
P="$1"; SLUG="$2"; DIR=/data/worktrees/cromford-bh-6896
M=/tmp/bh6896-measure/$P; H=$M/h
rm -rf "$M"; mkdir -p "$M"
cd "$DIR" || exit 1
export HARNESS_TEST_SANDBOX=1
. tests/lib/scratch.sh || exit 1
trap - EXIT
M=/tmp/bh6896-measure/$P; H=$SCRATCH/h
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/plans" \
         "$H/state/fly" "$H/state/fly-pool/$P" "$H/state/build-queue/$P" \
         "$H/state/remote-results/$P" "$H/state/pool/$P" "$H/builds"
TV="FLY_API_TOKEN_$(echo "$P" | tr '[:lower:].-' '[:upper:]__')"
printf '%s=tok-fixture-fly\n' "$TV" > "$H/env/fly.env"
printf 'GH_TOKEN=tok-fixture-gh\n' > "$H/env/global.env"
printf 'REPO_SLUG=%s\n' "$SLUG" > "$H/env/$P.env"
printf '%s %s - - 9 box-fixture 192.0.2.10\n' "$P" "$SLUG" > "$H/fleet.conf"
# The hub is armed for App tokens: a throwaway key (fixture, never a real App).
openssl genrsa -out "$H/env/github-app.pem" 2048 2>/dev/null
cp "$H/env/github-app.pem" "$H/env/github-app-builders.pem"
printf 'GH_APP_ID=1\nGH_APP_INSTALLATION_example-org=12345\n' > "$H/env/github-app.env"
cp "$H/env/github-app.env" "$H/env/github-app-builders.env"
: > "$H/flags/fly-pool-$P"
printf 'pool-%s\n' "$P" > "$H/flags/fly-pool-app-$P"
printf '{"app":"pool-%s"}\n' "$P" > "$H/state/fly/$P.json"
printf 'registry.fly.io/pool-%s:deploy-01\n' "$P" > "$H/state/fly/$P.image"
cp bin/result-prefix-ok.sh bin/fleet-conf.sh "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || true
for s in alert-line.sh beat.sh fly-envbundle.sh gh-token.sh pool-cap.sh sibling-serial.sh; do
  [ -f "$H/bin/$s" ] || scratch_install_closure "bin/$s" "$H" >/dev/null 2>&1 || true
done
chmod +x "$H"/bin/*.sh 2>/dev/null
mv "$H" "$M/h" && rm -rf "$SCRATCH"; H=$M/h
echo "setup $P ok: $(find "$H/bin" -type f | wc -l) files in bin"
```

```bash
#!/bin/bash
# run.sh <project> <owner/repo> <idle|reap|spawn> [extra env assignments...]
# Resets the fixture state, runs the REAL bin/fly-pool.sh once against the
# scratch tree, prints one tsv line:
#   project state wall_s cpu_s forks gh_calls fly_calls sleep_s box_ssh other_curl
set -uo pipefail
P="$1"; SLUG="$2"; ST="$3"; shift 3
DIR=/data/worktrees/cromford-bh-6896
M=/tmp/bh6896-measure/$P; H=$M/h
POOL=$H/state/fly-pool/$P; QD=$H/state/build-queue/$P; PD=$H/state/pool/$P
case "$H" in /tmp/bh6896-measure/*) ;; *) echo "refusing: HARNESS not under /tmp"; exit 2;; esac
rm -rf "$POOL" "$QD" "$PD" "$H/builds" "$H/state/remote-results/$P" "$H/locks" "$H/plans"
rm -f "$H"/flags/alerted-* "$H"/flags/*-$P-* 2>/dev/null
mkdir -p "$POOL" "$QD" "$PD" "$H/builds" "$H/state/remote-results/$P" "$H/locks" "$H/plans"
: > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
: > "$M/done-machines"
NOWISO=$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)
case "$ST" in
  idle) ;;
  reap)
    for i in 1 2; do
      mid=$(printf 'd0ne%010x' "$i"); key="FX-$((900+i))"
      jq -nc --arg m "$mid" --arg k "$key" --arg t "$((9000+i))" --arg s "$NOWISO" \
        '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:$s}' > "$POOL/$mid.json"
      echo "$mid" >> "$M/done-machines"
    done ;;
  spawn)
    for i in 1 2 3; do
      key="FX-$((800+i))"
      jq -nc --arg k "$key" --arg t "$((8000+i))" --arg e "$NOWISO" \
        '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:$e}' > "$QD/$key.json"
    done ;;
esac
CALLS=$M/calls.$ST.cur.tsv; : > "$CALLS"
export BH_CALLS="$CALLS" BH_POOLDIR="$POOL" BH_DONE="$M/done-machines" BH_SLUG="$SLUG"
# trace.sh: stamp the marker AFTER the fixture reset, so only the tick counts
[ -n "${BH_MARK:-}" ] && { touch "$BH_MARK"; /bin/sleep 1.1; }
F0=$(awk '/^processes/{print $2}' /proc/stat); T0=$(date +%s.%N)
mkdir -p "$M/tmp"
# env -i: nothing from this build machine's environment (HARNESS_ENV_DIR,
# GH_TOKEN, JOBS_URL ...) reaches the measured tick.
TIMES=$( env -i HOME="$M" TMPDIR="$M/tmp" BH_CALLS="$CALLS" BH_POOLDIR="$POOL" \
          BH_DONE="$M/done-machines" BH_SLUG="$SLUG" \
          PATH="/tmp/bh6896-measure/shims:/usr/local/bin:/usr/bin:/bin" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
          FLY_BIN_DIR=/tmp/bh6896-measure/shims "$@" \
          bash -c 'bash "$1/bin/fly-pool.sh" "$2" >/dev/null 2>"$3/stderr.last"; times' _ "$DIR" "$P" "$M" | tail -1 )
T1=$(date +%s.%N); F1=$(awk '/^processes/{print $2}' /proc/stat)
cat "$CALLS" >> "$M/calls.tsv"
# times line 2: children user and sys, e.g. "0m1.234s 0m0.567s"
CPU=$(echo "$TIMES" | awk '{ s=0; for(i=1;i<=2;i++){ split($i,a,/[ms]/); s+=a[1]*60+a[2] } printf "%.2f", s }')
GH=$(awk -F'\t' '$1=="gh" || ($1=="curl" && $2 ~ /github\.com/)' "$CALLS" | wc -l)
FLYC=$(awk -F'\t' '$1=="fly" || $1=="flyctl" || ($1=="curl" && $2 ~ /machines\.dev|fly\.io/)' "$CALLS" | wc -l)
SL=$(awk -F"\t" '$1=="sleep"{s+=$3} END{print s+0}' "$CALLS")
BS=$(awk -F'\t' '$1=="ssh"' "$CALLS" | wc -l)
OC=$(awk -F'\t' '$1=="curl" && $2 !~ /github\.com|machines\.dev|fly\.io/' "$CALLS" | wc -l)
printf '%s\t%s\t%.2f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$P" "$ST" "$(awk -v a="$T0" -v b="$T1" 'BEGIN{print b-a}')" "$CPU" "$((F1-F0-3))" "$GH" "$FLYC" "$SL" "$BS" "$OC"
```

```bash
#!/bin/bash
# measure-all.sh — 3 projects x 3 fixture states x (1 warm-up + 5 runs),
# the reap-only variant on the spawn fixture, and the idle fork baseline.
# Output: /tmp/bh6896-measure/runs.tsv (one line per measured run).
set -uo pipefail
B=/tmp/bh6896-measure; OUT=$B/runs.tsv
printf 'project\tstate\twall_s\tcpu_s\tforks\tgh_calls\tfly_calls\tsleep_s\tbox_ssh\tother_curl\n' > "$OUT"
for ps in cromford:example-org/cromford harness-console:example-org/cromford-console project-5:example-org/project-5; do
  p=${ps%%:*}; s=${ps#*:}
  "$B/bin/setup.sh" "$p" "$s" || exit 1
  : > "$B/$p/calls.tsv"
  for st in idle reap spawn; do
    "$B/bin/run.sh" "$p" "$s" "$st" > /dev/null    # warm-up (mints the App token cache)
    for i in 1 2 3 4 5; do "$B/bin/run.sh" "$p" "$s" "$st" >> "$OUT"; done
  done
  "$B/bin/run.sh" "$p" "$s" spawn POOL_SPAWN=0 > /dev/null
  for i in 1 2 3 4 5; do "$B/bin/run.sh" "$p" "$s" spawn POOL_SPAWN=0 | sed 's/\tspawn\t/\tspawn-reaponly\t/' >> "$OUT"; done
done
# noise floor: forks on this machine in 10 s with no run
F0=$(awk '/^processes/{print $2}' /proc/stat); /bin/sleep 10; F1=$(awk '/^processes/{print $2}' /proc/stat)
printf 'baseline_forks_10s\t%s\n' "$((F1-F0))" > "$B/baseline.txt"
echo done
```

## Appendix C: the inventory check

`trace.sh` writes the normalised write list. `check-inventory.sh` prints `MISSING <path>` for a traced path that no inventory row matches. It prints nothing when every path is covered. Run: `check-inventory.sh docs/notes/2026-10-15-BH-6896-fly-pool-offhub.md /tmp/bh6896-measure/trace-paths.txt`.

```bash
#!/bin/bash
# trace.sh <project> <slug> — no strace on this machine, so: a find -newer diff
# of the scratch tree around one tick per fixture state. Prints every path the
# tick created or changed, relative to the scratch HARNESS, <p>/KEY/machine
# normalised. Usage: for each project, trace.sh <p> <slug> >> trace-raw.txt;
# then: cut -f2 trace-raw.txt | sort -u > trace-paths.txt
set -uo pipefail
P="$1"; SLUG="$2"; B=/tmp/bh6896-measure; H=$B/$P/h
for st in idle reap spawn; do
  # run.sh resets the fixture, then stamps BH_MARK just before the tick.
  BH_MARK="$B/$P/.mark" "$B/bin/run.sh" "$P" "$SLUG" "$st" >/dev/null
  find "$H" -newer "$B/$P/.mark" -type f ! -path "$H/bin/*" | sed "s|^$H/||" \
    | sed -E "s|/$P/|/<p>/|g; s|-$P-|-<p>-|g; s|\.$P$|.<p>|; s|/$P\.|/<p>.|; s|FX-[0-9]+|<KEY>|g; s|[0-9a-f]{14}|<machine>|g; s|[0-9]{12}|<ts>|g; s|[0-9]{8}|<date>|g" \
    | sed -E 's#example-org-[A-Za-z0-9.-]+\.(json|lock)#<owner>-<repo>.\1#; s#(cromford|harness-console|project-5)#<p>#g; s#<p>-console#<p>#; s#gh-calls/<date>[0-9]{2}\.log#gh-calls/<date><hh>.log#; s#gh-rest-ledger/[0-9-]+T[0-9]{2}\.tsv#gh-rest-ledger/<day>T<hh>.tsv#' \
    | sed "s|^|$st\t|"
done
```

```bash
#!/bin/bash
# check-inventory.sh <note> <trace-paths> — prints MISSING <path> for every
# traced path that no inventory row's path-pattern cell matches; prints
# nothing when the inventory covers the trace. A cell holds one or more
# `backticked` globs; <x> in a glob is any text.
N="$1"; TR="$2"
mapfile -t GLOBS < <(awk '/^## 1\. Read\/write inventory/{f=1} /^### Trace confirmation/{f=0}
  f && /^\| / { split($0, c, "|"); print c[2] }' "$N" \
  | grep -o '`[^`]*`' | tr -d '`' | sed -E 's/<[^>]*>/*/g')
[ "${#GLOBS[@]}" -gt 0 ] || { echo "MISSING: no inventory globs read from $N"; exit 1; }
while IFS= read -r p; do
  [ -n "$p" ] || continue
  hit=0
  for g in "${GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ "$p" == $g ]] && { hit=1; break; }
  done
  [ "$hit" = 1 ] || echo "MISSING $p"
done < "$TR"
```
