# tests/fixtures/mr-red/drafts — BH-9532 (C0, #9539)

The fixtures `tests/staff-mr-red-contract.bh-9532-test.sh` builds its fake
GitHub answers from.

- `draft.json`: one element of `GET repos/<slug>/pulls?state=closed&sort=updated&direction=desc&per_page=100`,
  a closed-unmerged Mergify merge-queue draft. Only the fields
  `bin/staff/mr-red-collect.d/10-drafts.sh` reads are kept: `number`, `title`,
  `html_url`, `state`, `draft`, `user.login`, `head.ref`, `head.sha`,
  `merged_at`, `closed_at`, `updated_at`.
- `check-runs.json`: `GET repos/<slug>/commits/<sha>/check-runs?filter=latest&per_page=100&page=1`
  for that draft's head, with one `failure` run.

Source: assumed. The plan asked for a live `gh api` read at build time. The
build box's egress proxy denied `api.github.com:443` (egress.log,
2026-11-11T18:12:45Z), so no live read was possible. The shape is the GitHub
REST shape the repo's other merge-queue fixtures already use
(`tests/fixtures/unblock/batch-7699.json`, BH-7723: `user.login`
`mergify[bot]`, `head.ref` `mergify/merge-queue/...`, `merged_at` null). The
shas, numbers and times are fakes.

Near misses (source: assumed): the suite edits `draft.json` with jq for each
case of the decision table (merged, open, the `mergify/merge-queue-x/` prefix,
a non-Mergify author, closed past the lookback, success / cancelled / skipped /
neutral only, a failure superseded by a rerun success, a failure on check-runs
page 2, a draft on pulls page 2).
