# fleet-propagate: warn while a pool retry is queued, page when retries run out (BH-3680)

Doc: FLY-BUILDER-TRIAL

On 2026-09-30 `bin/fleet-propagate.sh` paged `--critical` twice for pool bakes
that BH-3463 had already queued a retry for, and both retries fixed themselves:

- 07:42Z b58d105: project-1 and project-3 `timeout`, retry queued (1/2). The
  next merge and the 08:15Z drain rebaked them.
- 10:21Z cdb99be: project-4 `timeout`, retry queued (1/2), rebaked ok by the
  10:25Z drain. The outer timeout had killed it at `#33 pushing layer ... 9.5s
  done`, a few seconds from finishing.

The page also said "Those targets are still running the OLD harness" in the
same sentence that listed a cold-warm pool, which had shipped the new harness.

## What changed

- Severity by outcome. A failed pool whose retry is queued is listed as
  `retrying:` in one `--severity warn` line. The run pages `--critical` only
  when the hub, a box or the crontab failed, or a pool failed with no retry
  left (`retry cap reached`, `no retry (POOL_BAKE_RETRY_MAX=0)`, or no verdict
  at all). `PROPAGATE_PAGE_ON_FIRST_FAIL=1` (settings row
  `lane.fleet-propagate.propagate_page_on_first_fail`, default 0) restores the
  old first-fail paging. The ticket named the knob `propagate.page_on_first_fail`;
  the lane registry keys every lane row `lane.<lane>.<env lowercased>`, so this
  is the closest legal name.
- The page's `failed:` pool list and its closing `Still running the OLD
  harness:` list name only the paging targets. A cold-warm pool gets its own
  clause, `shipped the new harness, warm layer cold (warm build timed out)`.
  The page's prefix, which the `fleet-propagate-partial` alert-verify row
  matches, is unchanged.
- A queued retry that bakes ok logs `pool <p>: ok on retry n/N` and says so in
  that run's success line (same UTC-date rule as the retry counter).
- Push grace. A bake still building at `POOL_BAKE_TIMEOUT_S` is killed as
  before. One that has reached the image push gets `POOL_BAKE_PUSH_GRACE_S`
  more (default 300, `0` = off). The log line and the capture header name the
  phase the timeout hit. The other option in the thread, counting a pushed tag
  in the registry as ok, was not taken: `bin/fly-image-build.sh` writes the
  image pointer and the fly_images row only after `fly deploy` returns, so a
  pushed but unrecorded tag is not what pools boot.

Operator reference: `docs/verification-map/propagate-page-severity.md`.
