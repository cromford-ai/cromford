# The MCP server says why a merge-queue batch failed: batch_failure (BH-7714)

Doc: MCP

## What changed

`mcp/tools/batch-failure.mjs` adds one `kind: 'read'` tool,
`batch_failure({repo, pr?, draft?, verdict_check?})`. Give exactly one of
`draft` (the Mergify batch draft PR) or `pr` (a PR the batch ejected or held).
The tool returns:

- the draft, its members (the `pull_requests:` numbers in the Mergify metadata
  YAML), the PRs queued ahead of it and its head sha;
- each failed check (latest run per name) with up to 40 failure lines from
  its job log, with ANSI codes and timestamps removed;
- per failed check, the member or ahead PRs whose changed files those lines
  name (`culprits`);
- per PR: state, head CI, the `lead-verdict` conclusion on its head, and
  `culprit` true / false / null;
- `requeue_candidates`: open PRs with `culprit: false`, green head CI and a
  `success` verdict;
- `dead_shards: true` and `note: "dead shards, re-queue all"` when every
  failed check was cancelled or timed out. Then every open PR is a candidate.

`culprit: false` needs a complete file list, the draft's complete check list
AND every failed check's lines.
An unread or capped read gives `culprit: null`, names the read in `partial`
and sets `complete: false`. Such a PR is never a candidate.

## Why

On 2026-10-20 one PR broke a batch, and Mergify ejected four innocent PRs
with no failing check named. A session found the culprit by reading the job
log and the file lists by hand.

## Settings (MCP client only)

| Variable | Default | Use |
|---|---|---|
| `HARNESS_MCP_GITHUB_TOKEN` | unset | A GitHub token with read access to the repo. Unset: the tool refuses with `github_auth_not_configured` and sends nothing. |
| `HARNESS_MCP_GITHUB_URL` | `https://api.github.com` | The GitHub API origin (GitHub Enterprise). |

The console has no route for job logs, PR file lists or head check runs. So
this tool reads GitHub REST through one seam, `mcp/lib/github.mjs`. It sends
GET requests only, follows the job-log redirect once without the token, and
returns error codes only. The reply removes the token before it is sent.

Test: `tests/mcp-batch-failure.bh-7714-test.sh` (wraps
`mcp/test/batch-failure.test.mjs`, a loopback GitHub stub, 0 calls off it).
