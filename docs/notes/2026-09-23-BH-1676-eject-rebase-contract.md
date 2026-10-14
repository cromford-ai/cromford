# BH-1676: the BH-1669 contract ships inert (two knobs, two stubs, a vocabulary)

Doc: MERGE-CONDUCTOR

## What changed

- `bin/lib/mc/log.sh` declares `MC_EJECT_REBASE` (default 1). Nothing reads it.
- `bin/lib/mc/queue.sh` has a `mc_dequeue_conflict <slug> <url> <head>` stub next to
  `mc_dequeue_reason`. It answers `""` with rc 0 and makes no read. Its header
  comment states what it will answer once BH-1669's ejection-rebase child fills it in.
- `bin/lib/pr-dep-gate.sh` has `pdg_ticket_enabled` (rc 0 unless
  `PR_DEP_GATE_TICKET=0`) and a `pdg_ticket_deps <slug> <issue>` stub that prints
  nothing with rc 0 and makes no read. No lane calls either. `pdg_hold` is unchanged.
- `docs/MERGE-CONDUCTOR.md` §8 gets both knobs in the flag table, marked reserved,
  and a subsection reserving the log lines, `MC_ATTEMPTS` marks and ledger detail.
- `tests/mc-eject-contract.bh-1676-test.sh` pins all of it through the production
  shim `bin/lib/merge-conductor-lib.sh`, including that no caller exists yet.

## Why

BH-1669 (ejection rebase + ticket-order hold) is split into five children. This is
Order 1: the names every later child imports, landed first so they do not collide.
The conductor, every merge lane and `pdg_hold` behave exactly as on main.
