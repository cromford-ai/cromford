# Meter-anchored cost

How the console turns a per-call ledger that is wrong into a dollar figure you
can put in front of a client.

## The problem

> **Update, 2026-09-14 — the undercount is being fixed at the source.** Rows are
> now priced from the run's own session TRANSCRIPT rather than from the CLI's
> `--output-format json` envelope (which reported one turn, and nothing at all
> for a run that was killed), and every raw `claude` caller in the repo now
> writes a row. See "Every model call produces a cost row, from its TRANSCRIPT"
> in [`../COST.md`](../COST.md) for the provenance, the new `row_source` /
> `session_id` / `result_usd` columns, the ticket/job/pr/run tags, and the kill
> switches. The `3-4x` figure below was measured by summing transcript LINES,
> which double-counts the usage object once per content block and reads ~2.2x
> high on its own; the honest expectation is that the anchor factor SHRINKS as
> boxes pick up the new rows, not that it reaches 1. It will not reach 1 while
> non-claude runners, off-repo lanes and the subscription/metered split remain,
> so the correction below stays — re-measure it, do not assume it.

`cost_rows` is the fleet's only per-call ledger — one row per agent call, with
the box, project, ticket key, stage, model, tokens and a priced `cost_usd`. It
**undercounts the real bill by 3-4x**. A row is written by the agent-call
wrapper, and every call that does not go through that wrapper never reaches the
ledger. The rows we have are real; the ones we are missing are the problem.

The account's own cash meter does not undercount. `extra_usage_snapshots`
(polled every 15 minutes by `bin/extra-usage-track.sh`, one row per ACCOUNT —
see *Account meters and the reconciliation* in the root `COST.md`) carries
`extra_used_usd` — the number the card is actually charged.

Neither one answers "what did this PR cost" on its own:

- the **meter** knows the total and nothing about who spent it,
- the **rows** know who spent it and are wrong about how much.

## The formula

The rows carry the *shape* of the spend. The meter carries the *scale*.

```
factor(account, window) = meter delta over the window
                          ÷ rows billed to that account over the SAME span

anchored(x) = raw rows of x × factor(the account x bills)
```

`x` is a PR, a ticket or a box. The raw sum ships beside the anchored one in
every row of every table, always — a scaled number with no ledger figure next
to it is unauditable, and an unauditable number on a money screen is how a bad
multiplier becomes a budget decision.

## When the factor is 1, and why that is not "no correction needed"

The cash meter only moves when an account is **past its weekly credits**. Inside
them a call is paid for by the subscription and the meter sits still, so a delta
of zero would divide the fleet's whole spend down to nothing.

Every account therefore carries a **state**, and only one of them multiplies:

| state | meaning |
| --- | --- |
| `metered` | a real, positive meter delta over a span that was fully in overage. This is the only state whose factor is ever ≠ 1. |
| `unmeasured` | a meter exists but this window cannot be measured against it (one poll only, a reset, a meter that did not move, part of the window inside weekly credits, or no priced rows to divide). |
| `no-login` | no meter poll for this account at all. Only a full login can read the usage endpoint — a setup-token gets 429 forever, which is why project-2/project-3/project-4 have no meter — and API-key vendors have no such meter. |

In `unmeasured` and `no-login` the factor is **1** and the anchored column is a
copy of the raw one. The console renders that copy muted and the factor as `—`,
never `1.00x`: "measured, and the rows were right" and "we could not measure
this" are opposite claims and must never look the same.

**Nothing metered is the normal case.** It is a state with a sentence, not an
error.

## Caveats

- **The span, not the window, is the denominator.** The project-6 poller
  started on 2026-09-14, so a 7d window holds only a few hours of meter.
  Dividing a week of rows by four hours of meter would report a factor of 0.02.
  The numerator and denominator cover the same instants or the account is
  `unmeasured`.
- **Fully in overage means every poll, not the last one.** A span that started
  at 87% of weekly credits spent part of itself on credits the cash meter never
  saw.
- **The factor is clamped** to `1/MAX … MAX` (default 20). `rows_usd` is a
  denominator: a window where one $0.02 row happened to carry a label would
  otherwise mint a factor of 900,000 and put a six-figure number on a PR. A
  clamped factor is reported as clamped on screen, not hidden.
- **$/PR and $/box do not add to the same total, on purpose.** A PR row carries
  the whole build's spend including calls made before the window; a box row
  carries only calls stamped inside it, triage and failed builds included. They
  are two different populations and the endpoint says so in `gaps`.
- **`pr_costs` has no usable time column.** `updated_at` is the nightly
  rollup's own clock, rewritten for every row. PRs are placed in the window by
  the stamp on the build dir that produced them, falling back to the merge
  instant. A row with neither cannot be placed in any window and is counted in
  `gaps` rather than guessed at.
- **Hand-run builds carry no ticket key** (`cost-rows-db-20260902`). Their
  dollars are real, so they appear in $/PR and $/box, but not in $/ticket.
- **A box can bill more than one account.** Anchoring is per (box, account) and
  summed — one box-wide factor would attribute project-6's multiplier to a row
  an API key paid for.
- **There is no cap figure in the meter data.** `extra_usage_snapshots` carries
  weekly utilization (`weekly_pct`) and a `spend_limit_reached` flag, but no
  dollar cap. The account strip shows those two and does not invent a cap.
- **The rows are still wrong.** Anchoring scales them; it does not fix the
  source. The row-source undercount is a separate fix.

## Where it lives

| piece | path |
| --- | --- |
| formula + endpoint | `worker/jobs/src/lib/core.js` (`METER-ANCHORED COST` block, `computeAnchored`) + `worker/jobs/src/routes/cost.js` (`GET /api/metrics/cost-anchored`) |
| worker unit tests | `worker/jobs/test/cost-anchored.test.js` (run via `tests/jobs-worker-test.sh`) |
| console presentation rules | `console-ui/src/lib/anchored.js` |
| the screen | `console-ui/src/screens/Costs.js` (`ANCHORED SPEND` section) |
| console tests | `tests/cost-anchored-test.sh` |

The arithmetic is **server-side only**. `console-ui/src/lib/anchored.js`
multiplies nothing; a second implementation of the factor in a browser would
eventually quote a different price for the same PR, and the disagreement would
surface as two screens showing two numbers.

## Endpoint

```
GET /api/metrics/cost-anchored?window=24h|7d
GET /api/metrics/cost-anchored?day=YYYY-MM-DD
    &limit=<1..1000, default 500>
```

Returns `{ accounts[], per_pr[], per_ticket[], per_box[], totals, gaps,
disabled, max_factor, window, from, to, as_of }`. Each table is capped at
`limit` rows (costliest first) with a `*_truncated` flag; `totals` always
covers the whole window, never the page. An unreadable `day` falls back to the
rolling window rather than 400ing — this is a read a dashboard polls.

## Knobs and kill switches

Every knob has a default; nothing here requires a deploy to turn off.

| knob | where | default | what it does |
| --- | --- | --- | --- |
| `cost-anchor-off` | `pause_flags` row (console flags PUT; reconciled onto boxes as `flags/cost-anchor-off`) | unset | **Kill switch.** The endpoint answers `200 {disabled:true}` with **empty** lists. |
| `COST_ANCHOR_OFF` | worker var (`wrangler.toml` / Pages env) | unset | Same kill switch, without needing D1. Set to `1`. |
| `COST_ANCHOR_MAX_FACTOR` | worker var | `20` | The clamp on the multiplier, both directions (`1/20 … 20`). Clamped to `1..1000`. |
| `COST_ANCHOR_ACCOUNT_MAP` | worker var | `project-6-account=claude:operator@example.com,hub=claude:operator@example.com` | Maps the **box that polled** the meter to the **account label** `cost_rows` bills. A business parameter, so it is configurable; the constant in code is the documented fallback, not the source. |

**Off answers empty, not raw.** A client that ignores the `disabled` flag
renders nothing rather than quietly relabelling raw dollars "anchored" — the
same lie in a nicer font.

The kill switch is read **before** the money queries, so an off endpoint costs
one indexed D1 read.

### Where the vars need setting

| var | environment |
| --- | --- |
| `COST_ANCHOR_OFF` | harness-jobs worker (prod). Optional — absent means on. |
| `COST_ANCHOR_MAX_FACTOR` | harness-jobs worker (prod). Optional — absent means 20. |
| `COST_ANCHOR_ACCOUNT_MAP` | harness-jobs worker (prod). Optional — absent means the two-account fallback above. |

No new env var is required for the feature to work, and none is needed in CI or
on any box: the console reads the endpoint through the existing coord proxy and
its session, and the three vars above are overrides only.

---

# What a PR is allowed to cost

The section above is about making a dollar figure *honest*. This one is about
deciding whether that figure is *too high*, and about noticing when the lane
that produces it has stopped.

## The alarm this replaced

`bin/pipeline-health.sh` carried a spend circuit breaker: a flat dollar cap per
project per 24 hours. `$300` a project, `$800` the fleet — the hardcoded
defaults, in force on every box, because `flags/cost-caps.conf` existed on none
of them.

On 2026-09-15 it paged four times before lunch:

```
02:11:42Z project-5 spent $1368.90 in 24h (cap $300)
08:31:30Z project-5 spent $1462.16 in 24h (cap $300)
12:01:34Z project-4   spent  $300.65 in 24h (cap $300)
14:41:57Z project-5 spent $1456.30 in 24h (cap $300)
```

Nothing was burning. project-5 merged ~90 PRs that day at $16-$50 each. The cap
was written for a fleet that shipped a handful of PRs a day, and **a daily
dollar cap is a budget for how much work the fleet is allowed to do** — it has
to be raised every time the fleet gets faster, and between raises it pages on
success. That is worse than no alarm: the next genuine runaway arrives wearing
exactly the same line.

## The budget is a unit price

The check is now on the **rate**, which holds on a 3-PR day and a 90-PR day
alike:

```
rate(project) = delivery spend over the window
                ÷ PRs the harness author set MERGED in the same window
```

Both numbers come from `state/cost/summary.json`, so numerator and denominator
are the same source and the same window. *Delivery* spend is the definition
`cost_per_merged_pr_7d` has always used — product-ideation stages (`ideate`,
`prd`, `mockup`, `signals`, `synth`) are out, everything that goes into shipping
a PR is in.

**24h first, 7d as the fallback.** A project that merges 90 PRs a day is judged
on today; one that merges four a week is judged on the week. The *budget* is the
same number either way, because a unit price does not change with the length of
the window you measure it over.

**Never divided by a tiny count.** Under `min_prs_for_rate` on both windows the
project is not evaluated at all — and is **named**, once a day, in one line with
its counts. One merged PR that happened to carry a decomposition's whole plan
cost is not a budget breach, and a skip nobody can see is how the last stale
threshold survived for a month.

**A count that could not be taken is not zero.** `merged_prs_24h` is `null` when
this box's token cannot see the repo — the hub's default PAT 404s on
`example-org/project-5` (`bin/lib/gh-repo-token.sh`). Those projects go in the
same once-a-day line with `merged_prs_token` saying which token was tried. Until
2026-09-15 that error was read as *zero merged PRs*, which is why the busiest
repo in the fleet showed `merged_prs_7d: 0` and a null `$/PR` all week.

The alert quotes all four numbers plus the **top three stages by cost in the
same window**, because "over budget" with no breakdown sends someone to read a
3MB CSV to find out which stage moved.

## The ceiling is still a ceiling

The rate is a slow signal fed by an hourly rollup. A runaway lane shows up in
`cost_usd` minutes before the rollup sees it, so the absolute brake stays: a
fleet-wide 24h dollar **ceiling** over the intraday ledgers
(`logs/cost.csv` on each box, `cost_usd` column only), one alert a day, naming
the biggest spenders.

It is never quoted as fleet spend anywhere else: it is a brake's number, not a
report's.

## K1 containment (2026-09-24): breakers that brake

The 2026-09-24 runaway / silent-stop analysis found four ways money moved past
every brake above. No per-ticket dollar budget was added; each fix is an
anomaly tripwire or a lane/fleet rate breaker, deterministic, and pages on a
path with no model in it.

| gap | what changed |
| --- | --- |
| The autohalt needed `flags/cost-autohalt-optin`, which no box had, so the breaker paged and never braked. | **On by default.** Kill switches: `flags/cost-autohalt-off` (a file, wins) or the settings row `lane.pipeline-health.cost_autohalt = 0` (the prefix is `lane.`, lane-gate.sh's `_lg_kpfx`). A project already paused (`paused-<p>` active) is left alone: no second halt, no overwritten reason, no page. After a pause the breaker will not pause the same project again for `COST_AUTOHALT_REARM_S` (`state/costhalt/<p>`). **Resuming** is the console's `resume_board` or `flag_set paused-<p> off`: deleting `flags/paused-<p>` on the box does not resume it, because `flag_sync` re-creates the file from the row. |
| The rate divides by merged PRs, so a project spending with **zero** merges was only ever named in the daily "could not evaluate" line (project-9: $643/7d, 0 merged). | **Zero-merge breaker**, merges counted by MERGE date (`bin/cost-rollup.sh` 7d now uses `merged:>=`, and the breaker takes max(7d, 24h)). **7d:** delivery spend ≥ `COST_ZM_7D_USD` with fewer than `COST_ZM_MIN_MERGES` merged in 7d → PAUSED (same flag/row as the rate halt) and paged critical once a day (`costzeromerge:<p>`). **24h:** spend ≥ `COST_ZM_24H_USD` with none merged in 24h → PAUSED only when the 7d merges are also under the minimum; a project that merged this week but not today is **paged, never paused**, because that is what a fleet-wide merge stop (CI outage, MonkCI cap, stuck queue, quiet hour) looks like. After a halt, a window is judged only once it lies wholly after the halt stamp (24h for the 24h rule, 7d for the 7d rule), so a resumed project is not re-paused daily off old spend. Per-project thresholds: `lane.pipeline-health.<p>.cost_zm_24h_usd` (and `_7d_usd`, `_min_merges`). A merged count that could not be taken is still not zero: those projects are never paused on a guess. The ledger's `fleet` bucket is not a project and is never judged. |
| Rows with an empty `cost_usd` added nothing to the ceiling, so an unpriced runner spent invisibly against it. | **Unpriced rows are priced pessimistically, for the brake only:** the model's own rates (cliff included), the price table's top rate per component for a model it does not know, `COST_UNPRICED_ROW_USD` ($2) for an rc-0 call that reported no usage. A failed call with no usage adds nothing, and neither does a `billing_mode=subscription` row (not cash). The ceiling page says how much of its total was priced this way. More than `COST_UNPRICED_RUNNER_HOUR_MAX` (60) unpriced rows from one runner in the last hour pages critical (`costunpriced:<runner>`, once a day). |
| The ceiling's ssh sweep was a hardcoded list of six boxes — no project-6, no project-9. | **The rows come from the topology:** the `cost_rows` table first (every box running `cost-rows-push`, plus the Fly builders' rows the hub ingests), and when it cannot answer, this box's ledger plus every distinct box in `fleet.conf --tailnet-ips`. The page names which source answered. A machine that is in neither (a Mac that does not push `cost_rows`) is still outside the brake. |

**The critical path** is `bin/lib/page-critical.sh`: one `CRITICAL` ALERTS
line (the dedupe file `state/page-critical.json` is read-modify-written under a
flock, and a corrupt one reads as empty), then a `"triaged":true` severity-critical beat (triaged is what keeps it
out of the alert-triage LLM lane's quarantine), and a direct Telegram DM when
the console does not take the beat (the bot token goes to curl on stdin, never
its argv). The rate halt, a halt that could not reach
its box, the zero-merge breaker, the fleet ceiling and the unpriced flood all
page through it; the `$/PR` rate alert itself stays on the ordinary path.

## The file

`catalog/cost-caps.conf`, read only through `bin/lib/cost-budget.sh`. With
`$COST_CAPS_CONF` set (the fixtures; cron never sets it) that file answers
alone. Otherwise the layers apply line by line, lowest to highest, and a higher
layer replaces only the keys it names (BH-4155):

| # | source | what it is for |
| --- | --- | --- |
| 1 | built-in | `$100/PR`, `min 5 PRs`, `$4000/day` fleet |
| 2 | `catalog/cost-caps.conf` | a reviewed commit; read only when no `flags/cost-caps.conf` is readable |
| 3 | `registry-seed` settings rows `conf.cost-caps.*` | the DB copy of row 2. `worker/jobs/schema.sql` seeds them (INSERT OR IGNORE), and `bin/harness-sync.sh` re-seeds through `bin/cost-caps-seed-sync.sh` on the hub whenever the catalog's bytes move, so a reviewed catalog edit reaches the running cap on the next hub deploy. A failed re-seed is one ALERTS line and retries every sync |
| 4 | `flags/cost-caps.conf` | machine-local, line by line |
| 5 | operator settings rows `conf.cost-caps.*` | Console → COSTS → CAPS (`PUT /api/cost-caps`, audited): the lever that needs no deploy |

`cost_budget_source` names every layer that answered, joined with ` + `.
`catalog/lane-caps.conf` resolves the same way through `bin/lib/lane-caps.sh`
(`conf.lane-caps.*`), under the `LANE_*_CAP_<LANE>` env overrides.

Grammar, keyword-led:

```
budget  <project> <usd_per_pr> [min_prs_for_rate]
default <usd_per_pr> <min_prs_for_rate>
ceiling <usd_per_day>
```

**The old grammar is refused, not reinterpreted.** A bare `project-5 300` row
used to mean $300 per *day*. Reading it as $300 per *PR* would raise the bar
tenfold and silence the alert forever — the same broken threshold with the alarm
switched off. Such rows are counted, named in a once-a-day alert, and the
project runs on the default until someone fixes the row.

Seeded 2026-09-15 from measured data. The gated figure
(`cost_per_merged_pr_*`) ran $40-$77/PR across the fleet; budgets sit at roughly
2x that. The file carries both that table and the attributed per-PR p50/mean
that sanity-checks it.

## Liveness: the rollup says when it last succeeded

`bin/cost-rollup.sh` is the **only** writer of `state/cost/`, and every dollar
figure on every screen reads what it wrote. It ran hourly with no lock, no
deadline and no liveness signal, logging one line per run into
`logs/agent-rules.log` that nothing read.

So "the hourly refresh stopped" was discoverable only by `stat`-ing four files —
which someone did on 2026-09-15, read a **local** `10:50` mtime as `10:50Z`, and
reported a five-hour stall in a lane that had last run 28 minutes earlier.

That trap is worth stating plainly, because it is set to catch the next person
too: `/etc/localtime` on the hub points at **America/Chicago** (UTC-5 in
September) while `/etc/timezone` still says `Etc/UTC`. `cron` follows
`/etc/localtime`, so `cron/hub.cron`'s `45 4 * * *` fires at **09:45Z** — which
is exactly what `logs/agent-rules.log` shows — whatever the `04:45Z` in the
comment beside it says. Every `ls -l` and `stat` mtime on this box is five hours
behind the UTC stamps the scripts write into their own logs, and the two are
routinely read side by side.

Three pieces close that:

| piece | where | what it does |
| --- | --- | --- |
| the stamp | `ledgers` row `cost-rollup/last-success` (BH-4158; was `state/cost/last-success`) | written on every successful run, explicit UTC ISO in `detail`. Written at the instant the windows were refreshed — a crashed python block exits before it, which is the point. A failed put is one `last-success row NOT written` log line, never a failed run. |
| the lock | `locks/cost-rollup.lock` | non-blocking. A tick that finds it held **exits 0** (dedupe, never a queue — the operator 2026-09-13). Past `2 × COST_ROLLUP_INTERVAL_S` the holder is wedged, and that is one ALERTS line a day naming the pid to kill. |
| the deadline | `exec timeout -k 60 $COST_ROLLUP_TIMEOUT_S "$0"` | a re-exec, not a cron wrapper, because the cron line is the one thing the script cannot ship a change to. Default 40 min against a ~23 min worst-case collection. |

`bin/pipeline-health.sh` pages **once** when the stamp ages past
`2 × COST_ROLLUP_INTERVAL_S` and **resolves once** when it comes back, clearing
the dedupe stamp so a recurrence re-pages immediately. The time it reads is
the newest of the row, a legacy `state/cost/last-success` and `summary.json`'s
mtime, and the line names the winner. A ledger it cannot read only stops
counting, and the line says `(ledger unreadable)` or `(no ledger row yet)`
rather than reading the outage as stale. Neither `summary.json` nor a legacy
stamp present means there is no rollup here to watch: no ledger request, and
nothing is claimed. The holder's pid + start sit in `locks/cost-rollup.running`
beside the lock.

## `$/PR` by repo and by account

`summary.json` now publishes the attributed per-PR split two ways, for the
console's cost panel and the daily digest:

```
cost_per_pr_by_repo_24h     cost_per_pr_by_repo_7d
cost_per_pr_by_account_24h  cost_per_pr_by_account_7d
cost_per_pr_undated_24h     cost_per_pr_undated_7d
```

Each row is `{repo|account, prs, cost_usd, cost_per_pr}`, costliest first. The
account is `fleet-cost.csv`'s `auth_account` column — the login that actually
paid, which no view could answer before.

Two things the reader has to know, and `cost_per_pr_note` carries both:

- **A PR is placed in a window by the stamp on the build dir that produced it**
  (`pr_costs` has no usable time column — see the caveats above). A PR with no
  dated dir is in no window and is counted in `cost_per_pr_undated_*` rather
  than quietly dropped in or out.
- **An account's `prs` counts PRs it *contributed to*.** A build that failed
  over from a subscription login to an API key bills both, so the by-account
  counts sum to more than the number of PRs.

These are **not** the same figure as `projects[].cost_per_merged_pr_*`, which
divides a project's *whole* delivery spend by its merged PRs and is the number
`catalog/cost-caps.conf` budgets against. Attributed $/PR runs lower — it only
counts builds that produced a PR.

## Knobs

| knob | default | what it does |
| --- | --- | --- |
| `COST_CAPS_CONF` | unset | override the budget file (fixtures) |
| `COST_CHECK_INTERVAL_S` | `1800` | how often the budget/ceiling check runs inside pipeline-health's `*/10` tick |
| `COST_AUTOHALT_MULTIPLE` | `2` | multiple of the budget at which `flags/spend-hold-<project>` is set: new builds held at the launch gate, in-flight work continues (BH-5526) |
| `COST_AUTOHALT` | `1` | the breakers HOLD new builds (1) or only page (0). `flags/cost-autohalt-off` wins over it (K1) |
| `COST_AUTOHALT_REARM_S` | `86400` | after a hold, the same project is not held again for this long |
| `COST_ZM_24H_USD` | `300` | zero-merge breaker, 24h delivery spend (holds only when 7d merges are also under the minimum); `0` turns that window off. Per project: `lane.pipeline-health.<p>.cost_zm_24h_usd` |
| `COST_ZM_7D_USD` | `400` | zero-merge breaker, 7d delivery spend; `0` turns that window off. Per project as above |
| `COST_ZM_MIN_MERGES` | `1` | fewer merged PRs than this in the window is "zero merges". Per project as above |
| `COST_UNPRICED_ROW_USD` | `2` | what the ceiling charges an rc-0 row that reported no usage |
| `COST_UNPRICED_RUNNER_HOUR_MAX` | `60` | more unpriced rows than this from one runner in an hour pages critical, once a day |
| `COST_ROLLUP_INTERVAL_S` | `3600` | the rollup's cron cadence; the staleness threshold is a multiple of it |
| `COST_ROLLUP_STALE_MULT` | `2` | how many intervals late is stale |
| `COST_ROLLUP_TIMEOUT_S` | `2400` | the rollup's hard deadline |
| `RECONCILE_BLANK_ROWS_MAX` | `20` | more than this many rc=0 rows from ONE runner arriving with an empty `cost_usd` in an hour pages once per runner per UTC day (`bin/cost-reconcile.sh --window 1h`). `0` turns that pass off |

None of these need setting anywhere for the feature to work: every one has a
documented fallback in the script that reads it, and the budgets themselves ship
in `catalog/cost-caps.conf`.

## Runaway ceiling (BH-5526 C3)

Each lane can carry one hard day ceiling, the settings row
`spend.ceiling.<lane>.day_usd` (dollars, all stages and projects, UTC day).
`bin/lib/llm-gate.sh` refuses a NEW start on a lane at or over it: a fresh
build at the launch gate (`BUILD_DEFERRED spend-ceiling …`) or a call outside
an admitted build (rc 74). An admitted ticket finishes all its stages. The hub
seeds the rows once a day at 3x each lane's p99 (7+ days of data), insert-if-absent,
through `bin/spend-ceiling-seed.sh`. `off` lifts one lane; the switch
`spend-ceiling-off` lifts all. Details: `docs/notes/2026-10-11-BH-5526-spend-ceiling.md`.

## Lane spend view (BH-5526 C4)

/costs → LANE SPEND · TODAY (UTC) shows each lane's spend today (the `cost_rows`
stamped with its `lane_id`, the sum the ceiling gate reads), its alert line
(`SPEND_ALERT_P99_MULT` x p99) and its ceiling row. The hub pushes the p99 table
once a day as `ledgers` rows of kind `spend_p99` (`bin/spend-lane-push.sh`), and
`GET /api/metrics/lane-spend` joins the three. Details: `docs/notes/2026-10-12-BH-6174-lane-spend.md`.

## Cost-capture parity

A call that the ledger cannot price is money nobody can see. Two different
things produce one, and they have different owners:

| shape | who notices | who fixes it |
| --- | --- | --- |
| the call reported tokens, the model has no price row | `bin/cost-rollup.sh` (hourly, daily line) | add the model to `catalog/model-prices.json` |
| the call reported **nothing at all**, on rc 0 | the box that made the call, immediately | that runner's usage capture |

The second one is the expensive one, and it used to be invisible. BH-406: 217
`grok/grok-4.6` rows in a single 24h window shipped with blank `input_toks`,
blank `output_toks` and blank `cost_usd`. The parser lived inline in the grok
branch of `bin/agent-call.sh` and assumed two things — that the ledger was at
`~/.grok/sessions/**/updates.jsonl`, and that a usage object carries
`costUsdTicks`. The ledger path had already moved once (2026-08-20), and a
session billed against the SuperGrok subscription pool reports no metered ticks
at all, so a perfectly good token count was thrown away. Nothing on the box said
so; the hub's rollup was the first and only mention, once a day.

### What guards it now

- **`bin/grok-usage.sh [--calls] [--envelope <file>] <t0-epoch> [grok-home]`** —
  the grok ledger reader, the same design as `bin/codex-usage.sh`. It WALKS the
  tree for any file touched at or after the call started and RECURSES each line
  for a dict carrying an input+output token pair, so neither the filename nor
  the key layout is a contract. Prints `in out cache_read cache_write usd`,
  empty for anything it cannot find, exit 0 always. `~/.grok/auth.json` is
  skipped by NAME, before any open — it is refreshed on every call, so it is the
  newest file in the tree exactly when this runs.
  `--envelope <file>` is the FIRST read in summary mode: the CLI's own
  `--output-format json` result document, which carries `usage.*` and a
  `total_cost_usd` the vendor computed from the meter it bills, and which
  belongs to this call by construction rather than by mtime. Anything that is
  not unambiguously a usage-carrying envelope — no file, unparseable, no
  `usage` dict, a `usage` dict without both an input and an output key — falls
  through to the walk, because a killed run never writes one and its tokens were
  still billed. `--calls` ignores it: that series is the ledger's.
  The output field counts a sibling `reasoning_tokens` (or `reasoningTokens`)
  on both paths: grok reports reasoning apart from `output_tokens` (the 1.0.40
  envelope says output 1 beside reasoning 412), so `output_toks` is 413 there.
  A nested `output_tokens_details.reasoning_tokens` is never added, because on
  that OpenAI shape the output count already includes it. Envelope dollars are
  the vendor total and do not change; a row priced from tokens now prices the
  reasoning too. The envelope read is switched on per box by
  `GROK_OUTPUT_JSON=1` or fleet-wide by the settings row
  `lib.agent-call.grok_output_json = 1`.
- **`cost_price_tokens`** (`bin/lib/cost-row.sh`) — tokens × the price table,
  component for component with `cost-rollup.sh`'s `row_cost()`, so a row priced
  at the call site and the same row priced by the hub never disagree. Empty when
  there is no table, no row for the model, or no counts — never `0`.
  Search order, first readable wins: `$MODEL_PRICES` (used as given, never
  fallen back from), `$HARNESS/state/model-prices.json` (the hub's live table,
  rewritten daily by `bin/update-model-prices.sh`), the repo checkout's
  `catalog/model-prices.json`, then `$HARNESS/catalog/model-prices.json` — all a
  fly builder has. `state/` is never propagated off the hub, so a box resolves
  the committed catalog exactly as it always did. `bin/transcript-cost.sh`,
  `bin/planned-files-cheap.sh`, `bin/orchestrate.sh` and `bin/cost-rollup.sh`
  use the same order.
- **`cost_parity_alert`** (`bin/lib/cost-row.sh`) — one ALERTS line when a call
  returned rc 0 and reported no usage at all. Every runner, not only grok.
  Deduped per runner/model/stage per UTC day via
  `flags/alerted-cost-parity-<runner>-<model>-<stage>-<YYYYMMDD>`; the line is
  appended BEFORE the flag is touched, so the failure shape is a duplicate line,
  never a lost page.
- **`cost_row_price`** (`bin/lib/cost-row.sh`) — the one place a row is priced,
  called from `run_attempt` in `bin/agent-call.sh` immediately before the row is
  assembled, for EVERY runner. Until BH-1020 only the grok branch priced its own
  tokens, so the codex, openrouter and fireworks lanes wrote real token counts
  beside an empty `cost_usd` and 1,987 rows / about $3.5K in three days read as
  $0.00 everywhere except `cost-rollup.sh` (which prices blank rows itself).
  Rules, in order: a dollar figure already on the row is final (a vendor or
  transcript measurement is never overwritten by a catalog estimate); any token
  count present is priced through `cost_price_tokens`; a price it cannot get
  leaves `cost_usd` EMPTY and writes `UNPRICED:no-price:<model>` into the `note`
  column; an rc-0 call that reported nothing gets `UNPRICED:no-usage`; a FAILED
  call with no usage is left alone, because it was never billed. The markers
  join an existing note (`cliff-routed:…`) with `;` rather than replacing it.
  The dollars are NOTIONAL, which is what `cost_usd` has always meant — a
  subscription row is still zeroed for cash by `billing_mode`, so cash views do
  not move and lane comparison, volume and cost-per-PR stop reading the fleet's
  busiest runners as weightless.
- **the blank-cost flood alert** (`bin/cost-reconcile.sh`, hourly) — the hub's
  half of the same question: how many rc=0 rows arrived with an empty
  `cost_usd`, per runner, in the last hour. More than `RECONCILE_BLANK_ROWS_MAX`
  (default 20) is one ALERTS line naming the runner, the count and the model
  most of the flood ran on, deduped per runner per UTC day via
  `flags/alerted-cost-blank-<runner>-<YYYYMMDD>`. It runs only on `--window 1h`
  so a day's total is never read as an hour's flood, it writes
  `blank-cost 1h clean` only after a successful read (a fetch that did not
  complete logs `unread` and alerts nothing), and it says `pages=<n> capped`
  when the page walker hit `RECONCILE_MAX_PAGES` and the count is a floor.
- **`bin/cost-rollup.sh`** still writes its daily fleet line, and now links back
  here. That line arriving with no `[cost-parity]` line in the box's own
  ALERTS.log means the box has not synced the call-site guard.

The row says which of these happened: `row_source=ledger` means the numbers came
out of the CLI's ledger, `none` means nothing was read. `cost_usd` is what every
cost view reads (`billing_mode` is still what says whether it was cash);
`result_usd` keeps the vendor's own reading beside it, so a ticks-less session
shows a table price in one column and an empty one in the other rather than the
two quietly merging.

### Fixture provenance

| fixture | what it is |
| --- | --- |
| `tests/fixtures/grok-usage-nested-ticks.jsonl` | the shape VERIFIED against live hub ledgers on 2026-08-20 (commit 57c8bd7): usage nested under `params.update`, with `inputTokens`/`outputTokens`/`cachedReadTokens`/`cacheCreationTokens`/`costUsdTicks` |
| `tests/fixtures/grok-usage-no-ticks.jsonl` | HYPOTHESIS, labelled as such in the file: the same shape with no `costUsdTicks`, which is what a subscription-billed session should look like. Nobody has captured one |
| `tests/fixtures/grok-usage-none.jsonl` | a ledger with no usage object at all, plus a `maxInputTokens` settings line that must NOT read as a call |
| `tests/fixtures/grok-usage/1.0.40/envelope.json` | RECONSTRUCTED, not captured, from figures the operator measured on a grok 1.0.40 / grok-4.7 session and posted verbatim on #1494 (2026-09-22 18:05Z). Every number and every key name except `result`/`type` is his; `result` is a flagged guess. `PROVENANCE.md` beside it is the full accounting. No `~/.grok/logs/unified.jsonl` fixture exists yet — `tests/cost-grok-usage.bh-1494-test.sh` §A8 carries that as a named TODO |

### Owed proof

The fix was built on a box with no grok CLI and no `~/.grok`, so no live ledger
was captured and no live row has been priced by it yet. On a grok-equipped box,
after the merge has synced, run one triage shard and read the row back:

```
grep ',grok,' /root/harness/logs/cost.csv | tail -1     # cost_usd (col 13) > 0, row_source (col 18) = ledger
grep 'cost-parity' /root/harness/logs/ALERTS.log        # empty on a healthy box
bin/grok-usage.sh 0 ~/.grok                             # prints the live shape, by hand
```

Until that row exists, this is BUILT, not proven live.

BH-1020 owes the same read-back. `cost_row_price` was built and driven against
`bin/agent-call.sh` in a scratch tree with fake CLIs; no live openrouter,
fireworks or codex row has been priced by it yet. After the merge has synced to
a box that runs those lanes:

```
grep ',openrouter,' /root/harness/logs/cost.csv | tail -1   # col 13 non-empty on a row with tokens
awk -F, '$7=="0" && $9!="" && $13==""' /root/harness/logs/cost.csv | wc -l   # should stop growing
grep 'blank-cost 1h' /root/harness/logs/cost-reconcile.log | tail -3         # one line an hour at :50
```

## Tests

| what | where |
| --- | --- |
| rate alerts once with all four numbers; small-n and uncountable repos are named, never divided by; ceiling; the old grammar is refused | `tests/cost-budget-test.sh` |
| K1: autohalt on with no opt-in, both kill switches, re-arm; the zero-merge breaker in both windows (uncountable repo, `fleet` bucket and a per-project row all spared); unpriced rows priced pessimistically into the ceiling; the per-runner unpriced flood; the topology sweep and the `cost_rows`-first read | `tests/cost-containment.k1-test.sh` |
| the critical page: one ALERTS line, a triaged critical beat sent strict, dedupe per key, a direct DM when the console refuses, "only copy" when there is no token | `tests/page-critical.k1-test.sh` |
| the UTC stamp, the non-blocking lock and its wedged-holder alert, the deadline re-exec, the detector's page/resolve/fallback | `tests/cost-rollup-liveness-test.sh` |
| the grok ledger reader (paths, shapes, credentials, stale sessions), `cost_price_tokens`, `cost_parity_alert`, and `bin/agent-call.sh` driven end to end for a priced row and a paged one | `tests/cost-grok-usage-test.sh` |
| grok 1.0.x: the envelope read before the walk and every shape that must fall through to it, the `modelUsage` key spellings, `--calls` still the ledger's series, and `bin/agent-call.sh` driven with `GROK_OUTPUT_JSON` on and off | `tests/cost-grok-usage.bh-1494-test.sh` |
| reasoning tokens in the output count: the sibling key added on the envelope and walk paths, the nested/codex/bad-value/no-output negatives, `--calls` input unchanged, and `bin/agent-call.sh` driven to a row with `output_toks` 413 | `tests/cost-grok-usage.bh-1636-test.sh` |
| the `lib.agent-call.*` settings rows: 11 registered knobs, none of them the cooldowns other lanes read, whose defaults match agent-call.sh's literals, a row turning the envelope on and setting `--max-turns`, no row = today's call, `LANE_GATE_DISABLE=1` ignores rows | `tests/agent-call-knobs.bh-1636-test.sh` |
| the rollup's daily unpriced line, its breakdown by cause and its link to this note | `tests/unpriced-alert-test.sh` |
| `cost_row_price` (the catalog product with `cache_read` as reported, `UNPRICED:*` markers, a vendor figure never overwritten, empty never `0`), plus `bin/agent-call.sh` driven across openrouter and grok and a mutation guard that proves the priced row goes blank without the function | `tests/cost-row-priced-test.sh` |
| the blank-cost flood alert driven through `bin/cost-reconcile.sh`: 21 blank rows page and 20 do not, failed and priced rows never count, the 24h window never runs it, the daily dedupe, the knob, and an unreadable ledger logging `unread` instead of `clean` | `tests/cost-reconcile.bh-1020-test.sh` |

Both extract the blocks **verbatim** from the shipped scripts by their markers,
so a rewrite that drops a behaviour fails rather than silently passing a copy.
