# Audit regression end to end tests

This suite uses the requested [Tester Army e2e](https://github.com/tester-army/e2e) runner and its Chromium engine. Both development dependencies are pinned. The additional dependency provides a repeatable browser runner, HTTP assertions, and failure traces; neither package ships in the dashboard or Workers. Tests use deterministic locators and assertions, with no model account, paid model calls or production credentials. Telemetry is disabled by the test command.

From the repository root, using the Node version in `.node-version`:

```sh
npm ci --prefix console-ui
npm ci --prefix tests/e2e-audit
E2E_AUDIT_OUTPUT=/tmp/cromford-audit-e2e npm test --prefix tests/e2e-audit
```

The pretest step generates the jobs registry and builds the production dashboard. The runner automatically downloads its matching Chromium headless browser on first use. Linux hosts may also need the browser OS libraries (`tests/e2e-audit/node_modules/.bin/playwright-core install-deps chromium`).

The tests exercise the real built dashboard, jobs and locks Workers, watchdog, and Pages proxy handlers over local HTTP. Databases are in memory and the listener binds only to loopback. The unpublished `harness-console` service's session probe is simulated with explicitly named fixture cookies. External service requests are refused. Consequently, this is integration coverage of this repository, not verification of a deployed console, live Cloudflare Access policy, real email delivery, or cloud machine operations.

The suite checks dashboard rendering, forged owner rejection and legitimate owner admission, QA login-code denial and permitted reads, command-ledger integrity, encryption-key protection, lock authentication, literal minter scopes, concurrent quota enforcement and dedicated watchdog authentication. Results and failure traces go to `E2E_AUDIT_OUTPUT`, or the ignored `.e2e/` directory when unset. Keep local results outside the checkout as above: generated runner IDs and trace hashes otherwise trigger the repository's identifier guard. CI uploads `.e2e/` from its separate test workspace.
