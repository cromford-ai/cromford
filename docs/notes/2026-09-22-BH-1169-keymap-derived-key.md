# BH-1169 — triage-gate keymap: derive `<PREFIX>-<number>` when a board row has no `key`

What changed and why:

- project-4 board list endpoint returns `number`, not `key`. The fingerprint
  deliberately omits both for un-adopted boards, so `state/<project>.keymap.json`
  was empty and `bin/lib/ticket-identity.sh` source (a) never saw project-4 tickets.
- `bin/triage-gate.sh` now reads each board's own `keyPrefix` from the `/boards`
  discovery response it already makes, and derives `{id, status, key:
  "<keyPrefix>-<number>"}` rows from the raw listing before it is discarded.
- Derived rows are merged LEFT of board-sent rows in the keymap write, so a real
  `key` from an adopted board always wins — for the same ticket, and also when a
  derived key COLLIDES with a key the board sent for a DIFFERENT id. That
  collision is the one that matters: the client-court guard resolves a build key
  to a ticket id through this map, so losing it sends a build to the wrong
  ticket (the BH-1042 failure class). K8 in the suite pins it — swap the two `+`
  operands and it goes red.
- A row is "keyless" when `key` is absent, `null` or `""`. jq reads `""` as
  true, so the filter is `(.key // "") == ""`, not `== null`: a board sending an
  empty string has not named the ticket, and its `number` still does.
- Closed-status filtering (BH-1042) is shared across both derived and board-sent
  rows via jq `def open`.
- The fingerprint is untouched: `number` and `key` still do not reach
  `state/<project>.gate.json` for un-adopted boards.

Files changed:
- `bin/triage-gate.sh` — derive block inside the per-board loop; keymap jq merge.
- `bin/lib/ticket-identity.sh` — one comment line noting the derivation now fills
  the project-4 keymap gap.
- `tests/triage-gate-keymap-derived.bh-1169-test.sh` — new suite covering project-4
  object-wrapped listings, project-3 bare-array listings, board-sent-key precedence
  including the collision case, a byte-for-byte compare proving a key-bearing
  listing writes the same file as before, missing keyPrefix, the unchanged
  malformed-board failure path (differential against the marker-stripped gate),
  `key: ""`, fingerprint non-widening, and a mutation check that strips the
  derive block.
- `docs/verification-map/ticket-identity.md` — the keymap gap is recorded as
  closed and the remaining-gap count drops from three to two.

Doc: ticket-identity
