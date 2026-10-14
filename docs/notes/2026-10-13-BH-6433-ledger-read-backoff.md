# The autoenqueue ledger read retries on a 2 s / 5 s / 10 s ladder and names its cause (BH-6433)

Doc: MERGE-CONDUCTOR

## What changed

- `_ae_status` in `bin/lib/autoenqueue.sh` reads an unusable ledger answer (rc 1, no file-ledger line) again after each wait of `_ae_backoff`. The default is `2 5 10`: four reads, 17 s of waits. Before this change it read once more after 2 s.
- A config fault (`no-secret`, `no-url`) is read once. A retry cannot fix it.
- `MC_AE_LEDGER_RETRY=0` and the ledger burst alert still mean one read.
- Each failed read writes one line to the merge-conductor log:
  `AUTOENQUEUE <slug>#<n> at <h8>: ledger read <i>/<n> failed — GET /api/ledger?kind=autoenqueue <code> body=<first 200 bytes, one line>`.
- The G2 Sentry event (`autoenqueue-ledger-unreadable`) is sent only after the last read. Its message is `<key> not enqueued: GET /api/ledger?kind=autoenqueue unreadable after <n> attempts (last <code>)`. Its extra adds `endpoint` and `attempts`. The fingerprint and `ledger_code` do not change.
- The skip line names the reads: `(http=500, read 4 times, waits 2s 5s 10s)`. With one wait it keeps `(<code>, retried once after <w>s)`.
- `_jobs_req` in `bin/lib/jobs/req.sh` has a new opt-in side channel, `JOBS_BODY_FILE`. When it is set, the request empties the file, then writes the first 200 bytes of the answer payload to it. `JOBS_STATUS_FILE` stays one word.
- Per-tick files next to `<tick>.<project>.ae-ledger`: `.body` (the last read's body) and `.tries` (the read count of the last unusable read).

## Knob

| Settings key | Default | Meaning |
|---|---|---|
| `lane.merge-conductor.mc_ae_ledger_backoff` | `2 5 10` | Waits in seconds before each re-read. 1 to 5 integers, each 0..60. Invalid is the default and one log line a tick. |

The knob is `catalog/lanes.d/merge-conductor.knobs.d/MC_AE_LEDGER_BACKOFF.json`.

## Why

On 2026-10-13 07:15Z the ledger read for example-org/project-4#1917 answered `http=500`. The lane retried once after 2 s and skipped the row. The Sentry event named neither the endpoint nor the attempt count, and no log line held the answer body.

`logs/jobs-client.log` on orgo-desktop holds the worker's answers for the same window:

- `2026-10-13 07:16:13Z [jobs-client] PUT /api/ledger http=500 error code: 1101`.
- 306 `error code: 1101` lines from 06:00Z to 09:59Z on 2026-10-13, in bursts at minutes :01, :16, :31 and :46 of each hour. The same minutes carry `GET /api/settings http=503 … D1_ERROR: D1 DB is overloaded`.
- Daily count of 1101 lines: 2229 on 2026-10-09, 80, 69 and 70 on 2026-10-10..12, 322 on 2026-10-13.

Cloudflare's `error code: 1101` means the Worker threw an exception. The fault is worker-wide on the quarter-hour cron spike, not in the ledger route. A spike lasts about 60 s, so the 17 s ladder covers a short spike only. The worker fault is out of scope here and needs its own ticket.

## Tests

`tests/autoenqueue-ledger-backoff.bh-6433-test.sh` (B1-B9). `tests/autoenqueue-ledger-retry.bh-5463-test.sh` sets `MC_AE_LEDGER_BACKOFF=2` to keep its one-retry premise.
