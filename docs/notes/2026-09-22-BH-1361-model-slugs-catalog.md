# BH-1361: the model → slug map is data (catalog/model-slugs.json), and the UNPRICED alert writes the line for you

**What was wrong.** `bin/update-model-prices.sh` priced from a `MAP='{…}'`
constant inside the script, so adding a model to the price table was a code
deploy. Both times the fleet met a new model the same thing happened: real spend
read as $0.00 on every cost view until somebody edited `bin/` and landed a PR —
grok on 2026-08-19 (~$460 in two days, blank cost column), `claude-opus-4-8` and
`deepseek/deepseek-v4-flash` on 2026-09-22 (30 calls, 24.7M tokens, #1360). The
UNPRICED alert that caught the second one said "add the model to
catalog/model-prices.json" and stopped there, which still left the hard part:
working out which OpenRouter slug prices the model, from a 400-entry API list.

**What changed.**

1. `catalog/model-slugs.json` is the map: `{ "<model key as cost rows name it>":
   "<openrouter slug>" }`, seeded with all 27 keys the constant had. Adding a
   model is a one-line data edit in that file.
2. `bin/update-model-prices.sh` resolves the map in this order: `$MODEL_SLUGS`
   if set (used AS GIVEN — an explicit override never falls through to another
   path), else `$HARNESS_CHECKOUT/catalog/model-slugs.json`, else
   `$HARNESS/catalog/model-slugs.json` (`bin/harness-sync.sh` already rsyncs
   `catalog/` to every box). The first path that EXISTS wins; if it parses as an
   object whose values are all strings it is the whole map, and it REPLACES the
   constant rather than merging with it — an operator who deletes a key meant to
   delete it. No file, or an unusable one, falls back to the `MAP` constant and
   writes ONE line to `logs/agent-rules.log`
   (`model-prices: slug map absent at …` / `slug map invalid at … `). That is a
   note, not a page: the lane still produced a full table, so it is not an
   ALERTS line. A valid but EMPTY `{}` is data, not damage — it maps nothing,
   the existing `>= 5` floor refuses the write, and yesterday's table stands.
3. The refresh now also writes `state/openrouter-models.json`
   (`{"fetched_at": …, "ids": [every id the API returned]}`), temp+mv, after the
   `>= 5` gate and before the price table. It already had the list in memory
   once a day; writing it down means the hourly rollup does not have to fetch it
   again. It is a hint source, not a contract: a failed write changes nothing
   and stops nothing.
4. `bin/cost-rollup.sh`'s `unpriced_pairs()` gives every pair a
   `suggested_slug` — `None` for a model that already has a price row (its row
   exists, the parse is the problem, and a catalog line would send the fix to
   the wrong file), otherwise the model itself when it IS an OpenRouter id, else
   the best `difflib` match in `state/openrouter-models.json` at ratio ≥ 0.6
   over the last `/` segment with `.`→`-` normalising, else `None`. Every read
   is fail-soft: no state file (it is hub-only and lands at 04:30Z), an
   unreadable one, or no close match all give `None`.
5. The UNPRICED alert names the line to add:

   ```
   No price-table entry: claude/claude-opus-4-8 (28 call(s), 19500000 tokens)
   [add to catalog/model-slugs.json: "claude-opus-4-8": "anthropic/claude-opus-4.8"]
   — the 04:30Z refresh prices it from that line; land the refreshed row in
   catalog/model-prices.json for the fallback.
   ```

   With no close match it says `"claude-opus-4-8": "<slug?>" (no close
   openrouter match — pick the id from https://openrouter.ai/api/v1/models)`.
   The hint is never a guess dressed as an answer.

**Closing an UNPRICED alert now.** Copy the bracketed line into
`catalog/model-slugs.json`, keep the keys sorted, open a PR. The hub's next
04:30Z refresh prices the model into `state/model-prices.json` and mirrors it to
the `model_prices` table, from which `bin/model-prices-sync.sh` pulls it to every
box. The committed `catalog/model-prices.json` is still the fallback every box,
fly builder and pool archive reads, so land the refreshed row there too — the
catalog-behind notice at the end of the refresh says when it has drifted.

**Why a catalog file and not a table.** It is operator data that moves by PR,
exactly like its sibling `catalog/model-prices.json`. It is NOT
`merge=union` in `.gitattributes` and must never be: git's union driver
concatenates both sides of a hunk, which for a JSON object is a file nobody
wrote (BH-1178). Two PRs adding different models conflict on one line and a
human resolves it; that is the right trade at roughly one model a month.

**Verification.** `tests/update-model-prices.bh-1361-test.sh` runs the whole
lane against a scratch `$HARNESS` and a real scratch clone: a key in the catalog
and absent from the constant gets priced (red on `origin/main`'s script via
`SCRIPT_UNDER_TEST=`), the constant still prices ≥ 5 models with no file or an
unusable one and logs exactly one line, an empty `{}` hits the floor and leaves
the previous table, the thin-list refusal moves neither state file, and an
unreadable `$MODEL_SLUGS` never falls through.
`tests/unpriced-alert.bh-1361-test.sh` drives `unpriced_pairs()` and the
extracted alert block: exact id → itself, `claude-opus-4-8` →
`anthropic/claude-opus-4.8`, `grok-4.6` → `x-ai/grok-4.6` and not
`x-ai/grok-4.5`, an unrelated model → null, a priced model → null, no state file
→ all null, and the ALERTS line carries the literal catalog line (red on
`origin/main`'s `bin/cost-rollup.sh` via `SRC=`).

Doc: COST
