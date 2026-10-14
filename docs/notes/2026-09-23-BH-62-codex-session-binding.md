# A codex-driven call reads its own session ledger, not the newest one

Doc: COST

## What was wrong

`bin/codex-usage.sh` found a call's tokens by taking the newest codex session
file touched since the call started. With two metered calls on one box, call A
could finish after call B had written a newer session. A's cost row then carried
B's tokens, and B's spend was counted twice. The openrouter and fireworks lanes
are the tier-3/3b survival lanes, and those lanes tend to fail at the same time,
so concurrent calls are the normal case during an outage (issue #62).

## What it does now

`codex exec` prints a `session id: <uuid>` banner on stderr, and each lane
already captures that stream to `$OUT.err`. The new `codex_session_id` in
`bin/agent-call.sh` reads the first line-start match. The codex, openrouter and
fireworks lanes pass it as the new third argument:
`codex-usage.sh <t0> "" <session-id>`.

`codex-usage.sh` now behaves three ways:

- **An id is given and a file carries it.** It reads only that file. The file
  counts as the call's own if its name is `rollout-<ts>-<id>.jsonl` or its first
  line is a `session_meta` record with `payload.id == <id>`. There's no mtime
  filter, because the id proves which call owns the file.
- **An id is given but no file carries it.** It prints blank fields. The row
  goes out unpriced and the existing `[cost-parity] UNPRICED` alert fires.
  Leaving it blank is better than borrowing another call's count, because
  borrowing is the exact misattribution this fixes.
- **No id is given** (no banner, or a direct caller). It uses the old
  newest-since-T0 heuristic, byte for byte. That path can still misattribute
  under concurrency, and the script header says so.

## Not covered

- The banner format and the `rollout-<ts>-<id>.jsonl` naming come from strings
  in the installed codex 0.156.1 binary. They haven't been checked on a live
  run. A live-lane re-canary is still what proves a priced row end to end.
- The codex lane's `codex_seen_model` session-file argument still uses
  `find -newermt | head -1`, so the model label can race in the same way.
  That's out of scope here.

Test: `tests/codex-usage.bh-62-test.sh`.
