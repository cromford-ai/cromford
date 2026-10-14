# Builders App follow-ups: pruned retry flags, a rotated installation hint, an owner row

Doc: OPERATOR-SETUP

BH-1602, three follow-ups from the #1590 review of the builders App (BH-1578).

## What changed

1. **Retry flags are pruned.** `profile_retry_record` in `bin/gh-token.sh`
   now deletes `flags/alerted-gh-app-profile-retry-*` older than 180 minutes,
   the same bound `bin/lib/gh-quota.sh` uses for `alerted-gh-quota-*`. The
   flag name carries the hour, so the current hour's flag is never pruned and
   the page is still once per profile per hour.
2. **The installation hint moves with a rotated token.** `rotate_gh_token` in
   `bin/fly-pool.sh` asks `--installation-id` with the same `--min-life` as
   the token. After the token push succeeds, it pushes that id to
   `/run/harness-env/gh-installation-id` on the machine. An empty file means
   the id is unknown. `gh_token_live` (`bin/lib/gh-token-live.sh`) reads that
   file together with the token:
   - an id exports `GH_TOKEN_INSTALLATION_ID`
   - an empty or non-numeric file unsets it, and the ledger falls back to `app`
   - no file leaves the spawn-time hint alone

   The rotation log line now names the installation. A failed hint push is one
   log line and doesn't stop the rotation.
3. **`POOL_GH_APP_OWNERS` settings row** (`lane.fly-pool.pool_gh_app_owners`,
   required, default `example-org`). This row lists the GitHub owners the
   `POOL_GH_APP_PROFILE` App is installed on: comma or space separated,
   case-insensitive, and `*` means every owner. For a pool project whose owner
   isn't listed, `bin/fly-pool.sh` mints from the hub App directly. There's no
   profile attempt and no hourly hub-retry page. It logs one line per tick and
   writes one ALERTS line per profile per owner per UTC day. The dedupe flags
   are `flags/alerted-gh-app-profile-owner-<profile>-<owner>-<YYYYMMDD>`,
   pruned after 48 hours.

## Why

The retry flags piled up forever. After a rotation that changed App, a
builder's ledger lines named the installation from spawn time instead of the
one it was actually spending. An owner the builders App isn't installed on
failed every profile mint and paged every hour for something only an operator
can fix.

## Operator action for a new owner

When a pool project is owned outside example-org, the daily ALERTS line names
the owner. You have two options:

- Install the builders App on that owner, then add the owner to
  `lane.fly-pool.pool_gh_app_owners` (for example `example-org, NewOwner`).
  Its machines move onto the builders bucket.
- Leave it as it is. The project keeps spending the hub bucket, and you get
  one page a day.

Test: `tests/gh-app-builders-followups.bh-1602-test.sh`.
