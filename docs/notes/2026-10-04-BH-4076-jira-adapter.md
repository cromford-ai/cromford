# Jira Cloud adapter on the tracker contract, behind a sandbox guard (BH-4076)

Doc: tracker-adapter, tracker-jira, settings-knobs

## What changed

- New `bin/lib/tracker/jira.sh`, the third adapter of `bin/lib/tracker.sh`
  (functions `trk_jira_*`). REST v3 through the scoped-token gateway
  `https://api.atlassian.com/ex/jira/<cloudId>` only; a site URL base is
  refused. Search is `POST /rest/api/3/search/jql` with bounded JQL and
  `nextPageToken` paging (4 pages of 50, then rc 1 `list incomplete`). Comments
  are read as ADF and turned into text; comments are written as ADF built from
  text (blank lines split paragraphs, a single newline is a hardBreak, a URL
  gets a link mark). Transitions are discovered with `GET …/transitions`;
  no status name or id is in the code.
- `trk_jira_context <project>` loads the credentials from the project's own env
  file (`JIRA_BASE`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_SITE`) and the
  allowlists, label, custom-field ids and status aliases from the settings rows
  `tracker_jira.<project>.*`. A malformed row or a worker outage fails the
  context, and then every verb answers 1 before any request.
- The sandbox guard: every verb names an issue key whose project must be on the
  tier's allowlist (`write_projects`; `comment_projects` for comment/link_pr
  only; `read_projects` for reads), and every write first GETs the issue and
  refuses unless Jira answers with the same key in the same project (a moved
  issue's old key resolves to the new one).
- `jira` is a registered adapter: a `tracker_adapter.<project>` row of `jira`
  resolves. fleet.conf column 4 never yields it.
- `bin/triage-gate.sh --buildable[-strict]` reads a Jira ticket through the
  adapter when the project's env file sets `JIRA_BASE` and its row is `jira`.
  The waitingOn and triageVerdict custom fields and "our comment is newest"
  (a comment by the token's own account, or a non-public one) block it the way
  they block a board ticket. In-app dependency text is not read for Jira.
  If `/myself` fails, waitingOn and triageVerdict still block; only the
  newest-comment check is unreadable (OK under `--buildable`, `BLOCKED
  unreadable` under `--buildable-strict`).
- `file_children` on a Jira project logs `FILE_CHILDREN no child-filing lane
  for jira (<project>)` and files nothing.

## Why

Wave 3 of BH-3979. The parent's guardrail is that development and tests write
only to a sandbox, so the allowlist is enforced inside the adapter rather than
left to the caller.

## Not done here

No project uses it yet. The live sandbox run (a sandbox ticket triaged, built,
PR linked, closed out), re-recording the fixtures against a real sandbox, and
switching project-15-backstage to read real tickets are human steps; the triage and
close-out lanes do not call the contract for any tracker yet.
