---
name: console-deploy
description: Deploy Mission Control (console-ui) to Cloudflare Pages (normally auto-deployed by harness-sync on the hub; this is the check and the fallback) and the harness-jobs worker/D1 that back it — Pages project env + D1 bindings via the Cloudflare API, npm ci + vite build, wrangler@3 pages deploy, and fail-closed anonymous probes as the verification. Use when console-ui or worker/ changed and the live console must be updated, or a console screen answers 503.
---

# console-deploy

Mission Control is a static Vite/preact SPA on **Cloudflare Pages** (project
`mission-control`, `https://console.example.pages.dev`) with Pages Functions
that proxy `/api/*` to the `harness-console` worker and read D1 directly for the
IDEAS / NOW / HISTORY / NEEDS screens. `worker/jobs` (the `harness-jobs` worker +
its own D1) is a separate deploy that ships in the same pass because the JOBS
screen depends on it.

Repo layout: `console-ui/` (SPA + `functions/`), `worker/jobs/` (worker +
`schema.sql`), `worker/watchdog/`. `console-ui/README.md` is the contract for what
each Pages Function needs.

## What deploys what, and what does NOT

- `bin/harness-sync.sh` already deploys **`worker/*`** automatically on any box that
  has `env/cloudflare.env`, sha-gated per worker, alerting when a wrangler deploy
  fails. Check that first — a worker change may already be live.
- **Cloudflare Pages is auto-deployed too, on the hub** (BH-3563). On any box with
  `cloudflare.env`, harness-sync launches `bin/console-pages-deploy.sh` detached.
  It is sha-gated on the settings row `deploy.console-ui.sha`, which holds main's
  last first-parent `console-ui/` commit that went live. It runs `npm ci`,
  `npm test`, `vite build` and `wrangler@3 pages deploy` in a snapshot under
  `state/`, stamps the row, then runs the step 4 probes.
- A red `npm test` refuses the deploy with a `console-pages-deploy-red` alert
  naming the failing tests and their test files (full log in `logs/console-pages-deploy-test-<sha7>.log`).
  A drift warning in pipeline-health (Pages more than 2h behind main) is
  BH-3564, not yet on main.
- Look here first: `logs/console-pages-deploy.log` and
  `bin/jobs-client.sh setting-get deploy.console-ui.sha`. To force a redeploy:
  `bin/jobs-client.sh setting-set deploy.console-ui.sha none`. To switch it off:
  the `fleet-propagate` knob `CONSOLE_PAGES_DEPLOY=0`.

## Credentials and identifiers

```bash
set -a; . /root/harness/env/cloudflare.env; set +a      # CLOUDFLARE_API_TOKEN (chmod 600, never echoed)
export CLOUDFLARE_API_TOKEN
export CLOUDFLARE_ACCOUNT_ID=00000000000000000000000000000000
```

The account id is not a secret (it is already committed in
`worker/jobs/wrangler.jsonc`). The API token is — never print it, never put it in a
log line, a commit or a PR body. If `env/cloudflare.env` is absent, this box cannot
deploy Cloudflare: say so and stop.

| thing | identifier |
|---|---|
| Pages project | `mission-control` → `console.example.pages.dev` |
| Pages D1 binding | `CONSOLE_DB` → D1 `harness-console-db` (`00000000-0000-0000-0000-000000000001`) |
| Pages secret | `HARNESS_SECRET` (same value as the boxes' `env/global.env`) |
| jobs worker | `harness-jobs` → D1 `DB` → `harness-jobs` (`00000000-0000-0000-0000-000000000000`) |

Confirm any of these rather than trusting this table:
`npx --yes wrangler@3 d1 list` and the project GET in step 1.

**Wrangler is pinned to `wrangler@3`** (`npx --yes wrangler@3 …`). It prints an
"out-of-date, update to wrangler@4" warning on every command — that warning is
expected and is not a failure. Do not silently move this pipeline to v4 while
deploying; that is its own change, tested on its own.

## 1. Pages project config — env vars and D1 bindings

A Pages Function that needs a binding **fails closed with a 503 naming the missing
binding**, by design. So a 503 on `/api/coord/*`, `/api/ideas/*` or `/api/cockpit/*`
is a config gap, not a code bug. Read the current config first (never a blind PATCH
— the config object is replace-semantics per environment):

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/mission-control" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  | jq '.result.deployment_configs | {production: {env_vars: (.production.env_vars|keys), d1: .production.d1_databases},
                                       preview:    {env_vars: (.preview.env_vars|keys),    d1: .preview.d1_databases}}'
```

`secret_text` values never come back from the API — you see the key, not the value.
Set or repair **`production` only**:

```bash
# HARNESS_SECRET is read from env, never typed into the command line or a file.
set -a; . /root/harness/env/global.env; set +a
curl -s -X PATCH "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/mission-control" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg s "$HARNESS_SECRET" --arg db 00000000-0000-0000-0000-000000000001 '
    {deployment_configs: {
      production: {env_vars: {HARNESS_SECRET: {type:"secret_text", value:$s}}, d1_databases: {CONSOLE_DB: {id:$db}}}}}')" \
  | jq '.success, [.errors[]?.message]'
```

**The preview environment binds nothing** (BH-6923). Never add `HARNESS_SECRET`,
`CONSOLE_DB` or any other binding or secret to `preview`: a preview runs unreviewed PR
code. The console-preview lane (`bin/console-preview-deploy.sh`) refuses a preview
environment that binds anything, and strips what it finds with one PATCH to
`deployment_configs.preview` only (`CONSOLE_PREVIEW_STRIP_BINDINGS`, default 1). On a
preview, a 503 that names one of these bindings is expected: the lane's QA reports it
as a `PREVIEW GAP:` line, not as a failure.

Config changes only take effect for **deployments made after them** — PATCH first,
then deploy. Never widen a binding to work around a 503: `CONSOLE_DB` is read-only
by construction (every statement in those Functions is a `SELECT`), and the gate
decisions still belong to the old console.

## 2. Worker + D1 schema (skip if `harness-sync.sh` already deployed it)

```bash
cd /root/harness-checkout/worker/jobs
../../bin/schema-build.sh --worker jobs --write   # schema.sql is not in git; this composes it from schema.d/
npx --yes wrangler@3 d1 execute harness-jobs --remote --file=./schema.sql </dev/null
npx --yes wrangler@3 deploy </dev/null
```

`schema.sql` is idempotent (`CREATE TABLE IF NOT EXISTS` etc.), so re-applying is a
no-op — that is why it runs before every deploy. `--remote` is load-bearing: without
it wrangler writes a local dev database and reports success. Expect the summary to
name the bindings (`DB: harness-jobs (1e0a8a7f-…)`) — a deploy that lists no D1
binding is wrong, stop and fix `wrangler.jsonc`.

## 3. Build and deploy the console

**Fallback** (the auto-deploy is the normal path). Run it from a full repo tree:
the suites import `../worker` and `../catalog`, so a copy of `console-ui/` alone
goes red.

```bash
cd /root/harness-checkout/console-ui
npm ci --silent </dev/null          # ci, not install — the lockfile is the input
npm test                            # node --test tests/*.test.js
npm run build </dev/null            # vite -> dist/
npx --yes wrangler@3 pages deploy dist --project-name mission-control --branch main \
  --commit-hash "$(git -C /root/harness-checkout rev-list -1 --first-parent HEAD -- console-ui)" </dev/null
```

`--branch main` is what makes it the **production** deployment; omit it and you have
published a preview that nobody is looking at. `console-ui/functions/` is picked up
automatically and appears in the output as `Uploading Functions bundle` — if that
line is missing, the proxy did not ship and every `/api/*` call will 404.

`</dev/null` on each command is deliberate: these run headless and a tool that stops
to ask a question would hang the deploy forever.

## 4. Verify — fail-closed anonymous probes

The console's whole auth story is that an unauthenticated caller gets nothing. So
the verification is an **anonymous** request to the two D1-backed Functions:

```bash
for p in api/coord/jobs api/ideas/list; do
  printf '%s=%s ' "$p" "$(curl -s -o /dev/null -w '%{http_code}' https://console.example.pages.dev/$p)"
done; echo '(want 403 403)'
curl -s -o /dev/null -w 'spa=%{http_code}\n' https://console.example.pages.dev/
```

Read the codes honestly:

- **403** — correct. The Function shipped and refused an anonymous caller.
- **404** — the Functions bundle did not deploy. The proxy is missing; redeploy.
- **503** — the Function shipped but its binding is missing (`CONSOLE_DB` or
  `HARNESS_SECRET`). Go back to step 1, then redeploy.
- **200** — a fail-OPEN. This is the worst outcome: the session gate is not being
  enforced. Treat it as a security incident, alert, and do not paper over it.

A `200` on `/` alone proves nothing about the API — check both.

Then sign in and actually look, if you are claiming the screens work: open
`https://console.example.pages.dev/login/<DASH_SECRET>` once to set the
year-long `HttpOnly` `dash` cookie (same-origin is the whole point — the cookie must
be set on the host the browser calls), then load the screens the change touched. If
you did not drive it, say the verification was probes plus build only.

## On failure

One actionable line, then stop:

```bash
echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$(hostname)] console deploy FAILED at <step>: <verbatim error> — live console is STALE at <last good deployment url>" \
  >> /root/harness/logs/ALERTS.log
```

A half-deployed console (new SPA, old Functions, or a binding that was never set) is
drift an operator will act on. Say which step failed and what the live state is now.
