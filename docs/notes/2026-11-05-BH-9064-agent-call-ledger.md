# Dedup before spend at agent-call: the persisted ledger (BH-9064, slice C0)

Doc: CALL-GUARD

## Why

The cost rows of 2026-10-29 to 11-04 show 3,021 calls that repeated one guard
fingerprint inside 60 minutes ($2,225) and 278 calls that ended rc != 0 and
still cost $1,322. K3 (`bin/lib/call-guard.sh`) counts paid calls per piece of
work. It stores no answer and has no terminal state. The box-local answer store
of BH-1037 (`choke_lookup`, `AGENT_CALL_LEDGER`) is opt-in, `review` only, and
lives on one box, so a fly-pool machine never sees a repeat from another one.
This slice (C0) adds the persisted check and makes every call keyed. Slices
C1 to C4 (execute resume, the declared context kill, the daily canary, the
7-day measurement) are separate tickets.

## What changed

- New D1 table `agent_call_ledger`, key `(project, stage, fp)`, index
  `idx_agent_call_ledger_last (last_at)` for retention
  (`worker/jobs/schema.d/202611051735-bh-9064-agent-call-ledger.sql`).
- New routes (`worker/jobs/src/routes/agent-call-ledger.js`, bearer):
  `POST /api/agent-call-ledger/begin`, `POST /api/agent-call-ledger/finish`,
  `GET /api/agent-call-ledger?project=&stage=&fp=[&body=1]`,
  `DELETE /api/agent-call-ledger?project=&stage=&fp=&actor=&reason=`.
  The begin decision is one upsert, so two boxes cannot both get `run` past
  the cap.
- Retention rule `agent_call_ledger.age`: rows older than the settings row
  `retention.agent_call_ledger.days` (7) are deleted by the hourly
  `bin/d1-retention.sh` lane (dry run first, one audit row per run). The money
  stays in `cost_rows`.
- `bin/lib/agent-call-ledger.sh` and its client
  `bin/lib/jobs/agent-call-ledger.sh` (both new). `bin/agent-call.sh` asks the
  ledger after every pre-call refusal (budget stop, context-kill repeat, K3)
  and before the phase row and the first rung:
  - `replay`: an ok answer with a non-blank body, of a stage in
    `AGENT_LEDGER_REPLAY_STAGES`, inside `AGENT_LEDGER_WINDOW_S`. The answer
    and the runner and model markers come back. One `LEDGER REPLAY` line, a
    zero-cost cost row with note `refused:agent-call-ledger:replay`, no vendor
    call, the K3 slot settled unbilled, exit with the stored rc.
  - `terminal`: `empty` (a blank `$OUT`, the stored rc 0), `failed` at
    the stage's attempt cap (the stored rc, for example 124), `running`
    inside `AGENT_LEDGER_RUNNING_TTL_S` (rc 74) or `parked` (rc 74). For a
    refusal, line 1 of `$OUT` and `$OUT.err` is
    `AGENT_CALL_REFUSED call-guard repeat ledger-<status> attempts=<n> fp=<fp>`.
    The first words are K3's repeat marker, so every reader that defers on a
    K3 repeat (triage-shard, box-chat, rt/) routes it with no edit. One
    `LEDGER TERMINAL` line, a zero-cost row with note
    `refused:agent-call-ledger:terminal`, the K3 slot settled unbilled.
  - `run`: the call goes on. `cg_finish` settles the row on the same exits as
    the K3 settle: ok (rc 0, non-blank `$OUT`, no CLI error envelope, with the
    body), empty (rc 0, blank), unbilled (nothing billed) or failed.
- Only a caller-named `AGENT_CALL_FP` replays. A call with no fp is keyed on
  K3's own `call_guard_fp "$PROMPT_SHA"` (`<ticket>:<HEAD>:p<prompt sha>`; the
  stage is the row's key column). That key is enforced but never replayed.
- An answer over `AGENT_LEDGER_ANSWER_MAX_BYTES` is settled ok with no body and
  `answer_bytes` set. It never replays: one more purchase, never a wrong answer.
  No file goes on the box.
- `bin/claude-cost.sh`: a stdin prompt is saved to a temp file, the prompt sha
  is of the argv and that file, and the call is claimed. The `K3 not claimed`
  branch is gone. claude-cost never replays and stores no body. It enforces
  the terminal states and records the attempts. A failed call whose
  transcript shows 0 tokens in and out (a quota, auth or 429 answer) settles
  `unbilled` and gives the attempt back. A failed call with no transcript
  settles `failed`. The temp file is removed on every exit.

## Knobs and switch

Settings rows `lib.agent-call-ledger.<env lowercased>`, registry
`catalog/lanes.d/_lib.agent-call-ledger.json`. Each code literal is only the
fallback of its row.

| Knob | Default | Meaning |
|---|---|---|
| `AGENT_LEDGER` | 1 | 0 turns the ledger off |
| `AGENT_LEDGER_STAGES` | K3's stages plus `canary` | guard stages the ledger keys |
| `AGENT_LEDGER_REPLAY_STAGES` | `review lead-review triage-shard canary mc-rereview` | stages whose ok answer replays |
| `AGENT_LEDGER_WINDOW_S` | 3600 | replay and attempt window |
| `AGENT_LEDGER_MAX_ATTEMPTS` | 3 | failed attempts before terminal. A stage's cap is never below its K3 ceiling (`call_guard_max`: orchestrator=6, plan=3), so K3 refuses first with rc 74 |
| `AGENT_LEDGER_RUNNING_TTL_S` | 7200 | how long a `running` row holds the work |
| `AGENT_LEDGER_ANSWER_MAX_BYTES` | 262144 | answer bytes kept in the row |
| `AGENT_LEDGER_TIMEOUT_S` | 5 | worker timeout of one ledger request |

Kill switch: `agent-ledger-off` (`catalog/switches.d/agent-ledger-off.json`): a
`switch.agent-ledger-off` settings row, else the file `flags/agent-ledger-off`.

## Reset a row

If a terminal row blocks work that must run again, reset it:

```
DELETE /api/agent-call-ledger?project=<p>&stage=<guard stage>&fp=<fp>&actor=<who>&reason=<why>
```

The row becomes `reset`, keeps who and why in `note`, and the next call is a
fresh run with attempts 1.

## Log lines

`logs/agent-call-ledger.log`:

- `LEDGER REPLAY fp=<fp> age=<s>s attempts=<n> served-by=<runner>/<model>`
- `LEDGER TERMINAL <status> fp=<fp> attempts=<n> rc=<rc>`
- `LEDGER MISS fp=<fp>` (an ok row with nothing to hand back: the call runs)
- `WARN ROUTE MISSING` (a 404 from the worker: one line per box per UTC day)

## Failure modes

The ledger never refuses on its own read failure. No `JOBS_URL`, a timeout, a
5xx, an answer that is not a decision or a 404: the call runs as before this
ticket. A crash between the call and the settle leaves `running`. After the
TTL it counts as a paid attempt.
