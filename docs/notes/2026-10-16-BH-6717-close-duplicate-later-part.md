# BH-6717: close-duplicate counts only a merge after the PR was opened

Doc: PR-OWNERSHIP

## What changed

`bin/pr-owner-sweep.sh` closed an ORPHAN as `close-duplicate` when ANY merged
PR had the same ticket key. On 2026-10-14 it closed #6328
(`ticket/bh-6173-r2`). #6328 was opened 1h46m after #6195 merged BH-6173. It
was a later part of the ticket, not a leftover.

- The ORPHAN arm now uses the MERGED_DUP time rule. A merged PR of the key is
  proof of "already shipped" only when `mergedAt > createdAt` of the open PR.
- The close comment names the newest such merge, in any list order.
- A PR opened after every merge of its key falls through to `stale-conflict`,
  then `handback`. It is never closed by this arm.
- An unreadable `createdAt` closes nothing. It is not listed as spared.
- The per-repo summary line has a new token, `spared-later=#n,...` or
  `spared-later=-`.

Out of scope: no read of "Refs" or "Closes" or of the issue state. No reopen
of #6328.

Tests: `tests/pr-owner-sweep-later-part.bh-6717-test.sh` (L1, L1b, L2, L3, L4,
L4b, L5).
