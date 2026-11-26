# BH-10102: fetch_log reads a 5 MiB window, takes a filter, and the lane-failure alert names the account

Date: 2026-11-25. Ticket: #10102.
Doc: FLY-POOL

## What was wrong

- `bin/fetch-log.sh` sent the last 16,000 bytes of a log (a `CAP=16000` literal). A RUNNER_EXHAUSTED alert 4 hours back in a 31 MB `ALERTS.log` was out of reach.
- The pool reap cut the RESULT line at 120 bytes (`DWHY`). The lane-failure alert stopped inside `runner=claude r` and never named the leased account.

## What changed

### `bin/fetch-log.sh <project> <which> <command_id> [match] [since] [until]`

An empty argument is "not set". `bcx_run` (`bin/lib/box-cmd-exec.sh`) reads `.match`, `.since` and `.until` from the `fetch_log` payload. It passes them only when one is set.

- `match`: a fixed string (case-sensitive, matched as plain text, so `class=account-exhausted(quota)` matches its own parens). A value written `/.../` is an ERE, run by awk. A back-reference, an ERE that does not compile, or a non-printable character is refused.
- `since`: lines at or after `<n>s|m|h|d` before now, or an ISO date or time (`2026-11-25`, `2026-11-25T09:37`, `2026-11-25 09:37:00Z`). No zone means UTC.
- `until`: lines before it (exclusive), same forms. It exists so that a `more` call can address lines older than the returned part.
- A line's time is the stamp at its start (`[?YYYY-MM-DD[T ]HH:MM[:SS]`). A line with no stamp takes the time of the line before it. With `since` set, lines before the first stamp are out.
- A bad input answers the `--error` envelope with `error:"bad_match"`, `"bad_since"` or `"bad_until"`, rc 0, and one `REFUSED: bad <field>` journal line. The match text never goes to the journal (`filter=1` only).

### Two knobs (`catalog/lanes.d/_lib.fetch-log.json`, seed rows in `worker/jobs/schema.d/202611251523-bh-10102-fetch-log-knobs.sql`)

| Knob | Row | Value | Ceiling |
|---|---|---|---|
| `FETCH_LOG_TAIL_BYTES` | `lib.fetch-log.fetch_log_tail_bytes` | 5242880 (5 MiB) | 16777216 (also in code) |
| `FETCH_LOG_RESPONSE_BYTES` | `lib.fetch-log.fetch_log_response_bytes` | 98304 (96 KiB) | 122880 |

A missing row gives the env value, else the code fallback (the same numbers).

- The window is the newest `FETCH_LOG_TAIL_BYTES` of the file (no filter) or of the filtered result (any filter). Only whole lines are kept. A single line longer than the window is sent as its last bytes with `line_cut:true`.
- The safe response size is 96 KiB. The beat travels as ONE argv string to `bin/beat.sh` and to `curl -d`. Linux limits one argv string to 131,072 bytes (MAX_ARG_STRLEN). The far-box result row caps `body` at 256 KiB. 96 KiB leaves room for the beat envelope. A 5 MiB beat could not travel today.

### The beat

The existing fields keep their meaning. `truncated` is true when any byte of the file (no filter) or of the filtered result was left out. New fields: `filter`, `window_bytes`, `matched_bytes` and `matched_lines` (filter only), `returned_bytes`, `returned_lines`, `omitted_bytes`, `omitted_lines`, `response_max_bytes`, `tail_max_bytes`, `line_cut`, `boundary_split` and `more`.

`more` is null when nothing was left out. Otherwise it holds the `fetch_log` arguments that return the left-out lines: the same `match` and `since`, and `until` set to the time of the first returned line. If the last left-out line has the same second as the first returned line, the returned lines of that second move to the left-out side, so no line falls between the two calls. If the whole returned part is one second, nothing moves and `boundary_split` is true. A log with no stamp on the first returned line has `more.until` null, and `more.note` says why.

### The pool lane-failure alert (`config/fly-pool.d/3400-pool-listing-and-reap.sh`, LANEFAIL arm only)

`LWHY` is the whole first RESULT line plus `account=<lease label>` (`MACCT`, sanitized to `[a-z0-9._-]`; `account=none` with no lease). It replaces the 120-byte `DWHY` in the two alerts, the `LANE FAILURE` say lines, the requeue reason, the spawn-hold reason and the `pool_deferred` status beat. Every other arm keeps `DWHY`.

## Not in this repo

The MCP `log_tail` tool and the console worker live in `cromford-console`. That tool must forward `match`, `since` and `until` into the `fetch_log` command payload. The box side here accepts them.

## Proof

- `tests/fetch-log-filter.bh-10102-test.sh` (knobs, 6 MiB windows for each `which`, a 30 MB ALERTS.log, filters, response fit, `more` round trip, `bcx_run`).
- `tests/fly-pool-lane-alert.bh-10102-test.sh` (the real `bin/fly-pool.sh` reap).
- `tests/fetch-log-test.sh` section 3 pins the old 16,000-byte edge through the knob.
