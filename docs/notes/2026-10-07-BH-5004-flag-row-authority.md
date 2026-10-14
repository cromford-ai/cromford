# Pause flags decide from the pause_flags row (BH-5004, wave 5 of #4951)

Doc: DB-COORDINATION-SPEC

## What changed

`flag_active` in `bin/lib/jobs/flags.sh` used to reconcile `flags/<name>`
against the row and then answer `[ -f flags/<name> ]`. When that reconcile
could not write the file (an unwritable `flags/`, a stale file `rm` could not
remove), the answer followed the file and not the row. It now answers from the
row it read:

| row read | answer |
|---|---|
| `active=1` | on, whatever the file is |
| `active=0` | on only when `flags/<name>` is strictly newer than the row's `updated_at` (a local touch made after it), else off |
| no row (404) | the file, silently |
| unreadable (transport failure, 5xx, a row without a 0/1 `active` or a worker-shaped `updated_at`) | the file, plus one `jobs-client.log` line `flag <name>: pause_flags row unreadable — decided from flags/<name> (active\|inactive)` when a worker is configured; silent when `JOBS_URL` is empty |

The file is still reconciled to the row as a mirror (BH-1370's table,
unchanged), but whether that write succeeds no longer changes the answer.
No file path was removed.

- **TTL cache.** The row read is memoised in process memory for
  `FLAG_ROW_TTL_S` seconds (default 10, `0` disables, a non-integer means 10;
  `env-templates/lanes/379-flag-row-ttl.env.example`). All three outcomes are
  cached, so an outage costs one failed request per name per TTL, and the
  fallback line is written once per fetch, not once per call. `flag_sync` (and
  the `flag-sync` CLI verb) still makes a fresh GET every time.
- **`flag_set` writes the row first.** It PUTs, then touches or removes the
  file. A landed PUT seeds the cache, so the same process's next `flag_active`
  makes no GET. A failed PUT (outage, or no worker configured) still writes the
  file and returns 1, because `bin/cost-local-brake.sh` is the brake during an
  outage.
- **CLI `flag-active`** answers through `flag_active` itself, and its BH-2643
  `source:` line reads `flag_active`'s own result instead of making a second
  GET. The four message strings are unchanged.
- **main-red.** The publish already wrote `main_red` and `main_red_events`
  (`mr_row`, BH-2373). The comment in `worker/jobs/schema.sql` that said no
  route writes them was stale and now names the writers.
  `tests/flags-row-authoritative.bh-5004-test.sh` case 7 drives the real
  detector, replays its `/api/main-red` body into the real worker and checks the
  `raise` and `new_sha` events.

## Assumptions a later wave may revisit

- A local touch newer than an inactive row still wins. Writers that touch
  `flags/<name>` with no row (`bin/quiesce-for-resize.sh`, `bin/harness-ctl.sh`
  all-off, `bin/poll-commands.sh`'s touch fallback, `pool-halt-*`) depend on it.
  Making any readable row beat any file means converting those writers to
  `flag_set` first.
- A 404 is not "the row says off": dozens of flags never had a row.
- The TTL is an env knob, not a settings row, because a settings read costs the
  same GET the cache exists to save.
