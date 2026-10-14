# Alert-line wave 3: library and small-script writers (BH-2365, BH-2314.3)

Doc: ALERTS-STATE-MACHINE

## What changed

These writers now call `bin/alert-line.sh` instead of `echo … >> ALERTS.log`.
The text after the stamp is the same as before, and the stamp is the helper's
default `date -u '+%F %TZ'`, which is the format every one of these sites
already wrote. Each line now beats `{kind:"alert"}` when it's emitted, and the
poll-commands re-beat skips it by marker.

- `bin/lib/lane-caps.sh`: DAILY SPEND CAP and NOISE BUDGET.
- `bin/lib/gh-repo-token.sh`: the INVISIBLE repo line and the blind-ticks line.
  The `kind:"fleet_alert"` beat after each one is unchanged.
- `bin/tickets-snapshot-push.sh` (2), `bin/stale-owed-tickets.sh` (3),
  `bin/review-autopilot.sh` (1, fleet_alert beat kept), `bin/rebase-train.sh` (1),
  `bin/deploy-train.sh` (1), `bin/fly-dispatch.sh` (`fleet_alert()`, beat kept),
  `bin/fly-onboard.sh` (1).
- `bin/triage-gate.sh`: `gate-selfwrite.py`'s stderr used to be appended to
  ALERTS.log raw, with no stamp and possibly several lines. It now goes to a
  temp file, and when that file isn't empty the gate writes one line,
  `[triage-gate] <project> gate-selfwrite.py: <last 1500 bytes>`. This is the
  one site whose text changed, because a raw stderr dump can't be stamped as it was.

The two libraries find the helper next to their own copy first
(`<lib dir>/../alert-line.sh`), then fall back to `$HARNESS/bin/alert-line.sh`.
They pass `HARNESS=<their root>`, so the line still lands in the same
`logs/ALERTS.log`. Callers and tests source the repo copy of the library with
`HARNESS` pointing at a tree that may not carry the helper. When lane-caps
can't find the helper at all, the day flag isn't touched, so the alert
retries on the next call.

## Not converted, on purpose

- `bin/lib/page-critical.sh` carries `# alert-writer: by-design`. It is the
  CRITICAL page path. Its first line is written before the strict critical beat,
  and the other two are the fallback for when that beat failed. Putting the
  helper's own strict beat (up to 30 s) in front of a page, or right after a
  beat that just failed, would delay or duplicate the page. Its baseline file
  is deleted.
- `bin/heartbeat-reaper.sh` goes through one `reaper_alert` function. It uses
  the helper when `bin/alert-line.sh` is executable and otherwise falls back to
  one raw append. This lane pages when `bin/` is partial, and the helper may be
  the missing file. Its baseline drops from 2 to 1.

## Tests

`tests/alert-line-wave-lib.bh-2314-test.sh` drives the real library functions
with the real helper and a recording `beat.sh`. It asserts the exact text, the
`kind:"alert"` beat, the sent marker, the kept `fleet_alert` beat, and that the
repo copy of the library reaches the helper through its own path. W6 runs
`bin/stale-owed-tickets.sh` whole on an orphaned build dir and pins its
ORPHANED BUILD line the same way.
Fixtures that build a partial scratch `bin/` now copy `bin/alert-line.sh`, and
the few that count every recorded beat now count by kind. Those edits are
marked `TEST-CHANGE: BH-2365`.
