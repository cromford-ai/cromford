# The hub consumer applies `fleet:` envelopes (BH-8541)

Doc: SECRETS-ENVELOPE

## What changed

- `bin/secrets-apply.sh` passes each pending id whose scope starts `fleet:` to
  `bin/envelope-consume.sh`, as it does for `ai-account:`. A `tracker:` scope
  is still skipped.
- `bin/envelope-consume.sh` handles a `fleet:` scope after the decrypt step.
  It calls `envelope_fleet_apply` (`bin/lib/envelope-fleet.sh`, BH-7976). The
  value goes to the hub's own `fly.env` or `global.env`. There is no ssh call
  and no vendor probe. The value is in a mode 600 tmp file, never on argv.
- For `fleet:telegram` the consumer then runs `bin/fleet-telegram-chat.sh`
  without the old `TELEGRAM_BOT_TOKEN` in its env, so the verb reads the new
  line. The verb stores `telegram.chat_id` and `telegram.bot_present`.

## Confirm details

| Result | Event | Exit |
|---|---|---|
| fly or tailscale written, read back, flagged | `applied fleet=<target>` | 0 |
| telegram written, verb printed `TELEGRAM_CHAT ok ` and exit 0 | `applied fleet=telegram chat=ok` | 0 |
| telegram written, verb printed `TELEGRAM_CHAT waiting` and exit 0 | `applied fleet=telegram chat=waiting` | 0 |
| telegram written, no executable verb | `applied fleet=telegram chat=not-installed` | 0 |
| telegram written, any other verb answer | `apply_failed fleet=telegram chat=failed` | 1 |
| bad scope or value (`'`, CR, LF, empty) | `apply_failed fleet=<target> refused` | 1 |
| write or read back failed | `apply_failed fleet=<target> write-failed` | 1 |
| line written, flag write failed | `apply_failed fleet=<target> unflagged` | 1 |

The verb's own line is never logged or put in an event. On `chat=failed` the
token line stays written; the next envelope replaces it in place.

## Until #7974 merges

`bin/fleet-telegram-chat.sh` is not on main yet. Every `fleet:telegram`
envelope ends `applied fleet=telegram chat=not-installed`, and
`telegram.state` stays `pending`. When the verb lands, the same code path runs
it with no further change.

## Probe

1. POST `/api/fleet/accounts/telegram` with an envelope id.
2. Wait one minute for the `secrets-apply` lane.
3. Run `curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/settings/telegram.chat_id"`.
4. Run the same request for `telegram.bot_present`. The value must be 1.

## Tests

`tests/envelope-fleet-consume.bh-8541-test.sh` F1-F9. F9 runs the real verb in
fake mode and prints `SKIP F9` until the verb is in the tree.
