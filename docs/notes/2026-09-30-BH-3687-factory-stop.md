# Factory stop: the CLI, the Fleet button, the poll-commands handler

Doc: harness-control-plane, fleet-pauses

BH-3712 is slice 5 of BH-3687. Slice 1 (BH-3708) shipped the switch itself: the
settings row `switch.factory-stop`, read by `bin/lib/factory-stop.sh` and the
lane gate. This slice adds the three ways to write it, all landing on the same
`PUT /api/settings` with a reason, so every stop has an audit row in
`config_changes` saying who and why.

## Turn it on

```
bin/factory-stop.sh on --reason "<why>"
```

It prints `factory-stop is ON (settings switch.factory-stop)` and exits 0 only
after a fresh re-read of the switch (the same read the lane gate does, with the
settings cache TTL at 0) shows a settings row saying 1. Exit codes:

| rc | meaning |
|---|---|
| 0 | recorded and confirmed by the re-read |
| 1 | the PUT failed (`NOT recorded (http=<code>)`), or it answered 2xx and the re-read does not show the requested state (`NOT confirmed: <what the re-read saw>`) |
| 2 | bad arguments: no or blank `--reason`, an unknown verb or flag, an actor outside `^[A-Za-z0-9._@-]{1,96}$` or `registry-seed`. Nothing is sent |
| 3 | this box has no jobs client or no `JOBS_URL` (`NOT recorded: jobs not configured`) |

An `on` that was not recorded (rc 1 from a failed PUT, or rc 3) writes one
alert through `bin/alert-line.sh --id factory-stop-unrecorded`: someone asked
for the factory to stop and it is still running. An `off` that fails does not
page. Every on/off that reached the write appends one line to
`logs/factory-stop.log`: timestamp, on/off, actor, `confirmed`,
`not-confirmed` or `not-recorded`, reason.

The actor is `--actor`, else `$FACTORY_STOP_ACTOR`, else `<user>@<short host>`.

## Check it

```
bin/factory-stop.sh status
```

One GET of the fleet row. It prints `factory-stop is ON` or `OFF`, then
`since <iso> (<duration>)`, `by <actor>` and `reason: <note>`. No row prints
`factory-stop is OFF (no switch.factory-stop row)`. A worker that does not
answer prints `factory-stop status unknown: the jobs worker did not answer` and
exits 1. `status` reads the fleet row only; a box row
(`switch.factory-stop.<box>`) is not shown there.

## Turn it off

```
bin/factory-stop.sh off --reason "<why it is safe>"
```

Same exit codes. OFF is confirmed only when a settings row reads 0. No row, or
a box row that still says 1, is `NOT confirmed`: that box is still stopped.

## From the console and Telegram

- **Fleet screen (`/`).** Above the `PAUSE FLEET…` row there is a
  `FACTORY STOP…` button. When the switch is on it becomes a red banner,
  `FACTORY STOPPED · since <iso> (<age>) · by <actor> · "<reason>"`, with a
  `RESUME FACTORY…` button. Both open an in-app dialog with a required REASON,
  and the confirm stays disabled until one is typed. The write goes through the
  coord proxy (`PUT /api/coord/settings`, the proxy stamps the signed-in
  actor), then the row is read again. The message under the button is what that
  re-read says (`factory-stop is ON`, or `write sent, re-read still says off`),
  never the click. The banner polls every 30 s. If the row cannot be read it
  shows `factory-stop status unavailable` and no button.
- **Console command `factory_stop`.** `bin/poll-commands.sh` handles
  `{type:"factory_stop", payload:{state:"on"|"off", reason, actor?}}` by running
  `bin/factory-stop.sh <state> --reason <reason>` as that actor (`console` when
  the actor is missing or outside the worker charset). The ack's result is the
  CLI's last line and `ok` is true only on its rc 0. A state other than exactly
  `on`/`off`, or a blank reason, is acked `refused: …` with outcome `refused`
  and the CLI never runs. Unlike `pause_set`, a blank reason is not defaulted.
- **Telegram `/factorystop on|off <reason>` is not wired yet.** The parse that
  turns it into a `factory_stop` command lives in the console-worker repo and
  is owed there.

## What keeps running while it is on

Only lanes whose manifest in `catalog/lanes.d/` carries a `factory_stop` tag
(launch, merge, deploy) stop. **As of this slice no lane carries the tag**: the
tags, parking in-flight builds and holding the tier-1 and review-prs merges
come with the other BH-3687 slices. Until they land, turning the switch on
records the stop and shows the banner, and stops nothing.

Everything untagged keeps running: paging and alerts, poll-commands (so you can
still turn it off from the console), and the console's `merge_pr` command,
which is an explicit human merge.

## How it differs from the other stops

- `flags/all-off` is a file on ONE box and stops every gated lane there. The
  factory stop is one fleet row and stops only the tagged lanes, everywhere.
- A `pauses` row is scoped (a project or the fleet) and stops one kind of work
  (`triage`, `builds`, `reviews`, `merges`) with a TTL. The factory stop has no
  TTL: it stays on until someone turns it off.
- `LANE_GATE_DISABLE=1` in a lane's environment bypasses the lane gate, and with
  it the factory stop.

## Caveat: Mergify

PRs already in the Mergify merge queue can still land while the factory is
stopped. The switch is read by the harness's own lanes, not by a queue GitHub
is already running. Check the queue if a stop has to be total.
