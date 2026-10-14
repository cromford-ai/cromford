# The triage gate's state has a ledger twin, so a moved box does not re-buy a triage

Doc: DB-COORDINATION-SPEC

## What was wrong

The triage gate kept its per-project state in three files on one machine:
`state/<p>.gate.json` (the consumed board fingerprint), `state/<p>.gate-meta` (the full-sweep
clock) and `state/<p>.gate.fail` (the BH-1021 failure counter). A project that moved boxes, or
a rebuilt box, had none of them. The gate answered `RUN daily-sweep` (no gate-meta) or
`RUN no-gate-state` (no gate.json) and bought a full triage session on an unchanged board. A
failure streak also restarted at 1.

## What changed

`bin/lib/triage-gate-ledger.sh` mirrors that state into `ledgers`, kind `triage_gate`, through
`bin/lib/ledger-twin.sh`:

| key | status | written by |
|---|---|---|
| `<project>` | `<sha256 of gate.json> <gate-meta epoch>` | `triage-gate.sh --seed`, the two absorb paths in `triage-gate.sh`, `rt_gate_consume`, `triage_shard_rearm` |
| `<project> fail` | `<sha16\|none> <n>` or `cleared` | `rt_gate_fail_consume` (count, and `cleared` at the cap), `rt_launch` on rc=0 (`cleared`) |

The row holds the fingerprint's sha, not the fingerprint. `ledgers.status` is cut at 128 chars
and `detail` at 4000 (`worker/jobs/src/routes/ledger.js`); a real fingerprint is ~135KB. When
the live board hashes to the row's sha, the live fingerprint is the consumed file byte for byte,
so the gate writes it back and answers `SKIP no-change (N tickets, gate restored from ledger)`.
Any other answer keeps today's `RUN no-gate-state`, and nothing is written.

The reads happen only when the file is absent: `gate-meta` before the daily-sweep check,
`gate.json` before the no-gate-state check, `gate.fail` before counting a failure. Hydration
never overwrites a local file. A miss, an outage, a malformed row or the flag being down reads
as "nothing there", which is today's answer. A write is file first, row second, and a failed
write is rc 0. `triage_shard_rearm` writes the row after its sidecar lock is released.

`state/<p>.gate.pending` has no row. It is written and consumed inside one tick.

## Activation

Dark until the `no-twin-ledgers` flag is up, the same flag as the other BH-1036 kinds:

    bin/jobs-client.sh flag-set no-twin-ledgers on "<reason>"

With the flag down every function in the lib makes no request. Probe once it is up:
`bin/jobs-client.sh ledger-get triage_gate <project>` should print `<64 hex> <epoch>`.

## Test

`tests/triage-gate-ledger.bh-2318-test.sh`.
