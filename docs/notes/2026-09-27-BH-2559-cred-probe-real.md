# Credential probes are real; the fly SMOKE job spends no inference

Doc: FLY-BUILDER-TRIAL, LLM_CALL_SITES

## What changed

- `bin/lib/cred-probe.sh`: `cred_probe <runner>` makes one free GET per runner
  (no model id, no tokens) and prints one class line: `ALIVE` rc 0, `DEAD <code>`
  rc 1, `INCONCLUSIVE <why>` rc 2, `DEGRADED <detail>` rc 3, `NO_ENDPOINT` rc 4.
  The paths are claude `/v1/models` with a setup-token (or `/api/oauth/usage`
  through `oauth-usage-fetch.py` with a full login), codex `/v1/models`,
  openrouter `/api/v1/key`, fireworks `/inference/v1/models` and grok
  `/v1/api-key`. Base URLs come from `endpoint_url`. The key goes to curl as
  `-H @<file>` in a 0700 temp dir, and that dir is removed before the function
  returns.
- `DEAD` is returned only for each runner's auth codes. It is never returned for 429, 5xx, a
  curl failure, a non-JSON 200 or an unresolved endpoint. xAI answers a bad key
  with `400 {"error":"Incorrect API key provided…"}`, not 401 (seen live
  2026-09-27), so that exact 400 is `DEAD 400` for grok. Any other 400 is
  still `INCONCLUSIVE`. A claude setup-token is `DEAD` on 401 or 403, the
  same as the full-login path.
- The setup-token path is proven live: on 2026-09-27 at 00:51Z a real
  `CLAUDE_CODE_OAUTH_TOKEN` probed `/v1/models` with the OAuth beta header and
  read `ALIVE http 200`, and a bogus one read `DEAD 401`. So SMOKE, which
  gates `bin/fly-onboard.sh` and `bin/fly-pool-rollout.sh`, has a working
  ALIVE source.
- `cred_inference_claim` / `cred_inference_record` use the worker `ledgers`
  table through `bin/jobs-client.sh`. The kind is `canary-inference` and the key is
  `<runner>:<fp>:<UTC day>`. Claim returns rc 0 after it writes a `claimed` row, rc 1 when any
  row exists, and rc 2 when the worker is unreachable or not configured (do not
  spend). An `empty` record counts as billed.
- `fly/builder-runner.sh` SMOKE runs `cred_probe claude`. An `ALIVE` answer
  writes `SMOKE_OK claude credential alive host=builder-<project>`. Any other
  answer writes `SMOKE_FAIL <class>`, and a missing lib writes
  `SMOKE_FAIL harness not synced`. SMOKE no longer calls `agent-call.sh execute`
  or the bare `claude -p`. It resolves no model and writes no cost row.

The `fly-builder-smoke` row in `catalog/llm-sites.json` and the two raw-call
allowlists still describe the old model call. The BH-2549 census slice owns
those files and rewrites them.
