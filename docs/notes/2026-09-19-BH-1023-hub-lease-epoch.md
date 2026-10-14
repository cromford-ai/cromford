# `hub-lease.sh check` re-validates the cached epoch, behind a flag row; the hub checkout still has to be re-pointed by hand

Doc: HUB-THINNING-PLAN

BH-432 (#785) landed the gating half of the lease: `cron/hub.cron` carries one
ungated `hub-lease.sh renew` line a minute and the hub lanes rendered behind
`hub-lease.sh check && `. Two items from #1023 were left: the epoch
re-validation, and re-pointing `/root/harness-checkout` at `origin/main`. This
note is the first one, plus the recipe for the second.

## The window this closes

`check` answered from `state/hub-lease.json` whenever that file was younger than
`HUB_LEASE_CACHE_S` (60 s) — no request, no comparison. `epoch` is the fencing
token, so a `promote` elsewhere, or an expired lease re-taken at `epoch+1`, was
invisible to the box that just lost it until its NEXT `renew` got a 409. For up
to a minute, two boxes both ran hub lanes. The 600 s grace path widens the same
window when the worker is unreachable, and that half is deliberately unchanged:
a re-validation cannot compare against a row it cannot read.

## What changed, in `bin/hub-lease.sh`

**`_epoch_check_on`** decides the mode, cheapest first and never a request of its
own: `HUB_LEASE_EPOCH_CHECK=1|0` wins both ways — from the process environment
first, then from `global.env` in the harness env dir — else the file
`flags/hub-lease-epoch-check`, else OFF. It ships OFF, so today's behaviour is
what every box gets on merge, byte for byte.

The env-file read is its own line, and it is the reason the box-local kill
switch is worth anything: the gated consumers are bare crontab lines with no env
loading at all, so a variable only the CLI would have sourced is invisible
exactly where this runs. `_epoch_check_env_file` pulls that ONE variable with the
same anchored `sed` `bin/jobs-client.sh` uses for `HARNESS_SECRET` — never
`set -a; . global.env`, which would drag a box's whole secret file into every
gated lane a minute. The anchor also keeps the template's commented
`#HUB_LEASE_EPOCH_CHECK=1` inert, and a value that is neither `1` nor `0` is not
an override: it falls through to the file, the same as unset (E9b-E9f).

**`cmd_check` step 1.** A fresh cache that says `held=0` still exits 1 with no
request in either mode — a non-holder has nothing to re-validate and never pays.
A fresh cache that says `held=1` exits 0 immediately when the knob is off; when
it is on, the cached `epoch` is carried into step 2 instead of short-circuiting.

**`cmd_check` step 2, rc 0.** `held=1` now additionally requires the row's epoch
to equal the carried one. Both sides go through the same `jq '(.epoch|tonumber?)
// empty'`, so a `"1"` from the wire equals a cached `1`; a row with no `epoch`
at all yields empty and is **never** equal, because absent is not "unchanged".
The cache is written with the ROW's epoch, so the next `renew` sends the right
fence. Steps 2 rc 1|2 and `*` are untouched.

**`cmd_renew`** gained `_sync_epoch_flag` before the `exit` in its two ANSWERED
arms (200 and 409): `flag_sync hub-lease-epoch-check`, guarded by `command -v`
so a box whose `jobs-client.sh` predates `flag_sync` keeps renewing. It is the
one lane already on the network every minute, which is why the knob costs
`check` nothing. The unreachable (`*`) arm deliberately does NOT sync: the flag
GET goes to the worker that just failed, so it can only fail too — it would
double that minute's timeout budget (~17s → ~34s) and write a second
`_jobs_log` line a minute for nothing, and the next answered renew reconciles
the row within a minute. A missing row leaves the file exactly as it is, and
renew's own exit code is decided before the sync runs. The epoch `renew` caches was already the
one the server GRANTED rather than the one it asked for; that is now pinned by a
test (E7) so an edit that caches the requested epoch goes red.

## Cost, with the flag on

The hub adds one GET per gated lane invocation whose cache was fresh and held —
at most one per gated lane a minute, single-D1-read each. On a worker outage each of those
spends `JOBS_TIMEOUT` (8 s) plus one retry before falling into the grace path
that already existed. The renew lane adds one `GET /api/flags/...` a minute, on
the hub only. No lock, no queue, no cap touched.

Dark, the only new cost is local: a gated lane whose cache is fresh and held now
`sed`s one line out of `global.env` before it answers from the file. One small
read per lane invocation, no network, on the path that used to short-circuit.

## Known race, not fixed here

`renew` and `check` both write `state/hub-lease.json` (atomically, temp+mv). If
`check` reads epoch N while `renew` is being granted N+1, `check` can write N
back; the next `renew` then sends N, gets a 409, and caches N+1 with `held=0`;
the one after that renews normally. One skipped minute, self-healing.

## Turning it on

Land the PR, wait an hour of healthy renews, then:

```bash
bin/jobs-client.sh flag-set hub-lease-epoch-check on "BH-1023"
# probes, on the hub, a minute later
ls /root/harness/flags/hub-lease-epoch-check     # exists
cat /root/harness/state/hub-lease.json           # held=1, fetched_at advancing
tail -3 /root/harness/logs/hub-lease.log         # silence is the healthy state
```

Off is `flag-set hub-lease-epoch-check off "BH-1023"`, never deleting the row: a
deleted row answers 404, which `flag_sync` reads as "nothing to reconcile" and
leaves the file — and the file is the switch. `HUB_LEASE_EPOCH_CHECK=0` in a
box's `global.env` (the harness env dir: `/etc/harness/env`, or `/root/harness/env`
where that is still a real directory) is the box-local kill switch, wins over the
file, and takes effect on the next minute's lanes with nothing to restart — the
script reads that variable itself, so it works from cron, which sources nothing.
Write it however the file is already written: `export HUB_LEASE_EPOCH_CHECK=0`,
an indented line, a trailing `# off during the incident`, a trailing tab and a
CRLF ending all resolve to the same 0 (E9h-E9n). Appending it under a line the
rollout already wrote works too — the LAST assignment wins, the way sourcing the
file would (E9m); first-wins is what made an appended kill switch a no-op in
silence. A COMMENTED line is still not a setting, and a value that is neither 1
nor 0 falls through to the flag file AND writes a
`knob: HUB_LEASE_EPOCH_CHECK=<v> ignored` line into `logs/hub-lease.log` — once
per incident, behind `flags/alerted-hub-lease-knob`, which is cleared the moment
the knob resolves — so a typo is visible in the log instead of reading as
agreement, without ~53 lines a minute for as long as it stands.
Exporting it into a process wins over the file too, but that only reaches the one
process, which is why the operator path is the env file.

## Re-pointing `/root/harness-checkout` at `main` — the guard's job, not yours

Since BH-1099 (#1121) this is automatic, and this note no longer claims
otherwise. `bin/fleet-propagate.sh` runs every 5 minutes on the hub and, before
its ff-only pull, reads the checkout's branch: a CLEAN checkout that no process
has its cwd under is forced back to `main`, logged as `hub: checkout was on
<branch>, forced back to main`. A dirty or in-use checkout is REFUSED instead —
`hub=fail`, with `hub_reason` naming the branch and the cause. On top of that
`bin/harness-sync.sh` refuses a non-main checkout with rc 30 (`refused
branch=<name>`) before it fetches anything, and sets `BRANCH=main`
unconditionally, so it can only ever deploy main. The contract for both is
`docs/verification-map/fleet-propagate-branch-guard.md`. Detection is separate
and still pages: `bin/pipeline-health.sh` check 8 ("Fleet checkout freshness")
compares that checkout's HEAD to `origin/main` every 10 minutes, tries the
idempotent `harness-sync.sh deploy` as an auto-heal, and raises
`driftfail:local` while HEAD is still not `origin/main`.

So the HAND step below is for ONE case: `fleet-propagate` logging `hub=fail`
because the checkout is dirty or in use. A build box has no access to the hub's
filesystem, so it has to be driven there, and the reason comes first — if the
guard is merely waiting on a process, the next `*/5` tick re-points it with no
help.

```bash
# on the hub (box-hub), as root — only after fleet-propagate logs hub=fail
grep 'hub:' /root/harness/logs/fleet-propagate.log | tail -3   # the refusal and its reason
git -C /root/harness-checkout status --porcelain --untracked-files=no   # what made it dirty
git -C /root/harness-checkout fetch -q origin main
git -C /root/harness-checkout merge-base --is-ancestor HEAD origin/main && echo "branch is merged, nothing to lose"
git -C /root/harness-checkout checkout -q main && git -C /root/harness-checkout pull --ff-only -q
/root/harness/bin/harness-sync.sh
git -C /root/harness-checkout rev-parse --abbrev-ref HEAD        # main
diff <(crontab -l) /root/harness-checkout/cron/hub.cron       # empty = no drift
```

If `--is-ancestor` fails, the branch carries commits main does not — open a PR
for them first rather than checking out over them. If the refusal said "in-use
by pid N", find out what that process is before taking the checkout out from
under it.

## How it is proven

```bash
HARNESS_TEST_SANDBOX=1 bash tests/hub-lease-epoch.bh-1023-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/hub-lease-test.sh
```

The first drives the real `bin/hub-lease.sh` CLI against a stubbed curl with a
pinned clock, asserting exit codes, the cache JSON, the ALERTS count and the
request sink — never the script's source text. E0 pins the dark path (no
request at all), E1 is the ticket's red case (fresh cache says held, row says
epoch+1), E3/E3b pin that the unreachable paths are unchanged and silent inside
grace, E5 pins that a non-holder makes no request, E7 the granted epoch, E8 the
row→file sync through `renew` and E8b that an unreachable renew fires no second
request into the same outage, E9 the env-over-file precedence, E9b-E9f the
`global.env` kill switch in the cron shape (the variable absent from the process,
present only in the file) with its precedence, its commented-line case and its
junk-value case, E9g that the runner's own `HARNESS_ENV_DIR` cannot decide those
cases, E9h-E9k that a trailing `# comment`, an `export ` prefix, a CRLF ending
and a leading indent each still kill the re-validation while a COMMENTED line
still does not, E9m that the LAST assignment in the file wins both ways (an
appended kill switch is honoured), E9n the trailing tab, E9l that an
unresolvable value is logged by name — including one masked by a later source —
and a dark box logs nothing, E9o that the line is once per incident and re-arms
once the knob resolves, E10 the string and absent epochs, D1 that no doc pins a
literal count of the gated lanes. The suite passes the knob to
the child only when a case sets it, so "unset" is unset the way a crontab line
runs it. Point `HUB_LEASE_SCRIPT` at `git show main:bin/hub-lease.sh` to watch it
go red.
