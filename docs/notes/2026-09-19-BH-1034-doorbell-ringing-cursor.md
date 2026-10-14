# Doorbell ringing from a `wakes` SELECT, and a cursor that survives a rebuild

Doc: EVENTS

**What changed (BH-1063, BH-1034.4).** Two small things, both about reading
evidence we already store instead of guessing.

## 1. A repo that has RUNG is armed (audit #35)

`bin/doorbell-coverage-check.sh` used to answer "is this repo's doorbell armed"
only by listing its webhooks. Our PAT cannot list hooks on several fleet repos,
so those repos alert `UNREADABLE` every day even when their doorbell is
demonstrably working — and the one alert that matters sits in a pile of ones
that do not.

Rows in `wakes` can only come from a live hook, so the table answers the same
question with better evidence and without spending a GitHub call.

- **Worker:** `GET /api/wakes/summary?hours=<n>` — bearer-authed like its
  neighbours, read-only, no schema change.
  `SELECT repo, COUNT(*) n, MAX(at) last_at, GROUP_CONCAT(DISTINCT kind) kinds
  FROM wakes WHERE at >= ?1 GROUP BY repo ORDER BY repo ASC`.
  `hours` clamps to 1..168 and defaults to 24; the answer is
  `{repos:[{repo,n,last_at,kinds}], since, hours, as_of}`. An empty table is a
  200 with `repos: []`, never a 404 — "nobody rang" is an answer.
- **Client:** `wakes_summary [hours]` in `bin/jobs-client.sh` prints TSV
  `repo n last_at kinds`, and the CLI verb is
  `bin/jobs-client.sh wakes-summary [hours]`. Every failure — transport, 5xx,
  and the 404 of a worker that predates the route — is rc 1 with EMPTY stdout.
- **Check:** `ring_state <slug>` answers `ringing` / `silent` / `unknown`. It
  fetches the summary ONCE per run and answers every repo in the registry from
  that one request. The slug match lowercases both sides and compares the whole
  slug, so `example-org/project-3` never rings `example-org/project-3`.

A `ringing` repo is reported `<repo>: doorbell armed (ringing, N wakes/24h,
last <at>)`, writes no alert, and its hooks are not read at all. `silent` and
`unknown` fall through to today's `doorbell_state` path unchanged — an outage is
not silence, and must never be able to suppress an alert.

Log: the per-repo line gains `ring=<state>` (and `n=`/`last=` on the ringing
path); the summary line and stdout gain `ringing=<n>`.

`DOORBELL_RING_H` sets the window in hours (default 24) and is named in the
script's Overrides header. It is an operator env knob like the script's existing
`JOBS_URL`/`HARNESS` overrides, not a `settings` row: a 24h window read once a
day does not need to change without a deploy.

## 2. The wake cursor is mirrored into `settings` (audit #15)

`state/wake-cursor` is the ONLY thing that stops a redelivered row from
re-launching a paid lane, and it stays that way. A box rebuilt or restored
without `state/` came back with no watermark and re-drained everything.

- `bin/wake-loop.sh` `drain()` writes the file first, exactly as before, then
  mirrors it: `setting_set "wake-cursor.$JOBS_BOX" "$top"`, fire-and-forget
  (`>/dev/null 2>&1 || true`, guarded by `command -v setting_set`). The ack
  still follows. Order is file → settings → ack, so "row written but file not"
  cannot happen and "file written but row not" is the designed degraded state.
- At startup, if `$CURSOR` is unreadable or holds no digits and
  `setting_get "wake-cursor.$JOBS_BOX"` answers a number, the loop seeds the
  file from it and logs `cursor seeded from settings: <n>`. It writes then logs,
  so the line never claims a seed that did not land. A readable file always
  wins; a non-numeric settings value is refused, not written.
- A settings outage changes nothing: same poll, same cursor file, same ack.
  `wakes.acked_at` stays housekeeping.

One caveat worth knowing: `_setting_key_ok` allows `[a-z0-9_.-]` only, so a box
whose `JOBS_BOX` carries an uppercase or exotic character never writes a mirror
and never finds one to seed from. The loop is unaffected either way.

Note that a box with no watermark at all polls `?since=0` today (drain() floors
an unreadable cursor at 0) — the seed does not change that path, it just means
a restored box usually has a watermark to send.

## QA on the hub (after the worker is deployed)

```
bin/jobs-client.sh wakes-summary 24
bin/doorbell-coverage-check.sh
```

The first prints one TSV row per repo that rang. The second prints
`<repo>: doorbell armed (ringing, N wakes/24h, last <at>)` for those repos,
`checked=… ringing=<n>` on the summary line, `ring=` on every line of
`logs/doorbell-coverage-check.log`, and no new `[doorbell]` alert for a ringing
repo.

## Tests

- `worker/jobs/test/wakes-summary.bh-1034.test.js` — `schema.sql` applied into
  `node:sqlite`, so the real SQL runs.
- `tests/doorbell-ringing.bh-1034-test.sh`
- `tests/wake-cursor-writethrough.bh-1034-test.sh`
