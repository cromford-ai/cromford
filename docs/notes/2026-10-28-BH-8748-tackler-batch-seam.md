# BH-8748: the Tackler reads red merge batches again

Ticket: BH-8748.
Doc: MCP

## What changed

- `bin/harness-sync.sh` copies `mcp/` to the live tree on every sync, before
  `bin/`. It uses `--delete` and keeps `mcp/node_modules/`.
- `ubq_batch_failure` (`bin/lib/unblock/collectors/queue.sh`) sets the seam
  env for the node call only. `HARNESS_CONSOLE_URL` comes from `CONSOLE_URL`.
  `HARNESS_MCP_GITHUB_TOKEN` comes from `bin/gh-token.sh --read <repo>`, minted
  per call, so any repo works. An operator-set value wins.
- node's stderr is no longer dropped. The shim writes one `ubq-reason: <code>`
  line. The `queue-unreadable` record carries it as `reason`, and the fallback
  card WHAT line ends `Reason: <code>.`
- A lane-wide seam defect (`tool-missing`, `module-missing`, `node-missing`,
  `console-url-missing`, `github-token-missing`, `no-harness-root`) is one
  record per repo per tick with `lane_defect: true` and the unread `drafts`.
  The tick (`bin/lib/unblock/seam-defect.sh`, `ubs_fold`) turns it into one
  ALERT per project and reason per `UNBLOCK_SEAM_ALERT_WINDOW_H` (default 24)
  and no card. The tick line adds `seam_defect=<n>`.

## Why

The hub had no `mcp/tools/batch-failure.mjs`. Every red-batch draft became
its own `queue-unreadable` card with no cause: 99 cards since
2026-10-27 01:44Z for one missing file.

## Owed after deploy

1. Check `ls /root/harness/mcp/tools/batch-failure.mjs`.
2. Remove `/etc/cron.d/mcp-env-refresh` and the `#MCP-ENV-2026-10-28` lines in
   the hub `global.env`.
3. Answer `hold` on the open `queue-unreadable` batch_failure cards, or let
   them expire (`UNBLOCK_CARD_TTL_H`, 72 h).

## Tests

`tests/unblock-seam-defect.bh-8748-test.sh` (S1-S8, F1-F5, B1) and
`tests/harness-sync-mcp.bh-8748-test.sh` (M1-M3).
