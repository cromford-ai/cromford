# Mergify's hotfix queue keys on `fix-main-red`, not `hotfix`

Doc: MERGIFY

## What changed

- `config/mergify/template.yml` keys the Mergify hotfix lane on `fix-main-red`
  at all four places it used `hotfix`: the `hotfix` queue's `queue_conditions`,
  the `hotfix first` priority rule, the rule that routes to the `hotfix` queue,
  and the `-label=` exclusion on the rule that routes to `default`. Queue and
  rule names are unchanged.
- `.mergify.yml`, `tests/fixtures/mergify/project-5.mergify.yml` and the §2
  block of `docs/MERGIFY.md` carry the same change (the first two are renders
  of the template; `bin/mergify-template.sh --check` holds them to it).
- The `hotfix` label keeps its pool meaning: a ticket labelled `hotfix` is
  still built first (`bin/lib/hotfix-lib.sh`, untouched). Its PR now queues in
  `default` like any other PR. The conductor's degraded-mode ordering still
  reads `hotfix`.

## Why

Jumping the queue restarts running work: `allow_checks_interruption: true`
interrupts every batch already building. On 2026-09-24 at 17:04Z a `hotfix`
PR (#2104) did that. A green 8-PR batch was thrown away and three batches
restarted. Urgent is not the same as main being red, so only a PR that fixes a
red main gets to do this.

## What it touches

- project-5's live `.mergify.yml` now drifts from the render. The daily
  `bin/mergify-sync.sh` check raises one `DRIFT` alert, and
  `bin/mergify-sync.sh apply` opens the sync PR in that repo. Until that PR
  merges, project-5 still keys the queue on `hotfix`.
- A repo without a `fix-main-red` label sends main-red fixes to `default`. They
  still merge, just at normal speed. `docs/MERGIFY.md` step 2 now creates the label.
- Pinned by `tests/mergify-hotfix-key.bh-2121-test.sh`.
