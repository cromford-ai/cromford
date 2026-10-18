# cron/ — GENERATED crontabs, one file per box

**There is nothing to hand-edit here, and since BH-1247 nothing to commit
either.** `cron/<box>.cron` is produced by `bin/render-cron.sh` from the lane
registry (`catalog/lanes.json`, itself generated from `catalog/lanes.d/`) plus
one file per lane, and it is **git-ignored**: a box renders its own at install
time, through `bin/render-crontab.sh`. Change a fragment and the next install
carries it — there is no second step.

```sh
bin/render-cron.sh <box-id>       # print one box's crontab — the safe one
bin/render-cron.sh --check        # sources valid, render deterministic, nothing committed
bin/render-diff.sh origin/main    # what THIS tree changes about what a box installs
bin/render-cron.sh --out-dir DIR  # write the whole fleet somewhere that is not the repo
```

> **Never run `bin/render-cron.sh --all` (or `bin/render-crontab.sh
> --from-fragments --all --write`) inside a box checkout.** Those write
> `cron/<box>.cron` into the tree, the file is git-ignored so `git status` will
> not show it and `git pull` will never delete it, and `bin/render-crontab.sh`
> would then be handed a frozen base that no fragment change can move. It
> refuses to use one while `cron/lanes/` is present (BH-1247), so the worst case
> today is confusion rather than a frozen crontab — but on a box there is no
> reason to write these files at all. Use `--out-dir`, or `bin/render-diff.sh`.
> If you find `cron/*.cron` in `/root/harness-checkout`, delete them.

## Where a line lives (BH-1178)

| you want to | edit |
|---|---|
| add a lane to some boxes | `catalog/lanes.d/<id>.json` (`.boxes`) **and** `cron/lanes/<NNN>-<id>.cron` |
| change a lane's schedule or redirect | that lane's `cron/lanes/` fragment |
| give one box a different line for a lane | a `# @box <id>` section in that fragment |
| add a box to the watchdog ping | a `fleet.conf` row for a project on that box (or a `# @boxrole <box> <box_id> <role>` line for a box with no project) **and** the box's id in `catalog/lanes.d/watchdog-ping.json` `.boxes` — never the fragment, which is one `@WATCHDOG@` line |
| put a hub lane behind the hub lease | `# @hub-lanes` in that fragment (or `# @ungated <why>` if it must run on every box — one of the two is required, and `<why>` is required with it: a bare `# @ungated` refuses the render) |
| add a line only one box runs | `cron/boxes/<box>.d/<NNN>-<slug>.cron` |
| move a lane's position on one box | `cron/boxes/<box>.order` |
| change a project's seven managed lanes | `bin/lib/cron-lines.sh` and `fleet.conf` |
| hold a hub lane for ONE project (a fix round on project-3 only) | `bin/harness-ctl.sh off <lane> --project <p> "<reason>"` — only lanes with `"per_project_hold": true` in `catalog/lanes.d/` take it; see `docs/notes/2026-09-22-BH-1464-harness-ctl-project-hold.md` |

Nothing above is a file another lane also edits, which is the point: before
this, every new lane appended to up to ten crontabs at the same place and two
builds adding two unrelated lanes conflicted every time.
`docs/verification-map/lane-cron-render.md` has the fragment format, the
hub-lanes coalescing rule and what the render proves.

`bin/render-cron.sh` composes the operator lines and then hands the result to
`bin/render-crontab.sh`, which still owns the fleet-managed project blocks and
the hub-lease gate exactly as described below — the box installs a crontab
produced by the same script as before.

## Why they are generated (project-7, 2026-08-30)

The crontab used to have TWO writers and no reconciliation between them:
`bootstrap-machine.sh` installed a project's lanes LIVE from `fleet.conf`, while
`update-runners.sh` applied this directory's hand-maintained file. Onboarding
`project-7` onto `box-project-6-1` installed seven lines the repo file had
never heard of; the next morning's 05:17 tick copied the file back over them and
the lane was dead for ten hours. Nothing errored — from each writer's point of
view nothing was wrong.

Now both writers call one renderer, and a `fleet.conf` row is enough on its own
to keep a lane alive.

## The model: managed blocks

Each file is the box's own lines, preserved byte-for-byte, plus one generated
block per project `fleet.conf` assigns to that box:

```
# BEGIN fleet-managed project=<name>
  ... run-triage, run-product*, healthcheck*, apply-migrations,
      merge-queue, deploy-train, review-prs           (* conditional)
# END fleet-managed project=<name>
```

Everything OUTSIDE the markers belongs to the operator and is never touched —
`@reboot`, the watchdog ping, `SHELL=`, comments, a box's weekly `security-scan`,
`postmerge-qa`, `rebase-train`, `mirror-sync`, `disk-clean`, `clock-sync`,
`harden-state`, and the hub's whole orchestration section. Since BH-1178 those
lines are themselves composed: add a box-specific line as
`cron/boxes/<box>.d/<NNN>-<slug>.cron` and a fleet-wide one as a lane fragment,
never by editing a file in this directory.

Four of those operator lines are fleet-wide rather than box-specific, and live
in EVERY file here for that reason. `disk-clean.sh` (daily). Since 2026-09-14,
`*/30 * * * * clock-sync.sh` — these containers have no NTP daemon and every box
measured 66-464s slow, which expires GitHub App tokens early and skews every age
comparison the box makes (docs/OPERATOR-SETUP.md, "The box clock"). And since
2026-09-17, `*/10 * * * * harden-state.sh` (BH-390), which re-arms `chattr +i`
on `env/` and the ssh key and `+a` on the ledgers, so a file a writer released
never stays writable: it takes `locks/harden-state.lock` with `flock -w 60`,
appends to `logs/harden-state.log` only when it changed a flag, and the cron
line's `>/dev/null 2>&1` is what sends its per-run status line nowhere. And
since 2026-09-17, `*/5 * * * * audit-tail.sh` (BH-444, incident #388), which
reads the kernel audit trail (`ausearch -k harness`) and pages once per
deletion, rename or truncate burst under the harness roots: it takes
`locks/audit-tail.lock` with `flock -n` and skips the tick if another run holds
it, writes one line per burst to `logs/audit-tail.log` before it alerts, and is
off via `AUDIT_TAIL=0` in `env/global.env` or `flags/audit-off`. What it watches,
how to read a burst line and what the BLIND alert means are in
`docs/AUDIT-TRAIL.md`.

The one exception, and the point of the design: an UNMARKED line invoking a
managed script for a project the box owns is absorbed into that project's block
rather than preserved. A lane installed by hand and a lane in the registry are
the same lane, and the box must end up running exactly one of it.

Conditionals are decided from checked-in data, documented in
`bin/lib/cron-lines.sh`: `run-product` only when `prompts/product-<project>.md`
exists (without it the script ALERTS and exits 1 every Monday), `healthcheck`
only when the project's `fleet.conf` prod URL is not `-`.

## hub-lanes markers

Every schedule line inside a `# BEGIN hub-lanes` / `# END hub-lanes` pair is
rendered with `/root/harness/bin/hub-lease.sh check && ` in front of its
command, so the lane only fires on the box that currently holds the hub lease.
Multiple blocks are allowed and the marker lines themselves are preserved. A
command that already carries exactly that prefix is left alone, so re-rendering
a rendered file returns it unchanged — the checked-in file IS the render, and
the gate is produced by `render-crontab.sh` rather than typed in by hand.

Only blank lines, `#` comments and five-field cron schedule lines are legal
inside a block. Anything else — `@reboot`, `SHELL=`, a bare command — fails the
render: stderr names the offending line, the exit is non-zero, and stdout is
empty. Same for unbalanced markers (a dangling `BEGIN`, an `END` with no
`BEGIN`, a `BEGIN` inside a block), each with its own exit code. A marker that
half-applies would leave a crontab nobody wrote, so the renderer produces
nothing at all instead.

**`VAR=value` assignments** inside a block get the prefix BEFORE the variable
(`... check && WINDOWS_ONLY=1 /root/...`): that is valid bash and the
assignment scopes to the right-hand side of the `&&`. A compound
`for ...; do ...; done` line is one command and is gated as a whole. The
renderer does not parse shell, so a **top-level `;` inside a block is only
partially gated** — the gate binds to the first command and everything after
the `;` runs regardless of the lease. Write those as two lines, each in the
block.

Files with no hub-lanes markers render byte-identical to their original
content — the pass is a no-op for marker-less files, which is every file in
this directory today.

## Box id vs. box hostname

`fleet.conf`'s box column holds hostnames (`box-project-3-2`) because that
is what `ssh` needs; these files are named by the short box id (`project-3`) because
that is what `/root/harness/state/box-id` carries. `cron_box_id_for()` in
`bin/lib/cron-lines.sh` is the only place that relationship is written down.

## Boxes with no projects

`hub` and `project-10` have no `fleet.conf` rows pointing at them, so they
render byte-identical to their current content — the renderer never invents
lanes for a box the registry does not claim.

`project-10`: PAUSED harness (2026-08-04, external team owns the repo). Its
file is a record; the box has no harness-checkout so nothing applies it.
