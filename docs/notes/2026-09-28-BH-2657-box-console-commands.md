# The console poller forwards box commands as rows, not ssh (BH-2657, BH-2528.4)

Doc: EVENTS

## What changed

- `bin/poll-commands.sh` no longer runs `ssh` or `scp`. The eight hand-offs in
  seven handlers (`run_triage`, `fetch_log`, `fetch_artifact`, `chat`,
  `update_company_map`, `chat_proposal`, `proposal_gate`) are gone.
- A command for a project another box owns is queued as a `box_console_commands`
  row (`box_ccmd_forward`, `bin/lib/jobs/box-console-commands.sh`), addressed to
  `cron_box_id_for <box>`. That box's `bin/box-console-commands.sh` claims and
  runs it. The console ack says `queued for <box> (box command <id>)`. A failed
  forward acks `forward to <box> failed (jobs worker <http|unreachable>)`, and
  the fetch and chat handlers still beat their failure reply.
- A command for a project the hub owns runs through `bcx_run`
  (`bin/lib/box-cmd-exec.sh`), the same code the boxes run.
- A new `# >>> box-command expiry (BH-2528)` block runs once per sub-cycle. Rows
  still queued after `BOX_CONSOLE_COMMANDS_TTL_S` (default 300, a knob on the
  `poll-commands` lane) get the failure beat, a `box_command_expired` line in
  `logs/console-commands.log` and one `[box-console-commands] <box>:` line per
  box in `ALERTS.log`. A claim never answered pages once per id; the seen ids
  live in `state/box-console-commands-stale.ids`. A failed expire call is one
  `logs/poll-commands.log` line.

## Correction to docs/EVENTS.md

EVENTS.md says the issue wake's launch "travels the way `bin/poll-commands.sh`'s
`run_triage` handler has sent it since the fleet split — `ssh -n root@<box>`".
The wake itself is unchanged, but the `run_triage` console handler no longer
uses ssh: it queues a `box_console_commands` row that the owning box's
`bin/box-console-commands.sh` claims.

## Box lane proven live before merge

The forward only works if the owning box runs the `box-console-commands` lane,
so the lane was probed end to end in production on 2026-09-28. A read-only
`fetch_log` row (`probe-bh2657-20260928T070420Z`, `which=''`, project `project-3`)
was queued for box `project-3` with the shipped `box_ccmd_forward` (HTTP 201,
created 07:04:20Z). The project-3 box claimed it at 07:04:31Z and answered at
07:04:32Z (`actor: "project-3"`, `status: failed`,
`result: refused: no whitelisted log for which='' project='project-3'`). The
refusal is the expected answer for an empty `which`: the row went queued →
claimed → answered by the box itself, with no ssh.
