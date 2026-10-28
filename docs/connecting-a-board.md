# Connecting a board

Cromford talks to every tracker through one set of verbs: list, read, comment,
transition, add and remove a label, link a PR, and close out. Each tracker has
an adapter for those verbs under `bin/lib/tracker/`, and
[bin/lib/tracker.sh](../bin/lib/tracker.sh) picks one per project.

A project uses the tracker it was enrolled with. To pick another, set the
settings row `tracker_adapter.<project>` to `github-issues`, `board`, `jira` or
`linear`. Any other value is refused. Settings rows are written with
`bin/jobs-client.sh setting-set <key> <value>`.

This page names settings and credentials only. Their values live under
`/etc/harness/env/` on the box, never in a settings file or a log.

## GitHub Issues

This is the default, and it needs nothing beyond your GitHub credential.

- **Reads:** open issues labeled `ai-build`, with their comments and labels,
  over GitHub's REST API.
- **Writes:** comments, labels, and open or closed state. Linking a PR is a
  `PR: <url>` comment, because issues have no PR-link field.
- **Credential:** the GitHub App or the token from your setup
  (`GH_APP_ID` and `GH_APP_PRIVATE_KEY_FILE`, or `GH_TOKEN`). See the
  [deployment guide](SELF-HOST.md#2-what-you-need).
- **Webhook:** the jobs worker takes GitHub deliveries at
  `POST /webhooks/github`, signed with `GITHUB_WEBHOOK_SECRET`.

GitHub has no "waiting on" or triage verdict fields, so the adapter reports
them as empty instead of guessing.

## Jira Cloud

Today Cromford reads, triages and wakes on Jira issues. A build does not
post its PR link or close-out comment back to the Jira issue yet.

Source: [bin/lib/tracker/jira.sh](../bin/lib/tracker/jira.sh).

- **Reads:** issues from a bounded JQL search, and their comments, over REST v3
  through Atlassian's gateway (`https://api.atlassian.com/ex/jira/<cloudId>`).
  Jira Server and Data Center are not supported.
- **Writes:** comments, labels and transitions. It asks Jira which transitions
  exist, so no status name is hard-coded. Linking a PR is a `PR: <url>` comment.
- **Credentials**, in the project's env file: `JIRA_BASE`, `JIRA_EMAIL`,
  `JIRA_API_TOKEN`, and optionally `JIRA_SITE`.
- **Settings rows:** `tracker_jira.<project>.write_projects`,
  `comment_projects` and `read_projects` are allowlists of Jira project keys.
  Also `label` (default `ai-build`), `waiting_on_field`,
  `triage_verdict_field` and `status_map`.

The allowlist is a hard guard. With no write row, nothing is written. Before
every write the adapter reads the issue back and refuses unless Jira answers
with the same key in the same project.

### Set up Jira

1. Create a scoped API token in your Atlassian account, with scopes that read
   and write Jira issues and comments. Find your site's cloud id:

   ```bash
   curl -s https://<your-site>.atlassian.net/_edge/tenant_info
   ```

   The gateway base is `https://api.atlassian.com/ex/jira/<cloudId>`. A site
   URL base is refused.
2. In Jira, put the label `ai-build` on the issues you want built. Note the
   status names of your workflow, for example To Do, In Progress, In Review
   and Done. The row `tracker_jira.<project>.status_map` maps Cromford's
   statuses to them, as `alias=Status;alias=Status`:

   ```bash
   bin/jobs-client.sh setting-set tracker_jira.<project>.status_map "todo=To Do;in_progress=In Progress;review=In Review;done=Done"
   ```

3. On the box that runs the project, put `JIRA_BASE`, `JIRA_EMAIL`
   and `JIRA_API_TOKEN` in `/etc/harness/env/<project>.env`. `JIRA_SITE` is
   optional: set it to `https://<your-site>.atlassian.net` and each ticket
   gets a link to its issue.
4. Point the project at Jira. A new project gets the rows when you load it:

   ```bash
   bin/load-project.sh <owner/repo> --tracker jira --prefix <KEY>
   ```

   For a project that is already loaded, set
   `tracker_adapter.<project>` to `jira` and the three rows
   `tracker_jira.<project>.write_projects`, `read_projects` and
   `comment_projects` to the project key.
5. To get changes at once instead of by polling, arm the webhook: set
   `JIRA_WEBHOOK_SECRET` on the jobs worker, add a Jira webhook to
   `https://<jobs-host>/webhooks/jira` with the same secret, and set the row
   `webhook_route.jira.<project key in lower case>` to `owner/repo`. See
   [Webhooks for Jira and Linear](#webhooks-for-jira-and-linear).
6. Check the connection. Run this on the box:

   ```bash
   bin/connection-probe.sh <project>
   ```

   The result is the settings row `connection.<project>.status`. It shows
   `ok`, or the error and the names of any missing variables. The lane
   `connection-probe` runs the same check every hour.

## Linear

Today Cromford reads, triages and wakes on Linear issues. A build does not
post its PR link or close-out comment back to the Linear issue yet.

Source: [bin/lib/tracker/linear.sh](../bin/lib/tracker/linear.sh).

- **Reads:** your team's open issues with a label (default `ai-build`), over
  Linear's GraphQL API.
- **Writes:** comments, labels and state. Linking a PR is a real Linear
  attachment. Labels are never created, so a label your workspace doesn't have
  is an error.
- **States:** mapped by Linear's state type (unstarted, started, completed,
  canceled). Review is the state named "In Review".

### Set up Linear

1. In Linear, open Settings and create a personal API key. Cromford sends it
   as the `Authorization` header of each GraphQL call.
2. In your Linear team, create the label `ai-build`. Cromford never creates a
   label, so a label your workspace does not have is an error. Review is the
   state named "In Review". If your team names it another way, set the row
   `tracker_linear.<project>.states` to a JSON object such as
   `{"review": "Code Review"}`.
3. On the box that runs the project, put `LINEAR_API_KEY` in
   `/etc/harness/env/<project>.env`.
4. Point the project at Linear. A new project gets the rows when you load it,
   with your team key as the prefix:

   ```bash
   bin/load-project.sh <owner/repo> --tracker linear --prefix <TEAM>
   ```

   For a project that is already loaded, set
   `tracker_adapter.<project>` to `linear` and `tracker_linear.<project>.team`
   to the team key.
5. To get changes at once instead of by polling, arm the webhook: set
   `LINEAR_WEBHOOK_SECRET` on the jobs worker, add a Linear webhook to
   `https://<jobs-host>/webhooks/linear` with the same secret, and set the row
   `webhook_route.linear.<team key in lower case>` to `owner/repo`. See
   [Webhooks for Jira and Linear](#webhooks-for-jira-and-linear).
6. Check the connection. Run this on the box:

   ```bash
   bin/connection-probe.sh <project>
   ```

   The result is the settings row `connection.<project>.status`. It shows
   `ok`, or the error and the names of any missing variables. The lane
   `connection-probe` runs the same check every hour.

## Webhooks for Jira and Linear

Without webhooks, Cromford polls. With them, a real change wakes triage right
away. The jobs worker takes `POST /webhooks/jira` and `POST /webhooks/linear`
([source](../worker/jobs/src/lib/tracker-webhooks.js)). Each checks its own
signature and drops repeat deliveries. Changes made by the accounts listed in
`webhook_self.jira` or `webhook_self.linear` are ignored.

Both are off until you arm them:

1. Set the worker secret `JIRA_WEBHOOK_SECRET` or `LINEAR_WEBHOOK_SECRET`.
2. In Jira or Linear, add a webhook to `https://<jobs-host>/webhooks/jira` (or
   `/webhooks/linear`) with the same secret.
3. Set the row `webhook_route.jira.<project key>` or
   `webhook_route.linear.<team key>` to your repo as `owner/repo`.

Before step 1 a delivery gets a `503`. After it, a bad signature gets a `401`,
and a delivery with no route row is accepted and does nothing.
