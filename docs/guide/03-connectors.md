---
title: Connectors
description: Which trackers Cromford reads, the credentials each needs, and what works today.
order: 3
---

# Connectors

Cromford talks to every tracker through one set of verbs: list, read,
comment, transition, add and remove a label, link a PR, and close out. Each
tracker has an adapter under `bin/lib/tracker/`. `bin/lib/tracker.sh` picks
one per project.

A project uses the tracker it was enrolled with. To pick another, set the
settings row `tracker_adapter.<project>` to `github-issues`, `board`, `jira`
or `linear`. Any other value is refused.

```bash
bin/jobs-client.sh setting-set tracker_adapter.<project> github-issues
```

This page names settings and credentials only. Their values live under
`/etc/harness/env/` on the box, never in a settings file or a log.

## GitHub Issues

This is the default. It needs nothing beyond your GitHub credential.

- **Reads:** open issues with the `ai-build` label, with their comments and
  labels.
- **Writes:** comments, labels, and open or closed state. A PR link is a
  `PR: <url>` comment.
- **Credential:** `GH_APP_ID` and `GH_APP_PRIVATE_KEY_FILE` for a GitHub App,
  or `GH_TOKEN`.
- **Webhook:** the jobs worker takes `POST /webhooks/github`, signed with
  `GITHUB_WEBHOOK_SECRET`.

## Jira Cloud

- **Credentials**, in the project's env file: `JIRA_BASE`, `JIRA_EMAIL`,
  `JIRA_API_TOKEN`, and optionally `JIRA_SITE`.
- **Settings rows:** `tracker_jira.<project>.write_projects`,
  `comment_projects` and `read_projects` are allowlists of Jira project keys.
  With no write row, nothing is written.

**Not yet:** today only the readiness check reads Jira tickets through this
adapter. The rest of the pipeline does not drive a Jira project end to end.

## Linear

- **Reads:** your team's open issues with a label (default `ai-build`), over
  Linear's GraphQL API.
- **Writes:** comments, labels and state. A PR link is a Linear attachment.

**Not yet:** the adapter is built and tested, but nothing in the pipeline
loads a Linear key or calls it. A Linear board cannot drive builds today.

## Webhooks for Jira and Linear

Without webhooks, Cromford polls. With them, a change wakes triage at once.
The jobs worker takes `POST /webhooks/jira` and `POST /webhooks/linear`. Both
are off until you arm them:

1. Set the worker secret `JIRA_WEBHOOK_SECRET` or `LINEAR_WEBHOOK_SECRET`.
2. In Jira or Linear, add a webhook to `https://<jobs-host>/webhooks/jira` (or
   `/webhooks/linear`) with the same secret.
3. Set the row `webhook_route.jira.<project key>` or
   `webhook_route.linear.<team key>` to your repo as `owner/repo`.

Before step 1, a delivery gets a `503`. After it, a bad signature gets a
`401`. Changes made by the accounts in `webhook_self.jira` or
`webhook_self.linear` are ignored.

[Connecting a board](../connecting-a-board.md) has the full detail for each
adapter.
