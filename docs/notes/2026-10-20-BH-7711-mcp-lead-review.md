# The MCP server shows, requests and resets lead reviews (BH-7711)

Doc: MCP

## What changed

`mcp/tools/lead-review.mjs` adds three tools. The registry loads the file by
itself; no shared tool file changed.

- `lead_review_show({repo, pr})` (read) sends two GETs in parallel:
  `/api/coord/verdicts?repo=&pr=` and `/api/coord/lead-reviews?repo=&pr=&limit=100`.
  It returns the verdict rows newest first, the request rows newest first, and
  the `- [BLOCK ...]` and `- [NOTE ...]` findings of the lead report. The report
  is the job's `lead_review_report` artifact. When the artifact was cut at the
  worker's 4000-unit cap, the report is the job's newest `lead_report`
  transcript. The job is the one the newest verdict note names as
  `lead-job:<job>`, else the newest `done` request's job. A report counts only
  when its title names this repo, pr and head. No report gives `report: null`
  and a `report_missing` reason that names the box and the `report_ref` path.
  A failed read is named in `partial`. A full page sets `*_complete: false`.
- `lead_review_request({repo, pr, head_sha, notes?, priority?, confirm})`
  (guarded) sends one `POST /api/coord/lead-reviews`, the ask
  `bin/lead-verdict.sh request` makes. The sha is used as given. A 2xx whose
  row does not carry the asked priority is the error
  `priority_not_stored: request <id> is <status>`.
- `lead_review_reset({request_id, confirm})` (guarded) sends one
  `POST /api/coord/lead-reviews/<id>/reset`, the ask `bin/lead-verdict.sh reset`
  makes.

A guarded tool checks `confirm` first. Anything but the boolean `true` is
`confirm_required`, and nothing is sent.

The console coord proxy gets two write rows in
`console-ui/functions/_lib/coord-writes.d/7711-lead-reviews.js`. Both carry the
Pages `LEAD_VERDICT_TOKEN`. The request row stamps `requested_by` as
`console:<actor>` and forwards only repo, pr, head_sha, scope_notes and
priority. It rewrites `review-tier:` and `review-mode:` in scope_notes to `=`,
as `lv_request` does. Every other lead-reviews write stays 405 from the console.

The jobs worker gets two changes in `worker/jobs/src/routes/lead-reviews.js`:

- `GET /api/lead-reviews` takes an optional `pr` (it needs `repo`). The
  statement is `LR_LIST_PR_SQL`. The UNIQUE(repo, pr, head_sha) autoindex
  serves it (EXPLAIN on 5000 rows in the test). Without `pr` the answer does
  not change.
- `POST /api/lead-reviews/:id/reset` reclaims a `running` request whose
  `COALESCE(heartbeat_at, updated_at)` is older than the settings row
  `lead_review_claim_stale_s` (fallback 900 s). The row goes back to
  `requested` in one compare-and-set pinned to the job and the beat the route
  read. The answer has `reclaimed_from` and `stale_s`. A running request with
  a fresher beat is still 409. `stale_reclaims` does not change. The old job's
  `/result` and `/heartbeat` answer 409, because `job_id` is now NULL.
  `bin/lead-verdict.sh reset` gets the same behavior through the same route.

## Why

A box restart left a request `running` after its report was written, and
reset refused it. Reading the findings needed ssh to the box. These tools do
both from an MCP client.

## Deploy order

- The console Pages project must deploy the new fragment. Until then the
  request and reset tools answer `http_405`.
- The jobs worker must deploy the route change. Until then the worker ignores
  `pr` and answers the repo's first 100 requests. The show tool drops the rows
  of other PRs, so it can miss this PR's rows. A stale running request is
  still 409.
- The `/api/coord/*` routes need the `dash` cookie, so the tools need
  `HARNESS_CONSOLE_SECRET`.

Tests: `tests/mcp-lead-review.bh-7711-test.sh`.
