# 2026-09-22 — BH-1185: the watchdog name comes from the registry, and three more render refusals

Doc: lane-cron-render

`bin/render-cron.sh` gained one substitution and three refusals. All four are
behaviours BH-559 (#812) specified and #1182 did not carry over when it
superseded that ticket's fragment grammar, plus one nit from the same review.
Filed so they did not vanish with the close.

**The render is byte-identical.** `bin/render-diff.sh origin/main` reports no
change for all twelve generated files, so no box's crontab moves.

## 1. `@WATCHDOG@`, and the second substitution in the grammar

`cron/lanes/260-watchdog-ping.cron` was ten literal lines: a default naming
`box-project-4-1` with **no `# @box project-4` header**, plus nine `# @box`
variants. So any box newly added to the lane's `.boxes` — and the operator
instruction for onboarding a box says to add it — silently pinged the watchdog
under project-4's name. At the watchdog that is indistinguishable from the new box
being down, and from project-4 being up twice.

The fragment is now one line:

```
*/5 * * * * /root/harness/bin/watchdog-ping.sh @WATCHDOG@
```

`@WATCHDOG@` is expanded by `cron_watchdog_name_for <box-id>` in
`bin/lib/cron-lines.sh`: `hub` → `box-hub`, otherwise the `fleet.conf`
box column of the first project whose `cron_box_id_for` equals the box id,
machine generation and all (`project-3` → `box-project-3-2`). It is the inverse
of `cron_box_id_for` and cannot be done with string surgery, because
`cron_box_id_for` DROPS that generation suffix.

A box the registry cannot name **refuses the render** — empty stdout, rc 1, the
box named. Resolution is lazy: the refusal fires only from a fragment that
actually carries the placeholder, so `project-10` (parked, no `fleet.conf`
row, not in the lane's `.boxes`) keeps rendering exactly as before.

Adding a box to the watchdog ping is now a `fleet.conf` row plus the box's id in
`catalog/lanes.d/watchdog-ping.json` `.boxes`. Never a fragment edit.

## 2. Duplicate schedule line

Two fragments emitting the same schedule line for one box refuse the render,
naming the box, the line and both fragments. Each fragment is exactly what its
author wrote, the registry is consistent and every `--check` is green — and the
box runs that lane twice, every tick, forever. Same class of failure the CRLF
guard already names: correct-looking sources, a crontab nobody would have
written.

The comparison is over the **expanded** text (after `@BOX@` / `@WATCHDOG@`),
across `cron/lanes/` and `cron/boxes/<box>.d` together, and before
`render-crontab.sh` adds the hub-lease prefix. A `# @box` variant REPLACES its
default, so a variant identical to its own default is not a duplicate.

Measured before the change: every one of the ten boxes renders with zero
duplicates, so the refusal is green on the fleet as it stands.

## 3. A managed script for a project the box does not own

A `cron/boxes/<box>.d/*.cron` line invoking one of `cron_managed_scripts`
(`run-triage|run-product|healthcheck|apply-migrations|merge-queue|deploy-train|review-prs`)
with a project `fleet.conf` does not assign to this box refuses, by `file:line`
and project name.

`render-crontab.sh` **absorbs** such a line into the managed block when the box
OWNS the project — that is the migration path off the hand-maintained crontabs
and is unchanged here. A FOREIGN project has no block to be absorbed into, so
the line was preserved verbatim as "the operator's" and the box ran a lane for a
project (or a parked one) with no registry row and no kill switch. Scripts
deliberately outside the managed set (`security-scan.sh` and kin) still take a
project argument and are not refused.

No `cron/boxes/*.d` file on main invokes a managed script, so this too is green
on the fleet as it stands.

## 4. `# @ungated` must carry a reason

The directive regex was `/^# @ungated( |$)/`, which accepted a bare `# @ungated`
with nothing after it. The reason is the whole point of the directive — it is
what a reviewer reads when asking why this hub-scoped lane fires on every box —
so bare, it is a typo that renders as a decision.

A bare or whitespace-only `# @ungated` in any fragment that renders for the box
now refuses by `file:line`, in a pre-scan that runs BEFORE the hub-gate check,
so a bare directive can never be counted as the declaration a hub-scoped lane
owes. The directive regex is tightened to `/^# @ungated[ \t]+[^ \t]/` as the
belt. All four real directives already carry a reason.

## Proof

`tests/render-cron.bh-1185-test.sh` — 59 assertions, every one of them driving
`bin/render-cron.sh` itself over a scratch copy of the repo. It includes the
adversarial negatives each refusal could break: all ten boxes still render and
render to the same bytes twice, a `# @box` variant is not a duplicate of its
default, a comment naming a managed script is not a line, a non-managed script
with a foreign project is fine, and a box with no `fleet.conf` row that uses no
placeholder still renders.
