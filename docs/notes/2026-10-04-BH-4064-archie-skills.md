# Archie's skills and their replay runner (BH-4064, wave 3 of #3966)

Doc: OPERATOR-SETUP

## What changed

- Five skills for the hub orchestrator live in `orchestrator/skills/`:
  `steward-initiative`, `triage-thread`, `rollout-review`, `cost-watch`,
  `brief-operator`. Each SKILL.md declares its verdict words on a `verdicts:`
  frontmatter line and has 2 or 3 recorded replay cases under `replays/`.
  Layout and case contract: `orchestrator/skills/README.md`.
- `bin/archie-skill-replay.sh [--skill <name>] [--root <dir>]` replays every
  case through `$ARCHIE_REPLAY_MODEL_CMD <prompt-file> <case-dir>` and compares
  the last `VERDICT:` line with `expected`. Unset, the model is the recorded
  reply (`recorded.txt`), so no vendor is called. rc 0 all passed, 1 any FAIL
  (an empty root is one), 2 usage.
- `bin/sync-skills.sh` takes `SKILLS_SUBDIR` (default `skills`) and never
  copies a `replays/` dir. `bin/harness-sync.sh` runs it a second time, in the
  `# >>> orchestrator skills` block, into
  `${ORCHESTRATOR_DIR:-/root/orchestrator}/.claude/skills`, only where that dir
  exists (the hub).
- `bin/fleet-propagate.sh`: `orchestrator/` is a fleet path, so a skills-only
  merge reaches the hub within minutes, and it is pool-exempt (no image rebake).

## Why

#3966 wave 3: Archie's repeated judgments ship as reviewed, testable skills,
and a skill edit can be checked against recorded cases before it goes live.

## Not done here

No live model replay, no `archie.replay` model route, no lane. Wave 5 adds
those, through `bin/agent-call.sh`. The suite is
`tests/archie-skill-replays.bh-4064-test.sh` (the ticket named it
`tests/archie-skill-replays-test.sh`; one new suite per ticket is the
convention).

## Operate

On the hub after a deploy: `ls /root/orchestrator/.claude/skills` lists the
five with no `replays/`, and `grep 'skills synced' /root/harness/logs/agent-rules.log | tail -2`
shows the orchestrator destination.
