# BH-9941: the blocked-resolver discovery cache keys on the content of fleet.conf

Doc: MERGE-CONDUCTOR

## Cause

On bh-hub-2, 2026-11-23, `logs/blocked-resolver.log` said `the cache header does
not match` 2,256 times, and every `discovery cache` summary line of the day said
`0 unchanged and skipped`. The `cromford` pass at 23:31Z read 792 candidates
in 2,157 s (`discovery=1257`, `rebuilds:592, builds:588`) and did 1 repair step.
The merge conductor reported `bin/blocked-resolver.sh is SATURATED` for parked PRs.

The header of a cache file (`bin/blocked-resolver.d/bh-9467-discovery-cache.sh`,
`bdc_begin`) held the modification time of `fleet.conf`. On the hub that time
moves about every 20 minutes, at the harness sync (23:05:05Z, 23:45:05Z,
00:05:10Z, 01:05:05Z), and the bytes stay the same (sha1 `6b1404b96e13` at
00:05Z and at 01:05Z). The time changed, the header did not match on the next
pass, and the whole cache was discarded.

Which step of the sync writes the file is not proven here. `bin/registry-export.sh
--install` writes only on a byte change (`put_if_changed`), and the fallback
`cp` in `bin/harness-sync.sh` copies the committed file, which is not the file
on the hub (6,266 bytes against 7,941). If the content ever alternates between
two renders, the checksum header discards the cache again; the check under
"After deploy" shows that case.

## Change

- The header holds `cksum` of the `fleet.conf` content (`<crc>:<size>`), not its
  modification time. A real registry edit still discards the cache.
- The header tag is `#bdc2`. Each old `#bdc1` file is discarded one time.

## Test

`tests/br-discovery-incremental.bh-9467-test.sh`: new case I6b writes
`fleet.conf` again with the same bytes and a new modification time, and asserts
that the next pass skips the 100 settled build dirs. Case I6 now changes the
content of `fleet.conf` to prove the discard. On the old code I6b fails with
`102 path(s), 0 unchanged and skipped, 102 read`.

## After deploy

On the hub, the second `cromford` pass after the deploy must log
`unchanged and skipped` above 0 and `discovery=` under 300 in its `prof:` line.
