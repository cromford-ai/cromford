# 2026-10-14 — BH-6742: flyctl and gh stay current; security updates are provisioned

Doc: BOX-SETUP, RUNNER-CLIS

## What changed

`bin/cli-update.sh` (every box, daily 05:17Z through `bin/update-runners.sh`)
now updates two more tools after claude, codex and grok, with the same
`logs/cli-versions.csv` row, stdout line and DB push:

| Tool | Where | How | Kept on failure |
|---|---|---|---|
| flyctl | every box that has it (today only the hub): `$HOME/.fly/bin/flyctl` first, else `command -v flyctl`/`fly` | `flyctl version upgrade` | the binary is copied to `<bin>.prev.tmp` first; a run that leaves it missing or older copies it back (`restored-prev`); a run that moved it keeps `<bin>.prev` (rollback: `cp -p <bin>.prev <bin>`) |
| gh | every box with apt-get | GitHub's own apt repo (`cli.github.com`): `sources.list.d/github-cli.list` + `keyrings/githubcli-archive-keyring.gpg`, added once; then `apt-get update` of that list only and `apt-get install gh` | apt keeps the old package when the install fails; a run that leaves gh missing or older reinstalls the dpkg version it had (`gh=<version>`) |

`CLI_UPDATE_SYS_TOOLS` (default `flyctl gh`) names them. A scratch box
(`CLI_UPDATE_HOME` set, tests only) runs neither unless the test names them.

## Security updates in provisioning

`bin/security-updates-ensure.sh` declares the setup operator-a5 applied by hand
on 2026-10-14 (the operator approved security updates, #6742):

- the package `unattended-upgrades`;
- `/etc/apt/apt.conf.d/52harness-security-only`: the `-security` pocket and the
  ESM apps and infra security pockets only, `Automatic-Reboot "false"`;
- `/etc/needrestart/conf.d/50-harness.conf`: `$nrconf{restart} = "l"` (list
  the services that need a restart, restart none);
- `/etc/cron.d/harness-security-updates`: 04:17Z daily, a random delay of up to
  20 min, `apt-get update -qq` (timeout 600 s), then `/usr/bin/unattended-upgrade`,
  both into `/var/log/harness-unattended.log`.

`bin/bootstrap-machine.sh` runs it on the first boot and
`bin/update-runners.sh` every day. It writes a file only when the content
differs. Two changes from the hand setup:
- The cron file now sets `SHELL=/bin/bash`. cron runs a `cron.d` line with
  `/bin/sh`, which has no `$RANDOM`, so the hand-made line always slept 0 s.
- The cron line runs `apt-get update` before `unattended-upgrade`.
  `unattended-upgrade` does not refresh the package lists, and the apt timers
  that do it never fire on these boxes. Without the update, the run reads old
  lists: it installs nothing new, or it gets a 404 on a removed version. The
  two steps are joined with `;`, so one broken source does not stop the
  security run.
The first daily run rewrites that file once on the hub and the 5 boxes.

## The check

`bin/cli-version-check.sh` (hub, 05:40Z) adds one report line per probed box:
`<id> security updates: last run <at|never>, <n> pending, setup yes|NO`. The
last run is the newest write of `/var/log/harness-unattended.log` or
`/var/log/unattended-upgrades/unattended-upgrades.log`; pending is the count of
`-security` packages a read-only `apt-get -s upgrade` would install, or
`unknown` when that simulation fails or times out. It is a
report line, not an alert. A box judged from its self-report is not ssh'd that
day, and its line says so.

## node and tailscale (the follow-up PR)

`bin/cli-version-check.sh` also reads `node --version` and `tailscale version`
on each probed box and compares them with the vendor's release feed:

- node: `https://nodejs.org/dist/index.json`, counted in the box's own major
  line only (a new major is a migration, not an update);
- tailscale: the GitHub releases of `tailscale/tailscale`, without drafts and
  prereleases.

The report line is `<id> tools: node <v> (current | latest <x>: <n>
releases, <d> days behind | latest unknown ...), tailscale ...`. `<d>` counts
from the release date of the oldest release newer than the box's version. One
ALERTS line per box per UTC day (`state/tool-behind-alerted`) when a tool is
more than `CLI_CHECK_TOOL_BEHIND_RELEASES` (default 3) releases or
`CLI_CHECK_TOOL_BEHIND_DAYS` (default 30) days behind. Both are settable lane
knobs: `lane.cli-version-check.cli_check_tool_behind_releases` and `..._days`.

Each feed is fetched once per run and cached in `state/tool-feeds/<tool>.tsv`
for `CLI_CHECK_FEED_TTL_S` (default 86400). A failed fetch is "latest
unknown", never "current": a stale cache is not used, the failure is not
cached, and an unknown latest never alerts.

## Not done here

- No real hub run yet. After the merge, the 05:17Z pass is the first real run
  of the flyctl and gh paths, and the 05:40Z check the first real feed read;
  their rows are in `logs/cli-versions.csv` and `logs/cli-version-check.log` on
  the hub.

Tests: `tests/cli-update-systools.bh-6742-test.sh`,
`tests/security-updates.bh-6742-test.sh`,
`tests/cli-version-check-tools.bh-6742-test.sh`.
