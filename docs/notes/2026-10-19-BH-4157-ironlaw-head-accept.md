# The iron-law ACCEPT as a jobs-DB row, writable from the console (BH-4157 slice C0)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

A head-bound iron-law ACCEPT is now also one row in the jobs DB `ledgers`
table. Before this, the only per-head ACCEPT was the empty file
`builds/<rec>/iron-law-accepted-<sha>` on the hub that ran the resolver.

- The row: kind `ironlaw-head-accept`, key
  `<owner/repo lowercased>#<pr>@<head40>`, status `accepted`, detail
  `{sha, source, reason, actor}`. `source` is `resolver`, `family` or
  `console`. The first ACCEPT for a head stands; a later write changes nothing.
- `bin/lib/ironlaw-carry.sh` has the helpers: `ila_key`, `ila_accepted`
  (rc 0 accepted, 1 no row for this head, 2 cannot say), `ila_put` (one
  claim statement), `ila_record_say` and `ila_gate`.
- `bin/merge-conductor.sh` and `bin/merge-sweep.sh` ask the DB when the scan
  found hits and no marker file answered. A row for this exact head unparks
  it. An outage or an unreadable row parks as before and logs
  `iron-law: DB accept UNVERIFIABLE on <h8> — parking as before`. The DB check
  needs no build record on the hub.
- `bin/blocked-resolver.sh` (the adjudicated ACCEPT) and
  `bin/lib/br/opt/family.sh` (the family carry) write the row after the marker
  file. A failed write logs `DB accept NOT recorded (the file marker stands)`
  and changes nothing else: no rung, no counter, no second adjudication.
- New worker routes `GET` and `POST /api/ironlaw-accept`
  (`worker/jobs/src/routes/ironlaw-accept.js`). The POST writes a row only when
  the conductor's `mc-merge-verdict` row holds that exact head on iron-law hits.
  A partial-scan hold (`iron-law: N file(s) not scanned`) is refused, because
  the conductor holds it whatever an ACCEPT says.
- The console PR page has an IRON-LAW HOLD panel with ACCEPT THIS HEAD (in-app
  modal, reason required) and the ACCEPT history. The coord proxy row is
  `console-ui/functions/_lib/coord-writes.d/7581-ironlaw-accept.js`.

## What did not change

- The marker file is still written and still read first. Slice C4 of #4157
  removes the file writer after this slice has run in prod.
- The BH-4474 fingerprint carry (`ironlaw-accept` rows) is unchanged. It runs
  after the new check; a DB ACCEPT sets the count to 0 first, as the marker does.
- Any signed-in console session can write an ACCEPT, the same as every other
  coord write row. The row records who did.

## Indexes and retention

No new table. Both reads use the `ledgers` primary key (kind, key): a point
lookup and a key range in one kind.
`worker/jobs/test/ironlaw-accept-indexes.bh-4157.test.js` runs EXPLAIN QUERY
PLAN on 50,000 seeded rows. The rows are one per accepted head. `ledgers` rows
are not deleted by `routes/retention.js`; the kind can join the BH-6774 archive
list through its settings row when an operator wants it archived.

## Still open in #4157

- C1: `state/blocked-resolver/` rungs, attempts and adjudications to DB rows.
- C2: `state/alerts/` alert-state dedup to DB rows, and the alerts view.
- C3: `state/remote-results/` to DB rows.
- C4: remove the `iron-law-accepted-<sha>` file writer and its readers.
