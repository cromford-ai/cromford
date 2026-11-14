# BH-9582: the lead review is asked for on the PR event

Doc: EVENTS

Slice C0 of #9582 (part C of BH-9559). Parts B and D stay open on #9582.

## What changed

- New wake class `bin/lib/wake-class-pr-lead.sh`. A `pr` wake whose event is
  `pull_request.opened`, `.reopened`, `.ready_for_review` or `.synchronize`
  makes the box that owns the repo read the PR once on GitHub (state, draft,
  head). An open, non-draft PR in a `LEAD_REVIEW_AUTO_REPOS` repo gets
  `lcw_ring lead-review <slug> <n> <head>` (dedupe `lead-review:<n>@<head12>`).
  The next drain claims that lane row and launches `bin/lead-review.sh tick`.
  Before this, the only ring was inside the `*/15` cron tick, after the
  worklist claim (`bin/lib/lead-gates.d/97-doorbell.sh`).
- A `synchronize` gives a new head, so a fix-round push gets a new ring.
  Whether a review runs is still `bin/lead-review.sh`'s decision (`lr_start`
  per head, spend and concurrency caps, `LEAD_REVIEW_RERUN_MAX`).
- The hub does nothing in this class: it claims every repo's `pr` rows for the
  merge conductor, and it runs no lead review.
- `bin/wake-loop.sh`: a class is armed by its `wake-lanes-<class>` flag, or
  else by its own `wc_<class>_default_on` answering 0. Only `pr-lead` defines
  one, so it is on with no flag. Every other class is unchanged.

## Knobs and kill switches

| Name | Kind | Default | Effect |
|---|---|---|---|
| `lead_review.event_wake.enabled` | settings row | 1 | 0 = the class rings nothing |
| `lead_review.event_wake.reads_max` | settings row | 20 (1..200) | GitHub PR reads per drain; the rest wait for the cron |
| `lead-chain-wake-off` | lane switch (row, else `flags/lead-chain-wake-off`) | off | stops every lead-chain ring |
| `flags/wake-lanes-off` | file | absent | stops every wake class |

Seeds: `worker/jobs/schema.d/202611140758-bh-9582-lead-review-event-wake.sql`.

## Log lines (`logs/wake-loop.log`)

- `wake classes armed: … pr-lead`
- `pr-lead: <slug>#<n> @<h12>: lead-review doorbell rung`
- `pr-lead: <slug>#<n> @<h12>: doorbell not rung (rc N); the */15 cron covers it`
- `pr-lead: <slug>#<n>: PR read failed; the */15 cron covers it`
- `pr-lead: <k> PR(s) over the read cap of <cap>; the */15 cron covers them`
- `pr-lead: off (lead_review.event_wake.enabled=0)` / `pr-lead: off (lead-chain-wake-off)`
- `pr-lead: no lead-review repos; the */15 cron covers it`

Test: `tests/lead-review-event.bh-9582-test.sh`.
