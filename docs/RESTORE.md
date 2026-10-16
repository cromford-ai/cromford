# Recovering a box

On 2026-09-15 the hub's `/root/harness/{env,bin,prompts,logs,builds}` vanished
under a running system ([#388](https://github.com/example-org/cromford/issues/388)).
There was no off-box copy, so nothing came back. This is the page you read when
that happens again.

Two independent layers, and you use them in this order:

1. **The Orgo daily snapshot** brings a whole computer back, disk and all, but
   as a NEW computer (§5). It is coarse and up to a day stale.
2. **The R2 state backup** brings this box's `env/`, `state/`, `logs/`,
   `flags/`, the `builds/` summaries and the orchestrator checkout back, merged
   into whatever survived, without ever letting old snapshot content overwrite
   newer live content (§3, §4).

Layer 2 goes ON TOP of layer 1.

---

## 1. What is backed up

[`bin/state-backup.sh`](../bin/state-backup.sh) makes one tarball per run and
uploads it to an S3-compatible bucket (we use Cloudflare R2).

| in the tarball | what it is |
|---|---|
| `env.tar.age` | the whole `env/` directory, encrypted with `age`. The ONLY way `env/` leaves a box. The script lists the tarball back and refuses to upload if one plaintext `env/` entry is in it. |
| `state/` | box id, quota, merge-conductor `pr-state.tsv`, cursors, ledgers |
| `logs/` | including `ALERTS.log` |
| `flags/` | the kill switches and cursors |
| `builds/<dir>/{RESULT,cost.csv,plan.md,review.md,pipeline.log}` | the build record, not the transcripts |
| `orchestrator/` | the checkout minus `node_modules` and `.git` |
| `meta/` | `box.txt`, `ts.txt`, `crontab.txt`, `checkout-head.txt` |

**Where.** Object key `<box>/<ts>.tar.zst` in the bucket named by
`BACKUP_S3_BUCKET` (`harness-state`). `<ts>` is `YYYYMMDDTHHMMSSZ`, UTC. The
sha256 of the tarball rides along as object metadata, which is what the restore
side checks before it extracts anything.

**How often.** Four times an hour, at minutes `5,20,35,50`. That cron line is a
separate slice ([#448](https://github.com/example-org/cromford/issues/448))
and is not in `cron/` yet — until it lands, the uploader runs when you run it.

**Retention.** Everything younger than `BACKUP_KEEP_ALL_DAYS` (7) is kept. Past
`BACKUP_KEEP_DAILY_DAYS` (30) it is deleted. In between, the earliest object of
each UTC day survives.

**The kill switch.** `STATE_BACKUP=0` in `env/global.env`, or
`touch $H/flags/state-backup-off`. Either one stops the lane before it reads the
config or takes its lock.

**Did it work?** `state/backup-last.json` is written only after `head-object`
confirms the remote size, so a stamp without a delivered object is impossible:

```
cat /root/harness/state/backup-last.json
{"ts":"<ts>","key":"<box>/<shipped>.tar.zst","bytes":12345,"sha256":"...","manifest":"<64 hex>","shipped":"<shipped>"}
```

`shipped` is the time of the last upload. `ts` is the last time the off-box
copy was proven to match this box's inputs. A run whose input manifest (name,
size and mtime of every input file) matches `manifest` uploads nothing: it
head-objects `key` at `bytes`, moves only `ts`, and logs `skip: inputs
unchanged since <shipped> (<key>) - shipped nothing`. A full upload still
happens at least every `BACKUP_FORCE_HOURS` (24). To force one now, run
`BACKUP_FORCE=1 bin/state-backup.sh`; the console "back up now" action does
this. A stamp written before BH-6173 has no `manifest`, so its next run ships.

No stamp, or an old `ts`, means the lane is failing. It also writes one
`logs/ALERTS.log` line per failure naming the stage and the key NAMES — never a
value.

**And you do not have to look** — there is a freshness alert. Since
[#399](https://github.com/example-org/cromford/issues/399) that `ts` is a
fleet signal: `bin/fleet-heartbeat.sh` reads it off every box over the ssh hop
it already makes, `bin/fleet-status-push.sh` carries it as
`backups.<box>.backup_age_min` in the fleet_status snapshot, the console's Fleet
screen shows it on the box tile, and `bin/pipeline-health.sh` pages once an hour
per box — `backup-stale` past 30 minutes (two missed cycles; the knob is
`backup_stale_min`), `backup-missing` for a box that has never stamped. A box
that is switched off, or whose `BACKUP_*` keys are still unset, is carried as
state and never paged: the "not configured" line above already says that once a
day, and a second hourly page per box would only teach people to mute the
channel.

**Measuring the backup's CPU on the hub (BH-6173).** The backup runs on the
hub. #6173 asked to move it off the hub with the per-project lanes of #6047.
On 2026-10-11 #6047 changed: per-project lanes now run on Fly lane-run
machines. A Fly machine cannot read the hub's local disk, and that disk is what
this lane archives. The warm standby (`bin/state-restore.sh --standby`) also
pulls the hub's objects every 15 minutes. So the lane runs on the hub at idle
priority, and a measurement decides if that is enough. If the measurement
fails, a new ticket moves the work to another box.

`bin/lane-cpu-sample.sh` takes the measurement. It reads `/proc` every 5
seconds for a whole cycle, adds the ticks up, and prints the CPU share of each
lane. A process counts
under its nearest `bin/<name>.sh` ancestor, so the lane's `tar` and `zstd`
count as `state-backup`. A process that exits inside the window still counts:
its ticks reach its parent's reaped-children time, and the tool counts that for
the lane of the child that exited. It writes nothing but two temp files, and it
removes them.

The acceptance asks for "under 2% across one 15-minute cycle". The backup runs
at minutes 5, 20, 35 and 50, so one window from minute 4 to minute 19 holds
exactly one full run and the quiet time after it.

1. On the hub, at minute 4 of an hour, run:
   `bin/lane-cpu-sample.sh --seconds 900 --interval 5`
2. Copy the lane table and the last line
   (`state-backup share=<p>% PASS|FAIL (limit 2%)`), with the start time, to
   #6173.
3. If the line says `PASS` (share under 2%), close ask 4 of #6173 as not
   needed.
4. If the line says `FAIL` (exit 1, share 2% or more), file a ticket to move
   `state-backup` off the hub, with the table.

The defaults are `--lane state-backup --max-pct 2`; a printed share equal to
the limit is FAIL.

Each tick counts once: when a child exits, the part of its life an earlier
interval already counted comes off. The share can be low by at most one
interval per run: a run that starts and ends inside one 5-second interval
counts for the process that reaps it (cron, "other"). The tool's own CPU counts
as "lane-cpu-sample", about 1% on the hub. Exit 2 means no CPU ticks were seen,
so there is no share.

---

## Setup

You do this once per fleet, then once per box.

**1. The bucket.** Create an R2 bucket called `harness-state`. Create an S3 API
token scoped to that bucket only (object read + write + delete — the retention
pass deletes). The endpoint is
`https://<account-id>.r2.cloudflarestorage.com` and the region is `auto`.

**2. The age key pair.** Once, on a machine that is NOT a box:

```
age-keygen -o harness-state.key
```

It writes the **private key** to `harness-state.key` and prints the public key.

- The public key goes in `BACKUP_AGE_RECIPIENT` on **every** box. It can only
  encrypt.
- The private key **never lives on a box**. Put it wherever your fleet keeps
  break-glass material (a password manager, an offline drive). A box that could
  decrypt its own backup gives an attacker who owns the box every secret in the
  bucket as well as the ones on disk.

You hand the private key to the restore with `--identity <file>`, on the machine
doing the restore, at the moment you do it.

**3. The tools**, on every box:

```
apt-get install -y age zstd awscli
```

**4. The env block.** In `env/global.env` (chmod 600). The template with the
full comment is GENERATED and not committed (BH-1247): its source is one file
per topic under [env-templates/lanes/](../env-templates/lanes/), and
`bin/render-env-example.sh --write` concatenates them into
`env-templates/global.env.example` when you want the whole thing in one file.
The `BACKUP_*` paragraph lives in the backup topic file:

```
BACKUP_S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
BACKUP_S3_BUCKET=harness-state
BACKUP_S3_ACCESS_KEY_ID=<r2-token-id>
BACKUP_S3_SECRET_ACCESS_KEY=<r2-token-secret>
BACKUP_S3_REGION=auto
BACKUP_AGE_RECIPIENT=age1<public-key>
```

`BACKUP_AGE_IDENTITY_FILE` is read by the restore side if it is set, and it
should NOT be set on a box — it is there so an operator machine can point at the
private key once instead of typing `--identity` every time.

**5. First run**, on the box:

```
bin/state-backup.sh
cat state/backup-last.json
```

A stamp with today's `ts` means the whole chain works: encrypt, tar, upload,
verify.

---

## 3. Restoring from R2

Everything here is [`bin/state-restore.sh`](../bin/state-restore.sh). It lists,
pulls, checks the sha256 against the stored metadata, extracts, decrypts `env/`
if you gave it an identity, prints the box's old crontab and checkout head, and
then hands the extracted tree to [`bin/restore-merge.sh`](../bin/restore-merge.sh).

**Dry run is the default.** Nothing in the live tree is written without
`--apply`.

**What is there:**

One `<ts>  <bytes>` row per backup, oldest first. An empty prefix prints
`no backups for <box>` and exits 1.

```
bin/state-restore.sh <box>
20260915T232000Z  40960
```

**Pull the newest one and read the plan** (writes nothing to `/root/harness`):

```
bin/state-restore.sh <box> latest
```

You get, in order: the object on disk, `sha256 ok <sha>`, the extracted tree,
whether `env/` was decrypted, `--- meta/checkout-head.txt ---` and
`--- meta/crontab.txt ---`, then one `SAME` / `ADD` / `LEDGER` / `UNION` /
`KEEP-LIVE` / `META` line per file and a `SUMMARY mode=dry-run`. Read that list
before you go further. The crontab is **shown, not installed** — if the box
needs its cron lines back, you paste them yourself.

**Do it for real:**

```
bin/state-restore.sh <box> latest --apply --identity /path/to/harness-state.key
```

**A named snapshot, into a tree that is not this box's `/root/harness`:**

```
bin/state-restore.sh <box> <ts> --apply --identity /path/to/harness-state.key \
  --live /root/harness --dest /root/harness/tmp/state-restore
```

`--backup-dir` and `--orchestrator-live` pass straight through to
`bin/restore-merge.sh`.

**Without an identity** the run says

```
env/ NOT decrypted (no identity given): env files will not be restored
```

and restores everything else, exit 0. **With the wrong identity** it says
`REFUSED env/: age rc=...`, restores everything else, and exits **1** — so the
run does not look clean when the secrets did not come back. Re-run it with the
right key and `env/` lands as plain `ADD`s; the whole thing is safe to repeat.

**Cleaning up.** Run by hand, the tool never deletes anything, including its own
destination (a standby's `--standby` stream is the exception: it removes its
own run dir, see [the verification map](verification-map/state-restore.md)). A second pull into the same place is refused with
`already pulled at <path>`. You own the removal:

```
rm -rf /root/harness/tmp/state-restore/<box>/<ts>
```

That directory holds a decrypted `env/`. Remove it when you are done.

**Exit codes.** `0` everything asked for happened. `1` refused or partly
refused — not configured, no backups for that box, sha256 mismatch, wrong
identity, extraction failed, destination exists, or the merge reported a
failure. `2` usage error, a `--dest` inside `--live` (extracting a snapshot over
live content is the wipe again, one directory deeper — the one exception is
`<live>/tmp`, which is where the default lands and which the backup never reads
from), or no `bin/restore-merge.sh` next to the script.

---

## 4. What the merge does, file by file

`bin/restore-merge.sh` walks the snapshot tree. First match wins. Live content
NEVER loses to older snapshot content.

| rule | when | what happens |
|---|---|---|
| `SAME` | live exists and compares equal | nothing |
| `ADD` | missing in live | copied, with parents and mode |
| `LEDGER` | `logs/<name>.{log,csv,jsonl,tsv}`, `builds/<dir>/{pipeline.log,cost.csv}` and live differs | snapshot lines first, then live lines not already present |
| `UNION` | `state/merge-conductor/pr-state.tsv` and live differs | every live row, then snapshot rows whose key column is absent from live |
| `KEEP-LIVE` | everything else that differs | live wins, and the path is reported |
| `META` | `meta/**` | printed for you, never applied |

`env/**`, `state/quota/**`, `state/wake-cursor`, `flags/**` and
`state/pr-owners/*.json` reach `KEEP-LIVE` by construction, so a restore can add
them but never overwrite them. Every file `LEDGER` or `UNION` replaces is copied
to the backup dir first; a failed backup cancels that rewrite.

**The `.alerts-cursor` lesson.** This is the expensive half of #388.
`flags/.alerts-cursor` is a plain byte offset that `bin/poll-commands.sh` tails
`logs/ALERTS.log` from. The 2026-09-15 recovery restored a longer `ALERTS.log`
while the cursor still pointed at an offset inside the old content, so
poll-commands re-beat every historical alert behind it — #388 counts 424 alerts
re-sent, and the operator-visible flood was about a thousand. So the merge
rewrites the cursor to `wc -c` of the merged `ALERTS.log`, **last**, after the
whole walk, and skips it only if the `ALERTS.log` merge itself failed. If you
merge harness state by hand, do that yourself.

`restore-merge.sh` takes no lock. `--apply` is an operator action taken with the
lanes fenced (§5), not a concurrent writer.

---

## 5. Restoring from an Orgo daily snapshot

Orgo keeps a daily snapshot of each computer. In the Orgo console:
**Settings → Backups → Restore**.

Three things about it that decide how you use it:

- It creates a **NEW computer**. The original keeps running. Nothing is
  overwritten, and nothing is switched over for you.
- The new computer needs the **full RAM of the snapshot**, so the restore fails
  on a plan smaller than the one the snapshot was taken on.
- The copy boots with the original's crontab, the original's Tailscale identity
  and the original's harness state. It will immediately start acting like the
  box it was copied from.

**Fence the copy before it does anything.** First commands on the new computer,
before you look at anything else:

```
crontab -r
pkill -f 'bin/run-build.sh'
pkill -f 'bin/run-triage.sh'
pkill -f claude
```

Then take its Tailscale identity away, or two machines will fight over one node
name:

```
rm -f /var/lib/tailscale/tailscaled.state
```

Wipe `/var/lib/tailscale/tailscaled.state` **before** any `tailscale up` on the
copy. Bringing it up with the original's `tailscaled.state` is how you lose the
original's route.

Now the copy is an inert disk you can read. Merge what it has into the live box
— run this ON THE LIVE BOX, pointing at the copy's tree over whatever path you
have to it:

```
bin/restore-merge.sh --snapshot <copy's /root/harness> --live /root/harness
```

Read the plan. Then:

```
bin/restore-merge.sh --snapshot <copy's /root/harness> --live /root/harness --apply
```

Then put the R2 layer on top, because the snapshot is up to a day old and the
bucket is fifteen minutes old:

```
bin/state-restore.sh <box> latest --apply --identity /path/to/harness-state.key
```

Restore the crontab last, by hand, from `meta/crontab.txt` — once you are sure
the box is the one that should be running lanes.

---

## 6. The weekly restore drill

`bin/restore-drill.sh` runs on the hub every Sunday at 06:00Z (behind
`hub-lease.sh check`). It is how "can we come back from a hub wipe" becomes a
measured answer instead of a hope.

**What it proves.** It borrows a fresh Orgo computer, hands it to
`drill_on_box` (`bin/lib/restore-drill-steps.sh`), and deletes it again. Once the
on-box steps land (#1732) that means: the newest off-box backup restored onto a
clean box and came up usable, and how old it was (RPO).

**What it does not prove yet.** Until #1732 merges, `drill_on_box` is a stub.
Every armed run creates a box, FAILs `steps not implemented`, and deletes the
box. That is honest, not broken. It also does not touch the Orgo daily snapshot:
that path is §5, and you drive it by hand.

**Arming it.** On the hub, in the env (`/etc/harness/env/global.env`):

1. `ORGO_API_KEY` — the Orgo API key. A secret, env only.
2. `RESTORE_DRILL_TEMPLATE_REF` — an Orgo template ref you own. There is no
   default, on purpose.
3. `BACKUP_S3_ENDPOINT`, `BACKUP_S3_ACCESS_KEY_ID`,
   `BACKUP_S3_SECRET_ACCESS_KEY` — the same values state-backup uses (§Setup).
4. `RESTORE_DRILL_IDENTITY_FILE` — the path on the hub to the key that decrypts
   the restored env. Leave it unset and accept a weekly FAIL `env not decrypted`
   once the steps land.

`state/box-id` must be readable too. Until 1-3 and the box id are all there,
every run SKIPs `not configured - missing: <names>` and makes no Orgo call. No
ALERTS line for that. The knobs and their defaults are in
`env-templates/lanes/346-restore-drill.env.example`.

**Reading the verdict.** One beat per run, `kind:"fleet_event"`, line
`restore-drill: <VERDICT> <detail> RPO=<seconds|unknown>`. The same verdict is
in `state/restore-drill-last.json`.

| Verdict | Means |
|---|---|
| OK | `drill_on_box` returned 0 and said OK. Nothing else stamps OK. |
| FAIL | The create answered non-2xx (a 403 without `RAM_ADDON` included), the box did not reach `running` within `RESTORE_DRILL_DEADLINE_S`, the steps failed, the run was killed, or a leaked box from an earlier run would not delete. |
| SKIP | Not configured (names what is missing), or Orgo answered 403 `RAM_ADDON`: the account's RAM pool cannot fit a `RESTORE_DRILL_RAM_GB` box. |

**RPO.** `RPO=` is how many seconds old the restored backup was when the drill
ran. `unknown` means the steps did not report one, which every FAIL before the
steps does. The marker keeps it as `rpo_s`, with `last_ok_ts` (the last OK
run, carried forward across FAILs) and `first_run_ts`.

**The spend guard.** A box is billed, so a run whose marker `ts` is newer than
`RESTORE_DRILL_MIN_INTERVAL_H` hours (24) exits 0 without buying one. To run it
now anyway:

```
bin/restore-drill.sh --force
```

A second run while one is live exits 0 straight away (`locks/restore-drill.lock`).

**A leaked box.** The id of every box the drill creates is written to
`state/restore-drill-inflight` before anything else happens, and removed only
after the delete succeeds. If a delete fails you get ONE ALERTS.log line naming
the id, and the next run deletes it before it buys another (if that fails too,
the run FAILs and buys nothing). To delete it by hand on the hub:

```
set -a; . /etc/harness/env/global.env; set +a
id=$(cat /root/harness/state/restore-drill-inflight)
curl -sS -X DELETE -H @<(printf 'Authorization: Bearer %s\n' "$ORGO_API_KEY") \
  "https://www.orgo.ai/api/computers/$id" -w '\n%{http_code}\n'
rm /root/harness/state/restore-drill-inflight   # only after a 2xx or 404
```

The drill never deletes by name or by listing computers. It only deletes the id
it created or the one in that file.

---

## 7. Rebuilding the fleet registry (D1)

The fleet registry (projects, boxes, lane memberships, account-to-box rows)
lives in the harness-jobs D1 database (BH-5651). Use this drill when that D1
is lost, reset or wrong. Run it on the hub.

The input is a nightly snapshot. The hub lane `registry-export`
(`41 3 * * *`) runs `bin/registry-export.sh --snapshot` and writes
`state/registry/export/<YYYYmmddTHHMMSSZ>/` with `registry.json`,
`import.json`, `fleet.conf` and `cost-accounts.json`.
`state/registry/export/latest` points at the newest one. The lane keeps
`REGISTRY_EXPORT_KEEP` snapshots (default 14).

1. Find `/root/harness/state/registry/export/latest` on the hub. If the hub
   lost it, restore the hub's `state/` from R2 first (§3) or from the Orgo
   snapshot (§5). Both carry `state/`.
2. If the D1 was reset or replaced under the same database name, remove the
   three stamps that make the next sync skip the apply:
   `rm /root/harness/state/worker-schema-applied-jobs /root/harness/state/worker-schema-progress-jobs /root/harness/state/worker-deployed-jobs`.
3. Run `bin/harness-sync.sh`. On a box with `env/cloudflare.env` it applies
   `worker/jobs/schema.sql` to D1, then deploys the jobs worker. Check
   `logs/update-runners.log` for `worker jobs schema.sql applied`.
4. Set `JOBS_URL`, `HARNESS_SECRET` and `REGISTRY_ADMIN_TOKEN` in the shell.
5. If the registry is empty (version 0, or 503 `registry schema not applied`),
   run `bin/registry-seed.sh --from-export /root/harness/state/registry/export/latest`.
6. If the registry is not empty, the seed refuses with
   `the registry is already seeded`. Run
   `bin/registry-seed.sh --from-export /root/harness/state/registry/export/latest --force`.
   The import does not delete rows that the snapshot lacks. It counts them as
   `stale=<k>` in its output line.
7. Check that `bin/registry.sh show` prints `projects=<n>`, where `<n>` is
   `jq '.projects | length' /root/harness/state/registry/export/latest/import.json`.
8. Check that this prints nothing:

   ```bash
   diff <(REGISTRY_SOURCE=db REGISTRY_CACHE_TTL_S=0 bin/fleet-conf.sh --projects) \
        <(awk '!/^[[:space:]]*(#|$)/ {print $1}' /root/harness/state/registry/export/latest/fleet.conf)
   ```

The boxes pick up the restored registry on their next `registry-sync` tick
(`*/5`). That tick rewrites `$H/fleet.conf` from the registry and applies the
crontab when the registry version differs from
`state/registry/applied-version`.

---

## Read next

| If you want to | Read |
|---|---|
| Stand up a fleet from nothing | [OPERATOR-SETUP.md](OPERATOR-SETUP.md) |
| What went wrong before, and what the rule is now | [LESSONS.md](LESSONS.md) |
| The env keys, with their comments | [env-templates/lanes/](../env-templates/lanes/) — one file per topic; `bin/render-env-example.sh --write` renders them into the single `env-templates/global.env.example`, which is generated and not committed (BH-1247) |
