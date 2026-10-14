# BH-1655 — a merged split child wakes the next sibling on a polling board

Doc: EVENTS, board-dependencies

## What was broken

On an in-app board (project-1, project-2, project-3, project-4) nothing re-read a chained
split child after its earlier sibling's PR merged:

- `bin/unblocked-children.sh` exits for every in-app board. It reads
  GitHub `Blocked-by:` lines, and in-app boards have none.
- No in-app board serves `dependsOn`/`blocked` yet (BH-815), so the in-app
  release in `inapp_released_lines` never fires.
- A merged child's board status is `review`, so the fingerprint does not move,
  and `bin/triage-gate.sh` answers `SKIP no-change`.
- The queue PR-gate only reads PR numbers written into READY-QUEUE lines. A
  deferred child with no queue line is invisible to it.

On 2026-09-23 project-3's TK-202 waited from 12:28Z to 13:18Z behind a TK-201 whose
PR had already merged.

## How a split chain advances now

1. **The record.** The parent's RESULT line 1 is `DECOMPOSED k1,k2,...` in land
   order. Each child's RESULT line 1 is `PR_CREATED <url>` or `PR_MERGED <url>`.
   `bin/lib/split-chain.sh` reads only those files on the owning box, plus
   `state/<project>.keymap.json` for "is it still open on the board".
2. **Due.** A child is due when every EARLIER key in its parent's line is
   merged, it is in the keymap, nothing covers it (no PR/DECOMPOSED/ROLLOUT_FILED
   result, no build dir without a RESULT, build lock free), and it was not
   offered in the last `SPLIT_CHAIN_REMIND_S`. The first child is never
   released by this pass. Merged means a merged PR: `PR_MERGED`, the cache
   `state/split-chain/<p>/merged/<KEY>`, or a REST read of the newest
   `PR_CREATED` url on the project's own repo. A failed read counts as not
   merged and is not cached.
3. **The gate.** Step 1c of `bin/triage-gate.sh` (after the event wake, before
   the queue brake) writes `state/split-chain/<p>/offered/<KEY>`, appends the
   key to `state/split-ready-keys-<p>`, logs
   `SPLIT_READY <KEY> (after <dep>=#<pr>,...)` to `logs/<p>.log`, and answers
   `RUN split-ready`. GitHub-Issues boards skip it.
4. **The tick.** `split-ready` is scoped like `board-changed`: the live
   fingerprint is fetched first, then `inapp_released_lines` reads and deletes
   the keys file, re-checks each key, and adds
   `board split: UNBLOCKED <KEY> "<title>" (... split sibling of <PARENT> ...)`
   to the tick scope. The line tells the session to launch it per the queue
   rules, or to write `SPLIT_DEFER <KEY> :: <reason>` in its output if it does
   not.
5. **The wake (optional).** `bin/lib/wake-class-split-chain.sh` is a BH-1034
   wake class. With `wake-lanes-split-chain` armed, a push to an in-app
   project's repo makes the hub ask the owning box to run
   `run-triage.sh <project>` (at most once per 120 s per project). It does not
   touch `state/wake-<p>`, so the gate still decides. Without the flag, step 1c
   fires on the owning box's next cron tick.

## Switches

- Kill flag: `flags/split-chain-off`. The gate and the scope behave as before.
- Class flag: `bin/jobs-client.sh flag-set wake-lanes-split-chain on` (ships off).
- Knobs (`catalog/lanes.d/_lib.json`, lib `split-chain`):
  `SPLIT_CHAIN_REMIND_S` (21600), `SPLIT_CHAIN_LOOKBACK_S` (1209600),
  `SPLIT_CHAIN_MAX_LOOKUPS` (10 GitHub reads per pass).

## Known limit

"Open on the board" is the keymap. A board whose listing has neither a `key`
the keymap keeps nor a `keyPrefix` + `number` to derive one has no keys in
that file, and this pass stays silent there. Check with
`jq 'has("TK-202")' /root/harness/state/project-3.keymap.json` on the owning box.
