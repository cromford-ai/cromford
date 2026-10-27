# A per-PR hold label for the blocked-resolver (BH-8474)

Doc: MERGE-CONDUCTOR

## Problem

`bin/blocked-resolver.sh` had no per-PR hold. On 2026-10-25 and 2026-10-26 it
closed three PRs as ABANDONED while a person or a Mac agent was fixing them:
example-org/project-6#2606 (18:02Z 10-25), example-org/project-6#2620 (02:15Z) and
example-org/cromford#7752 (07:21Z). Each one had to be reopened by hand.

The only hold the lane read was the ticket's HOLD comment (`br_hold_gate`).
That hold needs a ticket key and a comment on the issue.

## What changed

All new logic is in `bin/blocked-resolver.d/bh-8474-pr-hold.sh`. The driver
has two call sites.

1. **The label.** Put the label `resolver-hold` on the PR. While the label is
   on an open PR, the resolver runs no rung on it: no fix round (the hub does
   not queue or adopt one), no mechanical rung, no rebuild, no close. Each tick
   writes one log line:
   `PR HOLD — <url> carries label resolver-hold (seen since <time>, expires in <s>s) — no fix round, no rung, no close`.
   - `br_one` calls `prh_gate` directly after the unchanged-skip check. A held
     row returns rc 3 (no rung, no PER_TICK slot). It never calls `br_quiet`,
     so the unchanged-skip never hides a held row.
   - `br_abandon` calls `prh_close_gate` before `zr_close_gate` and
     `br_head_gate`. A held PR is rc 5: nothing closed, nothing recorded. This
     covers every `br_abandon` caller.
   - The match is exact and case-sensitive. `resolver-hold-off` and
     `Resolver-Hold` do not hold.
   - A PR read that fails holds the row for that tick (one line).
2. **The expiry.** The hold lasts `BR_PR_HOLD_TTL_SECS` (default 86400 s,
   24 h), measured from the first tick that saw the label (`pr_hold.since` in
   the resolver record). At expiry the resolver writes `pr_hold.alerted`, then
   sends ONE alert (id `br-pr-hold-expired:<slug>#<n>:<since>`), and processes
   the PR as normal. The label stays on the PR. The resolver never writes to
   GitHub for a hold.
3. **The label is removed.** The next tick clears `pr_hold` and writes
   `PR HOLD — lifted on <url>`. The ladder goes on with its counters intact.
4. **Human-push grace, 60 minutes.** BH-8328's HUMAN-PUSH DEFER already
   defers a close while a person's commit on the reset head is younger than
   `BR_HUMAN_PUSH_SETTLE_SECS`. Its default is now 3600 s (was 1800 s).

## Knobs

All in `catalog/lanes.d/blocked-resolver.knobs.d/`:
- `BR_PR_HOLD_LABEL`: default `resolver-hold`. Only `[A-Za-z0-9._:-]` is
  accepted; another value falls back to `resolver-hold` with one line.
- `BR_PR_HOLD_TTL_SECS`: default 86400, 0 = the label is not honoured.
- `BR_HUMAN_PUSH_SETTLE_SECS`: default 3600 (BH-8328), 0 = off.

`BR_OPT_OFF=bh-8474-pr-hold` turns the whole hold off.

## How to use it

1. Add the label `resolver-hold` to the PR on GitHub.
2. Check the hub log: `grep 'PR HOLD' /root/harness/logs/blocked-resolver.log`.
3. Remove the label when the fix is pushed.

## Cost

The label read is the `repos/<slug>/pulls/<n>` GET that `br_one` already makes.
The per-run read memo (`bin/lib/br/opt/readmemo.sh`) answers it, so it costs 0
extra REST calls when the memo is on. The record is written once when the label
is first seen, once at expiry and once when the label is removed.

## Tests

`tests/blocked-resolver-pr-hold.bh-8474-test.sh` drives the real driver with a
fake `gh` and a fake fix-round worker (P1-P3, P7, P13), and the fragment and
`br_abandon` directly (P2, P4-P12).
