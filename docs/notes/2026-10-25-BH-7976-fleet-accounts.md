# Fleet accounts through the envelope, slice C0 (BH-7976, BH-7939.2)

Doc: DB-COORDINATION-SPEC

## What changed

A person saves fleet-wide secrets on the console: the Fly org token, the fleet
Tailscale key, and the Telegram bot token. Each one must reach the hub only as
a BH-7964 envelope. This slice ships the parts that main supports today.

- **Scope grammar** (`worker/jobs/src/routes/secret-envelopes.js`,
  `FLEET_SCOPE_RE`). `POST /api/secrets/envelope` now also accepts:
  - `fleet:fly:<org>`, org = `[a-z0-9][a-z0-9-]{0,62}`. The org is not a
    secret, so it rides in the scope. The payload is the token only.
  - `fleet:tailscale` (the fleet key).
  - `fleet:tailscale:<project>`, project = `[a-z0-9_-][a-z0-9._-]{0,63}`, no `..`.
  - `fleet:telegram`.
  The `ai-account:` and `tracker:` scopes keep their answers.
  `tests/fixtures/fleet-scopes.bh-7939.tsv` is the one table that the worker
  and the hub parser must both obey.
- **`POST /api/fleet/accounts/telegram {envelope_id}`**
  (`worker/jobs/src/routes/fleet-accounts.js`, main bearer, 401 without it).
  - 400, before any D1 call, when the body is not an object whose only key is
    `envelope_id`. A `token` or `bot_token` key is 400 whatever its value. An id
    that is not a lower-case uuid is 400.
  - One batch of two reads (`STORED_SCOPE_SQL`, `STATE_SQL`; indexes
    `ix_secret_envelope_events_env` and the `secret_envelopes` PK). 400 when no
    `stored` event exists, the scope is not exactly `fleet:telegram`, the
    newest event is `expired` or `apply_failed`, or the row is at or past
    `expires_at`. A `consumed` or `applied` envelope is 200.
  - One batch of two settings upserts, actor `fleet-accounts`:
    `telegram.envelope_id=<id>` and `telegram.state=pending`. Answer
    `{envelope_id, state:"pending"}`, `cache-control: no-store`. A repeat
    POST writes the same two rows.
  - It never writes `telegram.chat_id` or `telegram.bot_present`.
- **Hub library `bin/lib/envelope-fleet.sh`**. It writes one secret into the
  hub env dir (`harness_env_dir`, `bin/lib/env-path.sh`):
  - `fleet:fly:<org>`: `fly.env` `FLY_ORG` and `FLY_API_TOKEN`, then settings
    row `fly.token_present=1`.
  - `fleet:tailscale`: `fly.env` `TS_AUTHKEY`, then `tailscale.key_present=1`.
  - `fleet:tailscale:<p>`: `fly.env` `TS_AUTHKEY_<P>` (the
    `bin/fly-provision.sh` name rule). No settings row.
  - `fleet:telegram`: `global.env` `TELEGRAM_BOT_TOKEN`. No settings row.
  - Each write replaces the key line in place (tmp file in the same directory,
    `umask 077`, `chmod 600`, `mv`). It never leaves a duplicate line. The line
    is `NAME='value'`. A value that is empty or holds `'`, LF, CR or NUL is
    refused, and nothing is written.
  - The settings row is set only after the line is read back.
  - Return codes: 0 ok, 1 refused, 2 failed (no flag), 3 written but not flagged.
    It prints one `ENVELOPE_FLEET` line and never a value.

## What is not in this slice

- **No production caller of `envelope_fleet_apply` yet.** The consumer
  `bin/envelope-consume.sh` and the `secrets-apply` lane are in PR #8149
  (BH-7965), which is not merged. Until child C1 wires them, a stored `fleet:`
  envelope is not consumed. It expires after `secret_envelope_ttl_s`.
- **No Telegram chat-id step.** `bin/fleet-telegram-chat.sh` is in PR #7985
  (BH-7974). C1 runs it after a telegram write. That verb sets
  `telegram.chat_id` and `telegram.bot_present=1`.
- **No screen posts to the route.** First-run and Settings → Fleet machines are
  BH-7939 C4/C5.

## Verify

- `cd worker/jobs && node --test test/fleet-accounts.bh-7939.test.js` (A1-A6).
- `HARNESS_TEST_SANDBOX=1 bash tests/envelope-fly-tailscale.bh-7939-test.sh`
  (E1-E8 and the worker suite).
- Live probe: `curl -s -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' -d '{"bot_token":"x"}' "$JOBS_URL/api/fleet/accounts/telegram"`
  answers 400 `send the token sealed in an envelope, never in the body`.
