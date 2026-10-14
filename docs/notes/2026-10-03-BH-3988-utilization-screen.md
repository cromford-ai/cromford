# utilization: the Mission Control screen (BH-4011, slice 4 of BH-3988)

Doc: VERIFICATION-MAP

## What changed

Mission Control has a UTIL tab (right after CI) at `/utilization`. It shows
one row per fleet.conf project from the newest hourly snapshot that
`bin/utilization-push.sh` writes (BH-4008), read through the coord proxy as
`GET /api/coord/utilization` every 60 s. No new Pages Function: the proxy
forwards any GET.

- `console-ui/src/api.js`: `api.utilization()`.
- `console-ui/src/lib/utilization.js`: `utilizationRows(resp, fleetProjects, now)`.
  A project with no snapshot is the row `no snapshot`. A snapshot older than
  2 h (or with an unparseable `as_of`) is `stale`. A bucket counts only when
  it is a non-negative integer (`pool_cap`/`free_slots` may also be
  `"unlimited"`), so anything else renders `—` and never 0. Snapshots for
  projects outside fleet.conf are named in a footnote, not dropped silently.
  A body without a `rows` array is an error, never an empty fleet.
- `console-ui/src/screens/Utilization.js`: the table, sorted by verdict
  severity (starved first), and a PAYLOAD panel under it when a VERDICT is
  clicked (pauses, basis, raw payload).

## Why the VERDICT title is not the collector's why

`util_verdict` computes a why, but `bin/utilization-push.sh` does not store
it. The screen uses `payload.why` when a section stores one, and otherwise a
fixed sentence per verdict plus the buckets `basis` marks `unmeasured`.

## What today looks like

Only the builds section has shipped, so every row reads `unknown` with
READY..PARKED, PAUSES and PRS as `—`. The siblings that add those sections
fill the columns without a console change.
