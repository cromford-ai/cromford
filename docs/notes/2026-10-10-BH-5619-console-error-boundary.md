# Mission Control catches a failed screen and reports it to Sentry (BH-5619)

Doc: CONSOLE, console-ui/README.md

## What changed
Before this change, a routed console screen that threw during render had no
error boundary above it. Preact unmounted the whole app, top bar and bottom nav
included, and no report went anywhere.

- `console-ui/src/app.js` wraps the routed screen in `ErrorBoundary`
  (`console-ui/src/ui/ErrorBoundary.js`), keyed by path. A failed screen shows
  `THIS SCREEN FAILED`, the error message and a RELOAD button. The top bar and
  bottom nav stay mounted. Navigation mounts a fresh boundary.
- `console-ui/src/lib/error-report.js` holds `initSentry(env)` and
  `reportError()`. `console-ui/src/main.js` calls `initSentry(import.meta.env)`
  once, before `render`. The boundary reports each caught error once.
- The dependency is `@sentry/browser`. The console does not use
  `@sentry/react` or a `preact/compat` alias.

## The DSN is build-time
`VITE_SENTRY_DSN` is read when `npm run build` runs, and Vite inlines it in
`dist/`. If it is unset, empty or blank, reporting is OFF and the fallback still
renders. Cloudflare Pages runs no build for this console, so a Pages env var is
never read. The hub builds `dist/` in `bin/console-pages-deploy.sh`, and that
script does not pass the var yet. Until a follow-up wires it, the deployed
console does not report errors.

## Options
`sendDefaultPii: false`, no Replay, no user data, tag `lane: console-ui`. The
SDK default integrations stay on, so uncaught errors and unhandled rejections
outside render are reported too when a DSN is set.

## Tests
`console-ui/tests/error-report.bh-5619.test.js` (cases A to F; case E mounts the
real `App` through `ROUTES`) and `tests/error-report-console.bh-5619-test.sh`.
