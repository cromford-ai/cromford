# Staff heartbeat: one generic tick for every staff agent (BH-5561, wave 4 of #5556)

Doc: EVENTS, CONTEXT-COMPOSITION, OPERATOR-SETUP

## What changed

A new hub lane, `staff` (`bin/staff.sh`, registry `catalog/lanes.d/staff.json`,
cron `cron/lanes/729-staff.cron`, `*/15` behind `hub-lease.sh check`). Each
tick runs `bin/staff.sh tick <agent>` once for each active agent on the staff
roster. The steps are in the script header. In short:

1. Kill flags first. `staff-off-all` and `staff-off-<agent>` are read with
   `flag_active` before any other read.
2. Collect. `bin/staff/<agent>-collect.sh` prints JSONL. No collector ships in
   this wave, so on the hub every tick collects 0 items and makes 0 calls.
3. Claim each item by fingerprint (`POST /api/staff/findings/claim`) before any
   spend. Items that another agent claimed, or that are suppressed or
   staff-filed, are dropped.
4. One model call for the new items only. Every agent uses ONE stage,
   `staff-tick`, and ONE route, `stage.staff-tick` (schema fragment 0022
   copies the `triage` rung 0). The agent rides as `STAFF_AGENT` and in
   `AGENT_CALL_FP`. the operator chose one stage on 2026-10-12: the stage-route-seed
   and lane-stage ratchets need a literal stage, and per-agent routing is a
   later ticket. So an operator cannot route or cap one agent alone today.
   The attempt counter is written before the call.
5. Act by autonomy level with agent-core `decide()` (through
   `bin/staff-core.mjs`): a digest line, one GitHub issue labelled
   `staff:<agent>`, or a refusal with one warn beat for a NEVER-list action.
6. Record the outcome (`POST /api/staff/findings/record`, new in this wave).
   The outcome is written to `state/staff/<agent>/acted/<fp>.json` first, so a
   lost record is re-posted with no second model call and no second issue.
7. A filing GitHub refuses (the issue list cannot be read, or the create is
   not HTTP 201) is held: the decision is written to
   `state/staff/<agent>/held/<fp>.json`. Later ticks retry the filing from
   that file with no model call and no attempt count, until it files. A
   GitHub outage never buys a second model call and never ends as `failed`.

Other changes:

- `bin/harness-sync.sh` rsyncs `agent-core/` to `$HARNESS/agent-core/` before
  `bin/`, because `bin/staff-core.mjs` imports `../agent-core/src`.
- 7 souls in `prompts/staff/`, ONE budget row (lane `staff`, stage
  `staff-tick`) in `catalog/context-budgets.json`, and the SOP
  `catalog/prompts/staff-tick.md`.
- `tests/context-budget-manifest-test.sh` §9 fails when the stage
  `bin/staff.sh` passes has no budget row, or when a per-agent `staff.<name>`
  row comes back.

## How lanes wake today (the ticket asked for this finding)

The staff tick is cron only. Every lane is a `cron/lanes/NNN-<id>.cron`
fragment. The one event hook is the GitHub webhook doorbell (docs/EVENTS.md
§4.3: `worker/jobs/src/routes/wakes.js`). It turns GitHub repo events into
`wakes` rows for the build-side lanes, for example `bin/triage-gate.sh`. Staff sources (cost rows, git history, feeds) are not
GitHub repo events, so the doorbell does not apply. Archie's wake collectors
(`bin/lib/archie-wake.sh`) run inside his own cron tick; they are not a push.

## Contracts later waves use

| Name | Value |
|---|---|
| Kill flags | `staff-off-all`, `staff-off-<agent>` |
| Stage / route | agent-call stage `staff-tick` for every agent, route `stage.staff-tick`, project `fleet`, lane `staff`; the agent is `STAFF_AGENT` and the `staff:<agent>:` prefix of `AGENT_CALL_FP`. Cost rows carry stage `staff-tick`, not the agent. |
| Budget env | `AGENT_CALL_BUDGET_USD_STAFF_TICK` = `STAFF_LLM_MAX_USD` |
| Held filing | `state/staff/<agent>/held/<fp>.json`: `{row, mode, class, ftitle}` |
| Collector | `bin/staff/<agent>-collect.sh`, JSONL on stdout, rc 0 = read ok |
| Item line | `{"item", "title", "source": {"kind", "url", "labels", "filedBy"?}, "observedAt", "class"?}` |
| Executable action | `file a ticket` |
| Issue | repo `STAFF_FILE_REPO`, label `staff:<agent>`, no `ai-build`, body marker `<!-- staff-fp:<fp> -->` |
| Digest | `logs/staff-digest.log`, one line per item |
| Finding status | `claimed` to `digested`, `filed`, `refused`, `unsupported` or `failed`, written only by the record route |

## Apply order

1. The worker deploy applies schema fragment 0022 (one `model_routes` seed,
   `stage.staff-tick`, no new table) and serves the record route.
2. `bin/harness-sync.sh` copies `agent-core/`, `bin/staff.sh`, the souls and
   the registry entry, and installs the cron line.
3. All 7 agents stay at `automation` (observe mode). Nothing in this wave
   raises a level.

## Probes on the hub (after merge and deploy)

- `ls /root/harness/agent-core/src/index.js`
- `node /root/harness/bin/staff-core.mjs soul /root/harness/prompts/staff/watchman-soul.md | jq .ok`
- `crontab -l | grep staff.sh`
- `SELECT count(*) FROM model_routes WHERE role = 'stage.staff-tick'` gives 1.
