# BH-9287: which App writes the verdict status, and when a failed write pages

## The cause

The project-6 conductor runs on a Fly lane-run machine (BH-6890). That machine
mints its GitHub tokens from its default App, `cromford-builders`.
`gh api apps/cromford-builders` shows `statuses: null`; `apps/cromford`
(the hub App) shows `statuses: write`. So every conductor publish of
`lead-verdict` / `harness-verdict` from a lane-run machine got HTTP 403. The hub
logged 363 failed publishes on project-6 from 2026-10-19 to 2026-11-07, plus 1
on project-3.

No merge was blocked. project-6's `.mergify.yml` does not require the status,
main has no branch protection, and the hub App publishes the same status a few
minutes earlier. But `mc_status_unpublished_alert` paged once a day per repo
anyway, and its text said to fix "the hub App", which was not the App that
failed.

## What changed

1. **Status App profile.** `bin/lib/verdict-status.sh` `vs_publish` mints from
   App profile `status` (`vs_status_profile`) when
   `<env dir>/github-app-status.env` is readable (`vs_status_profile_ready`).
   `bin/gh-token.sh --app status` already reads that file
   (`env/github-app-<profile>.env`, BH-1578) and keeps its own token cache.
   A box without the file mints exactly as before. The hub has no such file,
   so hub publishes do not change.
2. **The lane-run machine writes the profile.** `fly/lane-run-entrypoint.sh`
   writes `github-app-status.pem` and `github-app-status.env` (`GH_APP_ID`,
   `GH_APP_PRIVATE_KEY_FILE`, mode 600) when the Fly secrets
   `GH_APP_STATUS_ID` and `GH_APP_STATUS_PRIVATE_KEY` are both set. It then
   unsets the key. The file carries no `GH_APP_INSTALLATION_*` line:
   gh-token.sh unsets those for a profile and finds the installation on the
   JWT. The two names are optional rows in
   `catalog/lane-run-secrets.d/fly-pool.tsv`.
3. **Info line or alert.** When a conductor publish fails,
   `mc_status_unpublished_alert` asks `vs_mergify_names <repo> <context>`:
   - the repo's `.mergify.yml` names a success condition on the context
     (`check-success`, `check-success-or-neutral` or `status-success`, with
     `=` or `~=`, the context as a whole token): ONE alert per repo per UTC
     day, as before;
   - it names none, or there is no `.mergify.yml` (404): ONE
     `VS_UNPUBLISHED_INFO` line in the conductor log, no alert, no ledger mark;
   - the file could not be read: the alert, as before (fail toward visibility).

   The context is the one that failed (`$LR_CTX`, `lead-verdict` or
   `harness-verdict`). The read shares the conductor's `gh-policy-cache` entry
   `mergify`. The alert names the App from GitHub (`GET /app` on its JWT,
   `bin/gh-token.sh [--app status] --app-slug`), or says
   `unnamed (GET /app did not answer)`. The words "hub App" are gone.

## Operator step (staging the status App)

The code ships inert. Until the secrets are staged, a lane-run machine has no
status profile and still mints from the builders App; only the info/alert rule
and the App name change.

1. Print the staging command on the hub:
   `bin/lane-run-secrets.sh --stage-cmd lane-run-mk fly-pool project-6-os`.
   Run it. It stages `GH_APP_STATUS_ID` from the hub's `env/github-app.env`
   `GH_APP_ID` through stdin.
2. Stage the PEM by hand, as for `GH_APP_PRIVATE_KEY`: the hub App key text
   from the hub's `env/github-app.pem` as `GH_APP_STATUS_PRIVATE_KEY` on the
   lane-run app (the command prints a `# GH_APP_STATUS_PRIVATE_KEY:` line for
   this).
3. Deploy the staged secrets. A machine that boots after that writes the
   profile.

**Alternative:** grant `cromford-builders` "Commit statuses: Read and
write" in the App settings. Then no secret is needed and no code path changes.

**Edge:** if a `status` profile mint fails, gh-token.sh answers from the
default App (its hub retry, with the hourly `gh-app-profile-retry` ALERTS
line). The status alert then names the status App, not the App that answered.

## Console half (follow-up, example-org/cromford-console)

Not built here. This build cannot read `example-org/cromford-console`
(`git ls-remote` answered "Repository not found"), so the follow-up is
written here and in the PR body.

The console MCP `prs` tool returns `gh_failed`. `harness-console/mcp/lib/gh.mjs:40-52`
runs one GraphQL call (`gh pr list --state all --limit 100 --json ...statusCheckRollup`).
A project-6 head has 45 check runs, so the likely cause is the 25 s `execFile`
timeout or a GraphQL resource limit. `ghErrorKind` reports both as `gh_failed`.

Spec:

1. List PRs over REST: `GET repos/<owner>/<repo>/pulls?state=all&per_page=100`.
2. Read check runs for OPEN PRs only:
   `GET repos/<owner>/<repo>/commits/<head sha>/check-runs`.
   A closed or merged PR shows no rollup.
3. Report `gh_timeout` when the runner times out (the `execFile` timeout or
   an abort), apart from `gh_failed` for an API error.
4. Make no GraphQL call.

Acceptance tests:

- A runner that times out gives `gh_timeout`.
- A REST 500 gives `gh_failed`.
- No GraphQL call is made (the runner stub records every argv; none holds
  `graphql` or `pr list --json ...statusCheckRollup`).
