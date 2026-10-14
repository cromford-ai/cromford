# date-empty-stamp: a null quota poll reads stale, not fresh since midnight

Doc: TEST-DETERMINISM

## What changed

BH-1898 (slice 1 of BH-1816). `_acct_epoch` in `bin/account-pick.sh` now
answers `0` for an empty stamp before it calls `date`. `0` is the function's
existing "unparseable" value. `bin/lib/jobs/flags.sh`'s `_flag_epoch` date line
got a trailing `# determinism: ok date-empty-stamp` waiver and nothing else.

## Why

GNU `date -u -d ""` exits 0 and prints today's 00:00Z (#1815), so the old
`|| e=0` fallback never ran. An `ok` quota file with `polled_at: null` got an
age of "seconds since midnight", and `account_reading_class` read it as fresh
for the first `ACCOUNT_POLL_STALE_SECS` (3h) of every UTC day. Now it reads
`stale||` at any hour. The same reading feeds `account_headroom`,
`account_pick` and the Fly pool's `_pa_metered`.

`_flag_epoch` was already safe: its `case` only lets the worker's
`YYYY-MM-DDTHH:MM:SSZ` shape through to `date`, so an empty `updated_at` is
rc 1 and `flag_sync` leaves the box alone.

The lint reports `date-empty-stamp` on neither file now.
Suite: `tests/date-empty-stamp.bh-1898-test.sh`.
