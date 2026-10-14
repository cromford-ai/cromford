# 2026-09-22 — BH-426: a GitHub quota gauge, an alert at 20 percent, and a counter

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

1. **`bin/gh-token.sh --status` reports every token, both buckets, both reset
   times.** It used to print one line per App installation cache file carrying
   only the REST pair. It now prints one row per TOKEN this box holds — every
   `state/gh-app-tokens/*.json`, then `pat:default` (`GH_TOKEN`, else
   `gh auth token`), then `pat:admin` (`GH_ADMIN_TOKEN` out of
   `env/github-admin.env`) — deduped on a sha256 fingerprint of the token value,
   App rows first so a PAT that happens to equal an installation token keeps the
   more specific identity. The text line is the old one with the new fields
   appended:

   ```
   <identity> remaining=<r>/<l> expires_at=<iso|-> graphql=<r>/<l> rest_resets_at=<iso|-> graphql_resets_at=<iso|->
   ```

   `--status --json` prints the same rows as a JSON array
   (`identity, kind, slug, rest_remaining, rest_limit, graphql_remaining,
   graphql_limit, resets_at{rest,graphql}, expires_at, unreadable,
   graphql_unreadable`), and `[]` when the box holds no token at all. A bucket
   that did not parse is `0/0` with its `unreadable` flag set and ONE stderr line
   naming the identity — the BH-470 rule, now per bucket.

2. **The hub pushes `gh_quota`.** `bin/fleet-status-push.sh` has a
   `# >>> gh quota (BH-426)` block that sources `bin/lib/gh-quota.sh` and asks
   `gh_quota_rows`; the key lands beside the Anthropic `quota` block. When the
   helper is missing, fails, or prints anything that is not an array the key is
   ABSENT — not `null`, which a consumer's `Number()` reads as 0, and not `[]`,
   which reads as "this box holds no tokens" — and one `logs/gh-quota.log` line
   names the reason in a closed vocabulary (`helper-missing|helper-failed|nonjson`).
   `.gh_quota` joins the `del(...)` list of the 64000-byte size backstop.

3. **An alert at 20 percent, not at zero.** `gh_quota_alert` writes ONE
   `logs/ALERTS.log` line per token per reset window:

   ```
   [gh-quota] GitHub quota low for <identity>: rest <r>/<l> (<p>%), graphql <r>/<l> (<p>%), resets at <iso> — top callers last hour: <a> <n>, <b> <n>, <c> <n>
   ```

   It runs AFTER the watchdog push and the console beat, the same placement rule
   the BH-1000 lease alert took, so nothing in it can cost the dead-man signal.
   The threshold is `setting_get gh_quota_alert_pct` (seeded `20` in
   `worker/jobs/schema.sql`, its own `INSERT OR IGNORE` statement so
   `bin/harness-sync.sh` applies it without risking the BH-283 seed beside it),
   code fallback 20. A value outside 1..99 is logged once and ignored, never
   clamped.

4. **A call counter in `bin/lib/gh-limit-logger.sh`.** "The top three scripts by
   call count" needed a counter and there was none anywhere in `bin/`. The `gh`
   wrapper now appends `<epoch> <caller> <argv1> <argv2>` to
   `logs/gh-calls/<YYYYMMDDHH>.log` before the call. Time comes from bash's
   `printf '%(%s)T'` builtin, so counting costs no fork; every write is wrapped
   `{ … ; } >/dev/null 2>&1 || true`, so stdout, stderr and the exit code are
   untouched exactly as before. The first writer into a new hour prunes the
   directory at 180 minutes, so every box bounds its own counter with no cron
   line and no second process.

5. **`bin/merge-queue.sh` and `bin/blocked-resolver.sh` source the logger.** They
   were the two lanes on the merge path that never did, so a rate-limit 403 in
   either named no identity and their calls were invisible to the top-callers
   clause. Two guarded lines each, fail-open.

## What was NOT built, and why

The ticket's item 3 — "the conductor, merge-queue, merge-sweep and
blocked-resolver read from that cache instead of each calling `gh pr view --json`
per PR" — is already delivered by main: `mc_pr_view` is `gh api repos/<slug>/pulls/<n>`
over `bin/lib/gh-rest.sh` (BH-783/784/994), `bin/blocked-resolver.sh` carries
`# gh-rest: no-graphql`, and the conductor's listing is one `harness_pr_list` per
project per tick. So this ticket PINS that with a counter-based test
(`tests/gh-quota.bh-426-test.sh` section F: zero `pr view`, at most one `pr list`
per harness author, one REST read per PR, with a mutant that puts the per-PR read
back on GraphQL and goes red) and adds no cross-lane PR-list cache. A cache
shared by four cron lanes on three cadences is a serialization point and a
stale-read hazard of exactly the #768 shape; if it is wanted it is a child ticket.

No console tile for `gh_quota` either — the ticket says "pushes those numbers into
`fleet_status`" and nothing about rendering, and `console-ui/src/screens/Fleet.js`
does not read `quota` today.

## Which state and commands this touches

New files on a live box: `logs/gh-calls/<YYYYMMDDHH>.log`,
`flags/alerted-gh-quota-<identity>-<reset>`, `logs/gh-quota.log`. All three are
append-or-flag, none is a shared index, and both the counter files and the flags
are pruned at 180 minutes by the process that writes them. New knob:
`gh_quota_alert_pct`. No new env var, no new cron line.

Read-only commands: `bin/gh-token.sh --status`,
`bin/gh-token.sh --status --json | jq`, `ls logs/gh-calls/`,
`grep '\[gh-quota\]' logs/ALERTS.log`, and `jq .gh_quota` over the newest
`fleet_status` beat on the hub. Full detail in
`docs/verification-map/gh-quota.md`.
