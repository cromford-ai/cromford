# BH-3936: superseded close for every class, and the PR-health digest line (BH-3929 asks 4 and 6)

Doc: PR-OWNERSHIP

**What changed.** Two of the #3932 hook stubs are filled in.

- `po_superseded` (`bin/lib/pr-owner/superseded.sh`) closes an open PR of any
  class when its key already merged in another PR, when its ticket is done or
  rejected (`ph_ticket_status`, same file), or when a newer PR for the same key
  is the one that stays. EXTERNAL PRs get an `@author` comment. A PARKED PR is
  closed only by the merged-key rule. An ORPHAN keyed by branch or title is
  still closed by the sweep's own close-duplicate arm, unchanged. An unreadable
  ticket status means no superseded action for that PR that tick.
- `po_health_add` / `po_health_flush` (`bin/lib/pr-owner/health.sh`) write one
  `ledgers(kind=pr_health, key=<project>)` row per repo per sweep: open, age
  buckets, ownerless, approved not merged, blocked on CI only.
- The daily digest reads those rows (`pr_health` state section,
  `worker/jobs/src/lib/daily-digest/state-sections.js`) and prints one
  `PR health:` line per project (`bin/lib/daily-digest-render.sh`).
  `isEmptyDigest` counts a `pr_health` row as content.

**Writes this adds.** GitHub: one comment and one close per superseded PR, over
REST, counted against `PR_OWNER_MAX_ACTIONS`, nothing under
`PR_OWNER_DRY_RUN=1`. D1: `ledgers` rows `pr_superseded` (the comment dedupe)
and `pr_health`. Conductor: `mc_transition … CLOSED superseded:<by>` for a
closed PR the conductor already had a row for. No new file under `state/` or
`flags/`, no schema change.

**Not in it.** The ownerless alert after `pr_owner.ownerless_alert_hours`
(the knob stays seeded and unread), enroll (#3933), the CI-only BLOCK clear
(#3934), the age ladder (#3935).

**Key gate.** The key shape is the existing anchored one, so a branch whose
last segment starts with a key-like token (`fix/utf-8-encoding` reads as
`UTF-8`) is still keyed for the ORPHAN close-duplicate arm. The superseded
hook's key is gated: its prefix must be one a harness-authored PR in the repo
already uses (`TICKET_PREFIXES` in the sweep), so `UTF-8` and `WRANGLER-3`
never reach rules 1 to 3.

**Guards after review.** Rule 1 counts only a merge after the PR was opened,
and never while a build job for the key is live, so a reopened ticket's rebuild
is not closed as a leftover. On a product board rule 2 skips OWNED PRs and PRs
with a conductor row, because the fleet marks `done` before the merge. Rule 3
skips a PR the blocked resolver owns. Every close first asks `to_merge_hold`.
