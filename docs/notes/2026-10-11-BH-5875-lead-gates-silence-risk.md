# Silence, risk tier and in-build grace gates on the lead review worklist (BH-5875, child 3 of #5870)

Doc: LEAD-REVIEW

## What changed

- Three gate files in `bin/lib/lead-gates.d/`, run by the loader
  `bin/lib/lead-gates.sh` (BH-5873) for a worklist head with no request row:
  - `30-silence.sh` (gate 9 of the enqueue, BH-5797). It runs `ss_gate` on the
    head's compare. A public-leak marker gets the `needs-human` label and one
    comment, then rc 10 and one `[skip silence]` line. A lead-route marker is
    rc 11 (held), see "Not done here".
  - `60-risk.sh` (gates 4 and 6, BH-5022, BH-5325, BH-5024). Under
    `risk_tier.mode` shadow or enforce it classifies the head. A low head under
    enforce is posted through `bin/lead-verdict.sh post ... MERGE --source
    risk-tier` first; post rc 0 or 4 is rc 12 (no review), rc 5 is a full
    review, any other rc is rc 11. The JEV shadow runs inside it, as in the
    enqueue.
  - `70-inbuild-grace.sh` (gate 5, BH-5023). A medium head under enforce is
    held (rc 11) until the grace is spent.
- One new lib, `bin/lib/lead-gates-compare.sh`: `lgc_compare` reads the
  compare against the default branch once per head and tick, and shares
  gate 15's default-branch cache, so a tick still reads `GET repos/<slug>` once.
- The gates use the enqueue's state at the same paths
  (`state/lead-review-enqueue/silence/`, `risk.tsv`, `risk-pub-*`,
  `inbuild-wait-*`, `requested.tsv`). A head either lane classified or scanned
  is not classified or scanned again by the other.
- Every failed read or write is rc 11 (held), never a review and never a
  sign-off.

## Not done here

- A head with lead-route silence markers is held on the worklist. The
  enqueue's request carries the markers in its notes, and the dispatcher
  reviews that request row. A worklist start carries no notes (`review_one`
  reads only the request row's `scope_notes`), so the hold stays until the
  retirement child of #5870 gives the worklist a notes path.
- The risk-pub retry (republish a risk-tier status after post rc 4) stays in
  the enqueue, which reads the marker this gate writes.
- Nothing changes in prod until an operator sets `LEAD_REVIEW_WORKLIST=1`
  (default 0). No new knob, setting, lane or schema.
