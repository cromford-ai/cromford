## App signals: Sentry and PostHog per project (BH-9799)

APP SIGNALS (BH-9799, 2026-11-24). A fleet project can have its own Sentry org and PostHog project. The row is `catalog/signal-sources.d/<project>.json`; it holds env names, never a value.
- For an error on an app (a 500, a timeout, an exception), run `bin/sentry-lookup.sh '<route or error text>' <project>` before any theory. The project name picks that project's own Sentry org and token. A project with no row uses the global `SENTRY_ORG` and `SENTRY_API_TOKEN`.
- For app speed or failed API calls, run `bin/posthog-lookup.sh <project> --report web-vitals` (p75 LCP, CLS and INP by route, 7 days) or `--report api-failures` (failed calls by endpoint and status, 24 hours).
- Both readers print one line and exit 0 when a key is missing or the vendor fails. Treat that line as "no evidence", not as "no problem".
- A ticket or a comment quotes counts, routes and ids only. Never a key, a person's name or an email address. `bin/posthog-lookup.sh` refuses a query that reads person fields.
- To install or rotate a key on a box, use `bin/signal-env-install.sh <project> <NAME>` with the value on stdin. `docs/KEY-ROTATION.md` lists each key, its homes and its rotation date.
