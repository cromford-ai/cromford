# BH-9014: the MCP `file_issue` files a real issue

Doc: CONSOLE

Part of #8962 (slice C1). C0 (#9011) shipped the REST helper `gh_issue_create`.

## What changed

1. Pages. `file_issue` is in `BOARD_FALLBACK_TYPES`
   (`console-ui/functions/_lib/board-commands.js`). When the console worker
   answers `400 unknown action`, the proxy probes the credentials first, then
   `boardCommand` validates the body and queues the `commands` row.
   - Title: a string, trimmed, 1-256 characters (`ISSUE_TITLE_MAX`, GitHub's
     own limit). Body: a string of at most 20000 characters, absent = `""`.
   - ckey: `<project>:file_issue:<UTC minute>:<sha256(title+"\n"+body)[0:16]>`.
   - payload: `{title, body, actor}`.
2. Hub. `bin/poll-commands.sh` has a `# >>> file_issue handler` arm. It runs
   `ifcmd_run` from `bin/lib/tracker/issue-file-cmd.sh`.
3. `console-ui/src/lib/commands.js`: `file_issue` is in `BOARD`, so its row on
   `/history/commands` links to `/p/<project>` ("<project> board"), as
   `comment_issue` does.
4. `mcp/tools/actions.mjs` did not change.

## The hub rules (`ifcmd_run`)

- App token only. No `ghs_` token: rc 1, nothing filed.
- GitHub-issues boards only (fleet.conf board_prefix `-`). Any other project:
  rc 3 `refused:`. A fleet.conf read that fails: rc 1.
- Exactly once per command id. The issue body ends with
  `<!-- mc-command:<id> -->`. Before it files, the lib reads one page of the
  newest issues (`state=all&sort=created&direction=desc`). A non-PR issue whose
  body holds the marker: rc 0 `issue already filed: <url>`. A failed read: rc 1,
  nothing filed.
- Page size: the `poll-commands` lane knob `FILE_ISSUE_LOOKBACK`
  (`catalog/lanes.d/poll-commands.knobs.d/FILE_ISSUE_LOOKBACK.json`, default
  100, 1-100). `lane_env_apply poll-commands` puts its settings row into the
  env. Code fallback 100; any other value is 100. If more issues than that are filed between a first try and
  its retry, the retry files a duplicate. A retry comes within one lease window.
- The create is `gh_issue_create` (REST), with no labels. GitHub's
  `Validation Failed` is rc 3. Any other create failure is rc 1.
- Result on success: `filed #<n> <url> as the App (command <id>, actor <a>)`.
  It shows on `/history/commands?id=<N>`.

## Not verified here

A live MCP `file_issue` against prod. This box has no console token and no
prod D1. To check: run MCP `file_issue {project:<GitHub-issues project>, title,
body}`, read `/history/commands?id=<N>`, and open the URL in the result.
