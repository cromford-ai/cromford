# The queue-gates brake lets new tickets through (BH-9885)

**What it is:** step 2 of `bin/triage-gate.sh` (queued build work). When the
queue bytes and the state of every PR the queue lines name are unchanged, the
gate answers `SKIP queue-gates-unchanged`. That SKIP exits before step 6 (the
board diff). On project-3, 2026-11-21, it held nine new tickets (TK-791..799) for
up to 4 h behind three PR-blocked queued tickets.

Before that SKIP, the gate now fetches the live board fingerprint (the same
read step 6 makes) and calls `tgu_untriaged_rows` in
`bin/lib/triage-gate-untriaged.sh` on the consumed fingerprint
(`state/<p>.gate.json`) and the live one. A row is a trigger when it is NEW
since the consumed fingerprint, or when it MOVED and its `triageVerdict` is
null or empty. `prs`, `meta` and CLOSED rows are never triggers.

- Trigger found: the gate writes `state/<p>.gate.pending` and answers
  `RUN board-changed`. `bin/lib/rt/scope.sh` (board-changed arm) diffs
  gate.json against gate.pending with `bin/gate-diff.sh`, so only the moved
  tickets reach the session. `state/<p>.queuefp` is not written, so the next
  tick SKIPs the queue again.
- No trigger, no gate.json, a failed fetch or an unreadable answer: the SKIP
  line as before, and no file is written.

The hard recheck is a knob: `QUEUE_GATE_HARD_RECHECK_S` on lib id
`triage-gate` (`catalog/lanes.d/_lib.triage-gate.json`). Settings row
`lib.triage-gate.<project>.queue_gate_hard_recheck_s` (or
`lib.triage-gate.queue_gate_hard_recheck_s`). Code fallback 14400. Junk, or a
value under 2700, reads as 14400.

**How an operator reaches it:** it is not a screen. The lane is
`bin/run-triage.sh` → `bin/lib/rt/gate.sh` → `bin/triage-gate.sh <project>`.

**How to check it on a box:**

1. Confirm the queue is PR-gated: `state/<p>.queuefp` holds 3 lines.
2. Run `bin/triage-gate.sh <p>` while a new ticket is on the board. It prints
   `RUN board-changed`.
3. Run `grep 'gate=board-changed' logs/<p>.log` to see the tick that ran.
4. Run `bin/triage-gate.sh <p>` with no new ticket. It prints
   `SKIP queue-gates-unchanged (... hard recheck in Nm)`.

**Suite:** `tests/triage-gate-untriaged-wake.bh-9885-test.sh` (R1-R15 the
decision rule, U1-U4 the real gate and `bin/gate-diff.sh` on a stubbed in-app
board, K1-K4 the knob).
