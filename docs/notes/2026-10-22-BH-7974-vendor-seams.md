# Vendor seams and the Telegram chat id on the hub (BH-7974, slice BH-7939.0)

Doc: VERIFICATION-MAP

## What changed

- `bin/lib/vendor/seam.sh` is the fake / real switch for every vendor adapter.
  - `vendor_mode` prints `real` when `HARNESS_VENDOR_MODE` is unset, empty or
    `real`, and `fake` when it is exactly `fake`. Any other value is rc 2, so a
    typo never reads a seed.
  - `vendor_fake <vendor> <method> [key]` prints the seeded answer from
    `tests/fakes/vendor/<vendor>.json` (or `$VENDOR_FAKE_DIR`). An unseeded
    file, method or key is rc 70 `vendor-fake: <vendor>.<method> not implemented`.
    It makes no network call.
  - `vendor_call_log <vendor> <method>` appends `<epoch> <vendor> <method>` to
    `$VENDOR_CALL_LOG` in real mode only.
- `bin/lib/vendor/telegram.sh`:
  - `tg_call <token_var_name> <method>` makes one Bot API GET.
  - `tg_latest_chat_id <token_var_name>` prints the chat id of the newest
    `message`, `channel_post` or `my_chat_member` update. It is rc 4 when there
    is no such update, and rc 1 on a Telegram error, with the token cut.
  - Both take the NAME of the token variable. curl reads the URL from stdin
    (`-K -`), so the token is in no argv. `getUpdates` has no `offset`, so the
    call confirms no update.
- `bin/fleet-telegram-chat.sh` is a hub verb with no arguments.
  - On rc 0 it writes `telegram.chat_id=<id>`, `telegram.bot_present=1` and
    `telegram.state=ok` through `PUT /api/settings`. It reads
    `telegram.chat_id` back and only then prints `TELEGRAM_CHAT ok <id>`.
  - On rc 4 it writes only `telegram.state=waiting_for_message`.
  - On any other result it writes no row and prints `TELEGRAM_CHAT failed <why>`
    (rc 1).
  - No lane calls it yet. Sibling BH-7939.2 calls it after the envelope consume.
- The empty seams for the siblings: `bin/lib/vendor/fly-machines.sh` and
  `bin/lib/vendor/tailscale.sh` (owner BH-7939.1), and
  `console-ui/src/api-first-run.js` (`firstRunApi`, owner BH-7939.3) and
  `console-ui/src/api-fly.js` (`flyApi`, owner BH-7939.4). They are factories
  like the roadmap ones, so they can use `get` and `post`. `console-ui/src/api.js` spreads both
  into `api`.
- `tests/vendor-budget.bh-7939-test.sh` runs every `tests/*bh-7939*-test.sh`
  under fake mode with PATH stubs for curl, flyctl, fly, ssh and tailscale, and
  asserts 0 vendor calls. It also refuses a new `getUpdates` or `machine(s) run`
  call outside `bin/lib/vendor/` and the allow-list of files that had one on
  main.
- `tests/contract/telegram.contract-test.sh` calls the real API (getMe,
  getUpdates, a bad token). `.github/workflows/vendor-contract.yml` runs
  `tests/contract/*.contract-test.sh` on a push to main, nightly, by hand, and on
  a PR that touches `bin/lib/vendor/**` or `tests/contract/**`. It does not run in
  the PR loop. With no `TELEGRAM_BOT_TOKEN` secret, or on a vendor error, it
  prints `SKIP vendor: <reason>` and a `::warning::`, and stays green.

## Env names (test-only, unset in production)

`HARNESS_VENDOR_MODE`, `VENDOR_FAKE_DIR`, `VENDOR_CALL_LOG`. Unset means real
calls and no call log.

## Operator step for the contract suite

Add the repo secret `TELEGRAM_BOT_TOKEN` to run the contract suite for real.
Without it the suite skips.
