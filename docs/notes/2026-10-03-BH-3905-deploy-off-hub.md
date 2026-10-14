# Worker deploys move off the hub; the hub token proves it cannot write (BH-3905)

Doc: MERGE-CONDUCTOR

## What changed

#3905 takes Workers and D1 write access away from the hub. The deploy itself
moves to the `Deploy workers` GitHub workflow (#4088, a sibling slice). This
slice (BH-4089) adds the two pieces that make that safe to run:

- **`bin/cf-token-scope-probe.sh`**, run by hand on the hub. It sources
  `env/cloudflare.env` in a subshell, runs from `<checkout>/worker/jobs`, and
  prints one PASS/FAIL line per probe:
  - P1 `wrangler secret put BH3905_SCOPE_PROBE --name harness-jobs` must fail
    with an auth error. If it succeeds, the script deletes the secret at once,
    prints FAIL and writes one ALERTS line.
  - P2 `wrangler d1 execute harness-jobs --remote` of an
    `INSERT INTO verdicts ... WHERE 0` (zero rows even when allowed) must fail
    with an auth error.
  - P3 the same with `SELECT 1`. The hub keeps no D1 access at all.
  - P4 the Pages project GET that pipeline-health's drift check makes must
    answer HTTP 200 with `success: true`. This is the positive control: a dead
    token also fails P1-P3, so without P4 a pass would prove nothing.
  - P5 `wrangler whoami` with every Cloudflare credential unset must say "not
    authenticated", so no cached `wrangler login` is left on the box.

  Only an auth error counts for P1-P3. A timeout, a network error or "database
  not found" is a FAIL. Every `npx` runs under `timeout 120`. The raw output
  goes to `state/cf-scope-probe/<UTC>.txt` with the token scrubbed. Exit 0 means
  all five passed, 1 means any failed, and 2 means `cloudflare.env` or
  `worker/jobs/wrangler.jsonc` is missing.
- **The `# >>> deploy workers run` block of `bin/pipeline-health.sh`**. The
  main-red detector skips any workflow named deploy, so a red CI deploy would
  otherwise say nothing. Once an hour (`DEPLOY_WORKERS_EVERY`, default 3600,
  registered in `catalog/lanes.d/pipeline-health.json`;
  `state/deploy-workers.stamp`) it makes one `gh_rest` read of the newest
  completed main run of `deploy-workers.yml`. Anything but `success` pages
  `deployworkers:example-org/cromford` with the run id, short sha,
  conclusion and URL. A later success writes one RESOLVED line. A 404 (the
  workflow is not on main yet) and no completed run are silent. A GitHub answer
  it cannot verify (rc 75) or read logs one line and leaves the stamp alone, so
  the next tick asks again.

## Operator runbook

- **R1** On `example-org/cromford`, create the GitHub environment
  `cloudflare-deploy` with secrets `CLOUDFLARE_API_TOKEN` (Workers Scripts
  Edit, D1 Edit, Cloudflare Pages Edit; add Workers KV Storage Edit only if the
  first watchdog deploy asks for it) and `CLOUDFLARE_ACCOUNT_ID`. Prove it
  answers (a `wrangler whoami` from a `workflow_dispatch` run) BEFORE #4088
  merges. That PR gates the deploy lane on it.
- **R2** Merge #4088. Confirm the first `Deploy workers` run on main is green.
  If it is not, the deploy workers run block pages.
- **R3** On the hub, mint a token with only Account → Cloudflare Pages: Read,
  and write it to `/etc/harness/env/cloudflare.env` (chmod 600).
  `cloudflare-deploy.env` must NOT exist on the hub.
- **R4** Revoke the old broad token in the Cloudflare dashboard, run
  `npx wrangler logout`, then run `bin/cf-token-scope-probe.sh`. Paste the
  printed summary and the scrubbed `state/cf-scope-probe/<UTC>.txt` on #3905.
  Exit 0 records #3905's acceptance 1.
- **R5** Confirm a worker deploy goes through CI (acceptance 2): merge a change
  under `worker/`, or dispatch the workflow by hand. The deploy workers run
  block stays quiet and the console drift check stays green.
- **R6** Re-PUT any `lead_*` settings rows (none today), flip
  `human_verdict_mode` and `human_verdict_sig_mode` to `enforce`, and close
  #3846 (acceptance 3).

## Rollback

Write a deploy-scoped token to `/etc/harness/env/cloudflare-deploy.env` on the
hub. With #4088's gate in `bin/harness-sync.sh`, the hub deploys from that file
again. Deploy, then delete the file and re-run `bin/cf-token-scope-probe.sh` to
put the hub back to Pages Read.

## Not covered

- Worker source (`worker/**`) is not a lead-protected path. A merged worker
  change still deploys through CI, so the merge gates guard it, not the token.
- The hub's GitHub PAT can still push a branch that CI deploys once it merges.
  The merge gates cover that too; narrowing the Cloudflare token does not.
