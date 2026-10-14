# TRIAGE-STATE for PRs: a PR shard records its verdict (BH-3417 slice 3)

Doc: TRIAGE-STATE

BH-3420, part 3 of 3 of #3417. It builds on the BH-3418 contract
(`docs/notes/2026-09-29-BH-3417-pr-triage-state.md`) and reads the
`$d/pr-decisions.tsv` file that contract defines. Nothing writes that file yet
(the PR pre-check body is a separate slice), so today a PR shard records
nothing, exactly as before.

## What changed

- `bin/lib/triage-state.sh`: `_ts_dec_file <key>` names the file holding a
  key's decisions line, `pr-decisions.tsv` for a `pr-*` key and
  `decisions.tsv` for everything else. `ts_hash_of` and `ts_shard_hash` read
  through it. The shard snapshot still stores the line as `decisions.tsv`, so
  `ts_after_session` is unchanged and a PR shard gets the same #3347 snapshot
  and nonce handling a ticket shard gets: it stamps the pre-dispatch hash even
  when a later tick has rewritten `pr-decisions.tsv`.
- `bin/triage-state.py record`, only when `--key` starts with `pr-`:
  - a `DECISION` whose raw key is `pr-<n>` (any case), `#<n>` or `<n>`, with
    `<n>` equal to the PR's number, counts for the shard. `canon_key` folds all
    three onto `<n>`, which is not the shard's key, so before this the line
    never matched. `canon_key` itself is unchanged (the decisions.log backfill
    shares it).
  - `dec0` is the snapshot line's decision column instead of a hardcoded
    `llm`. The existing `has_effect` rule then scores it: a PR the pre-check
    would have skipped (`skip unchanged:<verdict>`) whose DECISION changes the
    verdict logs `triage-state shadow: would-have-missed`, and one that does
    not logs `model-noop-on-skip`.
- PR rows are PUT to `triage_state` as `ticket_key = pr-<n>`. Nothing reads
  them yet, and the key space cannot collide with a ticket's `<n>`.

## Not changed

Ticket shards still pass `dec0 = "llm"`, so a ticket shard never scores a
miss. That is a known gap, left for a follow-up.

Test: `tests/triage-state-pr-record.bh-3417-test.sh`.
