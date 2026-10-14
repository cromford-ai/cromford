# The worker deploy snapshot carries agent-core/ (BH-6687)

Doc: VERIFICATION-MAP

## The gap

`snapshot_tree()` in `bin/harness-sync.sh` archived `worker/`, `catalog/`, the
three composers and `bin/lib`. Since BH-5559, `worker/jobs/src/routes/staff.js`
and `staff-findings.js` import `../../../../agent-core/`. The snapshot had no
`agent-core/`, so `wrangler deploy` could not bundle. harness-jobs did not
deploy from 2026-10-10 03:15Z. Each failed pass wrote one ALERTS line: 694
lines in 4 days.

## What changed

- `snapshot_tree()` also archives `agent-core/`. A commit without it skips the
  path, as before for the other paths.
- A worker whose tree names `agent-core/` adds `-core-<sha>` to its deploy key
  (`state/worker-deployed-<w>`). `<sha>` is the last commit that touched
  `agent-core/`. An `agent-core/`-only commit now redeploys that worker.
  worker/watchdog does not import it, so its key does not change.
- A failed `wrangler deploy` goes through `deploy_fail_note`. The first failure
  ALERTs. While the deploy keeps failing, it ALERTs again at most once per
  `HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S` seconds (settings row
  `lane.fleet-propagate.harness_sync_deploy_alert_repeat_s`, default 3600,
  0 = every failure). A held failure is one `alert held, next in <n>s` line in
  `update-runners.log`. The ALERT carries `failing since <UTC> (<n> failed
  attempt(s))` and `--id worker-deploy-failed-<w>-<hostname>`.
- New state file `state/worker-deploy-failing-<w>`: one line
  `<first_epoch> <last_alert_epoch> <count>`. Other content, or a last alert in
  the future, counts as absent. A successful deploy removes it and logs
  `worker <w> deploy recovered after <n> failed attempt(s) since <UTC>`.

## Check

`tests/harness-sync-snapshot-agent-core.bh-6687-test.sh` pins all of the above.
After the merge, the first harness-sync pass on a box with
`env/cloudflare.env` sees a new jobs key and deploys:
`grep 'worker jobs deployed at' /root/harness/logs/update-runners.log | tail -1`.
