# The Cromford MCP server

`mcp/server.mjs` is a stdio MCP server with no dependencies beyond Node. It
talks to a Mission Control console you run, over the console's HTTP API, and
gives an MCP client (Claude Code, Claude Desktop, Cursor, VS Code, Windsurf)
tools to read the fleet and act on project boards.

It holds no state of its own. Every tool call is one request to the console,
sent once and never retried, except `batch_failure` (GitHub REST) and
`post_block` / `clear_block` (BH-7713), which run `gh api` and
`bin/lead-verdict.sh` on the MCP host and send nothing to the console. If the console does not serve a route, the tool
answers an error that says so (`console route not available: <path>`), never
an empty success.

## Settings

The server reads these from its environment at startup.

| Variable | Required | What it does |
|---|---|---|
| `HARNESS_CONSOLE_URL` | yes | Base URL of your console, `http` or `https`. The server exits 2 without it. |
| `HARNESS_CONSOLE_TOKEN` | no | Sent as `Authorization: Bearer <token>` on every request. |
| `HARNESS_CONSOLE_SECRET` | no | The console's `/login/<secret>` secret, which sets the `dash` cookie. Not wired yet: a secret alone sends nothing until the cookie flow lands. |
| `HARNESS_MCP_REPO_ALLOWLIST` | no | Comma-separated `owner/name` repos the guarded tools may touch. Empty means the guarded tools always refuse. |
| `HARNESS_MCP_GITHUB_TOKEN` | no | GitHub token for `batch_failure`, sent only to the GitHub API. Without it `batch_failure` answers `github_auth_not_configured` and sends nothing. Scrubbed from every result. |
| `HARNESS_MCP_GITHUB_URL` | no | GitHub API origin for `batch_failure` (default `https://api.github.com`; GitHub Enterprise or a test stub). |
| `HARNESS_MCP_GITHUB_RAW_CAP` | no | Bytes of a job log `batch_failure` keeps, from the end (default 8388608, 8 MiB). A longer log is `log_truncated` and named in `partial`. |
| `HARNESS_MCP_BATCH_PAGE_CAP` | no | Pages of 100 `batch_failure` reads per list: check runs, PR files, timeline (default 3). |
| `HARNESS_MCP_BATCH_CANDIDATE_CAP` | no | Mergify cross-references `batch_failure` reads from a PR timeline to find its draft (default 5). |
| `HARNESS_MCP_BATCH_LOG_CAP` | no | Failed job logs `batch_failure` reads per call (default 10). A check past the cap is `not_read_cap` and leaves every PR `culprit: null`. |
| `HARNESS_MCP_BATCH_LINE_CAP` | no | Failure lines `batch_failure` returns per failed check (default 40). |
| `HARNESS_MCP_BATCH_LINE_LEN` | no | Characters kept per failure line (default 500). |
| `HARNESS_MCP_GH_TIMEOUT_MS` | no | Milliseconds one `gh api` call from `post_block` / `clear_block` may run (default 60000). |
| `HARNESS_MCP_LV_TIMEOUT_MS` | no | Milliseconds one `bin/lead-verdict.sh` run from `post_block` / `clear_block` may run (default 90000). |
| `HARNESS_MCP_TEXT_CAP` | no | Characters of `gh` or `bin/lead-verdict.sh` output kept in a `post_block` / `clear_block` part (default 300). |

A cap knob that is unset, empty or not a positive integer uses its default.

With no token and no secret, every tool answers `console_auth_not_configured`
and nothing is sent. The token and secret are scrubbed from every result and
every log line.

## Wiring it into a client

Each snippet runs the same command. Replace the path with where your checkout
lives and the URL with your console.

### Claude Code

```bash
claude mcp add cromford \
  -e HARNESS_CONSOLE_URL=https://console.example.com \
  -e HARNESS_CONSOLE_TOKEN=... \
  -- node /path/to/cromford/mcp/server.mjs
```

### Claude Desktop

In `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cromford": {
      "command": "node",
      "args": ["/path/to/cromford/mcp/server.mjs"],
      "env": {
        "HARNESS_CONSOLE_URL": "https://console.example.com",
        "HARNESS_CONSOLE_TOKEN": "..."
      }
    }
  }
}
```

### Cursor

In `.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (global):

```json
{
  "mcpServers": {
    "cromford": {
      "command": "node",
      "args": ["/path/to/cromford/mcp/server.mjs"],
      "env": {
        "HARNESS_CONSOLE_URL": "https://console.example.com",
        "HARNESS_CONSOLE_TOKEN": "..."
      }
    }
  }
}
```

### VS Code

In `.vscode/mcp.json`:

```json
{
  "servers": {
    "cromford": {
      "type": "stdio",
      "command": "node",
      "args": ["/path/to/cromford/mcp/server.mjs"],
      "env": {
        "HARNESS_CONSOLE_URL": "https://console.example.com",
        "HARNESS_CONSOLE_TOKEN": "..."
      }
    }
  }
}
```

### Windsurf

In `~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "cromford": {
      "command": "node",
      "args": ["/path/to/cromford/mcp/server.mjs"],
      "env": {
        "HARNESS_CONSOLE_URL": "https://console.example.com",
        "HARNESS_CONSOLE_TOKEN": "..."
      }
    }
  }
}
```

## Tools

Every argument is checked against the tool's whole input schema before anything
is sent: an unknown key, a missing required field, a wrong type, an empty or
over-long string, an out-of-range number or a value outside an `enum` is refused
with `invalid_arguments: <path>` and no request reaches the console. Path segments are URI-encoded. Optional arguments become query
parameters only when given.

| Tool | Kind | Console route |
|---|---|---|
| `fleet_status` | read | `GET /api/dash/fleet` |
| `project_status` | read | `GET /api/dash/p/<project>` |
| `builds` | read | `GET /api/dash/builds?limit=` (unconfirmed: the console UI only reads `builds/<id>`) |
| `pipeline` | read | `GET /api/dash/kanban/pipeline?project=&shipped_limit=` (`limit` is sent as `shipped_limit`) |
| `prs` | read | `GET /api/dash/prs/<filter.project>?limit=&state=` (refused with `project_required` when `filter.project` is missing; `state` unconfirmed) |
| `alerts` | read | `GET /api/dash/alerts?limit=&project=&severity=` (unconfirmed) |
| `costs` | read | `GET /api/dash/costs?limit=&project=&since=` (query parameters unconfirmed) |
| `machines` | read | `GET /api/dash/machines` |
| `logs` | read | `GET /api/dash/logs/<project>?lines=` (unconfirmed: the console UI keys this route on a command id, not a project) |
| `chat` | read | `POST /api/dash/chat` with `{text}`, plus `target` when `project` is given. It posts a message; the reply arrives in the console's chat thread. It spends console-side model time. |
| `merge_queue` | read | `GET /api/coord/merge-queue/live?project=` (see [Merge-queue tools](#merge-queue-tools)) |
| `pr_stage` | read | `GET /api/coord/merge-queue/live`, then `GET /api/coord/pr-state-events?repo=&number=&limit=50` and `GET /api/coord/risk-tiers?repo=&pr=&limit=1` |
| `backlog` | read | `GET /api/coord/merge-queue/live?project=` and `GET /api/coord/jobs?project=&kind=build&status=running&limit=200` |
| `batch_failure` | read | GitHub REST, GET only, through `mcp/lib/github.mjs`: the batch draft PR, its check runs and failed job logs, and each member and ahead PR with its files, head checks and verdict check. Needs `HARNESS_MCP_GITHUB_TOKEN`. A culprit is a likely culprit: a log line that names a file the PR changed. A match is not proof, and `requeue_candidates` is advice only. A `pending` or `passed` batch has no candidates. |
| `file_issue` | write | `POST /api/dash/action` `{type:"file_issue", ...args}` |
| `comment_issue` | write | `POST /api/dash/action` `{type:"comment_issue", ...args}`. The hub posts one comment on the issue as the GitHub App, once per command id (`bin/lib/issue-comment-cmd.sh`). |
| `hold_issue` | write | `POST /api/dash/action` `{type:"hold_ticket", project, issue, reason}`. The hub adds the `hold` label (`bin/lib/ticket-hold-cmd.sh`). |
| `run_triage` | write | `POST /api/dash/action` `{type:"run_triage", ...args}` |
| `pause_board` | write | `POST /api/dash/action` `{type:"pause_board", ...args}` |
| `resume_board` | write | `POST /api/dash/action` `{type:"resume_board", ...args}` |
| `fetch_artifact` | write | `POST /api/dash/action` `{type:"fetch_artifact", ...args}` |
| `merge_pr` | guarded | `POST /api/dash/action` `{type:"merge_pr", ...args}`. Sent only when `confirm` is the boolean `true` (`"true"` and `1` refuse with `confirm_required`) and `repo`, trimmed and lowercased, is exactly on `HARNESS_MCP_REPO_ALLOWLIST` (else `repo_not_allowlisted`). A refusal sends nothing. (Unconfirmed: this repo has no console code that maps `{repo, pr}` to a merge.) |
| `set_automerge` | guarded | `POST /api/dash/action` `{type:"set_automerge", ...args}`. Same two conditions as `merge_pr`. (Unconfirmed, same reason.) |

"Unconfirmed" means this repo has no code that proves the console serves that
route or parameter. The tool still sends the request, and a console that
lacks the route gets you `console route not available`.

A console refusal shows its reason. A 4xx other than 401, 403 and 404 whose
body has a string `error` returns `http_<status>: <error>`, redacted and cut
to 200 characters, for example `http_400: unknown action`. Every other failure
is the bare `http_<status>`. The console worker does not list
`comment_issue` and `hold_ticket` in its own action types yet. The console
Pages origin queues them itself (BH-5820), so set `HARNESS_CONSOLE_URL` to the
Pages origin. The Pages origin queues a row only when the session's `dash`
cookie passes the worker's authed probe; otherwise it answers 403
`unauthorized`. A URL that points at the worker host directly gets
`http_400: unknown action` for both tools until the worker accepts them.

## Merge-queue tools

`mcp/tools/merge-queue.mjs` holds three read tools. They read console routes
only. They never run `gh` and never call a GitHub host.

- `merge_queue({project?})` returns `{as_of, complete, batches, waiting}`. Each
  batch carries `repo`, `draft`, `url`, `members`, `stage`, `checks`
  (`{done, total}`), `checks_text` (`"10/14"`), `progress`, `eta_s`,
  `eta_basis`, `failing`, `bisect` and `outcome`. `waiting` is in `position`
  order; an entry with no position is last.
- `pr_stage({repo, pr})` returns the PR's `queue_stage` (`{stage, batch, at}`
  from the live payload's `prs`), its `lead_stage` (the newest lead/CI row of
  the PR event log), `stages` (every event row, oldest first, with `since` and
  `at`), `blocked_on`, and `risk_tier`. `blocked_on` is the detail in the queue
  stage (`dequeued(Jobs worker failed alone)` gives `Jobs worker failed alone`;
  `dequeued (…)` with a space works the same). If the queue stage has no detail,
  it is the reason of a `lead_block`, `ci_red` or `approved_not_queued` row
  that is newer than the queue stage. The repo matches case-insensitively.
- `backlog({project, since?})` returns `counts` per stage word over the live
  payload's `prs`, `changed` (the PRs whose stage time is after `since`, oldest
  first) and `builds` (the running build jobs, grouped `planning` (stage
  `plan`), `building` (`execute`, `review`) and `queued` (`merge`)). `since`
  must be a date `Date.parse` reads, else the call answers
  `invalid_arguments: since` and sends nothing. Without `since`, `changed` is
  left out.

A field the console answers as null stays null; the tools never invent an ETA,
a progress value or a count. A stage that no PR is in is absent from `counts`,
not 0. The live read is required: if it fails, the tool fails. A body with no
`batches` array answers `bad_payload: /api/coord/merge-queue/live`, never an
empty queue. A failed event-log, risk-tier or jobs read sets that field to
null and names the route in `partial`. `complete: false` from the console is
passed through, and a full page sets `stages_complete` or `builds_complete` to
false.

The `/api/coord/*` routes accept the console's `dash` cookie only, so these
tools need `HARNESS_CONSOLE_SECRET`. With a token alone the console answers 403,
and the tool returns `http_403`. A console that does not serve the live route
gets you `console route not available: /api/coord/merge-queue/live`.

## Where the code lives

This repository's `mcp/` directory is the source of truth. The console
repository's own `mcp/` copy is to become a copy generated from this one;
until that switch is made it is unchanged and keeps working as it does today.

## Tests

```bash
HARNESS_TEST_SANDBOX=1 bash tests/mcp-server.bh-5223-test.sh   # the server, protocol and fleet_status
HARNESS_TEST_SANDBOX=1 bash tests/mcp-tools.bh-5218-test.sh    # the read and action tools above
HARNESS_TEST_SANDBOX=1 bash tests/mcp-guarded.bh-5225-test.sh  # the guarded tools and the generic defaults
HARNESS_TEST_SANDBOX=1 bash tests/mcp-merge-queue.bh-5671-test.sh  # the merge-queue tools
```

The first three spawn the real `node mcp/server.mjs` against a stub console.
The merge-queue suite loads the real tool registry in process and calls the
tools through the real console client against the same stub.
