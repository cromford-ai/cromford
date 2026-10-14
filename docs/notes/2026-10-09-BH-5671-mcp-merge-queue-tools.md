# The MCP server reads the merge queue: merge_queue, pr_stage, backlog (BH-5671)

Doc: MCP

## What changed

`mcp/tools/merge-queue.mjs` adds three `kind: 'read'` tools. The registry
loads the file by itself; no shared list changed.

- `merge_queue({project?})` reads `GET /api/coord/merge-queue/live` and returns
  the batches (members, checks as `10/14`, progress, ETA, failing check,
  bisect step) and the waiting line in position order.
- `pr_stage({repo, pr})` adds the PR event log and its risk tier to the live
  payload's `prs` entry: the queue stage, the lead/CI stage, every stage with
  its timestamps, what blocks it, and the tier.
- `backlog({project, since?})` returns counts per stage, the PRs that changed
  stage after `since`, and the running build tickets grouped
  planning/building/queued.

The tools read console routes only. They never run `gh` and never call a
GitHub host. A null field stays null. A failed optional read is named in
`partial`. The `/api/coord/*` routes need the `dash` cookie, so the tools need
`HARNESS_CONSOLE_SECRET`; a token alone gets `http_403`.

## Why

BH-5008 gives the merge queue one live payload. These tools let an MCP client
ask the same questions the console screen answers, without a GitHub call.

Tests: `tests/mcp-merge-queue.bh-5671-test.sh`.
