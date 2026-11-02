# Adding a box

A box is one fleet machine that runs the watchers of one or more projects.
Nine lists in this repo name each box. A box that is missing from one list is
not an error anywhere: it is a box that pings nobody, bills nobody, or is never
collected. `bin/box-register.sh` writes a box into every list with one command.
`bin/box-lists-check.sh` proves that the lists agree with `fleet.conf`.

`bin/box-launch.sh` makes the machine on Orgo, joins it to the tailnet,
installs the harness, runs `box-register.sh` and bootstraps the box. See
"Launching an Orgo box" below. The rest of this page is the repo side.

## Launching an Orgo box

```bash
bin/box-launch.sh newbox --project <p> --account <orgo-account>            # dry run
bin/box-launch.sh newbox --project <p> --account <orgo-account> --apply --confirm-monthly-usd <n>
```

`--account` is a key in `catalog/orgo-plans.json` `.accounts`. That entry gives
the plan limits, the pool, the prices, the template, the default specs and the
`catalog/cost-accounts.json` account for `box-register.sh`. `--vcpus`,
`--mem-gb` and `--disk-gb` override the defaults. A value over the vCPU cap, a
RAM size that is not a tier, or a value that is not a positive integer is
refused. `--root <dir>` is the checkout for the catalog, `box-register.sh` and
git (the default is the checkout the script is in).

The dry run is the default. It reads `GET /computers` (only when `ORGO_API_KEY`
is set), prints one `PLAN` line per step that is not done, and writes nothing.
`--apply` needs `--confirm-monthly-usd` equal to the `$/mo` the dry run prints,
until the computer exists. It also refuses before any network call while
`ORGO_API_KEY`, the catalog `template_ref` or `pool`, `BOX_LAUNCH_TS_AUTHKEY`
or the hub public key is missing.

| Step | What it does | Done when |
|---|---|---|
| `capacity` | Sums `GET /computers` against the catalog pool. Re-read on every run until the state has an Orgo id | The pool fits the specs |
| `create` | `POST /computers` with the catalog `template_ref`. A computer named `<host>` is adopted, not bought again | The Orgo id is in the state file |
| `running` | Polls `GET /computers/<id>` | `.status` is `running` |
| `tailnet` | Orgo bash: starts `sshd`, `cron`, `tailscaled`; `tailscale up` | A `100.64/10` address is in the state file |
| `hubkey` | Orgo bash: the hub public key into `authorized_keys` | `ssh root@<ip> true` is rc 0 |
| `harness` | ssh: clones or pulls `/root/harness-checkout`, syncs `/root/harness`. The new box has no GitHub credential yet, so the hub mints a short-lived token with `bin/gh-token.sh` and sends it on ssh stdin, never in argv | rc 0, `harness-sync.sh` included |
| `envfiles` | scp `global.env`, `<p>.env` and the optional files | Each file has the same sha256 on the hub and the box |
| `migrate` | ssh: `bin/migrate-env-dir.sh` | rc 0 |
| `ghapp` | ssh: `bin/ensure-box-gh-app-default.sh <p>` | rc 0, or rc 3 (recorded as `done-warn`) |
| `register` | `bin/box-register.sh <id> --ip <ip> --project <p> --account <a> [--like <box>] --apply` | rc 0 |
| `merged` | `git fetch`, reads `origin/main:fleet.conf` | The `<p>` row names the host and the address |
| `bootstrap` | ssh: `harness-sync`, `state/box-id`, `bin/bootstrap-machine.sh <p>` | rc 0 |
| `smoke` | ssh: `state/box-id`, the fleet-managed crontab block, `sshd`, `tailscale status` | All four pass |

Each step is stamped in `state/box-launch/<id>.json` after its effect is
verified. A re-run starts at the first step that is not stamped. A re-run with
other `--project`, `--account` or specs is refused: the state file is bound to
them. The env files are compared by name and hash. The script prints
`envfile <name> match` or `differ`, never a value or a hash.

### Why the script stops at `merged`

`box-register.sh` writes the working tree and never commits. Bootstrap reads the
box id from the `fleet.conf` row on the box (`bin/bootstrap-machine.sh`), so it
must run after the register change is on `origin/main`. The script prints
`WAITING: ...` and exits 4. Commit the change (step 4 below), open its PR, merge
it, and run the same command again.

The last stdout line is always the summary:

```
box-launch: box=newbox orgo=<orgo-id> ip=10.0.0.13 specs=4c/8gb/-gb usd_mo=73 smoke=PASS
```

| Code | Meaning |
|---|---|
| 0 | Done, or the dry run printed its plan. |
| 1 | A step failed. The state file keeps what is done. |
| 2 | A usage error, a refusal, a missing confirm or a missing setting. Nothing was bought. |
| 3 | `NEEDS PURCHASE: <dim> <qty> $<n>/mo`. The pool is short. Nothing was bought. |
| 4 | `WAITING`: the register change is not on `origin/main` yet. |

## The order of steps

1. Give the project a `fleet.conf` row. If the project is new, run
   `bin/load-project.sh <owner/repo> --project <p> --box <host> --no-bootstrap`.
   `box-register.sh` refuses a project that has no row. It does not invent a
   repo slug, a prod URL or a cron offset.
2. Run the dry run. It prints one `PLAN` line per change and writes nothing:

   ```bash
   bin/box-register.sh newbox --ip 10.0.0.13 --project <p> --account <account>
   ```

3. Read the `PLAN` lines. Then run the same command with `--apply`.
   The script runs `bin/box-lists-check.sh` and `bin/render-cron.sh newbox` after
   it writes. A red post-check is exit 1. The script does not roll back: use
   `git status` and `git diff` to see what it wrote.
4. Commit the change set alone (the last `NEXT: git add` line names the paths).
   Open its PR. The script never commits or pushes.
5. After that PR merges, make a fresh branch from `origin/main` and run the
   trap-eval step. Open it as its own PR:

   ```bash
   bin/box-register.sh newbox --trap-eval --apply
   ```

6. On the box, after the merge, install its crontab:
   `bin/render-crontab.sh newbox | crontab -`.

### Why trap-eval is a separate step

`tests/trap-eval-e2e.bh-128-test.sh` goes red when one branch diff changes both
`catalog/lanes.d/trap-eval.json` and a file under `cron/` (BH-1965). Registering
a box always changes `cron/`. So the main step never edits `trap-eval.json`,
and the trap-eval step refuses (exit 3) on a branch that already changes
`cron/`. The main step refuses (exit 3) on a branch that already changes
`trap-eval.json`.

## The arguments

| Argument | Meaning |
|---|---|
| `<id>` | The box ID. Lowercase letters and digits, first a letter: `^[a-z][a-z0-9]*$`. A hyphen is refused: the sanitizer and the lane registry break on one. `hub` is refused. |
| `--ip` | The tailnet address of the box. It must be in the CGNAT range `100.64/10` (second number 64 to 127). Another box must not have it. A box that already has an address keeps it. |
| `--project` | The `fleet.conf` row that moves to this box. |
| `--account` | The key in `catalog/cost-accounts.json` `.accounts` that pays for this box. Required until the box is in an account. A different account for a box that already has one is refused: one box, one account. |
| `--like <box-id>` | Copy that box's `cron/boxes/<box-id>.d` fragments, its `.order` file and its lane set. Use it for a box that needs a machine-specific fragment, for example the `@reboot` sshd line of an Orgo claude-code box (`--like project-6-os`). |
| `--root <dir>` | The repo checkout to edit. The default is the checkout the script is in. The script reads `<dir>/fleet.conf` only, never the caller's `FLEET_CONF`. |
| `--apply` | Write. Without it, the script is a dry run. |

The host name of a new box is `<HARNESS_BOX_PREFIX><id>` (`box-newbox`
by default). A box that already has a `fleet.conf` row keeps its host name.

The default lane set is the set of lanes that every other active watcher box
runs. The script reads it from the lane registry; it is not a list in the
script. A box that is already registered keeps its own lane set, unless you
give `--like`.

With `--like`, if the copied set has `healthcheck` and the project has no prod
URL (`-` in column 3), the script prints one `WARN` line and keeps the lane.

## The lists

| # | List | What it is for | Who reads it |
|---|---|---|---|
| L1 | `fleet.conf` column 6 (host) and column 7 (tailnet address) | The registry. Every other list is checked against it. | `bin/fleet-conf.sh`, `bin/box-for.sh` |
| L2 | `cron/boxes/<id>.d/` | The box's own crontab lines: `000-path.cron` and the `# @fleet-managed` marker. | `bin/render-cron.sh` |
| L3 | `cron/boxes/<id>.order` | Lanes that run at a box-specific position. Only with `--like`, when that box has one. | `bin/render-cron.sh` |
| L4 | `catalog/lanes.d/*.json` `.boxes` | Which lanes the box runs. | `bin/lanes-build.sh`, `bin/render-cron.sh` |
| L5 | `catalog/cost-accounts.json` `.box_aliases` | Host name to box ID, for cost rows. | `bin/cost-reconcile.sh` |
| L6 | `catalog/cost-accounts.json` `.accounts[<a>].boxes` | The box ID in `cost_rows` and the host in `jobs` (before a `pool-*` glob). | `bin/cost-reconcile.sh`, `bin/extra-usage-track.sh` |
| L7 | `worker/watchdog/src/boxes.json` | The boxes the watchdog expects a ping from. | the watchdog worker |
| L8 | `bin/share/mapping.py` `TAILNET_IPS` | Maps the address to a placeholder `10.0.0.<N>` before the repo is published. | `bin/share/` |
| L9 | `bin/cost-rollup.sh` overage loop | Which box meters the hourly rollup collects. | reads `bin/fleet-conf.sh --box-ids`: no edit |

The `BOXPROJ` string in `bin/cost-rollup.sh` is a project list, not a box list.
The rollup already adds every `fleet.conf` project to it, so a new box needs no
edit there. The parity check does not read it.

The edits to the two `jq`-stable JSON files (L5, L6, L7) use `jq`. The lane
files (L4) get a text edit of the `"boxes"` array only, because five lane files
are not `jq`-stable. The script checks that nothing outside `.boxes` changed.

## The parity check

```bash
bin/box-lists-check.sh            # this checkout
bin/box-lists-check.sh --root DIR # another checkout
```

The required boxes are `bin/fleet-conf.sh --box-ids` plus `hub`. A box named by
a `# @retired <project> <box>` line in `fleet.conf` is allowed in a list, and
not required. The check prints one line per finding and a summary line:

```
MISSING watchdog newbox
EXTRA lanes ghostbox
BAD cost_rows newbox in 2 accounts
box-lists: 3 finding(s) over 11 boxes
```

Exit 0 is no finding. Exit 1 is one or more findings. Exit 2 is an input it
could not read; it never reads a missing file as "no finding".

L8 is checked in one direction only. Every `fleet.conf` address must be a
`TAILNET_IPS` key. The table also maps the hub's address and old addresses
that no row names, and those entries must stay.

The public mirror ships no `bin/share/`, so it has no L8 table. There the
check prints one `NOTE tailnet_ips skipped` line and checks L1 to L7 and the
cost rollup. `box-register.sh` prints `NOTE L8 ... skipped` and writes the
other lists.

`tests/box-lists-parity.bh-5747-test.sh` runs the check on this repo, and on
fixtures where one list misses a box.

## Moving a project

Run the register command with the target box and the project. The script sets
column 6 and column 7 of that row. If that was the last project on the old box,
the post-check prints `NOTE` lines for the old box and a `NEXT` line to retire it.

## Box operations

`bin/box-ops.sh` with no argument is the cron tick that runs console box
commands. With a verb as the first argument, it operates one Orgo box:

```bash
bin/box-ops.sh restart oldbox                                  # dry run
bin/box-ops.sh stop oldbox                                     # dry run
bin/box-ops.sh resize oldbox --account project-6-account --mem-gb 8   # dry run
bin/box-ops.sh retire oldbox --to newbox                       # dry run
bin/box-ops.sh stop project-6-os --host box-project-6-os-1             # dry run, named host
bin/box-ops.sh retire project-6-os --host box-project-6-os-1 --delete  # dry run, named host
```

Add `--apply` to do the work. The code is in `bin/lib/box-ops-orgo.sh`.

`--host <name>` (restart, stop, retire) names the Orgo computer when another
box has the same box id. `bin/box-move.sh` keeps the old box id on the new
box, so without `--host` the id resolves to the new box (BH-8325). With
`--host`, box-ops reads the projects of that host and skips a state file that
names another host. `retire --host` without `--delete` is refused when another
live box has the id. `retire --host --delete --apply` skips the
`cron/boxes/<id>.d` check when origin/main gives the id to another live box.
The runbook is `docs/notes/2026-11-02-BH-8325-MKF-10-isolation.md`.

- `restart` sends `POST /computers/<orgo-id>/restart`, then reads
  `GET /computers/<orgo-id>` until the status is `running`.
- `stop` pauses each project on the box first: `flag_set paused-<p> on`
  writes the `pause_flags` row, then the `flags/` file. If one row does not
  land, the verb stops (exit 1) and the computer is not stopped. Then it
  sends `POST /computers/<orgo-id>/stop` and waits for `stopped`. It sends no
  POST when the computer already reports `stopped`. It never
  lifts a pause. It prints one `NEXT: lift with bin/jobs-client.sh flag-set
  paused-<p> off` line per project.
- `resize` needs `--account` (a key of `catalog/orgo-plans.json`). It reads
  the current specs. The flags you give are the target; the rest stay. It
  checks the plan limits and prices the change from the catalog. A price that
  is `null` is refused. When a dimension grows, it checks the account pool. A
  short pool prints `NEEDS PURCHASE: <dim> <qty> $<n>/mo` (exit 3). A `null`
  pool refuses `--apply`. A change that adds cost needs
  `--confirm-monthly-usd <n>`, where `<n>` is the added `$/mo` from the
  `COST:` line (not the new total). Then, in this order: ssh to the box and run
  `bin/quiesce-for-resize.sh` (its last line must start with
  `SAFE_TO_RESIZE`); `PATCH /computers/<orgo-id>/resize` with the changed keys
  (`cpu`, `ram`, `disk`); check that the `results` array names each key and
  reports no failure; read the specs again. The specs must equal the target.
  Orgo ignores a wrong key without an error, so both checks are necessary.
  Quiesce pauses the watchers on the box, and resize does not lift that pause.
- `retire` is described in "Retiring a box" below.

The box id is refused for `hub`, for the box that runs the command and for an
id that does not match `^[a-z][a-z0-9]*$`. The Orgo id comes from
`state/box-launch/<id>.json`, then `state/box-ops/<id>.json`, then the one
computer on `GET /computers` whose name is the box host. Zero or two matches
are refused. The key is the `--account` entry's `key_env`, else
`ORGO_API_KEY`. The script prints the name of an unset key, never a value.
`--apply` takes the dedupe lock `locks/box-ops-orgo-<id>.lock`; if it is
held, the script prints `box-ops: <id> already running` and exits 0. The
timeouts are the `BOX_LAUNCH_CALL_TIMEOUT_S`, `BOX_LAUNCH_POLL_S` and
`BOX_LAUNCH_DEADLINE_S` knobs.

The last stdout line is always
`box-ops: verb=<v> box=<id> orgo=<orgo-id> result=<OK|FAIL|PLAN|WAITING|REFUSED> <detail>`,
except when the lock is held.
The exit codes are the same as `bin/box-launch.sh`: 0 done or planned, 1 a
step failed, 2 a usage error, a refusal, not configured or a `COST:` line,
3 `NEEDS PURCHASE`, 4 `WAITING`.

The Orgo `stop`, `resize` and `DELETE` calls and the `results` shape are not
yet proven against the real API. `tests/box-ops-orgo.bh-5749-test.sh` stubs
them.

## Retiring a box

1. Move the projects and retire the box in the working tree:
   `bin/box-ops.sh retire oldbox --to newbox --ip 10.0.0.13 --apply`.
   It writes `state/box-ops/oldbox.json`: the host, and the Orgo id when a
   state file has it. It runs
   `bin/box-register.sh newbox --ip <newbox ip> --project <p> --apply` for
   each project on the box, then `bin/box-register.sh --retire oldbox --apply`.
   Without `--to`, it refuses (exit 2) while a project is on the box.
2. If `trap-eval.json` lists the box, step 1 stops after the moves (exit 2,
   `box-register --retire rc=3`). Commit the moves and merge them. On its
   own branch, take the box out of trap-eval:
   `bin/box-register.sh --retire oldbox --trap-eval --apply`. Merge it. On a
   fresh branch from `origin/main`, run step 1 again. No project is on the
   box now, so `--to` is not necessary.
3. Commit the change, open its PR and merge it.
4. Delete the Orgo computer: `bin/box-ops.sh retire oldbox --delete --apply`.
   It deletes only after `origin/main` has no `fleet.conf` row for the box
   host and no `cron/boxes/oldbox.d`. Until then it prints `WAITING` and exits 4.
   After the `DELETE`, a `GET` must show that the computer is gone. Then it
   stamps `deleted_at`, and a re-run deletes nothing.

`bin/box-register.sh --retire` refuses (exit 2) while a `fleet.conf` row names
the box, when a `# @standby` line names it, and for `hub`. It refuses (exit 3)
while `trap-eval.json` lists the box. `box-ops.sh retire` reports both as exit 2.

Retire removes L2 to L7. L1 needs no edit, because no row names the box. L8
is removed only when you give `--ip` and no other tracked file contains the
address. Otherwise the script keeps the entry and prints one `KEPT` line with
the files. The table is a redaction table: removing an address that a note
still contains would publish that address.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done, or the dry run printed its plan. |
| 1 | An apply step or the post-check failed. |
| 2 | A usage error or a refusal. Nothing was written. |
| 3 | Refused by the BH-1965 order. Nothing was written. |
