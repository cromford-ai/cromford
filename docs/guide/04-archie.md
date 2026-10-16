---
title: Archie
description: The hub's orchestrator. It keeps an eye on the goals you give it and tells you only when you need to act.
order: 4
---

# Archie

Archie is the hub's orchestrator. You give it a goal to track. It checks the
goal on a schedule and sends you one chat message when you need to act. When
nothing needs you, it stays silent.

Archie talks to you through the Telegram bot. Set up
[Telegram](../optional-services.md#telegram-or-slack) first.

## Track a goal

Send a message to the bot:

```text
Archie, track <goal> | metric: csv:logs/<file>.csv#<column> | every: 12h | escalate: change
```

Only the goal is required. The other fields:

- `metric:` a column of a CSV file under `logs/` on the hub. Without it,
  Archie reads no number.
- `every:` the check interval, as `<n>h` or `<n>d`, from 1 hour to 90 days.
  The default is `ARCHIE_DEFAULT_CADENCE_H` hours (24).
- `escalate:` when to tell you. `always` (the default), `change`, or a
  comparison such as `> 10` or `<= 0`. A comparison needs a metric.
- `links:` up to 10 URLs, separated by spaces.

## Answer it

Each message names its initiative as `I<n>`. Reply in the same chat:

```text
Archie approve I3
Archie change I3 <what to change>
Archie drop I3
```

## Let it decide

Each escalation has a class. When you approve the same class
`ARCHIE_DELEGATE_AFTER` times in a row (5), Archie offers to take that class.
Only you can move a class to Archie, and you can take it back:

```text
Archie delegate <class>
Archie ask first <class>
```

Some classes are never delegable: clients and customers, money, spend, cost,
budget, billing, invoices, prices, production, merges, deploys, releases, and
an escalation with no class. Archie also always asks when the goal or the
message is about secrets, key rotation or migrations.

## When it runs

The `archie` lane runs `bin/archie.sh` on the hub every 15 minutes. Each run
checks at most `ARCHIE_MAX_PER_TICK` due goals (3). The rest wait for the next
run.

- Quiet hours: `ARCHIE_QUIET_FROM_H` to `ARCHIE_QUIET_TO_H`, in UTC. Equal
  values (the default) mean no quiet hours.
- Daily cap: `ARCHIE_BEAT_CAP_DAY` messages a day (5).
- Messages held by quiet hours or the cap go out later as one digest.
- Each model call is capped at `ARCHIE_LLM_MAX_USD` dollars (0.6).
- `ARCHIE_ENABLED=0` stops the lane.

Each knob is a settings row named `lane.archie.<knob in lowercase>`:

```bash
bin/jobs-client.sh setting-set lane.archie.archie_quiet_from_h 22
```

To turn the lane off, run:

```bash
bin/harness-ctl.sh off archie
```

## Research

The `archie-research` lane runs `bin/archie-research.sh`. It scans the web
each day for work on AI software factories and agent harnesses. It scores
each find and writes the good ones to the Ideas ledger as proposals. It sends
a weekly digest. It posts nothing in public.

## The other Archie lanes

These hub lanes watch the factory itself:

- `archie-fm`: one playbook per stuck pull request.
- `archie-fm-watch`: stuck builds, an idle pool, disk, missing crons, a red
  main, and cost anomalies.
- `archie-fm-queue`: the merge queue.
- `archie-fm-improve`: files one `ai-build` issue for each cause of a
  recurring hand fix.
- `archie-learn`: a weekly learning report.
