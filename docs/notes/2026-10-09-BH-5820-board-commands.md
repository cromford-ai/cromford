# Console and MCP comment_issue / hold_ticket reach the hub (BH-5820)

Doc: MCP

## What was broken

- The console worker (repo `example-org/cromford-console`, `src/actions.js`
  `ACTION_TYPES`) does not list `comment_issue`, `hold_ticket` or
  `unhold_ticket`. It answers `400 {"error":"unknown action"}` before it
  inserts a row. So the console HOLD / UNHOLD button and the MCP
  `comment_issue` tool queued nothing.
- `bin/poll-commands.sh` had no `comment_issue` arm. A `comment_issue` row
  got `unknown command type comment_issue`.
- The MCP `hold_issue` tool sent `type:"hold_issue"`. The hub knows only
  `hold_ticket`, and it needed `ticket:'PREFIX-<n>'`.
- The MCP client dropped the console's refusal text. The user saw only
  `http_400`.

## What changed

- `console-ui/functions/api/[[path]].js` forwards every command to the worker
  first, as before. Only when the worker answers 400 `unknown action` for one
  of the three types, `console-ui/functions/_lib/board-commands.js` validates
  the body and inserts the `commands` row into `CONSOLE_DB`. The answer is
  `{ok:true, type, ckey, command_id}`, the worker's own success shape.
  - `comment_issue` ckey: `<project>:comment_issue:<issue>:<UTC minute>:<sha256(body)[0:16]>`.
    Payload `{issue, body, actor}`.
  - `hold_ticket` / `unhold_ticket` ckey: `<project>:<type>:<n>:<UTC minute>`.
    Payload `{ticket, reason, actor}` or `{issue, reason, actor}`.
  - Before it validates or writes, the proxy sends the incoming `dash` cookie
    to the worker's authed probe, `GET /api/dash/fleet`. Any answer other than
    200, no cookie, or an unreachable worker is a 403 `unauthorized` and no
    row. The worker's 400 does not prove that the worker checked the cookie
    first, so the 400 alone never permits a write. Every write is probed; there
    is no cache.
  - A bad body is a 400 that names the field. No `CONSOLE_DB` binding returns
    the worker's 400 unchanged. A failed write is a 503.
- `bin/lib/issue-comment-cmd.sh` (`icc_run`) and the `# >>> comment_issue
  handler` arm. The hub posts one comment as the GitHub App. The comment ends
  with `<!-- mc-command:<id> -->`, and a re-run that finds it posts nothing.
  No App token, a failed read or a failed POST is rc 1 (retry). A project that
  is not a GitHub-issues board, a bad issue, a blank or over-20000-character
  body, or a pull request is a refusal (rc 3).
- `bin/lib/ticket-hold-cmd.sh` takes `issue:<n>` when `ticket` is absent or
  null. A `ticket` string is matched as before.
- `mcp/tools/actions.mjs`: `hold_issue` sends `type:"hold_ticket"`.
  `mcp/lib/console.mjs`: a 4xx other than 401/403/404 with a string `error`
  returns `http_<status>: <error>`, redacted and cut to 200 characters.
- `console-ui/src/lib/commands.js`: a `comment_issue` row on
  /history/commands links to `/p/<project>`.

## Still open

- A request sent straight to the worker host, not the Pages origin, still gets
  the worker's 400 until the worker lists the three types.
- `file_issue` has the same gap in the worker. It is not in this change.
- Nobody observed the live refusal in this build. The box had no dash cookie.
  The diagnosis comes from the source. Run the step 2 probe below after deploy.
- The harness-console ticket for the worker change is not filed. The build box
  got a 403 on `example-org/cromford-console`.

## How to retire the Pages fallback

1. Add `comment_issue`, `hold_ticket` and `unhold_ticket` to the worker's
   `ACTION_TYPES`, with the payloads and ckeys above.
2. POST `{type:"hold_ticket", project:"bh5820-probe", ticket:"BH-1"}` to the
   worker host. It must answer 200 with a `command_id`. The hub refuses the row
   as `refused: bh5820-probe is not a GitHub-issues board`, with no GitHub call.
3. Delete `console-ui/functions/_lib/board-commands.js`, the fallback branch in
   `console-ui/functions/api/[[path]].js` and its node suite.
