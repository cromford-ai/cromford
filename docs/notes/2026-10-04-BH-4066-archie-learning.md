# Archie's learning loop (BH-4066, wave 5 of #3966)

Doc: OPERATOR-SETUP, MODEL-ROUTES

## What changed

- `bin/archie-learn.sh` is the only way a skill changes on the hub.
  `edit <skill> <new SKILL.md> [--case <dir>]... --why <text>` and
  `correct …` (at least one `--case`, the correction as a replay) stage the
  current skill with its replays (the learned copy, else the checkout's
  `orchestrator/skills/<skill>`), add the new cases as the next `NN-<slug>`, and
  run `bin/archie-skill-replay.sh` over EVERY case. A non-zero run is
  `rejected`: logged with the failing cases, rc 1, nothing moves. A green run
  promotes: `/root/orchestrator/learned/skills/<skill>/` (SKILL.md + replays),
  the live `/root/orchestrator/.claude/skills/<skill>/SKILL.md` (temp + mv) with
  a `.archie-learned` marker, the diff in `learned/history/` and on stdout. A
  failed install restores the old file and logs `promote-failed`. Refusals are
  rc 2 with no write; a held `locks/archie-learn.lock` is rc 3.
  `correct facts --why <text>` only logs the correction (facts are not gated).
- `propose <name> <dir>` gates a new skill and stages it in
  `learned/proposals/<name>/` without installing it; `adopt <name>` re-gates and
  installs it like a promote. The soul says adopt only after the operator says yes.
- `bin/archie-replay-model.sh` is the gate's default model: stage
  `archie-replay`, lane `archie-learn`, model from `model_routes`
  `stage.archie-replay` (seeded in `worker/jobs/schema.sql` from stage.execute
  rung 0, no literal), through `bin/agent-call.sh`. Its ledger
  `state/archie-learn/replay-cache/<sha256(model + prompt)>.json` is read before
  any call (`ok` and `empty` are terminal, `failed` stops at
  `ARCHIE_REPLAY_MAX_ATTEMPTS`), and the attempt is written before the call.
  `llm-sites.json` row `archie-replay`.
- `bin/sync-skills.sh` skips a destination skill holding `.archie-learned`
  (`skip (learned here): <name>`), so a deploy never reverts a learned edit.
  Once the repo's SKILL.md equals the live one (upstreamed in a PR) it clears
  the marker (`upstreamed: <name>`) and the skill takes repo deploys again; the
  weekly report lists only marked skills the repo does not carry yet.
- `bin/orchestrate.sh` `compose_v2_prompt` carries
  `/root/orchestrator/facts.md` (first 8000 bytes, a visible cut line past
  that) as `=== FACTS (facts.md, yours to edit) ===` right after STATE.md.
  The survival lane's brief is unchanged.
- `prompts/archie-soul.md` names the three memory layers (episodic: the
  conversation log, `logs/archie.log`, initiative events; semantic: facts.md;
  procedural: skills) and the correction rule.
- New hub lane `archie-learn` (`catalog/lanes.d/archie-learn.json`,
  `cron/lanes/725-archie-learn.cron`, daily 06:35Z behind
  `hub-lease.sh check`): `archie-learn.sh report` refreshes
  `state/archie-learn/skill-usage.tsv` from Skill tool_use lines in
  `/root/.claude/projects/-root-orchestrator/*.jsonl`, then once per closed ISO
  week writes `state/archie-learn/weekly/<W>.md` and sends one triaged
  fleet_alert beat (akey `archie-learning:<W>`): rework rate (last cromford
  row of `logs/outcome-rework-rollup.csv`), overrule rate (corrections logged
  that week / orc-monitor turns from `/api/metrics/llm-spend`), cost per check
  (archie-lane USD / `checked=` in `logs/archie.log`), skill counts, prune
  candidates, and skills learned here. `<W>.sent` is stamped only on beat rc 0.
  An unreadable input or a zero denominator prints `not measured`.
- Knobs (settings rows): `ARCHIE_LEARN_ENABLED` (1), `ARCHIE_SKILL_UNUSED_DAYS`
  (30), `ARCHIE_REPLAY_MAX_USD` (0.05 per call, 0 = off),
  `ARCHIE_REPLAY_MAX_ATTEMPTS` (2), and the lane's `LLM_USD_CAP_DAY`. Every
  lane's `LLM_USD_CAP_DAY` registry default is 0 (unlimited) by contract
  (`tests/llm-lane-knobs.bh-2533-test.sh`), so a daily cap for `archie-learn`
  is a settings row the operator sets (proposed: 1). Until that row exists NO daily
  cap is in force on this lane; the row is owed. The per-call 0.05 is a
  proposal for him too.

## Why

#3966 wave 5: Archie learns from corrections without a person editing files,
and a learned edit goes live only when every recorded case still passes.
Learned edits live under `/root/orchestrator/learned/` because writing them
into the repo would be a harness change, which stays a reviewed PR.

## Not done here

- Upstreaming a learned skill to `orchestrator/skills/` is a normal PR by a
  person. The weekly report lists every marked skill.
- The overrule rate counts `archie-learn.sh correct` calls. Wave 6's
  recommendation-vs-decision ledger is the better denominator when it lands.
- The transcript shape (`type: assistant`, `message.content[].type: tool_use`,
  `name: Skill`, `input.skill`) was checked against a Claude Code transcript on a
  build box, not against a real Skill call on the hub. The report prints how many
  invocations it parsed, and a skill is only flagged N days after it was first
  seen, so a parser that finds nothing shows up before it flags anything.
