# Console preview: the lane strips preview bindings, and QA reports a binding gap (BH-6923)

Doc: bin/console-preview-deploy.sh, bin/console-qa-run.mjs, skills/console-deploy/SKILL.md

## What changed

1. **The lane removes the bindings itself.** `preview_bindings_clean` in
   `bin/console-preview-deploy.sh` still refuses a preview environment that
   binds anything. Now, when it finds bindings and the knob
   `CONSOLE_PREVIEW_STRIP_BINDINGS` is 1 (the default), it sends ONE
   `PATCH /accounts/<acct>/pages/projects/<project>` per run
   (`strip_preview_bindings`). The body holds only
   `deployment_configs.preview`: each object-typed binding's names and each
   secret env var set to `null`, for example
   `{"deployment_configs":{"preview":{"d1_databases":{"CONSOLE_DB":null},"env_vars":{"HARNESS_SECRET":null}}}}`.
   It never holds a `production` key or a plain env var. Then the lane reads
   the project again and runs the same check (`preview_findings`).
   - A clean re-read: one log line `removed from the preview environment: …`,
     one `lane-alert.sh --log-only` notice, one
     `--resolve --id console-preview-bindings`, and the run deploys.
   - A re-read that still binds something (`after the lane removed them`), a
     PATCH that fails or answers `success:false` (`could not remove`), or an
     array-typed binding: the old refusal, with the same
     `console-preview-bindings` alert. No head is charged.
   - With the knob at 0 the lane refuses as before and sends no PATCH.
2. **QA tells a binding gap from a defect.** The preview environment binds
   nothing, so main's Pages Functions that need `CONSOLE_DB`, `HARNESS_SECRET`
   or `LEAD_VERDICT_TOKEN` answer 503 with `<binding> is not set|bound on this
   Pages project`. `bin/console-qa-run.mjs` reads the body of each same-origin
   `/api/` 503 (`previewGap`). A match prints one
   `PREVIEW GAP: <METHOD> <path> — <binding> not bound in the preview environment`
   line (once per method and path, before `QA COVERAGE:`), and the screen loses
   one `Failed to load resource … 503` console error per gap response
   (`dropGapErrors`). Every other console error, failed request, HTTP status
   and scroll still fails the screen. A body that does not read is not a gap.
   The lane's PR comment copies the `PREVIEW GAP:` lines. `observed.json` has
   a `gaps` list.
3. **The runbook no longer adds the bindings back.** Step 1 of
   `skills/console-deploy/SKILL.md` sets `HARNESS_SECRET` and `CONSOLE_DB` on
   `production` only, and says the preview environment binds nothing.

## Where the lane reads the Cloudflare credentials

`bin/console-preview-deploy.sh` sets `CFENV="$(harness_env_dir)/cloudflare.env"`.
`harness_env_dir` (`bin/lib/env-path.sh`) resolves `$HARNESS_ENV_DIR`, then
`/root/harness/env` when it is a real directory, then `/etc/harness/env`. The
lane reads `CLOUDFLARE_ACCOUNT_ID` from that file, else `account_id` from
origin/main's `worker/jobs/wrangler.jsonc`, and `CLOUDFLARE_API_TOKEN` only
inside the GET and PATCH subshells. No person or session reads the file for
the strip.

## Why

The guard refused every deploy since 2026-10-15
(`d1_databases CONSOLE_DB, env var HARNESS_SECRET`), so no console PR got a
preview or a QA verdict. With the bindings gone, the shell's
`/api/coord/whoami` and theme reads answer 503, and each 503 would fail every
screen. The gap rule keeps the verdict about the PR's own code.

## Known limit

The preview has no data path for coord, cockpit, ideas or outcomes reads. A
read-only proxy through the console worker (a `dashqa` GET path) needs a
change in `cromford-console`. That is the follow-up.

## Proof owed after merge

1. `grep 'removed from the preview environment' logs/console-preview-deploy.log | tail -1`
   names `CONSOLE_DB` and `HARNESS_SECRET`.
2. A re-read of the project in a subshell that sources the lane's `CFENV`
   shows no D1 entry and no `HARNESS_SECRET` under `.preview`, and both under
   `.production`.
3. The run summary shows `deploys 1` or more, and an open console PR has a
   `QA: PASS|FAIL for head <sha>` comment.
