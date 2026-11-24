# BH-9908: lookback reopen items carry the PR and the client's comment

Doc: reopen-reason

What changed:
- `bin/lookback-collect.sh` `src_reopen` now fills `pr` on each reopen item.
  The PR comes from `GET /api/ticket-status` (one call per project per chunk of
  `ticket_status.batch_max` keys) through `bin/lib/lookback-reopen.sh`
  `lrd_pr_map`. `files[]` then comes from that PR's GitHub file list.
- Each reopen item gets `comment` and `comment_status` from the
  `reopen_reason` ledger row or hub mirror (`lrd_comment`). A row from a
  different reopen day is `other-day` and shows no comment.
- `sources.reopen.detail` = `{pr_lookup, with_pr, with_comment}`. A failed PR
  lookup is named in `pr_lookup`. It does not set `.incomplete`.
- The clustering prompt items carry `pr` and `comment`. The harness issue
  evidence line adds `client comment: <author> (<at>): <text>`.
- `reason` is unchanged, so the reason-family keys and the 30-day follow-up
  match as before. The product-board filer is not changed.

Why: issue #9908. Nine reopens in one week had no PR, no files and no client
text in the bundle, so the lookback could not find a shared cause.

Test: `tests/lookback-reopen-detail.bh-9908-test.sh`.
