# review-prs, the conductor and the resolver share the per-head review key (BH-3940)

Doc: CALL-GUARD

## What changed

Slice 4 of BH-3930. Three review lanes now buy on guard stage `review-head`
(K=1) under the shared key `review:<repo>#<pr>@<head sha>[~reason]`, and each
asks `review_bought` (`bin/lib/review-bought.sh`) before it pays.

- `bin/review-prs.sh`: a hit records `{sha, verdict, reused_from}` in its
  state file, logs `review_skip_unchanged`, runs `merge_retry` and buys
  nothing. The check runs before the in-flight charge and the claim row. A
  re-review request buys under `~rereq` and a step-up under `~stepup`; neither
  is ever skipped. Their log lines carry `REREVIEW_REASON=`.
- `mc_rereview` (`bin/lib/mc/rebase.sh`): the new key and stage, and after a
  parsed verdict one `pr_attempts` row `rrverdict` = `<head> <WORD> <epoch>`,
  written whether or not pr-state rows are on. A put that fails is one log line.
  `mc_rereview_spawn` passes `MC_RR_REASON=noverdict` after a `failed` job (or
  the `rereviewretry` marker that replaced its file); a refused `~noverdict`
  claim is said once per (PR, head) (`rrnvdefer`).
- `bin/lib/mc/classify.sh`: `# >>> conductor bound-verdict consume` asks
  `review_bought … --except-builder` in `moved` mode. Approve on a green head
  (or `rrnoci`) rebinds through `hb_approve_bind`; block parks through
  `hb_block_park`; both write `rbverdict <key> <head>`. Anything else spawns as
  before.
- `bin/blocked-resolver.sh` (`# >>> br rereview post`): a hit skips `br_count
  llm` and `mc_rereview`, posts "Re-review not bought: …", records tag `reused`
  with no counter bump. A miss buys under `~preflight` or `~brnv<n>`.

`review_bought` is still the contract's stub (always a miss), so until the
reads sibling lands only the key, stage, `rrverdict` row and reasons are live.

## How to check

`bash tests/review-dedupe-lanes.bh-3940-test.sh`.
