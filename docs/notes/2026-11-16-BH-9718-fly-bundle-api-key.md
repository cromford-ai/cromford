# BH-9718: the Fly bundle path for an api-key project

Doc: ACCOUNT-ROUTING

Slice C1 of #9676 (BH-9334 Fix 2).

## Why

`agent-call.sh` (#9712) runs an api-key project's claude call on
`ANTHROPIC_API_KEY`. A Fly pool machine still got the hub's OAuth token and a
leased max account, and it never got the key. So the row changed no pool build.

## What changed

When the settings row `claude_auth.<p>` is `api-key`:

- `bin/fly-envbundle.sh`: the bundle has no `CLAUDE_CODE_OAUTH_TOKEN` line and
  has the marker `CLAUDE_AUTH_MODE=api-key`. The sanity check requires the
  marker. A bad row stops the bundle (rc 1) and leaves no bundle file.
- `bin/lib/pool-account.sh` `pool_account_lease`: no lease, no DB claim, no pin.
  The token line is stripped and the marker written. The answer is
  `name=apikey:<p> reason=api_key`, so the machine json gets
  `auth_account=apikey:<p>`. A failed rewrite empties the bundle. A bad row
  strips the token (`claude_auth_invalid`).
- `fly/entrypoint.sh`: the new block `# >>> api-key (BH-9718)` stages the app
  secret `ANTHROPIC_API_KEY_<PROJECT>` as `/run/harness-env/claude-api-key.env`
  (RAM, mode 600) and unsets every `ANTHROPIC_API_KEY_*` name. On the pull
  path, the marker with no secret writes `BUILD_DEFERRED api-key: ...` and exits 1.
- `fly/builder-runner.sh` `load_env`: with the marker, it exports the staged key
  only and unsets the OAuth token. `warm_up` returns 1 when there is no key.

## What did not change

- No row: every path is byte-same.
- `bin/fly-pool.sh`: no edit. Its lease parse, rebind and reap already handle a
  name with `:`.
- No new knob, table or vendor call.

## Tests

- `tests/fly-envbundle-api-key.bh-9718-test.sh` (E1-E12)
- `tests/pool-account-api-key.bh-9718-test.sh` (L1-L9b, K)
- `tests/fly-boot-api-key.bh-9718-test.sh` (B0-B8, R0-R7)
