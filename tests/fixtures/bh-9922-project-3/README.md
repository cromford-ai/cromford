# tests/fixtures/bh-9922-project-3 — the 2026-11-23 project-3 pool queue (BH-9922)

- `queue/TK-815.json` .. `queue/TK-840.json`: the seven rows that stood down
  behind TK-797 (PR #1326) at 18:16-18:22Z. They carry `after_on`, as the reap
  writes it after BH-9922 (the recorded rows had only `after`).
- `queue/TK-810.json`: the row from 2026-11-22 that waited on TK-776. The owner
  archived TK-810 on the project-3 board at 15:20Z on 2026-11-23.
- `board-tickets.tsv`: the board class of each ticket, for the
  POOL_TICKET_LIVE_FILE seam (bin/lib/pool-ticket-live.sh). TK-810 is archived.
- `pr-1326-files.json`, `schema.prisma`, `plan-TK-815.md`, `plan-TK-826.md`:
  the overlap side (tests/plan-overlap-additive.bh-9922-test.sh).

Ticket ids are made-up cuid-shaped ids, not the real board ids.
