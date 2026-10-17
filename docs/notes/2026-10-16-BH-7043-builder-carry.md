# A builder APPROVE carries to a merge-only head, and the replay fetch retries (BH-7043)

Doc: LEAD-REVIEW

## What happened

BH-5294 replays a lead MERGE onto a head that only took main in. On the hub it
almost never fired: 2,294 enqueue summary lines said `replayed=0`. Two causes,
both seen on #6988 on 2026-10-16:

1. `patch_same_fetch` ran one `git fetch origin main <head>`. When that one call
   failed, the replay gave up (`fetch of a8ba9ace54e1/1c00c40e5b6f failed;
   requesting as before`). The git error went to /dev/null.
2. The builder APPROVE is bound to the head it reviewed. A head that only took
   main in had no builder APPROVE, so it waited on CI (`no builder APPROVE on
   this head and CI not known green`).

## What changed

- `bin/lib/patch-same.sh` `patch_same_fetch <git-dir> <reviewed> <head>
  [<pr-number>]`. After a failed combined fetch it fetches `<head>` alone, then
  `main` alone, then, with a PR number, `+refs/pull/<n>/head`. Success is
  `<head>` resolving to a commit. A head already fetched in this process is not
  fetched again. On failure `PS_FETCH_ERR` holds the first git error line, with
  `://user:pass@` masked as `://***@`, 160 bytes max.
- `bin/lib/builder-carry.sh` `bc_carry` (new). It carries a builder APPROVE on
  head A to head B when `patch_same` says B carries A's patch (`identical`,
  `main-merge` or `patch-id`). It writes no verdict row and no head-bound
  artifact. Settled answers are cached in
  `state/lead-review-enqueue/builder-carry.tsv`
  (`<epoch> <slug> <n> <A> <B> <carried <how>|refused>`). `bc_prune` deletes
  rows older than 7 days on every enqueue tick, the `delta.tsv` window.
- `bin/lead-review-enqueue.sh`: a carried head is approved, so the BH-5294
  replay runs on it. The carry does not stand if the verdict history is
  unreadable or the newest lead word on another head is a BLOCK. A carry that
  stands writes one `modes.tsv` row `builder-replay` (`from=<A12> how=<how>`)
  per head and logs `builder APPROVE carried from <A12> (how:<how>)`. If the
  head is still requested, the scope note says `auto: builder APPROVE carried
  from <A12> (how:<how>) on <sha12>`. The risk tier treats it as a head no
  reviewer approved (BH-5630): it signs it off only as a lead-authored low
  rules-text head.
- The tick summary line has two new fields after `replayed=`:
  `builder_replayed=<n>` (carries that stood this tick) and `fetch_failed=<n>`
  (PRs whose fetch failed this tick, once per PR).
- Worklist gates 10 and 50 (`bin/lib/lead-gates.d/`) apply the same rule. Gate
  50 sends a carried head with a lead BLOCK or an unread history back to gate
  10's CI rule and resets gate 10's globals (`LGB_APPROVED=0`,
  `LGB_CARRIED=0`, `LGB_REQFOR` = `CI green` or empty). Gate 10 sets
  `LGB_REQFOR` to the carry text, and gate 60 treats a carried head as one no
  reviewer approved, as the enqueue does.
- `lw_replay` and the conductor's `lead_carry` pass the PR number to the fetch
  and name `PS_FETCH_ERR` in their held lines.

## Measure

On the hub, per day, before and after the deploy:

```bash
grep -h ' tick repos=' /root/harness/logs/lead-review-enqueue.log* | grep -o ' replayed=[0-9]*' | sort | uniq -c
grep -h ' tick repos=' /root/harness/logs/lead-review-enqueue.log* | grep -o 'builder_replayed=[0-9]*\|fetch_failed=[0-9]*' | sort | uniq -c
```

The before number is 2,294 lines with `replayed=0`.

Verified by `tests/builder-carry-merge-only.bh-7043-test.sh`.
