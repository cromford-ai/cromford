# The Claude auth probe — exit code and sentinel, never prose

> Implementation: `PROBE_BODY`, `classify_probe` and `box_verdict` in
> `bin/claude-auth-check.sh` (hub cron, hourly). The hub probes its own accounts
> itself; every other box is asked over ssh to run
> `/root/harness/bin/lane-probe.sh claude --endpoint`. Tests:
> `tests/auth-probe-classify-test.sh` (V1a-V1l drive the real probe body against a
> stub `claude`), `tests/auth-check-no-inference.bh-2549-test.sh`,
> `tests/lane-probe-endpoint.bh-2549-test.sh`, `tests/gh-visibility-canary-test.sh`,
> `tests/lane-down-canary.bh-1674-test.sh`.

## Credential first, inference once a day (BH-2560)

Every hour each box answers with `cred_probe claude` (`bin/lib/cred-probe.sh`):
one line, `ALIVE`, `DEAD`, `INCONCLUSIVE`, `DEGRADED` or `NO_ENDPOINT`. That
check reads the credential, not a model, so it costs nothing.

The inference probe (the sentinel ladder below) runs at most once per account
per UTC day, and only when `cred_inference_claim claude <fp>` returns 0. The
order is claim, then spend, then record:

- claim rc 0: print `INFERENCE`, run the probe, then
  `cred_inference_record claude <fp> <ok|down|degraded|empty>`;
- claim rc 1 (already spent today) or rc 2 (the store is unreachable): no
  inference at all;
- an inference agent-call refused (rc 74..79, an `AGENT_CALL_` marker in the
  answer) bought nothing, so nothing is recorded.

The inference goes through `bin/agent-call.sh`: stage `canary`, project `fleet`,
`AGENT_CALL_RUNNERS=claude` (no fallback vendor can answer for a dead login),
lane `claude-auth-check`, `ACCOUNT_ROUTING=0` (the credential this env holds).
So every paid probe writes a cost row. On the hub this is `PROBE_BODY`; on a
remote box it is `lane-probe.sh claude --endpoint`'s own "Reply with exactly: ok"
probe, claimed and recorded on that box.

**Until BH-2559 lands, the contract is a stub**: `cred_probe` prints
`NO_ENDPOINT` and the claim always returns 0. So today every hourly run still
buys its inference, now through agent-call with a cost row. A box without
`bin/lib/cred-probe.sh` behaves the same way.

### The model route and the day fp (BH-9125)

The probe runs on the model_routes role `auth.canary`. The seed copies
`bootstrap.smoke` rung 0 on the claude runner (a Haiku-class model), so no
model id is in code. `AUTH_CANARY_MODEL` overrides the row on one box.
`TRIAGE_MODEL` does not steer the canary. If the `auth.canary` route cannot be
read, the probe uses role `triage`, and `bin/lib/model-route.sh` writes its
ALERTS line for `auth.canary`. The day claim stays the first gate. After a
claim rc 0 with an account fp, the inference carries
`AGENT_CALL_FP=canary:<runner>:<account fp>:<UTC day>` (hub: `PROBE_BODY`;
remote box: `lane-probe.sh --endpoint`). The ledger keeps the answer of a
stage-canary call with a caller fp for `AGENT_LEDGER_CANARY_WINDOW_S` (86400 s).
So a second probe on the same day is a ledger replay with no vendor call. On the
hub the nonce is then 12 hex of sha256(fp), so a replayed answer carries the
sentinel of the second run. Only the asked model carries the fp; the
`auth.fallback` rung keeps a computed fp. `lane-probe.sh` default mode (from
`bin/lane-reprobe.sh`) carries no fp, because a reprobe needs fresh evidence.

### What each answer does

| endpoint | inference | branch |
|---|---|---|
| any | `ok` (`PROBE_OK`, or `ok` from a remote box) | ok: clear the box's STATE line and fleet row, RECOVERED; clear the conductor marker (hub only) |
| any | `authdown` | CLAUDE AUTH DOWN (same text as before) |
| any | `degraded` | MODEL POOL EXHAUSTED note |
| `ALIVE` | none, or inconclusive | ok, but the conductor marker stays |
| `DEAD` | none, or inconclusive | CLAUDE AUTH DOWN |
| `DEGRADED` | none, or inconclusive | MODEL POOL EXHAUSTED note |
| `INCONCLUSIVE` | none, or inconclusive | AUTH PROBE INCONCLUSIVE note |
| `NO_ENDPOINT` | inconclusive | AUTH PROBE INCONCLUSIVE note |
| `NO_ENDPOINT` | none | nothing this hour: no state change, no note |
| not an endpoint word (an old box, an ssh error) | the whole text | `classify_probe` of it, as before |

**The conductor marker** (`state/merge-conductor/lane-down`) is cleared only by
an inference answer of ok on the hub. An endpoint `ALIVE` proves the token, not
that Claude serves, so it never clears it.

**The 6-hourly runner loop** (codex, openrouter, fireworks, grok) calls
`lane-probe.sh <lane> --endpoint`. `ALIVE` clears a lane-down mark and `DEAD`
sets one. `INCONCLUSIVE`, `DEGRADED`, `NO_ENDPOINT` without an inference, and an
inference agent-call refused mark nothing. `NO_ENDPOINT` with an inference is
judged by an `ok` in the answer. A box still on the old `lane-probe.sh` ignores
`--endpoint`, answers its old probe, and is read as before.

`lane-probe.sh <lane>` with no flag (what `bin/lane-reprobe.sh` runs) is one
inference through agent-call, pinned to that lane, and prints the tail of the
answer; codex still prints `codex-cli-version=` first.

## Why (V1 alert hygiene, 2026-09-25)

From 2026-09-23 every box paged `CLAUDE AUTH DOWN` or `AUTH PROBE INCONCLUSIVE`
once a day. Every account was healthy. The probe asked the model to `say ok`,
kept only the **last line** of the answer, and `auth_evidence()` grepped that
line for `oauth|authorization|/login`. The model answered "ok" and then added a
note that the Vercel MCP plugin "needs authorization ... cannot run the OAuth
flow". The last line was the note, so the grep fired.

The lesson is not "tune the regex". Model output is prose, and a keyword grep
over prose is a guess. The probe now judges only things the model cannot say by
accident.

## The rule

Each run draws a random nonce and asks the model to reply with the word
`AUTHPROBE` and that code **joined by a hyphen**. The expected token
(`AUTHPROBE-<nonce>`) is fresh every run and never appears literally in the
prompt, so a CLI error that echoes the request back cannot pass for an answer
(review of #2290: with a fixed token in the prompt, it did). The probe prints ONE
line, and its first word is the verdict marker:

| what happened | marker | classification |
|---|---|---|
| rc 0 **and** the token in the output | `PROBE_OK` | **ok** — the account answered; nothing else in the text is read |
| rc 0, no token, the CLI's own logged-out phrase (`Invalid API key`, `Please run /login`, `Not logged in`) on **stderr**, or on stdout only as the CLI's exact message `Invalid API key · Please run /login` / `Not logged in · Please run /login` at a line start (a line merely starting "Not logged in to the X MCP server" is the model) | `PROBE_CLIAUTH` | **authdown** |
| rc 0, no token, otherwise (the same words mid-sentence in the answer included) | `PROBE_NOSENTINEL` | **inconclusive** — the prose rides along and is never judged |
| no token, a usage-credits refusal from the CLI (on stderr, at the start of a line, or with a non-zero exit; never mid-sentence in an exit-0 answer), fallback answers rc 0 + token | `DEGRADED` | **degraded**; if the fallback fails too, an exit-0 primary is `PROBE_NOSENTINEL` (inconclusive), never `PROBE_FAILED` |
| rc != 0 (the CLI itself refused) | `PROBE_FAILED` | **authdown** only if the CLI's own error text carries credential evidence (`Invalid API key`, `Please run /login`, `401` ...), else inconclusive |
| rc 137/143/124 or no output, twice | `INCONCLUSIVE` | **inconclusive** |

Keyword evidence is applied to a **failed CLI exit**, where the model never ran,
and to the CLI's three exact logged-out strings when the CLI itself printed them (stderr, or the start of a line). The model's own prose — the
Vercel MCP note, anything mentioning OAuth or authorization — is never judged.

## Condition keys

The canary's beats key on the condition, never on the date or hour:
`authdown:<box>`, `authprobe:<box>`, `pooldry:<box>`, `ghinvisible:<slug>`,
`lanedown:<box>-<lane>`, each with a matching `alertid` so the state machine
(`docs/ALERTS-STATE-MACHINE.md`) fires once, reminds, and closes. A date in an
akey minted a fresh console row every day for one unchanged condition.

**Recovery closes the outage's own row** (`auth_recovered`, review of #2290): on
the first ok probe after an outage — the box loop and the project-1-lane path
alike — it closes the state machine's record and sends `resolved:true` on the
SAME akey `authdown:<box>`, pre-triaged. It never opens a row of its own. (The
first cut resolved through `bin/lane-alert.sh --resolve`, whose akey is
`orclane:authdown-<box>`: the outage row stayed open, and a second outage inside
the 48h auto-stale re-fired an OPEN row, which pages nobody.)

**Depends on cromford-console `v1/alert-remind-ping`** (`src/alert-ping.js`):
that is what makes a `resolved:true` beat close its akey's row instead of
upserting it, and what re-pages an open row on the state machine's
`fire`/`remind`. This change must not merge before the console change deploys.

`ghinvisible` is `warn` (the digest) when the admin token still sees the repo,
because every routed lane keeps working; `critical` when no token sees it.
