# A red production deploy holds the merge queue and pages a person (BH-8781, slice C0)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## Why

Every project-3 Vercel production deploy from 2026-10-27 19:10Z to 2026-10-29
failed, 13 in a row. The merge conductor merged 11 PRs on 2026-10-28 onto that
red production. None reached production, and their 5 migration files did not
run. The deploy alerts stayed untriaged for 2 days, and no person was paged.

## What changed

- `bin/vercel-deploy-snapshot.sh` (hub, every 4 minutes) reads the NEWEST
  production deployment of each Vercel project, in any state. It writes two
  new keys into each `.projects[<p>]` of `state/vercel-deploy-status.json`:
  - `newest_prod`: `{id, state, sha, created_ms}`, or null when the project has
    no production deploy.
  - `prod_red`: `{since, sha, id}` while production is red, else null.
    - `ERROR` sets it. A red streak keeps its first `since`; `sha` and `id`
      name the newest failed deploy.
    - `READY`, or no production deploy, clears it.
    - Any other state (`BUILDING`, `QUEUED`, `CANCELED`) keeps the previous
      value: production is what it was until a deploy finishes.
    - A failed read keeps both previous keys and adds `<p>:newest` to the
      `FAILED` list of the log line.
  The summary line in `logs/vercel-snapshot.log` gains `prodred:[<projects>]`.
- On the transition to red (no record before, a record now) the lane calls
  `page_critical` once for the project, after the file is written: key
  `prodred:<p>`, lane label `prod-red`, TTL `PROD_RED_REPAGE_S` (86400 s). The
  page is one `CRITICAL [prod-red]` ALERTS line, a triaged console beat, and a
  Telegram DM when the beat fails. It names the deploy, the commit, the time,
  the owner (`HARNESS_GIT_EMAIL`) and the way to merge a fix.
- `bin/merge-conductor.sh` `pr_worker` calls `mc_prod_red_hold`
  (`bin/merge-conductor.d/bh-8781-prod-red-hold.sh`) in its READY arm, right
  after the main-red freeze. On a red record in a fresh snapshot, the row stays
  READY with the ready-why reason `production red since <since>, commit
  <sha8>`. One log line per (PR, head): `<key> READY and HELD: production red
  since ...`. No merge, no enqueue, no gh write, no budget. The first tick
  after a READY production deploy merges the PR.

## Design (r10)

The conductor reads one local file with `jq`. It makes no network call and
sources no lib, and it changes no shell option. Both lanes run on the hub, so
the file is the conductor's own copy. Earlier attempts (r4 to r9) read the
state through the jobs worker and added a lib under three scripts. Those
attempts selected 942 suites at the gate and never opened a PR.

## Fail open

A missing, unparseable or stale snapshot holds nothing. A snapshot is stale
when its `generated_at` is older than `MC_PROD_RED_MAX_AGE_S` (1800 s, 7 missed
runs). The conductor writes one `prod-red: snapshot unreadable or older than
<n>s for <p> ...; not held` line per project-hour. A dead snapshot lane must
not freeze every queue.

## Operator escape

1. To merge the fix through the hold, label its PR `fix-main-red` (or the
   `MC_MAIN_RED_LABEL` value) or `hotfix`. A PR whose whole diff is test files
   also passes.
2. To turn the hold off for one project, set the settings row
   `lane.merge-conductor.<project>.mc_prod_red_hold` to `0`.

## Not in this slice

- Item 3: triage defers client completion comments while production is red.
- Item 4: the console project row shows `prod: red since`. It reads `prod_red`.
- Item 5: migration alerts resolve on a green build log.
- Email to the owner. This repo has no mail seam; a mail vendor needs its own
  seam, fake and contract suite first.
- A project that does not deploy on Vercel is never held.
