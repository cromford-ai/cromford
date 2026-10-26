# MKF-6: project-6-os inventory, inert-lane holds, off-box backup (BH-8321)

Doc: OPERATING

Part of #8315 (Order 6 of 10). Refs #8321.

This note is the record for MKF-6. It changes no code, no row and no schedule.
The build box (a Fly builder) has no route to project-6-os: `ssh root@10.0.0.14`
timed out on port 22 at 2026-10-25 18:05Z. So the holds, the backup config and
the three live probes are operator steps. Each one is written below as an exact
command.

## 1. Cron inventory (46 lines)

Source: `bin/render-cron.sh project-6-os` at this PR's head (repo truth, the same
render `update-runners.sh` installs). It prints 46 non-comment lines: 7 for
project-6-os, 6 for project-6-desktop, 33 for the box. Parent #8315 fact 2
read 46 lines on project-6-os at 17:30Z, so the render and the live crontab agree on
the count.

- **Owner lane** uses the same rule as `lane_id` in `bin/hub-move.sh`: the
  first `bin/<x>.sh` in the command that is not `hub-lease.sh`, minus `.sh`.
  The PATH line and `@reboot` have no lane (`-`).
- **Move class** is from parent #8315 section 1. FLY-READY = code exists, only
  rows or ops are needed. HUB-OK = no LLM and no secret, so the hub can run it.
  NEW = new code. MOVES = moves with the box (Option A), and goes away or
  becomes NEW under Option B. INERT = no work for this project today.
  DONE = already on Fly. "box setup" = a line that starts the box, not a lane.
- Comments after a command (`# every 10 min: ...`) are not copied. No line
  carries a secret value.

| # | Schedule | Command | Project | Owner lane | Move class |
|---|---|---|---|---|---|
| 1 | (env line) | `PATH` (bin/gh-ledger first, then /usr/bin and /bin) | box | - | box setup |
| 2 | `1,11,21,31,41,51 * * * *` | `/root/harness/bin/run-triage.sh project-6-os` | project-6-os | run-triage | MOVES (A) / NEW, largest (B) |
| 3 | `1 9 * * 1` | `/root/harness/bin/run-product.sh project-6-os` | project-6-os | run-product | MOVES (A) / NEW lane_runs (B) |
| 4 | `43 6,18 * * *` | `/root/harness/bin/healthcheck.sh project-6-os` | project-6-os | healthcheck | MOVES (A) / HUB-OK (B) |
| 5 | `*/15 * * * *` | `/root/harness/bin/apply-migrations.sh project-6-os` | project-6-os | apply-migrations | MOVES (A) / HUB-OK or Fly lane_runs row (B) |
| 6 | `7,27,47 * * * *` | `/root/harness/bin/merge-queue.sh project-6-os >> /root/harness/logs/merge-queue.log 2>&1` | project-6-os | merge-queue | INERT: held here (Mergify lands the repo) |
| 7 | `4,19,34,49 * * * *` | `/root/harness/bin/deploy-train.sh project-6-os >/dev/null 2>&1` | project-6-os | deploy-train | INERT: held here (no VERSION_URL; Vercel git deploys) |
| 8 | `8,18,28,38,48,58 * * * *` | `/root/harness/bin/review-prs.sh project-6-os` | project-6-os | review-prs | MOVES (A) / NEW lane_runs (B) |
| 9 | `0,10,20,30,40,50 * * * *` | `/root/harness/bin/run-triage.sh project-6-desktop` | project-6-desktop | run-triage | MOVES (A) / NEW (B) |
| 10 | `43 6,18 * * *` | `/root/harness/bin/healthcheck.sh project-6-desktop` | project-6-desktop | healthcheck | HUB-OK |
| 11 | `*/15 * * * *` | `/root/harness/bin/apply-migrations.sh project-6-desktop` | project-6-desktop | apply-migrations | INERT (no migration endpoint), not held here |
| 12 | `6,26,46 * * * *` | `/root/harness/bin/merge-queue.sh project-6-desktop >> /root/harness/logs/merge-queue.log 2>&1` | project-6-desktop | merge-queue | MOVES (A) / NEW (B): ACTIVE lander (queue_provider none), NOT held |
| 13 | `4,19,34,49 * * * *` | `/root/harness/bin/deploy-train.sh project-6-desktop >/dev/null 2>&1` | project-6-desktop | deploy-train | INERT (no VERSION_URL), not held here |
| 14 | `7,37 * * * *` | `/root/harness/bin/review-prs.sh project-6-desktop` | project-6-desktop | review-prs | MOVES (A) / NEW (B) |
| 15 | @reboot | `/usr/sbin/sshd; /usr/sbin/cron; setsid -f /usr/sbin/tailscaled ...` (flags not copied) | box | - | box setup |
| 16 | `* * * * *` | `/root/harness/bin/box-console-commands.sh >/dev/null 2>&1` | box | box-console-commands | MOVES (A), box hygiene; goes away under B |
| 17 | `* * * * *` | `/root/harness/bin/wake-loop.sh` | box | wake-loop | MOVES (A), box hygiene; goes away under B |
| 18 | `*/5 * * * *` | `/root/harness/bin/harness-sync-timer.sh >/dev/null 2>&1` | box | harness-sync-timer | MOVES (A), box hygiene; goes away under B |
| 19 | `*/5 * * * *` | `/root/harness/bin/watchdog-ping.sh box-project-6-os-1` | box | watchdog-ping | MOVES (A), box hygiene; goes away under B |
| 20 | `*/2 * * * *` | `/root/harness/bin/tailscaled-watchdog.sh >/dev/null 2>&1` | box | tailscaled-watchdog | MOVES (A), box hygiene; goes away under B |
| 21 | `24,54 * * * *` | `/root/harness/bin/jobs-watchdog.sh --resume >> /root/harness/logs/resume-dead.log 2>&1` | box | jobs-watchdog | MOVES (A), box hygiene; goes away under B |
| 22 | `*/10 * * * *` | `/root/harness/bin/lane-reaper.sh >> /root/harness/logs/lane-reaper.log 2>&1` | box | lane-reaper | MOVES (A), box hygiene; goes away under B |
| 23 | `13,28,43,58 * * * *` | `/root/harness/bin/extra-usage-track.sh project-6-os >/dev/null 2>&1` | box | extra-usage-track | MOVES (A); under B the project-6-os Claude login moves to env/accounts.d on the hub |
| 24 | `23 * * * *` | `/root/harness/bin/quota-poll.sh >/dev/null 2>&1` | box | quota-poll | MOVES (A); under B the project-6-os Claude login moves to env/accounts.d on the hub |
| 25 | `1,11,21,31,41,51 * * * *` | `/root/harness/bin/cost-rows-push.sh project-6-os >/dev/null 2>&1` | box | cost-rows-push | MOVES (A), box hygiene; goes away under B |
| 26 | `*/2 * * * *` | `/root/harness/bin/preplan-tick.sh` | box | preplan-tick | MOVES (A) / NEW (B) |
| 27 | `3,13,23,33,43,53 * * * *` | `/root/harness/bin/gh-ledger-push.sh project-6-os >/dev/null 2>&1` | box | gh-ledger-push | MOVES (A), box hygiene; goes away under B |
| 28 | `*/10 * * * *` | `/root/harness/bin/reconcile-prs.sh` | box | reconcile-prs | INERT on project-6-os (owner row default hub) |
| 29 | `3,13,23,33,43,53 * * * *` | `/root/harness/bin/cost-local-brake.sh >/dev/null 2>&1` | box | cost-local-brake | MOVES (A), box hygiene; goes away under B |
| 30 | `17 5 * * *` | `/root/harness/bin/update-runners.sh` | box | update-runners | MOVES (A), box hygiene; goes away under B |
| 31 | `5 5 * * *` | `/root/harness/bin/model-prices-sync.sh >/dev/null 2>&1` | box | model-prices-sync | MOVES (A), box hygiene; goes away under B |
| 32 | `47 4 * * *` | `/root/harness/bin/disk-clean.sh >/dev/null 2>&1` | box | disk-clean | MOVES (A), box hygiene; goes away under B |
| 33 | `*/30 * * * *` | `/root/harness/bin/clock-sync.sh >/dev/null 2>&1` | box | clock-sync | MOVES (A), box hygiene; goes away under B |
| 34 | `*/10 * * * *` | `/root/harness/bin/disk-guard.sh >/dev/null 2>&1` | box | disk-guard | MOVES (A), box hygiene; goes away under B |
| 35 | `*/15 * * * *` | `/root/harness/bin/env-diff.sh >/dev/null 2>&1` | box | env-diff | MOVES (A), box hygiene; goes away under B |
| 36 | `8,23,38,53 * * * *` | `/root/harness/bin/tmp-sweep.sh >/dev/null 2>&1` | box | tmp-sweep | MOVES (A), box hygiene; goes away under B |
| 37 | `*/5 * * * *` | `/root/harness/bin/audit-tail.sh >/dev/null 2>&1` | box | audit-tail | MOVES (A), box hygiene; goes away under B |
| 38 | `*/10 * * * *` | `/root/harness/bin/harden-state.sh >/dev/null 2>&1` | box | harden-state | MOVES (A), box hygiene; goes away under B |
| 39 | `*/30 * * * *` | `/root/harness/bin/alert-warn-flush.sh >> /root/harness/logs/alert-digest.log 2>&1` | box | alert-warn-flush | MOVES (A), box hygiene; goes away under B |
| 40 | `* * * * *` | `/root/harness/bin/box-ops.sh >> /root/harness/logs/box-ops.log 2>&1` | box | box-ops | MOVES (A), box hygiene; goes away under B |
| 41 | `* * * * *` | `flock -n /root/harness/locks/lane-run-box.lock /root/harness/bin/lane-run-box.sh --once --box "$(hostname)" >> /root/harness/logs/lane-run-box-cron.log 2>&1` | box | lane-run-box | MOVES (A), box hygiene (no box: row placed on project-6-os) |
| 42 | `5,20,35,50 * * * *` | `/root/harness/bin/state-backup.sh >/dev/null 2>&1` | box | state-backup | MOVES (A), box hygiene; UNCONFIGURED today, see 'Off-box backup' |
| 43 | `*/15 * * * *` | `/root/harness/bin/lead-review.sh tick >/dev/null 2>&1` | box | lead-review | DONE for Fly (placement fly); the project-6-os tick is checked in 'lead-review on project-6-os' |
| 44 | `27 * * * *` | `/root/harness/bin/box-self-report.sh >/dev/null 2>&1` | box | box-self-report | MOVES (A), box hygiene; goes away under B |
| 45 | `*/2 * * * *` | `/root/harness/bin/fix-round-claim.sh >>/root/harness/logs/fix-round-claim.log 2>&1` | box | fix-round-claim | MOVES (A) / NEW: route fix rounds to the pool (B) |
| 46 | `23 3 * * 0` | `/root/harness/bin/conflict-hotspots-fleet.sh >> /root/harness/logs/conflict-hotspots.log 2>&1` | box | conflict-hotspots-fleet | MOVES (A), box hygiene; goes away under B |

## 2. Env inventory (names only)

Shape: the `Env file` rows of `bin/hub-move.sh inventory` (`cmd_inventory`,
`bin/hub-move.sh:260`): file name and key NAMES, never a value. Source: parent
#8315 fact 3, read on project-6-os at 2026-10-25 17:30Z. This build cannot read project-6-os,
so the names are "as of 17:30Z".

| Role | Source on project-6-os | Live value | How it moves |
|---|---|---|---|
| Env file | project-6-os.env | keys: MK_API_BASE BASE_BRANCH VERCEL_AUTOMATION_BYPASS_SECRET OPENROUTER_PROVISIONING_KEY COMPOSIO_API_KEY MIGRATION_TOKEN | Fly app secrets (parent D1), MKF-1/MKF-2 |
| Env file | project-6-desktop.env | keys: MKD_API_BASE BASE_BRANCH | Fly app secrets (parent D1) |
| Env file | global.env | 36 keys. Named in the parent: CLAUDE_CODE_OAUTH_TOKEN HARNESS_SECRET LOCKS_* RUNNER_* OPENROUTER_API_KEY XAI_API_KEY DEEPGRAM_API_KEY SENTRY_* (the full list is not in the parent) | age-encrypted in the snapshot (C4) |
| Env file | global.env, after section 5 | adds BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY BACKUP_AGE_RECIPIENT | stays on the box; the state-backup tarball carries it as env.tar.age |

**Re-check (names only), on project-6-os:**

```bash
cd /root/harness && bin/hub-move.sh inventory
```

It prints one `Env file` row per file with `keys: ...` and a `Cron lanes`
row with `lines=<n>`. If `lines` is not 46, or a key name differs from the
table above, update this note in a follow-up commit. The command prints no
value.

## 3. Holds: merge-queue and deploy-train for project-6-os

Both lanes are INERT for project-6-os:

- merge-queue: Mergify lands example-org/project-6 (the settings row
  `mc.queue_provider` for project-6 is `mergify`). Every tick logs `queue held: ... native merge queue`
  and does nothing else.
- deploy-train: it is gated on VERSION_URL, and project-6-os.env has none.
  Vercel git deploys the repo (deploy kind github-deployment).

Not held here: **project-6-desktop merge-queue** is the ACTIVE lander for that
repo (queue_provider none). Holding it would stop every project-6-desktop
merge. project-6-desktop deploy-train and apply-migrations are also inert,
but the ticket does not name them, so they stay on.

**Steps (an operator on the hub, from `/root/harness`):**

1. Hold merge-queue:
   ```bash
   bin/harness-ctl.sh off merge-queue project-6-os "MKF-6: Mergify lands project-6-os; the project-6-os lane is inert"
   ```
2. Hold deploy-train:
   ```bash
   bin/harness-ctl.sh off deploy-train project-6-os "MKF-6: Vercel git deploys project-6-os; no VERSION_URL"
   ```
3. Check both. Each must show the lane off for project-6-os with the reason:
   ```bash
   bin/harness-ctl.sh show merge-queue project-6-os
   bin/harness-ctl.sh show deploy-train project-6-os
   ```
4. Record the hold time (UTC) and the line count of the project-6-os log, for the probe:
   ```bash
   date -u '+%Y-%m-%d %H:%M:%SZ'
   ssh root@10.0.0.14 'wc -l < /root/harness/logs/merge-queue.log'
   ```

**Undo:** the same grammar with `on`:

```bash
bin/harness-ctl.sh on merge-queue project-6-os "MKF-6 undo: <reason>"
bin/harness-ctl.sh on deploy-train project-6-os "MKF-6 undo: <reason>"
```

**Why this works with no code change:**

- `harness-ctl.sh off <lane> [project] "<reason>"` takes a positional project
  for a project-scope lane (`bin/harness-ctl.sh:171`). Both lanes are
  `"scope": "project"` (`catalog/lanes.d/merge-queue.json`,
  `catalog/lanes.d/deploy-train.json`). The command writes the pause_flags row
  `lane-off-<lane>-project-6-os`.
- Both scripts call `lane_gate_or_exit <lane> "$PROJECT"` before any work
  (`bin/merge-queue.sh:35`, `bin/deploy-train.sh:25`). The project-6-os lane gate
  reconciles the pause_flags row and exits 0.
- A held tick writes its line `[lane-gate] merge-queue/project-6-os SKIPPED —
  lane-off-merge-queue-project-6-os (<n>)` to `logs/lane-gate.log` (`bin/lib/lane-gate.sh:1041`, through
  `_lg_log_throttled` at :327, one line per `LANE_GATE_LOG_EVERY_S`). It writes
  nothing to `logs/merge-queue.log`. So after the hold, that log gets 0
  project-6-os lines.

**Probe for acceptance test 1 (24 h after step 4, on project-6-os).** Put the line
count from step 4 in `N`. The count must be 0:

```bash
N=<line count from step 4>
tail -n +"$((N + 1))" /root/harness/logs/merge-queue.log | grep -c 'project-6-os'
```

If the log rotated in the 24 h, use the time filter instead (merge-queue
lines start `YYYY-MM-DD HH:MM:SSZ [<project>]`). Put the hold time from step 4
in `T`:

```bash
T='<hold time from step 4>'
awk -v t="$T" '($1 " " $2) >= t && /project-6-os/' /root/harness/logs/merge-queue.log | wc -l
```

The held ticks show here instead, at most one line per throttle window:

```bash
grep 'merge-queue/project-6-os SKIPPED' /root/harness/logs/lane-gate.log | tail -3
```

## 4. lead-review on project-6-os

Line 43 of the inventory runs `bin/lead-review.sh tick` on project-6-os every 15 min.
Parent fact 7: `lane_placement.lead-review.project-6-os=fly`.

**Code finding.** `bin/lead-review.sh:260` (FLY POOL, BH-8027): "With
lane_placement.lead-review.<project> = fly a tick queues that project's item
as ONE pool row (bin/lib/lead-pool.sh) and runs nothing here; the pool machine
runs `item`". So by the code, the project-6-os tick does not review project-6-os PRs
on project-6-os. It only queues them to the pool.

**This build did not read the project-6-os log** (no route to project-6-os). The operator
probe decides it, on project-6-os:

```bash
grep 'project-6-os' /root/harness/logs/lead-review.log | tail -40
```

Read the lines after the date the fly placement row was set. The strings
come from `bin/lib/lead-pool.sh` (`lrp_placed` at :107 and the item checks
below it):

- Expected (NOT a local review): `project-6-os: lead reviews go to the Fly
  pool (lane_placement.lead-review.project-6-os=fly)` (:117), and per item
  `<key>: on the Fly pool (queued); no local review` (:151), or `the
  Fly pool reviewed this head` (:157).
- The near miss that IS a local review: `project-6-os:
  lane_placement.lead-review.project-6-os=fly, but its routing is '<f>', not
  pool|0; reviews run on this box` (:119). The row says fly, but
  `queue_routing_facts` does not answer `pool|0`, so the tick reviews on project-6-os.
- Any other line of this tick for a project-6-os PR (a claim, a model run, a
  verdict post) after the placement date is also a local review.

**Rule.** If the probe shows one or more local review lines for project-6-os
after the placement date, file ONE fix ticket on the cromford board,
`Part of #8315`, with the log lines as evidence. If it shows only pool-queue
lines (or none), no fix is needed: write that result as a comment on #8321.

## 5. Off-box backup (state-backup on project-6-os)

Today project-6-os has no off-box copy: `state/state-backup-unconfigured-20261025`
exists (parent fact 10). Line 42 of the inventory runs `bin/state-backup.sh`
at minutes 5, 20, 35 and 50. MKF-8 and MKF-9 need this copy for rollback.

**What state-backup needs** (`bin/state-backup.sh:211`, all 4 required):

- `BACKUP_S3_ENDPOINT`
- `BACKUP_S3_ACCESS_KEY_ID`
- `BACKUP_S3_SECRET_ACCESS_KEY`
- `BACKUP_AGE_RECIPIENT` (the age PUBLIC key; the private identity never
  goes on a box)

Optional, with their defaults (`bin/state-backup.sh:136-137`):

- `BACKUP_S3_BUCKET` (default `harness-state`)
- `BACKUP_S3_REGION` (default `auto`)

**NEEDS_HUMAN (the operator):** the 4 values. They are an S3/R2 key pair, its
endpoint and an age recipient. This build has none of them and writes none of
them anywhere. If the fleet already uses one bucket and recipient for the
other boxes, use the same ones.

**Steps (an operator on project-6-os, from `/root/harness`):**

1. Release the env file (harden-state keeps env/ at `chattr +i`,
   docs/OPERATOR-SETUP.md):
   ```bash
   bin/harden-state.sh --release env/global.env
   ```
2. Add the 4 lines to `env/global.env` (the env dir that
   `bin/lib/env-path.sh` resolves, `/etc/harness/env`, mode 600). Type the
   values in an editor. Never put a value in argv, a log or a comment:
   ```
   BACKUP_S3_ENDPOINT=<value>
   BACKUP_S3_ACCESS_KEY_ID=<value>
   BACKUP_S3_SECRET_ACCESS_KEY=<value>
   BACKUP_AGE_RECIPIENT=<value>
   ```
3. Re-arm the file:
   ```bash
   bin/harden-state.sh --rearm env/global.env
   ```
4. Run one backup by hand, and read its log:
   ```bash
   bin/state-backup.sh; echo "rc=$?"
   tail -5 logs/state-backup.log
   ```
   It must exit 0. Before the upload it lists the tarball back and refuses
   (rc 1, an ALERTS line `leak-check`) if `env.tar.age` is not in it or if
   any plaintext `env/` entry is in it (`bin/state-backup.sh:416-425`). The
   bucket key is `<box-id>/<ts>.tar.zst` (`bin/state-backup.sh:429`).
5. The unconfigured marker: do NOT remove it by hand. A configured run
   removes every `state/state-backup-unconfigured-*` marker itself
   (`bin/state-backup.sh:246`). Check:
   ```bash
   ls state/state-backup-unconfigured-* 2>/dev/null | wc -l   # must be 0
   ```

**Probe for acceptance test 2 (on project-6-os).** The ticket writes it as
`bin/state-restore.sh list`. That is not the CLI: `state-restore.sh` has no
`list` verb, and `list` would be read as a box name. The listing is
`bin/state-restore.sh <box>` with no ts (`bin/state-restore.sh` usage,
docs/RESTORE.md "What is there"). The box prefix is this box's
`state/box-id`:

```bash
bin/state-restore.sh "$(tr -dc 'a-z0-9-' < state/box-id)"
```

It must print one or more `<ts>  <bytes>` rows (one per run since step 4).
The listing does not name `env.tar.age`. To see it in the newest object, run
the dry run (it writes nothing to `/root/harness`; with no `--identity` it
prints `env/ NOT decrypted (no identity given)`, and it prints
`no env.tar.age in this snapshot` only if the blob is missing):

```bash
bin/state-restore.sh "$(tr -dc 'a-z0-9-' < state/box-id)" latest
```

Remove the pulled copy after you read it: the tool never deletes its own
destination (`$H/tmp/state-restore/<box>/<ts>`).

## 6. Status

| Item | Rung | What is still owed |
|---|---|---|
| Inventory (AC 3) | BUILT: this note | re-check with `bin/hub-move.sh inventory` on project-6-os |
| Holds (AC 1) | not started | an operator runs section 3 steps 1-4, then the 24 h probe |
| lead-review check | code read only | an operator runs the section 4 probe |
| Off-box backup (AC 2) | not started | the operator gives the 4 values; an operator runs section 5 |
