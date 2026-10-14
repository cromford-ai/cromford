# pipeline-health retractions close their console row (BH-4054)

Doc: ALERTS-STATE-MACHINE

Part of #3997 (alert truthfulness, 2 of 4). Builds on BH-4053, which keys a
pipeline-health alert's row on `alert:ph-<folded key>`.

## What changed

- **The retraction names the row it closes.** The Retraction epilogue in
  `bin/pipeline-health.sh` now beats, per retracted key `K`,
  `{kind:"alert",project:"fleet",akey:"alert:ph-<K>",alertid:"ph-<K>",resolved:true,line}`.
  `ph-<K>` is folded with the same expression `alert()` uses, so the open and
  the resolve are one string (`stalepr:ts` becomes `ph-stalepr_ts`). The
  `RESOLVED` audit line in ALERTS.log and pipeline-health.log, the DEDUP delete
  and the `health:<K>` fleet_alert resolve beat are unchanged.
- **`bin/beat.sh` has a resolve path.** An alert beat carrying
  `"resolved":true` and no `alertstate` is resolved through
  `alert_state_resolve`, never noted, so it writes no jobs row. When nothing
  was open it is silent (`resolve-silent id=…` in logs/alerts-state.log). When
  a row closed, the beat is stamped `alertstate:"resolve"` and routed on the
  severity the condition was OPENED at: a critical condition's resolve is
  POSTed, a warn one's joins the digest batch, an info one stays on the box. A
  beat that already carries `alertstate` (lane-alert's) keeps its old path.
- **`bin/lib/alert-state.sh` lost two built-in rules.** The collapse rule that
  keyed `[pipeline-health] RESOLVED <key>` lines to
  `pipeline-health-resolved-<key>` (a new id per resolve: the junk row) and the
  severity rule that demoted them to `info` (so nothing ever reached the
  console). In their place is one `logonly` rule,
  `^\[pipeline-health\] RESOLVED [^ ]+ — `, for the TEXT copy of the
  retraction (alert-line's beat of the audit line, or the poll-commands
  re-beat). Without it that copy would open a fresh critical row saying
  something is fine. `beat.sh` already exempts `resolved:true` from logonly, so
  the structured resolve is never caught by it. `env-templates/alerts.conf.example`
  drops the same two rules.
- **A skipped check is not a cleared one.** When `gh_budget_low` skips the
  stalepr, starved or stale-dequeue check (stale dequeue also when its lib is
  missing), that check's keys from last run's `state/health-active.txt` are
  carried into this run's fired set. stalepr does the same per repo when the
  repo is invisible to the token or its PR list fails (exact-line match, so
  `stalepr:ts` never carries `stalepr:tsx`). A carried key is neither
  retracted nor re-alerted: its DEDUP stamp stays.
- **`bin/lane-alert.sh --resolve` closes the console twin.** After the
  `orclane:<id>` resolve it also beats
  `{kind:"alert",akey:"alert:<id>",alertstate:"resolve",resolved:true}` on the
  same severity, which closes the row the poll-commands re-beat opened through
  the alias. A resolve of nothing open still sends nothing.

## Not changed

- costrollupstale, hubsyncstall and console-pages-drift resolve outside the
  epilogue. Their RESOLVED text lines are log-only now, but they send no
  structured `alert:ph-*` resolve (left for the next #3997 ticket).
- The console closing an akey's row on a `kind:"alert"` `resolved:true` beat is
  the cromford-console contract; it is not verified from this repo.

## Tests

`tests/ph-retract-closes-row.bh-4054-test.sh`,
`tests/lane-alert-resolve-console.bh-4054-test.sh`.
