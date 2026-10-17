# fly-onboard puts the project's Fly token on the console worker (BH-7196)

Doc: OPERATOR-SETUP

`bin/fly-pool-rollout.sh` writes `FLY_API_TOKEN_<P>` to `env/fly.env` on the hub. Before this
change nothing gave that token to the `harness-console` worker. The console `machines` view showed
`FLY_API_TOKEN_<P> not set` until an operator ran `wrangler secret put` by hand.

**The onboarding step.** On the OK and ALREADY paths, `bin/fly-onboard.sh` runs
`bin/console-fly-secrets.sh --project <p>`. That puts `FLY_API_TOKEN_<P>` on the console worker.
A re-run (ALREADY) puts the same value again. If the step fails, the verdict and the exit code do
not change. The step writes one ALERTS line:
`[fly-onboard] <p>: console secret FLY_API_TOKEN_<P> NOT put (rc N): <wrangler error> …`.
The step does not run on the FAILED path or on a refused (non-hub) run.

**The catch-up command.**

| command | effect |
|---|---|
| `bin/console-fly-secrets.sh` | dry run (default): print `MISSING <NAME>` per name, put nothing |
| `bin/console-fly-secrets.sh --apply` | put each missing name, print `PUT <NAME> ok\|FAILED` |
| `bin/console-fly-secrets.sh --project <p>` | put `FLY_API_TOKEN_<P>` |

"Missing" is the `FLY_API_TOKEN_<P>` names in `env/fly.env` (not the bare org `FLY_API_TOKEN`)
minus the names `wrangler secret list` returns, by exact name. A list that does not parse is
exit 1, never "0 missing". Exit: 0 ok, 1 a wrangler call failed or no token, 2 usage or no
`env/fly.env`, 3 not configured.

**Config rows** (hub `env/global.env` only, never the process environment):

- `CONSOLE_CF_ACCOUNT_ID`: required, 32 hex. Unset or malformed = exit 3, and one ALERTS line per
  onboarding. There is no fallback to another account id.
- `CONSOLE_WORKER_NAME`: optional, default `harness-console`.

`CLOUDFLARE_API_TOKEN` comes from `env/cloudflare.env`. The Fly token goes to wrangler on stdin.
It is never on argv, and every error body is scrubbed (`***`) before it reaches a log.

**Go-live step.** Set `CONSOLE_CF_ACCOUNT_ID` in the hub's `env/global.env`. Then run
`bin/console-fly-secrets.sh` on the hub, and `--apply` if it lists missing names.
