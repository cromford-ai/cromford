# The lookback lane can be turned on: a dry week in the digest, then live (BH-3691)

Doc: TRUST-PROGRAM, LANES

## What changed

The lane itself (BH-1795) was merged but never switched on. Five gaps stood
between it and the ticket, and this change closes them in `bin/lookback.sh`,
`bin/lib/lookback-followup.sh` and `catalog/lanes.d/lookback.json`:

- **A dry run clusters and reports.** `LOOKBACK_DRY=1` used to print the bundle
  inventory and stop before clustering. It now makes the clustering call (the
  same one weekly call a live run makes, capped by `LOOKBACK_MAX_USD`), lists
  each cluster a live run would dispatch as `would file: <target> <title>`,
  calls no filer, and sends the summary with `--severity warn`, so it lands in
  the batched digest. The last line is the go-live command. Any value other
  than exactly `0` (or unset) is treated as dry and the summary says so.
- **The cap is per rolling 7 days.** `LOOKBACK_MAX_ISSUES` used to cap one run,
  so a by-hand re-run could file five more. The driver now reads every
  `ledgers(kind=lookback_cluster)` row once and counts those whose
  `detail.filed_at` is in the last 7 days. A read that fails, returns no
  `ledgers` array or fills its 1000-row page stops all filing that run
  (`week cap unverifiable (<why>), filing stopped`).
- **App-target clusters stay off product boards.** A board ticket is
  client-visible and has no `ai-build` label. It is filed only with the new
  knob `LOOKBACK_APP_FILING=1` (default 0). Otherwise the summary says
  `not filed: app filing off:` and the cluster does not use up the cap.
- **The follow-up records whether a fix merged.** At 30 days, a harness-repo row
  is checked for a merged PR on `ticket/bh-<issue>`. The ledger detail gains
  `fix_merged` (`yes` + `fix_pr`, `none`, or `unknown` when the read could not
  be made or verified), and the comment gains a `Fix:` line.
- **Every summary carries a measure line**: clusters filed to date, in the last
  7 days, followed up (recurred / stopped), and with a merged fix (and how many
  of those recurred anyway).

Dedupe against open issues (ledger row, then the body marker), the `ai-build`
label and the evidence lines were already in `bin/lib/lookback-file.sh`. They
are now pinned through the real driver by `tests/lookback-live.bh-3691-test.sh`.

## Turning it on (a hub step after merge, not part of the PR)

1. After the merge has reached the hub (`bin/fleet-propagate.sh` or
   `update-runners.sh`), on the hub:
   `bin/harness-ctl.sh set lookback LOOKBACK_DRY 1`, then
   `bin/harness-ctl.sh on lookback "BH-3691 dry week"`.
2. Check that `lookback.cluster` routes to the claude runner
   (`GET /api/model-routes/lookback.cluster`). Otherwise the dry run says
   `clustering not configured` and has no clusters.
3. The dry run fires Monday 2026-10-05 06:45Z. Its summary reaches the digest
   with the next `alert-warn-flush` drain.
4. Go live after reading it: `bin/harness-ctl.sh set lookback LOOKBACK_DRY 0`.
   The first live run is Monday 2026-10-12 06:45Z.
5. Kill: `bin/harness-ctl.sh off lookback "<reason>"`.
