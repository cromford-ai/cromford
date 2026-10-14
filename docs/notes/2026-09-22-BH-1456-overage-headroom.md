# BH-1456 — an account in overage has headroom, and `default` is judged by the account it bills

`Doc: ACCOUNT-ROUTING`

## What was wrong

Two defects, and the first one hid the second.

**1. The overage reading was thrown away.** The usage endpoint reports an
`extra_usage` object — is this account billing extra usage, has it reached its
spend limit, how much of that limit is spent. `bin/quota-poll.sh`'s `normalize()`
emitted `five_hour`, `seven_day` and `per_model` and dropped it, so no
`state/quota/<account>.json` could say "overage is on". `account_reading_class`
in `bin/account-pick.sh` therefore applied `ACCOUNT_WEEK_MAX` (90) to every `ok`
poll and answered `capped` for an account at weekly 100% that was billing
overage and serving every request perfectly well. Both pickers park a `capped`
account, so the hub picked `default`-or-nothing and the Fly pool logged
`all_capped` and shipped the default token.

**2. `default`'s meter belonged to a different account.** `state/quota/default.json`
is derived, not polled (the endpoint is rate-limited per account, so
`bin/extra-usage-track.sh` polls once and `quota-poll.sh` reads its snapshot).
The snapshot it read was `state/extra-usage-last.json` — the BOX LOGIN's meter.
On the hub the stored login is operator@example.com (weekly 4%), but the `default`
credential is `env/global.env`'s `CLAUDE_CODE_OAUTH_TOKEN`, which bills
operator@example.com (weekly 100%). So the row described an account nothing was
spending, and the account everything was spending had no row at all.

## What changed

- `normalize()` carries `extra_usage` through (renaming `utilization` to `pct`,
  like the two windows beside it), and `status_json` carries `extra_usage: null`
  so every reader sees one shape. **Absent is `null`, never `false`**: "we have
  no reading" and "overage is off" are different facts and the classifier
  branches on the difference.
- `ACCOUNT_DEFAULT_LABEL` (`env/global.env`, identity, not settable from the
  control plane) points the `default` derivation at
  `state/extra-usage-last-<label>.json` and names the label in the row's
  `source`. Set but missing → one `default fallback label_snapshot_missing:<label>`
  row per run and today's derivation stands. Unset → byte-identical to before,
  and no log row, because otherwise every box that never sets it would log one
  every ten minutes.
- `account_reading_class` prints three fields, `class|rank_pct|detail`. The class
  WORDS are unchanged — every reader in the repo branches on
  `capped`/`metered`/`stale`/`unreadable`/`none` — and the new third field says
  which rule produced the class (`5h`, `week`, `model`, `spend_limit`,
  `disabled`, `extra_cap`, `overage`). `account_pick` logs it as
  `drop:capped:<detail>`, and `_pa_metered` prints `capped:<detail>`.
- The overage branch answers before the subscription thresholds: enabled and
  intact → `metered|<extra pct>|overage`, ranked on the overage meter, because
  once an account bills extra usage the subscription windows no longer bound
  what it can serve. `ACCOUNT_EXTRA_MAX` (default 97) is the ceiling on the
  overage meter itself.
- **What still refuses, and had to**: `spend_limit_reached`, `disabled_reason`,
  `user_disabled`, and the overage meter at `ACCOUNT_EXTRA_MAX`. Those were the
  correct refusals of 2026-09-18/19 and this change must not spend them away.
  `is_enabled` false or absent takes none of these paths and falls through to
  the thresholds exactly as before.
- `bin/agent-call.sh`'s `account-exhausted` arm cools an overage account for
  `ACCOUNT_OVERAGE_COOLDOWN_SECS` (900) instead of six hours, and its
  `ladder_note` carries a `WARN` excerpt of what the runner actually said. Six
  hours is right for "this subscription is spent until it resets" and wrong for
  the one account on the box that still has budget. `auth` and spend-limited
  accounts keep the full window — `account_overage_ok` says no to both.
- `bin/quota-status.sh` carries `extra_usage` in `--json` and prints one
  ` extra: …` line per account that has a reading. That line is what explains a
  row reading `WEEK 100%` with `STATE ok`.

## The short cooldown is a BACKDATED stamp, on purpose

`state/quota/cooldown/<vendor>/<account>` holds one epoch and `account_cooling`
compares `now - at` to one window. A second field or a second file would mean
changing that reader, `cooldowns_json` in `bin/quota-status.sh` and
`bin/quota-poll.sh`'s expiry sweep — three readers and their BH-940 tests — to
express something the existing shape can already say. So
`account_cooldown_stamp_short` writes `now - (ACCOUNT_COOLDOWN_SECS - secs)` and
every reader keeps its single window: the account returns in `secs`, the status
table's "would have run to" line is right, and the sweep still collects it.

## Knobs

| knob | default | where |
|---|---|---|
| `ACCOUNT_DEFAULT_LABEL` | unset | `env/global.env`; hub: `project-6-account`. Registered in `catalog/lanes.d/quota-poll.json`, `settable: false` (it is an identity) |
| `ACCOUNT_EXTRA_MAX` | 97 | `bin/account-pick.sh`, beside `ACCOUNT_WEEK_MAX` |
| `ACCOUNT_OVERAGE_COOLDOWN_SECS` | 900 | `bin/account-pick.sh`; read by the `agent-call.sh` ladder arm |

## Operator step

The hub needs `ACCOUNT_DEFAULT_LABEL=project-6-account` in its
`env/global.env`. Until it is set, the `default` row keeps describing the box
login rather than the token — which is defect 2, unfixed, on that box only.
Every other box is correct with the knob unset.

## Not in scope

`bin/extra-usage-track.sh` (the snapshot writer already carried the raw
`extra_usage`), the console Costs screen (it reads overage from
`extra-usage.csv` by another path), `pool_account_cooldown` and
`orc_account_refuse` (neither has classified stderr at stamp time, so both keep
the long window), and the merge conductor's account fact.

## How to drive it

```bash
HARNESS_TEST_SANDBOX=1 bash tests/quota-poll.bh-1456-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/account-pick.bh-1456-test.sh
```
