# BH-9676: an api-key project's claude call runs on its own key

Doc: ACCOUNT-ROUTING, COST

Slice C0 of #9676 (part of BH-9334 C2). This slice is the call-time path.
The docs sections (`docs/ACCOUNT-ROUTING.md`, `docs/COST.md`) stay with #9677.

## What changed

When the settings row `claude_auth.<project>` is `api-key`, a claude call
through `bin/agent-call.sh` for that project:

- runs with `ANTHROPIC_API_KEY` and with `CLAUDE_CODE_OAUTH_TOKEN` unset. It
  never unsets the key.
- never reads `account.<project>` or `accounts.d`. The own-account pin and
  `bin/account-pick.sh` do not run.
- writes the account-routing.log reason `api_key` and the account
  `apikey:<project>` (also in `$OUT.account`).
- writes a cost row with `billing_mode=metered`, `auth_fp` = the hash of the
  key, and `auth_account=apikey:<project>`. A fingerprint label does not
  replace that value.

The claude rung refuses with rc 76, calls nothing and spends nothing when:

| Cause | failovers.log | account-routing.log reason |
|---|---|---|
| The box has no `ANTHROPIC_API_KEY` | `...has no ANTHROPIC_API_KEY, not falling back to OAuth` | `api_key_unavailable` |
| A managed-settings file sets `forceLoginMethod` or `forceLoginOrgUUID` | the file and the key name (never the value) | `managed_settings_block` |
| The row has a value outside `oauth` / `api-key` (any project) | `settings row claude_auth.<p> is not oauth or api-key` | `claude_auth_invalid` |

A refusal writes no cooldown stamp and rotates no account. The ladder descends
a rung, as it does for a pinned account with no token.

Other parts:

- `bin/lib/claude-auth.sh`: new `claude_auth_managed_guard`. It reads
  `${CLAUDE_MANAGED_SETTINGS_FILE:-/etc/claude-code/managed-settings.json}`
  and every `*.json` in `${CLAUDE_MANAGED_SETTINGS_DIR:-/etc/claude-code/managed-settings.d}`.
- `bin/billing-mode.sh <runner> [project]`: claude plus an api-key project
  answers `metered`. With no project the answer is the env rule, as before.
- `bin/lib/cred-probe.sh`: `cred_probe claude` probes the key
  (`x-api-key`, GET `/v1/models`, DEAD on 401/403) when no OAuth token is set.
  `cred_account_fp claude` uses the order OAuth token, key, stored login.

A project with no row (every project today), or with `oauth`, runs exactly as
before.

## Later slices

- C1: the Fly bundle (`bin/fly-envbundle.sh`, `fly/entrypoint.sh`,
  `bin/lib/pool-account.sh`).
- C2: the meter skips and the `cost_ceiling.<project>` spend brake.

## Tests

`tests/agent-call-api-key.bh-9676-test.sh`,
`tests/billing-mode-api-key.bh-9676-test.sh`,
`tests/cred-probe-api-key.bh-9676-test.sh`.
