# TRIAGE-STATE for PRs: the pre-check body (BH-3417 slice 2)

Doc: TRIAGE-STATE

BH-3419, part 2 of 3 of #3417. The contract slice (BH-3418,
`docs/notes/2026-09-29-BH-3417-pr-triage-state.md`) wired `ts_pr_precheck`
into `ts_tick` as a stub. This slice fills it in, so the `board prs:` lines of
a tick are decided before a model call. Slice 3 (#3420) records a PR shard's
verdict against the hash; until it lands a stored PR row has no
`verdict_hash` from a session, so most open PRs still decide `llm new`.

## What runs

`ts_pr_precheck <project>` (`bin/lib/triage-state-pr.sh`), called by `ts_tick`
right after the ticket pre-check:

1. Returns with the defaults and reads, writes and logs nothing when
   `PR_STATE_MODE` is `off`, the tick names no `board prs:` line, or the board
   fingerprint (`state/<p>.gate.pending`, else `gate.json`, read directly, so
   it runs even with `TRIAGE_STATE_MODE=off`) has no `issues`.
2. `_ts_pr_keys`: the `pr-<n>` key and verb of every `board prs:` line in
   `TICK_SCOPE` and `BOARD_SEC`, keyed by `triage_shard_key` exactly as the shard
   loop keys them. The last verb wins.
3. Per key, with the open-PR list (`_ts_prs_json`, shared with `_ts_owned`):
   - a list row whose title matches `^merge queue: ` or whose branch starts
     `mergify/merge-queue/` (`triage-state-pr.py pr-draft`) is `draft`: no read,
     no row;
   - `REMOVED`, or not in the (100-capped) list: one `triage-gate.sh --thread`
     read. A draft title is `draft`; `closed` goes to `decide` as a closed entry
     (`stamp closed-on-board`, the `closed_stamp`-salted hash); open or unread
     is hash `-`. Absence from the list is never terminal;
   - open with a row: one thread read, one `pulls/<n>/reviews` read and
     `vd_standing` on the head (rc 1 = `none`, anything else = unhashable),
     then `triage-state-pr.py pr-hash`;
   - list unreadable and not `REMOVED`: hash `-`, no read.
   Every thread read counts once against `TRIAGE_STATE_MAX_FETCH`, on its own
   counter (the ticket pre-check has its own); `_ts_gh_budget_low` stops all
   reads. Any failed read, or the cap spent, is hash `-` (`llm unhashable`).
4. Rows by `triage_state_get` per key (never the list). A failed get makes
   every row unreadable: `llm rows-unreadable`.
5. `bin/triage-state.py decide` (unchanged) over `pr-hashes.tsv`, with
   `--decisions /dev/null` (a ticket-era DECISION line cannot seed a PR).
   `candidate` becomes `skip unchanged:buildable`: a PR key is never enqueued.
   A closed key with no line (its row is already `closed`) is `skip terminal`.
6. `pr-decisions.tsv` (key, key, decision, reason, hash, seed, 1, -); rows
   written by `_ts_observe` with `last_mode` = the PR mode, drafts left out.
7. `TS_PR_READY=1`, `TS_PR_SKIPSET` = the keys decided skip, stamp or draft,
   `TS_PR_DRAFTS` = the drafts. The decision pass failing leaves READY 0.
8. One lane-log line:
   `triage-state-pr <mode>: <n> PR(s), <k> to the model: <keys>, <s> unchanged, <t> stamped terminal: <keys>, skipped|would skip <d> mergify draft(s): <keys> [reads=<nf>]`.
   `skipped` only when `ts_tick` will act on it: enforce on one of the enforce
   gate reasons. Everything else says `would skip`.

## The hash

`pr-hash` is the sha256 of canonical JSON
`{v:"pr1", head, state:"OPEN", labels, mq, reviews, lead, last_comment}`:
`head` lowercased; every label name (ours included, sorted); `mq` from
`mergify_state` (the newest `mergify[bot]` comment with a Mergify payload: its
`state`, `unparseable:<sha[:16]>` for a payload that does not parse, null for
none); the latest `[login, state]` per reviewer among reviews on the head;
`lead` the lead file verbatim; `last_comment` the id of the newest comment
`triage-signal.py gh()` keeps (our App's comments dropped, the same rule the
ticket hash uses). Any unreadable shape is rc 1.

## Tests

`tests/triage-state-pr-precheck.bh-3419-test.sh`.
