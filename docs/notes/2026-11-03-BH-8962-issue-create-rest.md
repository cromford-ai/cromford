# BH-8962: issues are filed over REST, not `gh issue create` (slice C0)

Doc: GH-REST

## What changed
- New helper `gh_issue_create <owner/repo> <title> <body-file> [labels...]` in
  `bin/lib/tracker/gh-issue-create.sh`. It runs
  `gh api -X POST repos/<repo>/issues -f title=<t> -F body=@<file> -f labels[]=<l> ...`.
- rc 0: the `.html_url` is on stdout, and `GH_ISSUE_NUMBER` and `GH_ISSUE_URL` are set
  from the JSON `.number` and `.html_url`. No caller parses URL text any more.
- rc 1: one line on stderr (the API `.message`, else gh's first stderr line), and both
  globals are empty. A response with no positive `.number` or no `.html_url` is rc 1.
- `GH_ISSUE_CREATE_TIMEOUT_S` (opt-in, unset = no bound) runs the call under `timeout`.
  `bin/lib/post-merge-verify.sh` sets it to its existing 60.
- The 5 live callers use the helper: `fc_file_issues` (`bin/lib/fc-issues.sh`, decompose,
  rollout and slice children), `bin/load-project.sh` (the verification-map and
  agent-architecture tickets), `bin/up10-lane.sh` and `pmv_act`
  (`bin/lib/post-merge-verify.sh`). Without the helper each one fails closed. None falls
  back to `gh issue create`.
- The `$GHLOG` lines and the `DRYRUN gh issue create ...` lines keep their bytes.
- The helper runs on the identity its caller armed (`raw-by-design`, registry entry
  `tests/gh-app-ratchet-by-design/lib/tracker/gh-issue-create.sh.txt`).
- REST creates a label that does not exist. `gh issue create` refused it. All 5 callers
  use labels that exist (`ai-build`, `infra`, labels inherited from the parent).
- Test fakes: `gh_cli_rest_create` in `tests/lib/gh-cli-rest-adapter.sh` answers the REST
  create from a stub's own `issue create` arm (also through `gh_cli_rest ... post`).

## Why
`gh issue create` uses GraphQL. Fleet accounts hit the GraphQL rate limit, and the call
stopped mid-run. A REST create costs 1 core call.

## Not in this slice
The MCP `file_issue` hub path (slice C1 of #8962).

## Verify
`HARNESS_TEST_SANDBOX=1 bash tests/gh-issue-create.bh-8962-test.sh`. Case B1 fails on any
live `gh issue create` in `bin/` or `worker/`.
