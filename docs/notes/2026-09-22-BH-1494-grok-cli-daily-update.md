# grok is a runner CLI the fleet updates daily, and its 1.0.x cost row prices

Doc: OPERATOR-SETUP, COST

## Why

On 2026-09-22 the fleet's grok CLIs sat at 0.2.118 on six boxes, 1.0.5 on
project-6, 1.0.13 on project-1-1 and MISSING on small, while xAI's current
release was 1.0.40 and Grok 4.7 had already shipped as Grok Build's default
model. `bin/cli-update.sh` updated claude and codex every morning and
`bin/cli-version-check.sh` alerted on both; grok was in neither, so a stranded
box looked exactly like a quiet one — the same shape as the Fable 5.1 incident
that bought those two scripts in the first place.

## What changed

**`bin/cli-update.sh` treats grok as a third CLI.** `CLIS` defaults to
`claude codex grok`. grok has no npm package: xAI ships a native binary at
`~/.grok/downloads/grok-linux-x64` with `~/.grok/bin/grok` symlinked at it, and
the update mechanism is re-running the installer
(`curl -fsSL https://x.ai/cli/install.sh | bash`). Contract unchanged from the
other two — a row in `logs/cli-versions.csv` and the DB, non-zero only when a
CLI ends up WORSE or MISSING, a failed update that left the old binary is a log
line.

Two things about it are grok-specific and deliberate:

- **The launcher is read before PATH.** The installer links into `/usr/local/bin`
  only when its own PATH check says it must, and never into `/usr/bin` — while
  every lane reaches grok by prepending `$HOME/.grok/bin`
  (`bin/agent-call.sh`, `bin/lane-probe.sh`, `bin/orchestrate.sh`). So MISSING
  here means "the lanes cannot run it", not "cron's `/usr/bin` has no link".
  The generic relink step still gives cron's PATH one link afterwards.
- **`~/.grok/downloads` is kept one cycle** as `~/.grok/downloads.prev`, and
  ONLY on a run that actually changed the version. Rollback is one command, and
  the log line prints it:
  `mv ~/.grok/downloads.prev/grok-linux-x64 ~/.grok/downloads/grok-linux-x64`.
  A no-op day that snapshotted would overwrite the real previous release with a
  copy of the current one, and the rollback would restore the broken build.
  the operator's hand-made `downloads.pre-20260922` is never touched.

**`catalog/cli-min-versions.json`** gains `grok` under `clis` with its
`native_launcher`, `grok-4.6` and `grok-4.7` at a floor of `1.0.40`, and
`grok-4.6` in `fleet_defaults` (`GROK_MODEL` defaults to it in
`bin/agent-call.sh`). The `gpt-6-astra` floor went from `0.153.4` to `0.155.1`;
the fleet is already there.

**`bin/cli-version-check.sh` probes the catalog's CLI list**, not a hardcoded
`claude codex`. The ticket assumed the check would cover grok with no change;
it would not have — the probe's list was hardcoded and it resolved every CLI on
the cron PATH, so the day this merged every box would have reported
"grok MISSING on the cron PATH". It now reads `${CLI_CHECK_HOME:-$HOME}/.grok/bin/grok`
first in both the cron view and the login view, which also means a box whose
`/usr/local/bin` holds an older grok is not reported as a split it does not
have. Adding a CLI is now one catalog edit.

**`bin/grok-usage.sh` learns 1.0.x.** Two separate misses, both in the operator's
2026-09-22 comment: `total_cost_usd` sits at the envelope's TOP level beside
`usage` rather than inside it, and `modelUsage`'s spellings
(`cacheReadInputTokens`, `cacheCreationInputTokens`, `costUSD`,
`total_cost_usd_ticks`) were in none of the reader's key lists. That is exactly
"tokens, but blank cache and blank dollars". The key lists now carry them, and
a new `--envelope <file>` makes the CLI's own `--output-format json` result
document the FIRST read in summary mode: one parse, the vendor's own dollars,
and a source that belongs to this call by construction rather than by mtime.
Every miss falls through to the tree walk exactly as before — a killed run never
writes an envelope and its tokens were still billed.

**`bin/agent-call.sh` gains `GROK_OUTPUT_JSON` (default `0`).** At `1` the grok
lane adds `--output-format json`, keeps the raw envelope at `$OUT.envelope`,
writes `.result` to `$OUT` (raw envelope passed through, with a log line, when
that field is not a string) and prices the row from the envelope. At `0` the
lane is byte for byte what it was.

At `1` the lane also truncates `$OUT` itself before the call. At `0` the CLI's
`> "$OUT"` redirect did that as a side effect; at `1` stdout goes to the
envelope, and `$OUT` is keyed on (PR, head) and reused by every rung of the
survival ladder — so without the truncate a CLI that exits 0 printing nothing
would leave the PREVIOUS attempt's answer on disk, and the `[ -s "$OUT" ]`
guard would ship it as this call's with rc 0. `$OUT.envelope` is also swept on
a ledger replay, beside `$OUT.json`/`.err`/`.events`/`.account`: a replayed
answer was not bought by the run that wrote the envelope, and the envelope is
what prices a row.

## Still owed (neither is claimable from this PR)

1. **Flip the default.** Which envelope field carries the ANSWER TEXT is
   documented nowhere this fleet can reach (docs.x.ai 404s, x.ai/cli 403s from a
   box). `.result` is Claude Code's spelling and the key set xAI prints matches
   it, which is why it is tried first — but it is a guess, so the knob defaults
   off. One probe on a 1.0.40 box (`grok --output-format json -p 'say ok'` and
   read the keys) settles it, and then `GROK_OUTPUT_JSON=1` in
   `env/global.env`.
2. **The tree-walk fixture.** 1.0.40 dropped `sessions/**/updates.jsonl` for
   `~/.grok/logs/unified.jsonl`, and no 1.0.x line of that file has been
   captured — no grok binary on the builder, and BH-1494 forbids buying a
   metered session to make one.
   `tests/cost-grok-usage.bh-1494-test.sh` §A8 prints it as a named TODO and
   counts it as neither a pass nor a fail.

`catalog/model-prices.json` has no `grok-4.7` row, so a 4.7 call with no vendor
dollars prices EMPTY and pages through `cost_parity_alert`. Not added here: the
fleet default is still `grok-4.6`, the envelope path carries xAI's own figure,
and prices ride `bin/update-model-prices.sh`.

## Where it is pinned

`tests/cli-update.bh-1494-test.sh` (the installer shapes, retention, bootstrap,
redaction), `tests/cli-version-check.bh-1494-test.sh` (floor, at-floor, missing,
launcher-before-PATH, catalog-driven CLI list) and
`tests/cost-grok-usage.bh-1494-test.sh` (envelope-first, the 1.0.x spellings,
`--calls` unchanged, `bin/agent-call.sh` driven with the knob on and off, and
the `-m` pin on `bin/lane-probe.sh`).
