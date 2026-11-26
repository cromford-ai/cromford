# BH-10115: a retried Fly fix round is no longer refused at materialise

What changed:

- `bin/lib/queue-row-job.sh` `_qrj_fixround` accepts the pool key `FXR-<id>-<ck8>` and the retry key `FXR-<id>-<ck8>-r<n>` (n >= 1, no leading zero). BH-9906 added the retry key in `frp_key`. The hub check still accepted only the first form, so a retried round was closed `fixround meta rejected (key)` and never ran (row 2701, 2026-11-25).
- `_qrj_rr_refuse` posts ONE fix-round finish `setup-blocked <b64 reason>` as the meta's box when it refuses a fixround meta that names a numeric id and a valid box. The fix row then does not stay claimed until the box's stale re-offer. If the finish fails, nothing retries it: the stale re-offer finishes the row as before.
- `bin/blocked-resolver.d/bh-8896-fix-round-tree.sh` `frt_adopt_gate` reads the live pool row of a retried round (n = the row's `record_in.timeout_requeues` count) and sets `FRT_KEY`. `frt_refund` names that key.

Proof: `tests/fix-round-fly-retry.bh-10115-test.sh` (K1-K2, F1-F4, E1, A1).
