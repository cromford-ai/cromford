# BH-8848: vs_publish posts only as the App on a minting box, and says why a POST failed

Doc: GH-REST, MERGE-CONDUCTOR

## What changed
- `vs_publish` (`bin/lib/verdict-status.sh`) writes the `lead-verdict`, `prequeue-verdict`
  and `landing-path` commit statuses. On a box that mints App tokens (`gh_auth_armed`
  rc 0), it now sends the POST only on an App installation token (`ghs_*`).
  `bin/gh-token.sh` prints the PAT when a mint fails, so a token that is not `ghs_*`
  counts as a failed mint. vs_publish puts the caller's token back and mints once more.
  If that also fails, it prints one line and returns 1 with no POST:
  `vs_publish: no App token for <slug>; <context>=<state> NOT published on <slug>@<sha12>`.
- A box that does not mint (no `env/github-app.env`, `GH_APP_TOKENS=0`, the kill switch,
  or no `gh_auth_armed` loaded, for example the lead's Mac) posts on its own gh auth, as before.
- The failure line keeps its prefix and adds the token kind and GitHub's message:
  `... NOT published on <slug>@<sha12> (HTTP 403[, rate-limit]; token=app|pat|gh-auth|other[; GitHub: <message>][; retried once after <N>s])`.
  The token value is never printed.
- `gh_rest` sets one new variable, `GH_REST_MESSAGE`: GitHub's JSON `.message` on a
  non-2xx answer other than 304/404, on one line, cut to 200 characters. It is empty
  otherwise. No existing branch, return code or variable of `gh_rest` changed.
- A 403 or 429 that `gh_rest` classed `rate-limit`, with a `Retry-After` of 1..N seconds,
  is sent once more after that wait. N is the knob `VS_RETRY_AFTER_MAX_S`
  (settings row `lib.verdict-status.vs_retry_after_max_s`, default 30, 0 = never retry).
  A success after the retry prints one line
  `vs_publish: <context>=<state> published on <slug>@<sha12> after one retry (...; Retry-After <N>s)`.

## Why
bh-hub-2 logged `NOT published ... (HTTP 403)` three times (2026-10-30 01:13Z, 21:24Z,
2026-10-31 06:33Z) with no cause. The old code ran `gh_auth_for "$slug" || true`, so a
failed mint posted on the PAT, and `gh_rest` dropped GitHub's message.

## Test
`tests/verdict-status-app-token.bh-8848-test.sh`.
