# Cost levers (2026-07-24)

The fleet used to run a full Opus session per project per 10-min tick (~3,400/month)
mostly to conclude "nothing changed". Four levers fix the structure:

## Lever 1 — deterministic triage gate (`bin/triage-gate.sh`)

`run-triage.sh` now asks the gate before launching any LLM. The gate fetches the board
via curl+jq (same internal tokens, same DIFF KEYS the prompts use: status / waitingOn /
triageVerdict / commentCount / lastActivityAt / title) and prints `SKIP no-change` or
`RUN <reason>`. LLM sessions now happen only when: the board changed, the READY-QUEUE
has lines, a finished build awaits its board comment, the daily full-sweep is due
(FULL_SWEEP_SECS, default 24h), or the gate itself fails (**fail-open — a broken gate
spends money, never misses a ticket**).

- Force a run: `touch /root/harness/flags/force-triage-<project>` (one-shot) or
  `FORCE_TRIAGE=1 run-triage.sh <project>`.
- Seed after deploy (avoids one paid run): `triage-gate.sh <project> --seed`.
- Skipped ticks log `rc=skip :: gate no-change (...)` in the project log.

## Lever 0 — cost instrumentation (`bin/agent-call.sh`)

Every LLM call (triage / plan / preplan / execute / review / fix / decompose) routes through
`agent-call.sh`, which runs claude with `--output-format json` and appends to
`/root/harness/logs/cost.csv`:
`ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd`.
The triage summary line + beat now carry `[gate=... model=... cost=$...]`.
(The row has grown three times since: `billing_mode`, then `auth_fp,auth_account`,
then the session + attribution columns — see "Every model call produces a cost
row, from its TRANSCRIPT" below for the current 24-column shape and for where
the numbers come from now, which is no longer the `--output-format json`
envelope.)
Fleet cost query (from the hub, over SSH): `for w in $(cut -d= -f2 /root/harness/env/fleet.env); do ssh $w "tail -n +2 /root/harness/logs/cost.csv"; done | awk -F, '{s+=$13} END {print s}'`

## Lever 2 — per-stage model tiering (env, not code)

Optional vars in `env/global.env` (code fallbacks = the previous hardcoded models):

| Var | Default | Note |
|---|---|---|
| `TRIAGE_MODEL` | claude-opus-4-8 | fleet runs Opus (2026-07-24 decision): the gate killed the volume and per-box accounts made Opus triage allowance-cheap, so triage judgment stays strong. Drop to `claude-sonnet-5` only if a box hits its cap. |
| `PLAN_MODEL` | claude-fable-5-1 | also used by preplan |
| `EXECUTE_MODEL` | claude-opus-4-8 | |
| `REVIEW_MODEL` | claude-fable-5-1 | keep strong — this is the merge gate |
| `FIX_MODEL` | = EXECUTE_MODEL | |

## Lever 3 — multi-vendor runners (Codex / Gemini seam)

Per-stage runner selection: `RUNNER_TRIAGE / RUNNER_PLAN / RUNNER_PREPLAN /
RUNNER_EXECUTE / RUNNER_REVIEW / RUNNER_FIX` = `claude` (default) | `codex` | `gemini`.
A non-claude runner missing its CLI/auth **falls back to claude** with one ALERTS line/day.

**Per-project execute split (2026-07-24, the operator's call):** project-2, project-3, AND project-4
build claude-primary on their own dedicated Claude accounts (`RUNNER_EXECUTE=claude`,
Opus) with `RUNNER_EXECUTE_FALLBACK=codex` — included allowance burns first, sol
catches overflow. The cascade was only guaranteed when EXTRA USAGE IS DISABLED on the
account (cap-hit must FAIL, not silently bill credits): that was confirmed OFF on
project-2, project-3, and project-4 (the operator, 2026-07-24) and is **SUPERSEDED — see "Extra usage is
now ON" below**. project-1 stays codex-primary
(fallback claude) — see "The hub's billing identity" below for what the hub's
Claude login actually is. Failover fires on ANY nonzero primary exit (cap hit, auth expiry,
crash, timeout) with an ALERTS line + a second cost.csv row; downstream gates
(empty-diff check, adversarial review) still judge the result.

Codex lane model: `gpt-6-astra` (GPT-6, since 2026-09-06 — `agent-call.sh`
`CODEX_DEFAULT_MODEL`; set `CODEX_MODEL` in `env/global.env` only to override).
The "pin nothing, track OpenAI's default" policy ended 2026-08-20 when the
ChatGPT-account default drifted to `~z-ai/glm-latest`. gpt-6-astra is the only
GPT-6 slug the ChatGPT OAuth lane accepts (`gpt-6`, `gpt-6-codex`, `-pro`, `-mini`,
`-astra-pro` all answer 400 "not supported when using Codex with a ChatGPT account")
and it needs **codex CLI >= 0.153.4** (`bin/update-runners.sh` keeps boxes current;
`bin/lane-probe.sh codex` prints the version). OpenRouter list rate $10/M in, $50/M
out ($1/M cache read) vs sol's $2/$10 — notional only, the lane is flat-rate ChatGPT Pro.
`/root/.codex/config.toml` sets `model_reasoning_effort = "xhigh"` on the hub.

**Codex lane origin note:** Codex CLI 0.145.0 on all four
boxes, authed to the dedicated ChatGPT Pro account operator@example.com (per-box
`/root/.codex/auth.json`, chmod 600). Split: Codex executes, Claude plans + adversarially reviews + fixes.
Smoke-proven from a box with the exact agent-call flags. Limit/auth failures fall back
to claude with one ALERTS line/day. Gemini: install `@google/gemini-cli`, auth,
`RUNNER_FIX=gemini` etc — seam ready, not enabled.

## Lever 4 — billing structure (DONE 2026-07-24: per-box Claude accounts)

Each box's `global.env` carries its own `CLAUDE_CODE_OAUTH_TOKEN` — project-2, project-3,
and project-4 each run a dedicated Claude account (the operator set these up 2026-07-24; verified
4 distinct tokens across the fleet). Flat subscription allowances instead of shared-pool
extra usage; a cap hit on one box defers only that project. `cost.csv` per box shows each
account's API-equivalent burn — use it to right-size tiers (post-gate, triage barely
registers; builds dominate). If a box ever needs pay-as-you-go instead, replace its
`CLAUDE_CODE_OAUTH_TOKEN` with `ANTHROPIC_API_KEY` in global.env.

## Extra usage is now ON for project-2 / project-3 / project-4 (the operator, 2026-08-24)

**This supersedes the 07-24 "confirmed OFF" doctrine above.** Read the consequence
before changing anything in the runner cascade.

**What changes mechanically.** With extra usage OFF, hitting the weekly cap made
the call FAIL, and that error is what drove the codex/grok failover cascade. With
it ON, the same cap hit **BILLS at API rates instead**. Nothing errors. So for
these three boxes:

- the failover cascade **no longer fires on cap-hit** — there is no error to
  trigger it, and the build simply continues on Claude at cash rates
- `RUNNER_EXECUTE_FALLBACK=codex` still covers auth/crash/timeout failures, which
  do still error. It no longer covers "out of allowance".
- the old safety property (spend is bounded by the subscription) is **gone**, and
  nothing in the code replaces it

**What replaces it**, and both halves are required:

1. **Per-account tracking** (`bin/extra-usage-track.sh`, one line in every
   `cron/*.cron`, every 15 minutes since 2026-09-14). Each box polls every LOGIN
   it holds — one account per login, not one account per box; see *Account
   meters and the reconciliation* at the end of this file, which supersedes the
   one-login-per-box assumption in this paragraph.
   `cost-rollup.sh` collects each box's `extra-usage.csv` and emits
   `overage_accounts` + `fleet_overage_total_usd` into `summary.json`. An account
   that does not report is NAMED in the note, never summed as $0 — a silent zero
   and a quiet week are the same number and must not read the same.
2. **Account-side spend caps** (the operator's side, per account). Tracking tells you it
   happened; only a cap stops it. The hub ran to $18,863 in one weekly window
   with no cap, which is what this section exists to prevent repeating.

**The tracking is the only signal.** There is no error, no failover, and no log
line at the moment an account crosses into paid usage other than the meter this
tracker reads. If the hourly poll stops, the fleet is spending blind — treat a
missing sample as an incident, not as a quiet hour.

⚠️ The meter's window (weekly vs billing-cycle) is still **UNVERIFIED** — see the
note in the section below. It affects how `fleet_overage_total_usd` should be
read, and it is settled against the Console once, not guessed at twice.

## The hub's billing identity — ACCEPTED, not a finding (the operator, 2026-08-24)

**Hub sessions bill `operator@example.com`, BY DESIGN.** That covers everything the
hub runs on its ambient login: orchestrator turns, box-chat, `claude-auth-check`,
`update-runners`. This is a decision, not drift — do not "fix" it, and do not
re-flag it in an audit.

`env/orchestrator.env` (the dedicated setup-token seam read by `orchestrate.sh`)
exists and is **deliberately unprovisioned**. Absent, the stored login is used,
which is the accepted behaviour rather than a degradation.

This paragraph exists because the previous wording — "the hub's Claude login is
the operator's main account" — is ambiguous enough that it sent an audit chasing an
$18.8K overage on `operator@example.com` on 2026-08-24. `orchestrate.sh` had it right in
a code comment while this file had it vague; the doc was the thing that misled.
Name the account, or a future reader re-derives the wrong one.

**Known figures (2026-08-24), so an anomaly is recognisable as one:**

| Signal | Normal |
|---|---|
| Orchestrator burn | ~$600-670/day |
| Meter cross-check | $22-30/hr |
| Notional step-up | **2026-08-24** — `fleet_notional_7d` rose when codex and box-chat volume became visible for the first time. NOT a burn: those lanes always ran, they just recorded no tokens. Cash is unchanged (codex is subscription). |
| grok triage input | 620K mean / 3.7M max tokens per call, 62% over xAI's 200K cliff (hub, 7d to 2026-08-24). The assembled prompt is <25K tokens, so this is agentic session accumulation, not prompt size — see `runner_input_stats_7d` in summary.json. |

Tracked by `bin/extra-usage-track.sh` (hourly, writes `logs/extra-usage.csv`) and
`orchestrator-burn.csv`. The day-alert threshold is tuned against the first row of
that table — see the header of `extra-usage-track.sh` for why $100 was noise.

⚠️ **Unverified:** whether the endpoint's `used_credits` is a WEEKLY or a
billing-cycle figure is not yet established ($666/day x ~28d ≈ $18.6K is
suspiciously close to the observed meter, which would make it monthly). The
rollup currently labels it weekly. Do not relabel on either guess — settle it
against the Console, once, then fix the label everywhere at the same time.

## P2: fewer paid calls around execute (2026-09-25)

Volume, not dollar budgets (the operator). Three deterministic levers, each a settings
row and each fail-open. Full note: docs/verification-map/p2-overhead-cuts.md.

- **Pre-plan skip** (`PREPLAN_SKIP_SMALL`, default on): no pre-plan for a key
  triage tagged `size=S` or `kind=copy` on its queue line, a board title that
  kind-gate reads as copy, or a key whose build is already running. The build's
  PLAN stage plans it. The key's `planned-files.txt` is still written from the
  free tiers of `bin/planned-files-cheap.sh`, so dep-verify and the overlap
  guard keep their evidence. Logged `PREPLAN_SKIP small:` once per key.
- **Triage throttle** (`TRIAGE_MIN_INTERVAL_S` capped at 86400,
  `TRIAGE_MAX_RUNS_DAY`, per project, default off): a low-yield board's paid
  ticks at a cadence and under a daily ceiling, counted at the paid launch.
  Forced, daily-sweep, no-gate-state and event-wake ticks are never held.
- **Health precondition** (`TRIAGE_HEALTH_GATE`, default on): the ticks that
  need the board are not bought while the project has no repo/board in
  fleet.conf (checkout opt-in), its board fetch has failed 3 gate ticks running,
  or an operator wrote `state/triage-health/<p>.down`. Queue and results ticks
  proceed. One warn-digest line a day via `lane-alert.sh`.

## Context-diet campaign (2026-08-20/21) — doctrine

Three levers moved the bill; vendor choice barely did. Hub grok spend paced ~75%
below its Aug-19 peak within two days of these landing.

- **Measure the tick mix FIRST.** Lever 4 (board-changed scoping) targeted what
  turned out to be the RAREST tick type; the 24h audit showed queue-pending +
  results-sweep at ~80% of triage spend. Before optimizing any pipeline's cost,
  pull the gate-reason distribution from cost.csv/logs — optimize what actually
  fires, not what's conceptually central.
- **Volume beats rate.** Gate skips, scoped context (levers 4+5: the gate's own
  deterministic state becomes the session's reading list), and floor-routing
  mechanical lanes (medic + repeat-family alert-triage → fireworks flash) each
  save multiples. Swapping vendors at the same token volume saves percents —
  grok-4.6's 5-8x cheaper rate card realized only 30-45% vs Fable (cache-hit
  ratio, CLI loop efficiency, 200K long-context doubling all eat the sticker
  discount).
- **A lane you cannot price is a lane you cannot trust.** The grok lane ran
  2 days / ~$460 with blank cost.csv fields (usage parser aimed at the wrong
  JSON path); the bill was the only symptom. Full rule: cost-capture parity in
  ~/.claude/rules/metered-api-dedup.md — new lanes must emit PRICED rows on
  their first real call, verified against the vendor's own ledger.
- Scope log markers: `scope=N` (board-changed diff), `scope=queue`,
  `scope=sweep`, `scope=full`. All three scoped forms verified live 2026-08-21.

## Cost rows and per-PR account attribution live in the harness-jobs DB (2026-09-02)

the operator: "add it to the queue" (account attribution on pr_costs) and "move the rows
to the DB as well". Two mirrors, both fail-open, both idempotent:

- **`pr_costs.auth_account` + `account_breakdown`** — `bin/cost-rollup.sh` now
  writes both into `state/cost/cost-per-pr.csv` and the hourly push carries them.
  `auth_account` is the label that paid the LARGEST share of the PR (never
  "mixed"; "unknown" when every row predates PR #173's `auth_fp,auth_account`
  columns), and `account_breakdown` is the full `label:usd;label:usd` split.
- **`cost_rows`** — every box's `logs/cost.csv` rows, mirrored every 10 minutes
  by `bin/cost-rows-push.sh <box>` (cron line beside the extra-usage tracker in
  `cron/<box>.cron`) through `jobs-client.sh metric_cost_rows`. The cursor is a
  file line number in `state/cost-rows-push.cursor` that advances only after a
  2xx, chunks are ≤2000 rows per request, and the PK `(box, row_hash)` with
  `row_hash = sha256(raw line)` makes any re-push a no-op. Short 13/14-column
  rows land with `billing_mode/auth_fp/auth_account` NULL. Three consecutive
  failed pushes write one ALERTS line; a quiet tick writes nothing.

**`cost.csv` on each box REMAINS the write-ahead source of truth.** Nothing
reads it back from the DB, nothing trims it, and a worker outage costs a delay,
never a row (`logs/cost-rows-push.log` on the box says what moved).

Querying by account (the bearer is `HARNESS_SECRET` from `env/global.env`):

```bash
J=https://harness-jobs.operator.workers.dev; A="authorization: Bearer $HARNESS_SECRET"
curl -s -H "$A" "$J/api/metrics/cost-rows?auth_account=client-project-2-max&since=2026-09-01T00:00:00Z&limit=500"
curl -s -H "$A" "$J/api/metrics/cost-rows?project=project-3&stage=execute"
curl -s -H "$A" "$J/api/metrics/pr-costs?limit=50" | jq '.pr_costs[] | {pr_url, cost_usd, auth_account, account_breakdown}'
```

Or straight SQL on the hub (`worker/jobs/`, `wrangler d1 execute harness-jobs --remote --command=...`):

```sql
SELECT auth_account, ROUND(SUM(cost_usd),2) usd, COUNT(*) calls
  FROM cost_rows WHERE ts >= '2026-09-01' GROUP BY auth_account ORDER BY usd DESC;
SELECT auth_account, COUNT(*) prs, ROUND(SUM(cost_usd),2) usd FROM pr_costs GROUP BY auth_account;
```

## Every model call produces a cost row, from its TRANSCRIPT (2026-09-14)

Three holes closed at once, because they were one hole seen from three angles.

**1. A run that died produced a row with no numbers.** The row was built from
`claude -p --output-format json`'s result envelope, which only exists if the run
survived long enough to print it. A timeout, a kill, an OOM: blank tokens, blank
dollars. 16 of one day's 478 hub claude rows; 2,008 of 8,000 all-time.

**2. The envelope's `.usage` is one turn, not the session.** Nobody had checked.
Against the raw session transcripts, `cost.csv` reads low — the measurement that
started this wave said 3-4x, and that measurement was itself ~2.2x hot for the
reason in the next paragraph, but the direction was right and the example.com
account meter corroborates the transcript side.

**3. Anything that called `claude` directly produced NO row at all.**
`bin/greenfield.sh`, `bin/orchestrate.sh`'s turns, `bin/box-chat.sh`'s rung 1 —
not lanes reporting wrong numbers, lanes reporting nothing.

### Where a row's numbers come from now

`bin/transcript-cost.sh <session-id>` sums the session's own JSONL
(`~/.claude/projects/<cwd-slug>/<session>.jsonl`) per model and prices it from
`catalog/model-prices.json`. Three things it gets right that a naive sum does
not:

- **It de-duplicates on the API response.** Claude Code writes one JSONL entry
  per CONTENT BLOCK and repeats the identical `usage` object on each. Measured
  on hub session `4c9ab765`: 65 usage-carrying entries for 40 responses, one
  response written three times. Summing lines claims 5,378,875 cache_read where
  the session read 2,400,809 — 2.24x high. The key is `message.id`, then
  `requestId`, then the entry uuid. (`bin/claude-usage.sh` and the throwaway
  `/tmp/jsum.py` reference pricer both sum lines; treat their numbers as hot.)
- **Cache writes are priced per TTL, read not guessed.** `usage.cache_creation`
  splits into `ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` per
  message, so a session that used both pays both rates. The catalog carries the
  5-minute rate (1.25x prompt); the 1-hour rate is derived as 2x prompt so a
  catalog refresh cannot leave the two halves disagreeing.
- **Subagents are included.** A Task subagent's turns land in the same file with
  `isSidechain:true`; companion files (`<session>*.jsonl`) and siblings naming
  this session as their parent are summed too.

An unknown model is reported as **unpriced** and named, never funded from a
neighbour's rate — `cost_usd` is then partial and says so in
`logs/claude-cost.log`. Exit codes: `0` priced, `3` no transcript for that
session, `4` transcript exists but holds no API response (a run killed before
its first turn) — three distinct answers because the caller writes a different
row for each.

### The row

`logs/cost.csv` gains eight columns, appended at the END so every positional
reader of the first sixteen is unchanged (`note` is BH-656's, 2026-09-18 — see
`docs/verification-map/runner-cliff.md`; the other seven are this wave's):

```
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,
cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,
session_id,row_source,result_usd,ticket,job_id,pr,run_id,note
```

- `session_id` — the `--session-id` the call ran under, i.e. the exact
  transcript this row was priced from. Without it a row is a number nobody can
  re-derive.
- `row_source` — `transcript` | `result` | `none`. Which reading the token
  columns came from. `none` is a row whose call died before either existed,
  which is still a row (rc, duration, who paid).
- `result_usd` — the envelope's own `.total_cost_usd`, kept beside `cost_usd`
  rather than replaced by it. A disagreement above `COST_SOURCE_DELTA_PCT` is
  logged to `logs/cost-source-delta.log`; that log is how the fleet learns what
  `.usage` actually covers, from traffic rather than from the docs.
- `ticket,job_id,pr,run_id` — attribution, from `COST_KEY`/`COST_JOB`/
  `COST_PR`/`COST_RUN_ID`, falling back to `HARNESS_TICKET`/`JOB_ID` which the
  build lanes already export. `run_id` defaults to the build dir the stage's
  output landed in, the unit the nightly rollup already joins to a RESULT and a
  PR — so "what did this PR cost" stops needing a time window to guess with.

The one-time header upgrade in `cost_append` now has four generations behind
it (13 → 14 → 16 → 23 → 24); old rows are untouched and parse with the new names
empty. `bin/lib/cost-row.sh` is the single writer both wrappers share, extracted
from `agent-call.sh` so there is one place the ledger can be wrong instead of
two. Readers made tolerant in the same change: `bin/cost-rollup.sh` (the
canonical `fleet-cost.csv` header is now the full 23 — a name the header omits
is not an empty field, it is a value parked in `DictReader`'s restkey where
nothing looks), `jobs-client.sh metric_cost_rows` (its `len(f) > 16: continue`
would have silently skipped every new row while the cursor marched past it), and
the worker's `cost_rows` POST/GET plus an additive `ensureColumns` ALTER.

### Raw `claude` callers go through `bin/claude-cost.sh`

Same argv, same stdin, same stdout, same stderr, same exit code as `claude`;
afterwards there is a row. It mints a uuid and passes `--session-id` up front so
the transcript path is known **before** the call and a killed run can still be
priced, and it forwards SIGTERM/INT/HUP to the child — `timeout` signals the
wrapper now, not the CLI, so without that forwarding the timeout would stop
cutting calls short AND the killed run's row would be lost.

Three cases where no id is injected, all of which still get a row: the caller
passed its own `--session-id`; the call CONTINUES a conversation (`-c`/`-r`,
where the CLI owns the id, so the transcript is discovered afterwards — newest
session file under this cwd, priced with `--since` so a continuation contributes
this turn and not its history); or the switch is off.

Converted in this repo: `bin/greenfield.sh` (per-stage rows), `bin/orchestrate.sh`
(all three turn call sites), `bin/box-chat.sh` rung 1 — which also **deletes** its
hand-rolled row, the one that carried tokens and an empty `cost_usd` for as long
as it existed.

**`tests/no-raw-claude-test.sh` is the lint** that keeps it that way: nothing
under `bin/`, `fly/` or `skills/` may run `claude -p` / `claude --print` except
the two wrappers and the files in `tests/raw-claude-allowlist.txt`, each with a
reason. The bar for the allowlist is not "this call is cheap", it is "wrapping
it would change what it proves" — credential probes, where a wrapper fault would
read as an auth failure. The lint is self-tested against fixture trees, because
a green lint that has quietly stopped matching is worse than no lint.

**The orchestrator's off-repo lane runners on the hub** (`/root/orchestrator`,
not in this repo) must call `claude-cost.sh` the same way: replace
`claude -p …` with `/root/harness/bin/claude-cost.sh -p …` and export the tags
around it —

```bash
export COST_STAGE=lane COST_PROJECT="$project" COST_KEY="$ticket" \
       COST_RUN_ID="$run_id" COST_PR="$pr_url"
/root/harness/bin/claude-cost.sh -p --dangerously-skip-permissions --model "$m" "$prompt"
```

No other change: the wrapper does not touch the prompt, the model, the exit
code, or the output.

### Knobs, defaults and kill switches

Every one has an env default; the transcript path has a file switch too, for a
box you cannot restart. **Off never means "no row"** — it means the row falls
back to the CLI envelope, which is exactly the behaviour before this change.

| knob | default | what it does |
|---|---|---|
| `COST_TRANSCRIPT_ROWS` | `1` | `0`/`no`/`off`/`false` → no `--session-id`, no transcript pricing; rows come from the envelope with `row_source=result`, or `none` when there is no envelope either. |
| `$HARNESS/flags/transcript-cost-off` | absent | The same switch as a file. Touch it to disable on a running box; delete it to re-enable. No restart, no deploy. |
| `COST_CACHE_TTL` | `auto` | `5m` / `1h` force the cache-write rate for messages that carry NO per-TTL split (older transcripts). A message that declares its split always wins. |
| `COST_SOURCE_DELTA_PCT` | `20` | Percent gap between the transcript and envelope readings that gets a line in `logs/cost-source-delta.log`. |
| `COST_TRANSCRIPT_SCAN_MAX` | `400` | Upper bound on the sibling-file scan for subagent transcripts. A project directory with more files than this is not scanned at all rather than scanned partly — a partial scan undercounts silently. |
| `MODEL_PRICES` | unset | Overrides the price table. Default search: repo `catalog/model-prices.json`, `/root/harness-checkout/...`, then `$HARNESS/catalog/...` (fly builders have no checkout). |
| `COST_STAGE` / `COST_PROJECT` | `raw` / `fleet` | The stage and project columns for a `claude-cost.sh` call. |
| `COST_KEY` / `COST_JOB` / `COST_PR` / `COST_RUN_ID` | `$HARNESS_TICKET` / `$JOB_ID` / empty / build dir | The attribution tags. |

These are box-side only — `env/global.env` per box, nothing in Vercel, CI or the
worker. The worker needs no new env; its new columns arrive through the same
`ensureColumns` ALTER that added `pr_costs.auth_account`.

### Asking the new questions

```bash
J=https://harness-jobs.operator.workers.dev; A="authorization: Bearer $HARNESS_SECRET"
curl -s -H "$A" "$J/api/metrics/cost-rows?ticket=TK-109&limit=500"
curl -s -H "$A" "$J/api/metrics/cost-rows?row_source=none&limit=100"   # rows with no numbers, and why
```

```sql
-- what a ticket cost, and how much of it the ledger could actually price
SELECT ticket, row_source, ROUND(SUM(cost_usd),2) usd, COUNT(*) calls
  FROM cost_rows WHERE ticket <> '' GROUP BY ticket, row_source ORDER BY usd DESC;
-- how far the CLI envelope is from the transcript, fleet-wide
SELECT ROUND(SUM(cost_usd),2) transcript_usd, ROUND(SUM(result_usd),2) envelope_usd
  FROM cost_rows WHERE row_source='transcript' AND ts >= '2026-09-14';
```


## Non-Anthropic vendor spend (2026-09-14, cost fix 5)

Everything above measures the Anthropic bill. The rest of what we pay for lived
in four dashboards nobody opened: the xAI wallet that runs fleet triage (the
recurring $100 top-ups), the OpenRouter tier-3 survival lane, codex, and the Fly
pool — which IS the compute bill. `cost.csv` carries model-priced *estimates*
for the grok/openrouter rows (`bin/cost-rollup.sh` `METERED_VENDORS`), and
before this nothing had ever compared an estimate to an invoice.

`bin/vendor-spend-pull.sh` (hub cron, hourly at :33) polls every vendor we hold
a key for and writes one row per `(vendor, ts)` into `logs/vendor-spend.csv`
and, through `jobs-client.sh metric_vendor_spend`, the `vendor_spend` table.

**Each row carries its own honesty.** `kind` is `metered` (the vendor told us a
dollar figure) or `computed` (we derived it). `status` is `ok`,
`no-spend-endpoint`, `auth-failed` or `error`. A vendor we cannot price writes
an **empty** `usd` and a note saying why — never `0`. "We could not measure it"
and "it cost nothing" are indistinguishable once one of them is spelled `0.00`,
and it is always the first one that hides a bill.

### The vendor table

| Vendor | Key (env var) | Endpoint | kind | Cadence | What it means |
|---|---|---|---|---|---|
| `openrouter` | `OPENROUTER_PROVISIONING_KEY` (fallback `OPENROUTER_API_KEY`) | `GET /api/v1/credits`; `GET /api/v1/keys` for per-key usage | **metered** | hourly | The only vendor that answers with a real number. `/credits` requires a **management** key — an inference `OPENROUTER_API_KEY` answers 403 "Only management keys can fetch credits for an account" (probed 2026-09-16). `total_usage` is cumulative, so the row's `usd` is this reading minus the last; `balance_usd` = `total_credits − total_usage`. The per-app key budgets the hub PATCHes ride along in `raw`. Daily reconcile against our rows: see OpenRouter reconciliation (BH-3983). |
| `xai` | `XAI_API_KEY` | none — `/v1/api-key` is the **auth probe** only | computed | hourly | xAI publishes no billing route (`/v1/billing/usage`, `/v1/usage`, `/v1/credits` all 404; `management-api.x.ai` 404s at nginx, probed 2026-09-14). `usd` is the sum of `logs/cost.csv` rows with `runner=grok` in the window, priced at retail. An estimate, not the invoice. |
| `fireworks` | `FIREWORKS_API_KEY` | none — `/v1/accounts` is the auth probe only | computed | hourly | `/v1/accounts` answers 200, but `usage`, `billing` and `invoices` under it all 404 (probed 2026-09-14). Same cost-row estimate, `runner=fireworks` — but every fireworks row on the hub is currently **unpriced**, so the row publishes an empty `usd`, not `$0`. See *Estimates from our own cost rows* below. |
| `codex` | `OPENAI_ADMIN_KEY` (**absent**) | `GET /v1/organization/costs` | computed | hourly | Needs an admin key. This fleet's codex lanes authenticate with the ChatGPT subscription, so there is nothing to read: the row is `no-spend-endpoint` with an **empty** `usd`. The notional retail price of the codex tokens goes into `raw`, labelled notional — `cost-rollup` classifies codex as unknown-billing on purpose, and turning that into cash would invent spend. The metered branch is written and arms itself the day `OPENAI_ADMIN_KEY` lands. |
| `fly` | `FLY_API_TOKEN`, `FLY_ORG` | Machines API `/v1/apps`, `/v1/apps/<app>/machines`, `/v1/apps/<app>/volumes` | computed | hourly | Fly's GraphQL has no billing (`billables` and `invoices` are both undefined fields on `Organization`, probed 2026-09-14). So: seconds each machine was running inside the window × guest size, priced from `catalog/fly-prices.json`, plus provisioned volume GB. **Known undercount:** a machine created *and* destroyed entirely inside one window is invisible to both the event log and the current state; the row's note says so. |

`catalog/fly-prices.json` is the price table — edit it when Fly's list prices
move. The script carries the same numbers as a documented fallback used only
when the catalog is missing or unparseable, and a row priced that way says so in
its note, so a stale catalog is visible instead of silently assumed.

### Estimates from our own cost rows

For `xai` and `fireworks` — the vendors with no billing API — `usd` is the sum
of `logs/cost.csv` rows with that vendor's `runner` inside the window, priced at
retail by `bin/cost-rollup.sh`. Priced and unpriced rows are counted separately,
because `cost.csv` leaves `cost_usd` **empty** for any model with no catalog
price:

| What the window holds | What the row publishes |
|---|---|
| priced rows only | their sum, noted as an ESTIMATE |
| some priced, some not | the priced sum, noted as a **FLOOR**, with the unpriced count |
| rows, none of them priced | **empty `usd`**, noted `NOT $0` |
| no rows at all | `0.0000` — a real zero: this box made no calls through that runner |
| `cost.csv` unreadable | empty `usd`, noted as such |

The third line is the one that matters. Every `fireworks` row on the hub is
unpriced today (probed 2026-09-14: 7 rows in the window, all of them), and
summing them as zeroes would have reported Fireworks as a free vendor forever —
`$0` is also what "nothing happened" looks like, so nobody goes back and checks.
The fix is to price the model in `catalog/model-prices.json`; until then the row
says out loud that it could not.

### Windows

Each row covers `(previous row's window_end, now]`. A **failed** poll does not
advance the window: if it did, whatever was spent while the vendor API was down
would fall into a window no row ever covers. The first reading for a vendor is a
baseline (empty `usd`) covering one cadence.

### Alerts

- Three **consecutive** failed polls for one vendor (`auth-failed` or `error`)
  → one `lane-alert.sh vendor-spend` line, then quiet until it recovers. One
  blip is not news; an alarm that rings hourly is an alarm nobody reads.
- A readable balance below `VENDOR_BALANCE_FLOOR_USD` → one line per vendor per
  day. Today only OpenRouter exposes a balance; the xAI wallet does not.

### Knobs and kill switches

| Setting | Default | Effect |
|---|---|---|
| `VENDOR_SPEND=0` in `env/global.env` | on | stops the whole poller |
| `flags/vendor-spend-off` | absent | same, without editing env (console-flippable) |
| `VENDOR_SKIP='xai,fly'` | empty | skips those vendors, polls the rest |
| `VENDOR_BALANCE_FLOOR_USD` | `20` | balance-low alert threshold |
| `VENDOR_SPEND_FAIL_STREAK` | `3` | consecutive failures before one alert |
| `VENDOR_WINDOW_MAX_SECS` | `21600` | clamp after an outage — a box down for two days must not publish one row claiming two days of Fly compute it sampled once |
| `VENDOR_WINDOW_DEFAULT_SECS` | `3600` | the first-ever window for a vendor |
| `VENDOR_HTTP_TIMEOUT` | `25` | per-request seconds |
| `FLY_PRICES` | `catalog/fly-prices.json` | price table path |

All of these live in `env/global.env` (the script sources it itself; cron does
not). Nothing here needs setting for the default behaviour — every knob has a
working default and the keys are already on the hub.

### Reading it back

```bash
J=https://harness-jobs.operator.workers.dev; A="authorization: Bearer $HARNESS_SECRET"
curl -s -H "$A" "$J/api/metrics/vendor-spend?limit=20" | jq '.vendor_spend[] | {ts,vendor,usd,kind,status,balance_usd}'
curl -s -H "$A" "$J/api/metrics/vendor-spend?vendor=fly&since=2026-09-14T00:00:00Z"
/root/harness/bin/jobs-client.sh metric-vendor-spends openrouter 2026-09-01T00:00:00Z
```

```sql
-- what did the non-Anthropic vendors cost this week, and how sure are we?
SELECT vendor, kind, ROUND(SUM(usd),2) usd, COUNT(*) polls
  FROM vendor_spend WHERE ts >= '2026-09-08' AND usd IS NOT NULL
  GROUP BY vendor, kind ORDER BY usd DESC;
-- which vendors are we NOT measuring, and why
SELECT vendor, status, note, MAX(ts) FROM vendor_spend WHERE usd IS NULL GROUP BY vendor, status;
```

`--dry-run` prints rows and writes nothing — no CSV, no DB push, no alert, and
no touch of the failure-streak or balance-floor marker files. Those markers are
suppressors, so a human dry-running the poller must not be able to silence the
hourly job's real alert for the rest of the day.

Dry run, printing rows instead of writing them:
`bin/vendor-spend-pull.sh --vendor openrouter --dry-run`.

### OpenRouter gap, bucketed (BH-3983)

`bin/openrouter-audit.sh --since <iso> --until <iso> [--json] [--export <csv>]` prints the
tracer's one line (vendor meter vs openrouter `cost_rows`), then splits the gap into
buckets. `other-keys` is usage on keys outside `OPENROUTER_RECONCILE_KEYS` (not harness
spend). `unpriced-rows` is openrouter rows with a blank `cost_usd`. `killed-no-row` is
rc 143/137 kills from this box's `failovers.log` plus reaped openrouter builds. `residual`
is whatever is left. Read-only; `docs/verification-map/openrouter-ledger.md` has the details.

## Pool machines push their own cost rows (2026-09-14)

A Fly pool machine (`bin/fly-pool.sh`, `fly/entrypoint.sh`, `fly/builder-runner.sh`)
is volume-less: its rootfs, and with it `/data/harness/logs/cost.csv`, dies with
the machine. Every watcher box has mirrored its rows into `cost_rows` every 10
minutes since 2026-09-02; pool machines had no such loop, so **pool spend existed
only as `jobs.spent_usd` per-job totals** — $1,456 in the 24h to 2026-09-14
($1,366 of it project-5) with no per-stage row, no per-model row and no account
label behind any of it.

The pool launch archive includes `catalog/`, including `model-prices.json`.
`transcript-cost.sh` resolves that table from the extracted runtime. Without
it, a fresh machine records token usage with zero dollars and an unpriced-model
warning. `tests/pool-pricing-catalog-test.sh` builds the launch archive and
prices a synthetic session using only its extracted catalog. This changes
future launches; existing zero-dollar rows still need separate reconciliation.

**One identity, three writers, no double count.** A machine's rows are pushed
under `pool-<project>-<machine-id>` — the string `fly/entrypoint.sh` computes
once and exports as `COST_ROWS_BOX`, the same id the ledger's `box` column
carries. They are **never** re-labelled as the hub. The `cost_rows` PK is
`(box, row_hash)` with `row_hash = sha256(raw csv line)`, so the three writers
collapse onto one row each:

1. **The machine, while it runs.** `fly/builder-runner.sh` starts a background
   loop after the hub's env+job push lands (not before — a pusher with no
   `HARNESS_SECRET` cannot authenticate) and runs `bin/cost-rows-push.sh
   <box>` every `COST_ROWS_PUSH_S` seconds.
2. **The machine, at every terminal path.** `run_job` is a thin wrapper around
   `_run_job`, so a RESULT written, a `BUILD_DEFERRED` from warm-up or the disk
   guard, a `BUILD_ERROR`, an adopted PR and a SMOKE probe all flush on the way
   out — after the RESULT is on disk, before the loop idles. `EXIT`/`TERM`/`INT`
   traps flush on the crash path and on the idle-timeout exit.
3. **The hub, on reap.** `bin/fly-pool.sh`'s `push_pool_cost_rows` pushes the
   reaped build dir's `cost.csv` (which `bin/agent-call.sh` tees row-by-row as
   the build runs) under the machine's box id, with the cursor in
   `<build-dir>/.cost-rows.cursor`. This is the backstop for the one case the
   machine's own loop cannot cover: SIGKILL, OOM, or a stop between the last
   push and the RESULT. It logs one line —
   `cost rows: pushed N (M dup) for pool-<p>-<mid>` — and a full dup count is
   the evidence that the machine's own loop had been working.

**Nothing re-appends reaped rows into the hub's `logs/cost.csv`,** and nothing
ever did: `bin/cost-rollup.sh` reads `builds/*/cost.csv` straight into the
derived `state/cost/fleet-cost.csv` (deduped by `sort -u`, each row already
carrying `host=pool-<p>-<mid>` from `agent-call.sh`), and `cost_append` in
`agent-call.sh` is the only writer of `logs/cost.csv` anywhere in the tree. A
pool row landing there would be mirrored a second time under `box=hub` by the
hub's own 10-minute cron. `tests/pool-cost-rows-test.sh` guards both halves.

**Fail-open, always.** Every push is `timeout … || true`: a worker outage costs a
delay, never a row and never a build. The machine's periodic push and its final
flush share `locks/cost-rows-push.lock`, so a flush that lands mid-push simply
skips — that push is already doing the work, and the reap covers the remainder.
A reap push failure writes fly-pool's own log line, not the cron mirror's
3-strike ALERT, and does not advance the cursor.

**Known gap, stated rather than hidden:** the runner's idle loop sleeps in 5s
steps and bash defers a trap until the running command returns, so a `fly machine
stop` can reach SIGKILL before the `TERM` flush runs. That case is exactly what
writer 3 exists for.

### Reconcile check

```bash
# rows the file holds, where the cursor sits, what is still owed, what the DB has
bin/cost-rows-push.sh --verify pool-project-5-9080ee2f34d786 \
  --csv builds/pool-project-5-TK-701-202609141000/cost.csv \
  --cursor builds/pool-project-5-TK-701-202609141000/.cost-rows.cursor
# rc 0 reconciled · rc 1 rows still owed · rc 2 the DB could not be read
# (db_rows is capped at the route's own limit of 2000 and says so)

# and the fleet question this whole lane exists to answer:
J=https://harness-jobs.operator.workers.dev; A="authorization: Bearer $HARNESS_SECRET"
curl -s -H "$A" "$J/api/metrics/cost-rows?box=pool-project-5-9080ee2f34d786&limit=500"
```

```sql
SELECT stage, model, COUNT(*) calls, ROUND(SUM(cost_usd),2) usd
  FROM cost_rows WHERE box LIKE 'pool-%' AND ts >= '2026-09-14'
  GROUP BY stage, model ORDER BY usd DESC;
```

### Knobs and kill switches

| knob | default | where | effect |
|---|---|---|---|
| `COST_ROWS_PUSH` | `1` | `env/global.env` (hub + the pushed pool bundle), or the environment | `0` stops the machine loop, the final flush AND the hub reap push — all three run the same file. `--verify` keeps answering. |
| `flags/cost-rows-push-off` | absent | `/root/harness/flags/` on the hub; `/data/harness/flags/` on a machine | same kill, as a file |
| `COST_ROWS_PUSH_S` | `300` | machine env (`global.env`) | seconds between the machine's pushes |
| `COST_ROWS_PUSH_TIMEOUT_S` | `60` | machine env | per-push timeout on the machine |
| `COST_ROWS_REAP_TIMEOUT_S` | `120` | hub env | per-push timeout on the reap |
| `JOBS_URL` | `https://harness-jobs.operator.workers.dev` | `bin/jobs-client.sh` (falls back to `env/global.env` when that file sets it) | where the rows go |

**No new env var anywhere, in any environment.** The machine authenticates with
`HARNESS_SECRET`, which `bin/fly-envbundle.sh` already puts in the bundle
(`/run/harness-env/global.env`, which `fly/entrypoint.sh` symlinks to
`/data/harness/env` so `$HARNESS/env/global.env` resolves on a machine exactly
as it does on a box). `JOBS_URL` is unset fleet-wide and resolves to the default
compiled into `bin/jobs-client.sh`. The knobs above are all optional overrides
with working defaults, so shipping this needs no Vercel/CI/box env change at all.

## Account meters and the reconciliation (2026-09-14, cost fix 4)

Two independent measurements of the same money, made to agree:

- the **account meter** — Anthropic's own extra-usage figure, read from
  `https://api.anthropic.com/api/oauth/usage` by `bin/extra-usage-track.sh` into
  D1 `extra_usage_snapshots`. This is the invoice.
- **our rows** — `cost_rows`, one per call, plus `jobs.spent_usd` for any
  machine whose rows are not in the window. This is the ledger every dashboard,
  PR cost and budget here is built on.

Nothing compared them until now. That is how `operator@example.com` reached $23.8K
of a $35K monthly cap with its meter unread for fifteen days: a ledger cannot
see an invoice, and an invoice cannot see a lane.

### The account map — `catalog/cost-accounts.json`

The unit of a meter is an **ACCOUNT**, not a box. A box is where a call runs; an
account is who gets the invoice, and the two stopped being the same thing when
the hub's lanes started billing `operator@example.com` while the hub's stored login
belongs to `operator@example.com`. The map is data, in git, because it is a business
fact and not a code constant:

| account | who | login | reads its meter? |
|---|---|---|---|
| `project-6-account` | operator@example.com | hub, `/root/.claude-project-6` | yes |
| `hub-gmail` | operator@example.com | hub, `/root/.claude` | yes |
| `project-1` | project-1 box account | project-1, `/root/.claude` | yes |
| `project-2` | project-2 dedicated | project-2, `/root/.claude` | **no** — 1-year setup-token |
| `project-3` | project-3 dedicated | project-3, `/root/.claude` | **no** — 1-year setup-token |
| `project-4` | project-4 dedicated | project-4, `/root/.claude` | **no** — 1-year setup-token |

`project-6-account` pays for every hub lane, every Fly pool machine, and the
project-5 / project-6 / project-9 / small boxes. Each entry also carries the
`auth_accounts` labels its `cost_rows` rows are tagged with, the `boxes.cost_rows`
whose UNLABELLED Anthropic rows belong to it, the `boxes.jobs` patterns whose
`spent_usd` bills it, and `box_aliases` translates a `jobs.box` into the
`cost_rows.box` the same machine writes under (`box-hub` is `hub`).

### What the meter CAN and CANNOT show

- **Only a full login can read it.** A `.credentials.json` with a refreshToken
  gets 200; a setup-token (`sk-ant-oat01…`) gets **HTTP 429 permanently**, and a
  box token gets 403 `user:profile`. A login that cannot read its meter now
  records a row with `status=no-login` instead of writing nothing — silence and
  a quiet week were the same absence in this table, and only one of them is
  fixed by provisioning a login.
- **The dollar figure only moves past the weekly credits.** Below 100% weekly
  utilization the spend is subscription credits and the meter honestly reads
  $0. A $0 meter is NOT "no spend".
- **It is an account total, not a lane breakdown.** It cannot say which box,
  project or PR spent the money — that is what `cost_rows` is for. The
  reconciliation is the only thing that can tell you the two disagree.
- `bin/oauth-refresh.sh` keeps each login alive (an accessToken lives ~8 hours
  and nothing else on a box ever runs a session on the file).

### Dedicated metered account for the harness (decision for the operator)

The `operator@example.com` meter also bills the operator's Mac Claude Code sessions, so a
move on it cannot confirm what the harness spent. Recommendation: put the
harness boxes on a separate metered account that only harness boxes use, and
keep the Mac on its own. Then that account's meter delta is harness cash and
nothing else, and the reconciliation can compare it to `cost_rows` directly.
Nothing has been changed; this is a recommendation and the call is the operator's
(BH-3985).

### The reconciliation contract — `bin/cost-reconcile.sh`

Per account, per window, ONE row into D1 `cost_reconciliation` (worker
`POST/GET /api/metrics/reconcile`) and ONE line into `logs/cost-reconcile.log`.
The row's `state` is the honest half, and it is why this is not a single number:

| state | meaning | compared? |
|---|---|---|
| `metered` | past the weekly credits — the meter moves in cash | yes |
| `credits-covered` | weekly utilization < 100% at window start | no: the meter has no $ to compare |
| `no-login` | no credential on this account can read its meter | no |
| `no-meter` | no snapshot in the window at all (the poller is down) | no |
| `meter-reset` | the meter fell inside the window (weekly/monthly boundary) | no |

The comparison spans **what the meter actually saw** (first to last sample in
the window), not the window asked for — comparing 40 minutes of meter against 24
hours of rows is how the first run reported a -1146% gap. Rows are summed for
this account's `auth_accounts` labels and Anthropic runners only; `jobs_usd` is
the fallback for a machine with **no rows in the window** — a machine that has
rows is never counted twice, which is what `box_aliases` exists for, and since
*Pool machines push their own cost rows* above, a pool machine's job total drops
out of this sum the moment its first push lands. What is left in `jobs_usd` is
the honest remainder: a machine SIGKILLed before its reap, or spend older than
the row pipeline. `unattributed_usd` is Anthropic spend on this account's boxes
carrying no label — counted nowhere, reported, never silently folded in.

**The alert**: `|gap| > RECONCILE_GAP_PCT` (default 10) on a `metered` account
only, above a money floor and a span floor, ONE per account per day via
`bin/lane-alert.sh`. A gap means either spend is running through a lane that
writes no cost row, or the account map is missing a label.

**Its sibling:** `docs/COST.md` (*Meter-anchored cost*) divides the same two
numbers over the same span, for the opposite purpose — the console multiplies a
raw row sum by `meter ÷ rows` to put a defensible dollar figure on a screen,
where this job subtracts them to raise an alarm. They are the same measurement
read two ways (`gap_pct ≈ 100 × (1 − 1/factor)`), and both refuse to compare
anything that was not fully past the weekly credits for the whole span. If one
ever says `metered` where the other says it cannot measure, that disagreement is
itself the bug — they read the same `extra_usage_snapshots` rows.

```bash
# by hand, against the live ledger — reads only, writes one log line
bin/cost-reconcile.sh --window 24h --dry-run
bin/cost-reconcile.sh --window 1h --account project-6-account
bin/cost-reconcile.sh --window day 2026-09-13

J=https://harness-jobs.operator.workers.dev; A="authorization: Bearer $HARNESS_SECRET"
curl -s -H "$A" "$J/api/metrics/reconcile?account=project-6-account&limit=24" \
  | jq '.reconciliations[] | {window_key, state, meter_delta_usd, rows_usd, jobs_usd, gap_pct, alerted}'
curl -s -H "$A" "$J/api/metrics/extra-usage?box=project-6-account&limit=5"
```

### Cadence, knobs and kill switches

| cron | where | what |
|---|---|---|
| `13,28,43,58 * * * *` | every `cron/<box>.cron` | `extra-usage-track.sh <box>` — every login this box holds |
| `50 * * * *` | `cron/hub.cron` | `cost-reconcile.sh --window 1h` |
| `50 4 * * *` | `cron/hub.cron` | `cost-reconcile.sh --window 24h` |

15 minutes, not hourly: a 1h-window delta needs two samples inside the window,
and at one sample an hour every hourly window has exactly one.

| knob | default | effect |
|---|---|---|
| `EXTRA_USAGE_LOGINS` | from `catalog/cost-accounts.json`, else `<box>=/root/.claude` | `label=/config/dir,label=/other` — the logins this box polls |
| `EXTRA_USAGE_TRACK=0` / `flags/extra-usage-track-off` | on | **kill the meter poll** |
| `EXTRA_USAGE_CAP_ALERT_PCT` | 98 | alert at this % of the extra-usage cap |
| `EXTRA_USAGE_CAP_ALERT_DEDUPE_S` | 21600 (6h) | cap-alert dedupe, per label |
| `EXTRA_USAGE_DAY_ALERT` | 1300 | same-day cash-delta alert, per label |
| `EXTRA_USAGE_STALE_HOURS` | 6 | how stale a meter must be before the daily METER DOWN line |
| `RECONCILE=0` / `flags/cost-reconcile-off` | on | **kill the reconciliation** |
| `RECONCILE_GAP_PCT` | 10 | the gap that alerts |
| `RECONCILE_MIN_METER_USD` | 1 | money floor — a % of $0.40 is noise |
| `RECONCILE_MIN_SPAN_MIN` | 30 | span floor — a 3-minute span measures clock skew |
| `RECONCILE_WINDOW` | 24h | default window when `--window` is not passed |
| `RECONCILE_PAGE_LIMIT` / `RECONCILE_MAX_PAGES` / `RECONCILE_JOBS_LIMIT` | 2000 / 10 / 500 | how far back the row walk reads |
| `COST_ACCOUNTS_FILE` | `$HARNESS/catalog/cost-accounts.json` | the account map |

Everything above is read from `env/global.env` (both scripts source it
themselves — cron does not). No new env var is REQUIRED anywhere: every knob has
a code default, and `HARNESS_SECRET` / `JOBS_URL` are already set fleet-wide.

**Retired in the same change:** `/root/orchestrator/bin/project-6-usage-poll.sh`
and its `7,22,37,52` operator line in `cron/hub.cron`. It was the 2026-09-14
stopgap that read the project-6 meter because the tracker could only poll one
login. The tracker polls both now, posts the same `extra_usage_snapshots` rows
under `box=project-6-account`, and carries the same >=98%-of-cap alert. Two
pollers on one account would split a per-account rate limit and write the same
series twice.

### OpenRouter reconciliation (BH-3983)

The account loop above can only check Anthropic, because only Anthropic has an
extra-usage meter. OpenRouter is checked by its own block in the same script,
`# >>> openrouter reconcile (BH-3983)`, on the daily run only (`24h` and
`day:*`; the hourly `1h` run skips it). It calls `or_ledger_compare` from
`bin/lib/openrouter-ledger.sh` (BH-3998) and compares two numbers over the
vendor's own span (the two `vendor_spend` readings that bracket the window):

1. **What OpenRouter billed.** The `vendor_spend.cumulative_usd` delta between
   those two readings. With `OPENROUTER_RECONCILE_KEYS` set, it is the summed
   `raw.keys[].usage` delta of the named keys instead.
2. **What our rows price.** The sum of priced `cost_rows` with
   `runner=openrouter` inside the same span. Rows with a blank `cost_usd` are
   counted as `unpriced`, never as $0.

**Scope.** With `OPENROUTER_RECONCILE_KEYS` empty the line says `scope=account`:
that is the whole OpenRouter account, so product-app and personal keys are
included and the gap is expected to be larger than ours. Set the knob to the
harness key NAMES (comma-separated, never a secret) and the line says
`scope=harness-keys`. Key names are never printed.

**The alert.** One `[cost-reconcile] OPENROUTER RECONCILE` line through
`bin/alert-line.sh` (the `kind:alert` writer) when the gap is over 15% AND
over $20, both strict, so exactly $20 or exactly 15% stays quiet. Once per UTC
day, on the flag `flags/alerted-cost-reconcile-openrouter-<YYYYMMDD>`, touched
after the alert is sent. The alert names the span and the
`bin/openrouter-audit.sh --since <a> --until <b>` command that shows where the
money went. `--dry-run` logs ` would alert` and sends, flags and pushes nothing.

**One log line per daily run**, whatever came back:

```
cost-reconcile openrouter 24h scope=account state=ok vendor=$200.00 rows=$100.00 (2) unpriced=0 gap=$100.00 (50.0%) alerted=1
```

Every `state=`, and only `ok` can alert:

| state | meaning |
|---|---|
| `ok` | both numbers were read; the gap is real |
| `unread` | a read failed or hit a cap (the vendor read's 1000-row cap, the rows reader's `COST_ROWS_READ_PAGES` ceiling, a named key missing from a snapshot). A failed read, never a quiet day |
| `no-meter` | fewer than two `ok` vendor readings in the window: the vendor poller is down or its key is refused |
| `meter-reset` | OpenRouter's cumulative went down inside the span, so the delta is not a spend |
| `no-lib` | `bin/lib/openrouter-ledger.sh` is not on this box yet (bin/ sync lag) |

A row whose note carries `killed:sig=` is an OpenRouter row written when
`agent-call` was killed mid-call; the line's `killed` count (in the alert and
the pushed row's note) says how many of the span's rows were that.

Each daily run that got a line back also pushes one `account:"openrouter"` row
to `POST /api/metrics/reconcile` with the rest of the run's rows
(`meter_delta_usd` is the vendor delta, `state` is the word above).

| knob | default | effect |
|---|---|---|
| `RECONCILE_OR=0` | 1 | **kill the OpenRouter reconcile** (an invalid value counts as on) |
| `RECONCILE_OR_GAP_PCT` | 15 | the % gap that alerts (strict) |
| `RECONCILE_OR_MIN_USD` | 20 | the $ gap that alerts (strict) |
| `OPENROUTER_RECONCILE_KEYS` | empty (whole account) | key names to compare instead of the account |

All four are lane knobs in `catalog/lanes.d/cost-reconcile.json`, so a settings
row drives them; an invalid number falls back to its default.
