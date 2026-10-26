# The MCP server posts and clears a review block: post_block, clear_block (BH-7713)

Doc: MCP

## What changed

`mcp/tools/review-verdict.mjs` adds two `kind: 'guarded'` tools. The registry
loads the file by itself; no shared list changed.

- `post_block({repo, pr, head_sha, findings, confirm})` reads the PR head and
  refuses with `head_moved` (or `head_unreadable`) and 0 writes when it is not
  `head_sha`. Then it posts, in order: a PR comment with the findings, a
  `REQUEST_CHANGES` review with `commit_id: head_sha` and the findings as its
  body, and a human BLOCK row (`bin/lead-verdict.sh post <repo> <pr> <sha>
  BLOCK --source human --report-url <comment url>`). When the PR has the
  `merge-queue` label, it removes the label and posts `@mergifyio dequeue`.
- `clear_block({repo, pr, head_sha, verdict, note?, confirm})` makes the same
  head check, posts a human `MERGE` or `MERGE-WITH-NOTES` row on `head_sha`
  (`--note` when given), and then dismisses every `CHANGES_REQUESTED` review
  whose author is the `gh` login of the host (case-insensitive). It dismisses
  nothing when the row did not record with exit 0. It never touches a review
  by another person.

Each call returns `{repo, pr, head_sha, verdict, parts}` with one entry per
part (`comment`, `review`, `verdict`, `dequeue`; or `verdict`, `dismiss`) and a
status: `ok`, `skipped`, `not_needed`, `partial` (lead-verdict exit 4 or 5),
`refused` (exit 3) or `failed`. A failed part does not stop the parts after it
in `post_block`. Any `failed`, `partial` or `refused` part sets `isError`.

The comment and the review end with `<!-- review-verdict:block <sha> <fp12> -->`
(`fp12` = the first 12 hex of sha256 of the findings). A retry with the same
head and findings finds the marker and skips the comment and the review.

Both tools need `confirm: true` (the boolean) and the repo on
`HARNESS_MCP_REPO_ALLOWLIST`. Without either they send nothing.

## These two tools do not call the console

`docs/MCP.md` says each tool call is one request to the console. That is not
true for these two tools. They run on the MCP host: `gh api` as the host's
`gh` login, and `bin/lead-verdict.sh` from the checkout the server runs from
(`mcp/../bin/lead-verdict.sh`). The reason: a `--source human` row needs the
human verdict token, and that token is only on the host that runs this
server. A copy of `mcp/` without `bin/` reports the `verdict` part as
`failed: bin/lead-verdict.sh not found`. Every text a part returns is
redacted and cut to 300 characters.

## Why

A BLOCK posted only as a comment let a lead MERGE-WITH-NOTES through. A BLOCK
row alone started no fix round, because the fix-round lane reads a person's
standing CHANGES_REQUESTED review as its brief. Mergify also waits on
`#changes-requested-reviews-by=0`, so a cleared block must dismiss that
review. One call now does all the parts, or says which part failed.

Tests: `tests/mcp-review-verdict.bh-7713-test.sh`.
