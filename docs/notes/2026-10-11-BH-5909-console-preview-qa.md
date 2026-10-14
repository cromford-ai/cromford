# Console PRs get a preview deploy and browser QA before merge (BH-5909, slice 1)

Doc: MERGE-CONDUCTOR

## What changed

`bin/console-preview-deploy.sh` is a hub lane (every 5 minutes). It is off by
default. For each open same-repo PR whose head changes `console-ui/` it:

1. **Builds** the head in its own tree, as an unprivileged user with a clean
   env, using `npm ci --ignore-scripts`. Only the plain files of `dist/` come
   back.
2. **Deploys** a Cloudflare Pages preview under the PR's branch alias.
   - The deploy tree holds the PR's `dist/` and origin/main's `functions/` and
     `src/`.
   - The lane strips `_worker.js` (a file or a directory), `_routes.json` and
     `functions/` from the PR's `dist/`. Pages would run a `_worker.js` as the
     site's server code in place of `functions/`. So no server code from the PR
     runs on Pages before review; the preview runs main's Functions only.
   - wrangler is pinned (`CONSOLE_PREVIEW_WRANGLER`, 3.114.17), with npm's user
     and global config off and the registry pinned.
   - The account id comes from the hub's `cloudflare.env`, else from
     origin/main.
3. **Checks the preview environment first.** The Pages project's PREVIEW
   environment must bind nothing: any non-empty binding key (D1, KV, R2,
   services, Durable Objects, queues, AI and any key the lane does not know)
   and any env var of type `secret_text` or with a secret-like name stops it.
   If it binds one, or if the config does not read, no preview deploys, and
   one alert names what was found.
4. **Runs browser QA** on the preview.
   - The hub mints a read-only QA session from the console worker:
     `POST /api/qa/session` with `Bearer HARNESS_SECRET`, from
     cromford-console #46.
   - `bin/console-qa-run.mjs` signs in on the preview origin
     (`/qa-login/<token>`) and checks that `/api/dash/fleet` answers 200.
   - It loads `CONSOLE_PREVIEW_QA_SCREENS` (default `/`) at 1440px and 390px.
     It only loads pages; it never clicks.
5. **Posts one PR comment** with:
   - the preview URL;
   - the QA lines, `QA COVERAGE` and `QA: PASS|FAIL for head <sha>`;
   - the markers `<!-- console-preview sha=… url=… -->` and
     `<!-- console-qa sha=… result=… -->`.

Screenshots and `qa.md` stay on the hub under
`state/console-preview-qa/<pr>-<sha12>/`.

## The read-only QA session

- **Mint:** the console worker mints a token `<exp>.<hmac>`. The HMAC is
  HMAC-SHA256 under HARNESS_SECRET. The TTL is 1800 s, at most 3600.
- **Cookie:** `/qa-login/<token>` sets `dashqa`.
- **Reads only:** the worker accepts `dashqa` for GET and HEAD only.
- **Previews only:** the Pages `/qa-login/` function works only on a
  branch-alias preview host. The production host gets 403.
- **Writes on Pages bindings:** the Pages functions that write with their own
  bindings refuse any write that carries `dashqa`. These are `/api/coord` and
  the `/api/*` board-command fallback.
- **Limit: the preview's own JS can read.** `dashqa` is HttpOnly, but the
  preview serves the PR's unreviewed `dist/` JS on the same origin. That JS can
  make GET requests that carry the session, so it can read the read-only console
  data (fleet, jobs, boards) and send it anywhere. Only same-repo PRs get a
  preview, and the session lasts at most 3600 s.
- **Failed builds:** a build or deploy failure takes no `MAX_PER_RUN` slot. The
  head's state file records `failed <n>`. At `CONSOLE_PREVIEW_MAX_ATTEMPTS` (2)
  the head is terminal: one PR comment says so, and no later run builds it.
- **Only the head's own failure counts.** A failed `npm ci` or vite build, or a
  refused `dist/`, records `failed <n>`. A box fault charges no head: no build
  dir, a build that cannot be isolated (no `setpriv`, no build user), a copy
  that failed, or a wrangler auth, network, rate-limit or 5xx error. The run
  stops and raises one `console-preview-box` alert, and the next tick tries
  again.
- **An upload failure is classified.** Only Pages refusing the head's own
  `dist/` (a file over 25 MiB, too many files, a bad `_headers` or
  `_redirects`) is the head's fault. Every other upload error is the box's: auth,
  network, rate limits, a 5xx, npm's own errors (npm 10 prints
  `npm error code ENOSPC`), a timeout, a kill (rc 137), and any error nobody
  classified.
- **One head never stalls the lane.** If the same head is the run's upload box
  fault more than `CONSOLE_PREVIEW_MAX_ATTEMPTS` runs in a row, the next run
  skips it and tries the next head. Only if a later head uploads in that run
  (proof that the box can upload) is the skipped head tried once more, and a
  failure then is charged to it. An account-wide fault, such as a token that
  can read the project but not upload, uploads nothing, so it charges no head.
- **Per-run cap:** one run makes at most 2 x `CONSOLE_PREVIEW_MAX_PER_RUN` build
  attempts. The rest wait for the next tick.
- **A rejected comment is not a rebuild.** The body is kept as
  `state/console-preview-qa/<pr>-<sha12>/comment.md`. A rejected POST records
  `posting <n>`, and later ticks post the kept body again. At
  `CONSOLE_PREVIEW_MAX_ATTEMPTS` the lane stops and raises one
  `console-preview-post` alert.
- **`main.<project>` is refused by its host.** `CF_PAGES_BRANCH` is a build-time
  variable, so a direct-upload deploy does not pass it to Functions at runtime.
  The `/qa-login/` host check is the guard that holds in production.

## Operator steps before the first run

1. Deploy cromford-console #46 (`npx wrangler deploy` in that repo).
2. In the Pages project `mission-control`, open Settings and then Preview.
   Confirm it binds nothing and holds no secret. The lane refuses to deploy until
   this is true.
3. Set `lane.console-preview-deploy.console_preview_deploy` to 1. Watch one
   console PR get its comment, and look at its screenshots on the hub.

## Not in this slice

- The lead gate (a UI PR with no `QA: PASS` on its head gets a BLOCK). That is
  slice 2.
- Showing the screenshots on the PR. Today they stay on the hub.
- QA of a PR's own Functions changes. The preview runs main's Functions.
