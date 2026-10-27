# The PR unblock agent's review family, in shadow (UNB-2, BH-7724)

Doc: PR_UNBLOCK_AGENT_PLAN_2026-10-20

## What shipped

UNB-2 ships the review family of the PR unblock agent as code that the UNB-0
tick (#7722) will call. Nothing calls it yet. Nothing in it writes to GitHub or
to the jobs worker.

- `bin/lib/unblock/collectors/review.sh`: the read-only collector. It prints one
  JSON record per stall and one `collector-meta` line, always last. Four kinds:
  `lead-block-unrouted` (U5), `lead-block-cap-only` (U6), `lead-request-stale`
  (U7) and `stale-change-request` (U11). It makes 0 model calls. The only file
  it writes is one line in `logs/unblock.log`.
- `bin/lib/unblock/judge.sh`: `unblock_judge <question> <input-file> <key>` asks
  one closed-set question (`test-weakening`: LEGIT, WEAKENED, UNSURE;
  `cap-only`: CAP_ONLY, UNSURE). `unblock_judge_route <rule-file> <answer>`
  prints `proceed`, `block` (and the cites on line 2) or `escalate`.
- `catalog/prompts/unblock-judge.md`: the judge SOP.
- `catalog/unblock-rules.d/U5-block-findings-route.json`, `U6-inconclusive-cap.json`,
  `U7-lead-rerequest.json`, `U11-stale-cr-dismiss.json`: the four rules.

## The seam contract with UNB-0 (#7722)

UNB-0 is not built. This slice took these names and paths first:

- A1. `bin/lib/unblock/judge.sh` is a whole file, not a fill of an S0 stub.
- A2. The tick runs `bin/lib/unblock/collectors/review.sh --project <p> --repo <owner/name>`
  (or sources it and calls `unblock_collect_review` with the same arguments).
  It sources `bin/lib/unblock/judge.sh` and calls `unblock_judge` and
  `unblock_judge_route`.
- A3. The judge keeps its own paid-answer ledger in hub-local files,
  `state/unblock-judge/<fp>.json` `{outcome, attempts, answer, cost_usd, ts}`.
  It only answers "did we already pay for this question". The decision record
  stays UNB-0's `unblock_decisions` table.
- A11. The model comes from the model route role `unblock.judge`. UNB-0 seeds
  the route. Until then every judge call answers `no-route` and calls nothing.
- The engine that evaluates a rule file is UNB-1's `bin/lib/unblock/rules.sh`
  (#7723). The suite uses a test-only evaluator in its place. Each `match.all`
  entry and each `action.args` value is a jq expression over the record.

## The unblock-judge budget row stays with UNB-0

This slice ships no `catalog/context-budgets.d/` row for the `unblock-judge`
stage. `tests/context-budget-manifest-test.sh` refuses a row whose stage no
`bin/*.sh` or `prompts/*.md` file names ("stale row"), and the judge's call
site is in `bin/lib/unblock/judge.sh`, which that check does not read. Its
call-site scan reads only `bin/*.sh` too, so no row is required for this
slice. UNB-0 adds the doc's row (target 6,000, ceiling 20,000 tokens) with
`bin/unblock.sh`, which names the stage.

## The judge's spend rules

An input over its cap (400 diff lines, 60 report lines) or an unreadable SOP
file makes no call. The ledger is read before any call. `ok` and `empty` are terminal. A `failed`
attempt is retried up to `UNBLOCK_JUDGE_MAX_ATTEMPTS`. The attempt is written
before the call. An agent-call rc of 74 to 79 billed nothing, so the attempt is
handed back. A reply that is not exactly one upper-case word of the question's
set is stored as UNSURE (billed, terminal). The answer `cap_only` is UNSURE,
not CAP_ONLY: the parse does not fold case.

## Knobs (environment; code default is the fallback)

| Knob | Default | What it sets |
|---|---|---|
| `UNBLOCK_REVIEW_PR_MAX` | 100 | open PRs read per tick |
| `UNBLOCK_REVIEW_PAR` | 6 | parallel per-PR reads |
| `UNBLOCK_LEAD_STALE_S` | 900 | heartbeat age that makes a lead review request stale (U7) |
| `UNBLOCK_CR_DISMISS_LOGINS` | empty | logins whose CHANGES_REQUESTED reviews qualify for U11 with no marker |
| `UNBLOCK_JUDGE_MAX_ATTEMPTS` | 2 | failed judge calls per fingerprint |
| `UNBLOCK_LLM_MAX_USD` | 0.6 | the per-call budget (`AGENT_CALL_BUDGET_USD_UNBLOCK_JUDGE`) |
| `UNBLOCK_JUDGE_LEDGER_DAYS` | 30 | judge ledger retention |
| `UNBLOCK_JUDGE_PRUNE_DRY` | 0 | 1 = log the prune count, delete nothing |
| `UNBLOCK_JUDGE_TIMEOUT_S` | 120 | the agent-call timeout of the one judge call (10 to 900) |
| `UNBLOCK_JUDGE_DIFF_MAX_LINES` | 400 | input line cap of the test-weakening question (1 to 5000) |
| `UNBLOCK_JUDGE_CAP_MAX_LINES` | 60 | input line cap of the cap-only question (1 to 2000) |
| `UNBLOCK_REVIEW_BLOCK_LINES_MAX` | 60 | `- [BLOCK` lines kept per record in `block_lines` (1 to 1000) |

UNB-0's lane registry file is where these become settings rows. The last four
already have rows: `catalog/lanes.d/unblock.knobs.d/<KNOB>.json` (lead review
BLOCK hardcoded-knob on 69cabb43). An out-of-range value is the default; the
judge also logs one warn line. Test C15 proves each value is honoured.

## Nothing acts until UNB-4

The rule files name the actions `post_block`, `fix_round`, `lead_rerequest`
and `dismiss_review` (act.sh's names and args, UNB-8 #8418). Nothing in this slice runs them. UNB-4 (#7726, act mode)
owns every GitHub and verdict write.

## Tests

`tests/unblock-review-rules.bh-7724-test.sh`, cases C1 to C15.
