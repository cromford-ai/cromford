# BH-8918: name guard and the hosted Board API (BH-7913 wave 1 of 6)

Doc: HOSTED-BOARD, PRODUCT-BOARD-PROVENANCE, BOARD-API-CONTRACT

## What changed

- New rules-pack component `name-guard` (`catalog/rules-pack.tsv`, suite
  `tests/name-guard.bh-8918-test.sh`). `bin/name-guard.py` reads the lines a
  diff adds and refuses a deny term outside an allow-listed path. The lists are
  `catalog/name-guard.d/`: two deny files and `allow.txt`. The tracker deny file
  applies only to the hosted board's own files (its `scope:` lines). Rename
  detection is on, so a moved file's unchanged lines are not "added".
- `docs/PRODUCT-BOARD-PROVENANCE.md`: nothing copied; every new product noun
  gets a knockout-search note in its PR.
- The jobs worker serves the Board API at `/api/hosted-board/<project>/`
  (`worker/jobs/src/routes/hosted-board.js`, an OPEN family with its own token
  check; HARNESS_SECRET is refused there). The gated family
  `hosted-board-admin` sets up a board and issues or revokes a token.
  `bin/jobs-client.sh hosted-board-token` calls it and prints the token once.
- Six tables in `worker/jobs/schema.d/202611040340-bh-8918-hosted-board.sql`,
  with an index per query and eight settings rows (six knobs, two retention
  windows). Retention rules `hosted_board_events.age` and
  `hosted_board_idem.age` delete after 180 days. Tickets and comments have no
  rule.
- `bc_probe_origin` takes the board prefix as a 5th arg. Under
  `/api/hosted-board/` the two internal items are `unverified` and not probed.
- Empty seams for waves 2-6: three route modules, five console-ui modules,
  `bin/hosted-board-intake.sh` and the lane `board-intake` (gated, no cron line).

## Choices a reviewer should know

- The list index is `(project, board_id, updated_at, id)`, not the ticket's
  `(project, board_id, status, updated_at)`. The list has no status filter, so
  with status in the middle SQLite chose the number index and sorted the whole
  board. The chosen index reads one page and needs no sort
  (`worker/jobs/test/hosted-board-explain.bh-8918.test.js` E1).
- The `board-intake` lane is wired (it runs the lane gate), not `wired: false`
  as the plan said: `tests/lanes-registry-test.sh` check 12a refuses an unwired
  lane this repo owns. It has no cron fragment, so nothing schedules it.
- A bad token answers 401 (the ticket), not 404.
- The list is a page of `hosted_board.list_page_max` (500) with `nextCursor`.
  Lanes read the first page only.
