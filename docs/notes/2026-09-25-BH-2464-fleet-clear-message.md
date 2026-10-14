# quota-status: a fleet-only clear says it cleared the fleet cooldown

Doc: ACCOUNT-ROUTING

`bin/quota-status.sh --clear-cooldown <vendor> <account>` clears this box's
cooldown file and the fleet row (BH-2355). When there was no local file but the
fleet row was there, it printed `no cooldown for claude/a (fleet row cleared)`
and exited 0. The line said there was nothing to clear and that it had cleared
something.

That case now prints `cleared the fleet cooldown for claude/a`. The rc (0) and
the operator log line in `logs/failovers.log` are unchanged. Every other
outcome prints what it printed before:

- file and row: `cleared cooldown claude/a (...) (fleet row cleared)`, rc 0
- nothing on either side: `no cooldown for claude/a (no fleet row)`, rc 1
- no fleet reachable, no file: `no cooldown for claude/a (fleet not reachable)`, rc 1

Pinned by `tests/quota-status-fleet-clear.bh-2464-test.sh` and case 4 of
`tests/account-cooldown-fleet.bh-2319-test.sh`.

The ticket also asked that a fleet row with a malformed box id log its
`skipping fleet row` line once per row instead of on every
`bin/lane-reprobe.sh` tick until the row expires. `seed_fleet()` now keeps the
ids it has already logged in `state/lane-reprobe-skipped.txt`, rewritten each
tick to the malformed ids still live. An id logs once, and again only after its
row is gone and a new one appears. A well-formed row is seeded exactly as
before. Pinned by `tests/lane-reprobe-skip-once.bh-2464-test.sh`, red on the
code before this change (three ticks, three lines).
