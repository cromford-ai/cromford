# BH-9460: one wrangler helper heals a broken npx cache, names a tool failure, and re-pages a stale worker

Doc: ALERTS-STATE-MACHINE

## Why

On 2026-11-09 at 16:59 UTC the worker-phase step timeout (240 s) killed
`npx --yes wrangler` while npm was installing wrangler into
`/root/.npm/_npx/<hash>`. The cache stayed half-written. Each of the next 131
`npx --yes wrangler` calls stopped with `npm error code ENOTEMPTY` before
wrangler started, and npm does not repair that state. The jobs worker did not
deploy for about two days. `bin/harness-sync.sh` alerted
`schema.sql statement 1/23 failed against D1`, but no statement reached D1. The
`deploy FAILED` alert was held by its repeat window on a folded `--id`, so it
did not page again.

## What changed

1. New lib `bin/lib/wrangler-run.sh`. `wrangler_run [--spec <s>] <timeout> <args>`
   is the one way the hub runs wrangler for the worker deploy, the D1 apply and
   the console Pages deploy.
   - `wrangler_tool_code` reads a TOOL FAILURE: an `npm error code E…` or
     `npm ERR! code E…` line, and no wrangler start banner. An npm line after
     the banner is not a tool failure.
   - On a tool failure the helper moves the npx cache directory aside to
     `<dir>.aside-<epoch>` and runs the command ONE more time. The directory is
     the `…/_npx/<hash>` the npm output names, else `<cache>/_npx`. One aside
     copy is kept.
   - If the retry passes: rc 0 and one `wrangler-run: npx cache healed` line.
     If it fails as a tool again: rc 87, and the code goes to
     `state/wrangler-tool-error`. Any other failure returns wrangler's rc with
     no retry, so a SQL statement or a deploy is never sent twice.
2. Pinned install, outside the deploy step. `hs_step wrangler-install plain`
   runs before `worker-phase`. It takes `flock -n locks/wrangler-install.lock`,
   installs the knob spec into `state/wrangler-npx/.stage.<pid>`, verifies the
   wrangler `package.json`, renames the stage to `v<ver>-<epoch>` and swaps
   `state/wrangler-npx/current` atomically. A kill leaves only a stage dir; the
   next run deletes it. `wrangler_run` then uses `wrangler@<ver>` on that
   cache. If no verified install exists, `wrangler_run` uses the shared cache
   with the self-heal. Retention: `current` and the previous version dir stay;
   older version dirs and stage dirs are deleted on each install run.
3. Alert text. A tool failure in the schema apply writes
   `worker/<w> wrangler could not start: <code> — no SQL reached D1 <db>`
   through `deploy_fail_note` stage `wrangler-tool`, never
   `statement N/M failed against D1`. The batch path does not re-run the chunk
   one statement at a time on rc 87. A deploy rc 87 writes
   `wrangler could not start: <code> — deploy of <w> SKIPPED, LIVE WORKER IS STALE`.
   A real SQL error keeps the statement alert. Only a good deploy clears the
   `wrangler-tool` state.
4. Stale page. `worker_stale_page` runs from `deploy_fail_note` and from the
   statement-alert branch. When `state/worker-deployed-<w>` is at least
   `HARNESS_SYNC_WORKER_STALE_PAGE_S` old, it writes one alert with an id per
   page (`worker-stale-<w>-<host>-<now>`), so it is a new row and pages. It
   pages again at most once per that window (`state/worker-stale-paged/<w>`).
   A good deploy removes the stamp.
5. `bin/console-pages-deploy.sh` runs `wrangler_run --spec wrangler@3 600 pages deploy …`.
   The npx argv is unchanged. rc 87 alerts `wrangler could not start: <code>`.

## Knobs (catalog/lanes.d/fleet-propagate.knobs.d/)

| Knob | Default | Meaning |
|---|---|---|
| `HARNESS_SYNC_WRANGLER_SPEC` | `wrangler` | npx spec the pinned install resolves and freezes |
| `HARNESS_SYNC_WORKER_STALE_PAGE_S` | 21600 | stale-page window; 0 = off |
| `HARNESS_SYNC_WRANGLER_INSTALL_RETRY_S` | 3600 | wait after a failed pinned install before the next download |

## Not changed

`bin/console-postmerge-qa.sh` and `bin/lib/console-preview.sh` set a fresh
per-tree `npm_config_cache`, so they cannot inherit a broken shared cache.
`bin/console-fly-secrets.sh` sends a secret on stdin, and a retry cannot send
it again. `bin/cf-token-scope-probe.sh` is an operator probe.

## State

- `state/wrangler-tool-error`: one npm code line (last rc 87).
- `state/wrangler-npx/current` (symlink), `v<ver>-<epoch>/.spec`, `.version`,
  `.install-failed` (`<epoch> <spec>`).
- `state/worker-wrangler-tool-failing-<w>`: the existing
  `worker-<stage>-failing-<w>` format.
- `state/worker-stale-paged/<w>`: the epoch of the last stale page.

Test: `tests/wrangler-npx-selfheal.bh-9460-test.sh`.
