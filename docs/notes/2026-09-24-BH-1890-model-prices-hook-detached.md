# The deploy price hook runs detached, refuses an empty table read, and a catalog POST only inserts

Doc: model-prices

## What changed

Follow-ups from the #1888 review of BH-1566 (BH-1890).

- **Detached from harness-sync** (`bin/harness-sync.sh`). The hook used to run
  in the foreground. On the hub the first deploy of a price change can take
  about 200 s (the refresh alone is up to 150 s), and `bin/fleet-propagate.sh`
  runs harness-sync under `timeout 300`. A slow run got the sync killed after
  its stamp, recorded `hub=fail(rc=124)` and skipped the codegraph index. Now
  harness-sync starts it with `setsid timeout 600`, stdin from `/dev/null`,
  output appended to `logs/model-prices-deploy-sync.log`, fds 6-9 closed, and
  goes straight on. Closing the fds matters: fleet-propagate holds its own
  `flock` on fd 9 around harness-sync, and a hook that inherited it would keep
  fleet-propagate locked out, silently, for as long as the hook ran. The hook's own `flock -n` on `locks/model-prices-deploy-sync.lock`
  dedupes a second deploy's launch while one is running. A run killed at 600 s
  leaves its key unstamped, so the next deploy retries.
- **An empty table read is refused** (`bin/model-prices-deploy-sync.sh`). On
  the hub, a `MODEL_PRICES_MIN=0` GET with zero models while
  `state/model-prices.json` holds models, or does not parse, sends no POST.
  Before, every catalog model looked missing and the whole catalog went in
  over the live rates. The hook raises one warn alert under
  `model-prices-deploy-sync`, writes one `update-runners.log` line, exits 0 and
  does not stamp. An absent state file or one with no models is a fresh hub,
  and the POST goes ahead as before.
- **A catalog POST only inserts** (`worker/jobs/src/routes/cost.js`,
  `POST /api/model-prices`). `source=catalog` is `ON CONFLICT(model) DO
  NOTHING`, so a live rate the 04:30Z refresh wrote between the hook's GET and
  its POST is never replaced. Every other source keeps the full upsert.

## Check it

- `bash tests/model-prices-deploy-sync.bh-1890-test.sh`
- `cd worker/jobs && node --test test/model-prices-catalog-insert.bh-1890.test.js`
- On the hub after a price commit deploys: `tail logs/model-prices-deploy-sync.log`.
