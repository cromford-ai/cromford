# The MCP server reads a ticket's live status: ticket_status and stuck_tickets (BH-8973, slice C0)

Doc: MCP

## Why

A planner session that asked "where is ticket X" read the kanban pipeline
snapshot, or grepped hub logs. The snapshot lags, and it does not say which
machine runs a build, what the ticket waits on, or why the last attempt
stopped. This slice reads the hub's own D1 rows at call time.

## What changed

1. **Worker routes** `worker/jobs/src/routes/ticket-status.js` (fragment
   `worker/jobs/test/route-table.d/bh-8973-ticket-status.txt`), bearer-gated,
   read-only:
   - `GET /api/ticket-status?project=<p>|repo=<owner/name>&key=<K>...&issue=<n>...`
     (format `ticket-status v1`): `{format, project, repo, fresh_at, tickets, unknown}`.
     A key is trimmed and upper-cased. An issue resolves through
     `build_queue.ticket_id`; an issue with no row is in `unknown`. A repo
     resolves through `projects`: no row is 404 `unknown_repo`, two rows are
     409 `ambiguous_repo`. More tickets than `ticket_status.batch_max` is 400
     `too_many`.
   - `GET /api/ticket-status/stuck?project=|repo=`: the `queued` or `claimed`
     queue rows (oldest enqueued first, at most `ticket_status.stuck_scan_limit`,
     `truncated` when there are more) whose `last_activity_at` is older than
     `ticket_status.stuck_min` minutes, oldest activity first.
2. **The reads.** One loader serves both routes. Round 1 is ONE `env.DB.batch`
   of 10 set-based statements (11 with the project's repo) over `json_each` of
   all keys: `build_queue`, `pool_holds`, `pool_markers`, `pool_spawns`,
   `pool_terminals`, `jobs` (kind build or fix), `ticket_events`,
   `ticket_edges`, `pr_records`, `ledgers` kind `br_attempt`. Round 2 is ONE
   batch of at most 3 statements: the newest job's heartbeat and last stage
   event, and the blockers' own queue rows. A warm call runs at most 15
   statements (`/stuck` 16), for 1 ticket or 20. A D1 error is a 503, never
   a partial `not_known`.
3. **Two indexes** (`worker/jobs/src/lib/core.d/bh-8973-ticket-status.js`,
   applied by `ensureColumns`): `idx_build_queue_project_ticket_id` (an issue
   to its key, and the blocker rows) and `idx_pr_records_repo_head` (a
   ticket's PRs by branch). Test S8 runs `EXPLAIN QUERY PLAN` on every
   statement at 10 000 queue rows, 50 000 jobs, 20 000 PRs and 200 000
   events. No new table, so no retention rule.
4. **Knobs** (settings rows, `worker/jobs/schema.d/202611110521-bh-8973-ticket-status.sql`):
   `ticket_status.stuck_min` 90, `ticket_status.batch_max` 20,
   `ticket_status.attempts_limit` 20, `ticket_status.stuck_scan_limit` 200.
   The MCP side has the env knob `HARNESS_MCP_TICKET_STATUS_COMMIT_READS`
   (default 20).
5. **MCP tools** `ticket_status {repo|project, tickets:[{key}|{issue}]}` and
   `stuck_tickets {repo|project}` in `mcp/tools/ticket-status.mjs`. Each sends
   one console GET to `/api/coord/ticket-status[/stuck]`. Then each reads the
   last commit time of every ticket branch through `mcp/lib/github.mjs`, in
   parallel, capped by the env knob: `last_commit_at` plus `commit_source`
   (`github`, `github_auth_not_configured`, `no_branch`, `no_repo`,
   `skipped_cap` or `github_error:<code>`).

## The state of a ticket (first match wins)

| State | Rule |
|---|---|
| `merged` | a PR on `ticket/<key>` or `ticket/<key>-*` with `merged_at` (or state `merged`), or phase `merged` |
| `abandoned` | phase `abandoned`, or a `pool_terminals` row with `cleared_at` NULL |
| `running` | the newest build or fix job is `running`; `stage` is the job stage, or `fix-and-recheck` for a fix job |
| `in_resolver` | the newest `br_attempt` row is newer than the newest job's `updated_at`; `rung` is the row's status |
| `spawning` | the queue row is `claimed` and no job runs |
| `held` | the queue row is `queued`, and a ticket hold, a live sibling hold or a project spawn hold with `until_at` in the future exists |
| `queued` | the queue row is `queued` |
| `pr_open` | an open PR |
| `not_known` | no queue row and no job |
| `stopped` | anything else: the row is done or failed with no open PR |

A sibling hold is live while the `after-since` marker exists and no
`after-released` marker is newer. `bin/fly-pool.sh` `pool_after_gate` clears
`after-since` on release but keeps `after-released` for 24 h, so a later hold
has both markers. `waits_on` lists the blockers (`ticket_edges`, each with the
blocker's queue phase or status), the sibling hold, the ticket hold, the spawn
hold, the lead verdict and merge queue state of an open PR, and a running fix
round. `last_activity_at` is the newest of the queue row's `updated_at` and
`phase_at`, the newest job's `updated_at`, its heartbeat and last stage event,
the newest spawn and the newest marker.

## Assumptions

- `in_resolver` reads `br_attempt` rows keyed `<project>/<project>-<ticket key>#...`.
  That is `bra_key(<project>, br_cap_key(<project>, rkey, <ticket key>))`, the
  key the resolver writes (`bin/lib/br/record.sh`). The test fixture builds the
  key with those shell helpers. A resolver record keyed on a PR number is not matched.
- `in_resolver` comes before `spawning`, `held` and `queued` on purpose. After a
  resolver `rebuild` rung enqueues a fresh queue row, the ticket reads
  `in_resolver` until a new job starts, because the resolver is the actor that
  moves it.
- `stuck_tickets` does not filter on the `ai-build` label. D1 holds no labels.
  A `build_queue` row exists only for a labelled, enqueued ticket, so the
  `queued`/`claimed` rows are the same set.
- The outcome code is the first word of `jobs.meta.result`; a job with no
  result shows `outcome: null`.
- `stuck_tickets` reads only `queued` and `claimed` rows. PR-open and in-queue
  tickets stay with `GET /api/lifecycle/stuck` (BH-8731).

## Still owed (C1, stays on #8973)

Item 3 of the ticket: one status comment per ticket on the issue, edited in
place at each state change. Its natural hook is the lifecycle transition
writer (BH-8733, open PR #8910).

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/mcp-ticket-status.bh-8973-test.sh` runs
`worker/jobs/test/ticket-status.bh-8973.test.js` and
`mcp/test/ticket-status.bh-8973.test.mjs`.
