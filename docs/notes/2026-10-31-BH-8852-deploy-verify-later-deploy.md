# deploy-verify accepts a later deployment that contains the merge (BH-8852)

Doc: MERGE-CONDUCTOR

## Why

Vercel skips the build of a merge sha when a newer main commit lands before
the build starts. It deploys only the newest commit. On project-6-os,
2026-10-31, f0c814df (#3436) got no deployment of its own. 4 later main
commits each deployed with success, and compare f0c814df...4c9e090a read
ahead_by=4. `bin/deploy-verify.sh` polled `deployments?sha=f0c814df` for
20 min and paged "no successful production deployment within 20 min" twice
(alerts 51400 and 51427). Both pages were false.

## What changed

- When the exact-sha query is readable and finds no production deployment,
  each poll also reads the newest production deployments of the repo
  (`deployments?per_page=<n>`). It walks them newest first to the first one
  whose newest terminal status is `success`.
- If `compare <merge>...<deployed>` answers `ahead` or `identical`, the verify
  passes. `pipeline.log` gets one line:
  `deploy-verify: verified through <deployed sha8>, which contains <merge sha8>`.
  The smoke check, the OK line, the hotfix-after-deploy hook and
  post-merge-verify (`--served` = the deployed sha) then run as before.
- `behind`, `diverged`, an empty or unreadable compare: no pass. The poll
  continues. A non-empty compare answer is read once per run.
- A `failure` or `error` deployment is never a pass. If one that contains the
  merge was seen, the 20 min timeout FAIL gets a suffix:
  `(later deployment <sha8> contains <sha8>: state=<state>)`.
- The scan runs before the 5 min deploy-hook block, so a merge that is already
  live through a later deployment does not fire the hook.

Not changed: the exact-sha path (a failed exact deployment still FAILs at
once), the hook-recovery path, the smoke-only paths, the 20 min window.

## Knob

`deploy.verify.later_deploy_scan` (settings, default 10, valid 1..100): the
page size of the later-deployment read. A missing row, an outage or a value
out of range is 10.

## Test

`tests/deploy-verify-later-deploy.bh-8852-test.sh` drives the script end to
end with a stub `gh` that applies the script's own `-q` filters.
