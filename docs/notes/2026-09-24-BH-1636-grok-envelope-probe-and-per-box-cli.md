# The grok envelope probe, grok rows in cli_versions, and a per-box grok requirement

Doc: COST, OPERATOR-SETUP

## What changed

These are the rest of BH-1636, items 1 and 4. Items 2 and 3 shipped in #1647;
see `2026-09-23-BH-1636-grok-reasoning-and-agent-call-knobs.md`.

- **`bin/grok-envelope-probe.sh` (new).** It makes one metered grok call on the
  box it runs on, with `--output-format json --max-turns 1` under
  `timeout 180`. It asks grok to echo a nonce. The verdict is `ok` only when
  the nonce comes back at `.result` and `bin/grok-usage.sh --envelope` prices the
  envelope at a non-zero dollar figure. The model is `grok.default` rung 0 from
  model_routes, or `--model`. The call is keyed in the job ledger (kind
  `grok-envelope-probe`, key `<grok version>:<model>`) before it spends:
  `ok` and `billed-fail` are terminal, so the probe is never bought twice
  (`--force` buys another). An unreadable ledger means no call. The envelope,
  the `~/.grok/logs/unified.jsonl` lines that carry the envelope's session id,
  and a `PROVENANCE.md` whose first line is `# CAPTURED` go to
  `state/grok-probe/<version>/`, after a scan for credential-shaped strings. With
  `--flip`, and only after an `ok` verdict is in the ledger, it writes the
  settings row `lib.agent-call.grok_output_json = 1` and reads it back.
  **Every call it makes lands one `logs/cost.csv` row** (the operator, 2026-09-24: "A
  billed grok call must land a priced cost row"). Stage `grok-envelope-probe`,
  runner `grok`, project `${COST_PROJECT:-fleet}`, the call's rc and duration,
  and the tokens and dollars `bin/grok-usage.sh --envelope` reads, on every
  verdict: `ok`, `billed-fail` (a timeout included) and `refused`. It goes
  through `cost_row_emit` and is priced by `cost_row_price`: the envelope's own
  dollars stand; tokens with no dollars are priced from
  `catalog/model-prices.json`; with no price the cost is blank and the note says
  `UNPRICED:*`, never 0. A refusal with no usage is a priced $0. The note is
  `probe:<verdict>:<detail>`. The row is written before the ledger verdict, so a
  ledger that fails after the call still leaves the spend costed. A run that
  stops before the call writes no row. The DB copy comes from the */10
  `bin/cost-rows-push.sh` mirror: the probe does not load the jobs client, so
  `cost_row_emit`'s at-source POST is skipped, as it is in `bin/claude-cost.sh`.
  Exit codes: 0 ok or already probed, 1 refused or billed-fail, 3 nothing to
  probe with (no grok, below the floor, no model route), 4 ledger unusable,
  5 the flip did not read back. Every non-zero exit writes one ALERTS.log line.
- **`tests/cost-grok-usage.bh-1494-test.sh` §A8** now asserts over every
  `tests/fixtures/grok-usage/*/` whose `PROVENANCE.md` opens with `# CAPTURED`.
  The envelope must price (tokens and non-zero usd), `.result` must be a string,
  and the unified.jsonl, when there is one, must walk to input and output
  tokens. With no such dir the TODO line is printed as before. It now names the
  probe as the way to capture one. The 1.0.40 dir is RECONSTRUCTED and does not
  arm it.
- **`POST /api/metrics/cli-versions` keeps grok rows.** The route's allowlist
  was `claude|codex`, so every grok row that `bin/cli-version-check.sh` and
  `bin/cli-update.sh` pushed after BH-1494 was dropped. On 2026-09-24 the r2
  build read `GET /api/metrics/cli-versions?limit=2000` and got 1,973 rows and
  none for grok. A grok row is now written to `cli_versions` history only. It writes no
  `box_status` row, because that table has no grok column, and before this
  change the claude-or-else ternary would have filed grok's version under
  `codex_version`.
- **`CLI_CHECK_OPTIONAL`** (settings row
  `lane.cli-version-check.cli_check_optional`, default empty). It is a
  space-separated list of `<cli>@<box-id>` pairs. A listed pair whose CLI reads
  MISSING raises no alert. Its TSV row and DB row say
  `not required on this box (CLI_CHECK_OPTIONAL)`. Only MISSING is waived. An
  installed CLI below its floor, behind the hub, or split across PATHs still
  alerts. Malformed tokens are ignored and named in
  `logs/cli-version-check.log`. Empty means every CLI is required on every box,
  the same as before. This change writes no row.

## Why the flip matters beyond parity

As read by the r2 build, project-4's triage rows repeat identical token counts across separate calls
(`137686 / 2100` at 10:52, 11:42:43 and 11:42:52 on 2026-09-24; `169770 / 386`
three times on 09-23). That is the newest-file walk reading one session for
several concurrent calls. The envelope belongs to its call, so the flip fixes
the attribution as well as the missing cache and dollar fields.

## What is still owed (not done by this change)

The build box had no grok binary and no grok auth, so **the probe has not been
run**. There is no real capture yet, and `GROK_OUTPUT_JSON` is still 0. An
operator runs, on a box with grok >= 1.0.40 and working auth (project-4 has 81
priced grok triage rows since 2026-09-20):

```
/root/harness/bin/grok-envelope-probe.sh --flip
tail -1 /root/harness/logs/cost.csv    # grok-envelope-probe,grok,... with cost_usd > 0
/root/harness/bin/jobs-client.sh setting-get lib.agent-call.grok_output_json    # 1
```

Then open a follow-up PR that commits the capture:
`cp -r /root/harness/state/grok-probe/<version> tests/fixtures/grok-usage/`.
That arms §A8. No box has a `CLI_CHECK_OPTIONAL` row. Which boxes should carry
one is an operator call, made from the grok rows that
`GET /api/metrics/cli-versions?cli=grok` returns after this deploys.
