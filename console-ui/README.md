# Mission Control (`console-ui`)

The web front-end for the cromford fleet control plane. It is a static SPA
(Vite + preact + htm, no JSX) served from Cloudflare Pages, with a Pages
Functions proxy that puts it on the same origin as its API.

The API contract it is built against is
[`harness-console/docs/DASH_API.md`](../../harness-console/docs/DASH_API.md) —
that document is authoritative, not this one.

## Local development

```bash
npm install
npm run dev        # http://localhost:5180
```

`npm run dev` proxies `/api/*` and `/login/*` straight to
`https://harness-console.operator.workers.dev` (see `vite.config.js`), which is the
dev twin of the production Pages Functions proxy. You still need the `dash`
cookie: open `http://localhost:5180/login/<DASH_SECRET>` once and it is set for a
year. Without it every call answers `403` and the app renders its
"NOT SIGNED IN" screen rather than a broken dashboard.

## Build

```bash
npm run build      # -> dist/  (static, self-contained)
npm test           # node --test, no framework
```

`dist/` contains no external references: every font is a self-hosted
latin-subset variable woff2 in `public/fonts/` (JetBrains Mono for Phosphor;
Archivo, Geist and Geist Mono for the Mill themes, with their SIL OFL 1.1
licence in `public/fonts/OFL.txt`). No Google Fonts link ever ships, and every
icon is inline SVG.

## Error reporting (BH-5619)

Every routed screen renders inside `ErrorBoundary` (`src/ui/ErrorBoundary.js`).
If a screen throws during render, the boundary shows a `THIS SCREEN FAILED`
block with the error message and a RELOAD button. The top bar and bottom nav
stay mounted, and navigating to another route mounts a fresh boundary.

The boundary reports the error once to Sentry through `src/lib/error-report.js`,
but only when `VITE_SENTRY_DSN` was set at build time:

- `VITE_SENTRY_DSN` is a **build-time** variable. Vite inlines it into `dist/`
  when `npm run build` runs. Setting it on the Cloudflare Pages project does
  nothing, because Pages runs no build for this console: the hub builds `dist/`
  in `bin/console-pages-deploy.sh` and uploads it.
- Unset, empty or blank means reporting is OFF. The SDK is never initialised,
  and the boundary still renders its fallback.
- Set it in the environment of the `npm run build` that produces the deployed
  bundle (today: the build step in `bin/console-pages-deploy.sh`, which does not
  pass it yet), or in your shell for a local build:
  `VITE_SENTRY_DSN=https://<key>@<org>.ingest.sentry.io/<id> npm run build`.
  Never commit it; `.env*.local` files are git-ignored.
- Options: `sendDefaultPii: false`, no Replay, no user data, tag
  `lane: console-ui`. The `@sentry/browser` default integrations stay on, so
  uncaught errors and unhandled rejections outside render are reported too.

## Deploying

Cloudflare Pages, build output `console-ui/dist`, with `console-ui/functions/`
deployed alongside it as Pages Functions.

On the hub this is automatic (BH-3563): harness-sync runs
`bin/console-pages-deploy.sh` detached, which deploys main's last first-parent
`console-ui/` commit once, gated on the settings row `deploy.console-ui.sha`. A
red `npm test` refuses the deploy with an alert. The log is
`logs/console-pages-deploy.log`; the by-hand fallback and the probes are in
`skills/console-deploy/SKILL.md`.

The Functions:

- `functions/api/[[path]].js` forwards `/api/*` to the worker, preserving
  method, body and cookies in both directions.
- `functions/login/[secret].js` forwards `/login/<secret>`, passes the worker's
  `Set-Cookie` through so the cookie is scoped to the Pages origin, and rewrites
  the `302 Location` to `/` so the operator lands on the SPA.
- `functions/api/coord/[[path]].js` forwards `/api/coord/*` to the **harness-jobs**
  worker (the coordination DB behind the JOBS screen). Different worker,
  different credential: it attaches `Bearer $HARNESS_SECRET` server-side, so
  **the Pages project must have `HARNESS_SECRET` set** (same value as the boxes'
  `env/global.env`) or that screen answers 503 saying exactly that. The `dash`
  session is not re-implemented here — the incoming cookie is presented to the
  console worker's own authed endpoint and only a 200 buys the proxy, so there
  is one definition of "signed in" and rotating `DASH_SECRET` revokes both at
  once. Only `GET` passes, plus `PUT /api/coord/flags`.

- `functions/api/merge-pr/release.js` serves `POST /api/merge-pr/release {id}`
  for the hub poller (BH-4917), not for the browser. After the poller acks a
  `refused: head moved…` merge_pr, it asks this endpoint to rename that one
  row off `<project>:<ticket>:merge_pr`, so the next merge_pr from any entry
  point (MCP tool, Telegram, box command, console) is a new command. Auth is
  `Bearer $HARNESS_SECRET`, not the dash cookie. The write goes through
  `CONSOLE_DB`, so the hub needs no D1 access. **It needs `HARNESS_SECRET` and
  the `CONSOLE_DB` binding**, and answers 503 naming whichever is missing.

- `functions/api/ideas/[[path]].js` serves `/api/ideas/*` for the IDEAS screen.
  Same delegated session check as coord — the incoming `dash` cookie is presented
  to the console worker and only a 200 buys the read — but a different source:
  the console worker has **no JSON read for proposals** (its `/product` view is
  server-rendered HTML), so this function reads the rows the worker's own beats
  wrote, straight out of its D1. **The Pages project must bind D1
  `harness-console-db` as `CONSOLE_DB`** or the screen answers 503 saying exactly
  that. `GET` only, and every statement in the file is a `SELECT`: the gate
  decisions (approve / kill / revise) still belong to the old console.

  **What the list carries about a mockup**, because the MOCKUP column on
  `/ideas` reads both and neither needed adding: `mockup_url` is the interactive
  mockup `bin/post-proposal.sh` uploaded to the client's board and wrote back on
  the beat, so only proposals that were actually posted (and whose upload
  succeeded) have one; `shots` is a `COUNT(*)` over `proposal_assets`, the
  desktop/mobile PNGs `bin/push-proposal-assets.sh` pushed after
  `bin/mockup-shot.sh` rendered them, and those bytes come back from
  `/api/ideas/asset/<project>/<slug>/<kind>`. The `mockup.html` itself never
  reaches the console, so those two are the whole of what is clickable from
  here. A row with neither never reached the drafting stage.

- `functions/api/cockpit/[[path]].js` serves `/api/cockpit/*` for the **NOW**,
  **HISTORY** and **NEEDS** screens, and the deep half of `/p/:project`. Same
  delegated session check and the same D1 binding as ideas — **`CONSOLE_DB`
  must be bound** or those screens answer 503 saying exactly that. The old
  console server-renders `/`, `/history` and `/needs` as HTML and has no JSON
  for them (probed off-cookie: those paths answer `403`, i.e. a real route
  refusing the session, while `/api/dash/history`, `/api/dash/needs`,
  `/api/dash/runs` and `/api/dash/events` all answer `404`), so this reads the
  rows the worker's own beats wrote. `GET` only; every statement is a `SELECT`.

Same-origin is the whole point: the `dash` cookie is `HttpOnly`, so it must be
set on the host the browser is calling. No CORS, no bearer token in JS, and the
secret only ever travels in that one request path.

`public/_redirects` sends every other path to `index.html` so deep links and
reloads reach the router. Pages Functions are matched before that fallback, so
the proxy still wins for `/api/*` and `/login/*`.

## Screens

| Route | What it is |
|---|---|
| `/` | Fleet overview — summary strip, machine tiles, sortable projects table |
| `/world` | The fleet as a place — a low-poly 3D planet, a territory per project, a body per live claim, a beacon where something needs a person, idle boxes asleep on the orbital station. Arrow keys / WASD walk a selection ring between bodies and territories, Enter opens, Escape clears. Falls back to the 2D hex map without WebGL |
| `/now` | What the harness is DOING — last tick per board, what is building, the activity feed |
| `/history` | Every run and every build on record, cursor-paged, filters in the URL |
| `/history/commands` | The latest 200 console and chat commands: who sent each one, its status and outcome, and a link to the PR, job, idea or board it acted on; sortable, filters in the URL |
| `/needs` | Everything waiting on a person: alerts, dead commands, parked builds, ideas at the gate |
| `/machines` | Orgo box liveness + Fly machines per project, orphan jobs called out |
| `/jobs` | Coordination DB: a headline from the live counts, 01 The line (one row per ticket in flight on an eight-station track, plus a log of the newest beats), 02 lanes, 03 claimed/recent jobs with heartbeat age and orphan state, 04 the burn rollup, 05 the pause flags (BH-4990) |
| `/t/:ticket` | One ticket's job rows and where it stands on the line; every ticket key on `/jobs` links here. Interim until the full ticket page (BH-4947 wave 2) |
| `/jobs/:id` | One job all the way down — its stage events and ledger rows |
| `/p/:project` | Project drill — controls, runs, builds, live log tail, volume, events, the whole-ledger totals and the company map |
| `/runs/:id` | One run, with its stored ~7KB session tail |
| `/builds/:id` | One build — live mission view (phase strip + sub-stage, model/spend rail, progress log polled every 5 s while the job is running), artifacts, timeline |
| `/kanban` | PIPELINE (harness state) and BOARDS (client ticket snapshot) tabs; PIPELINE renders as CARDS or LIST, remembered per viewer |
| `/pr/:project/:number` | PR drill — stats, artifact tabs, build rows, timeline |
| `/lead-reviews` | The lead review lane: today's spend against `lead_review.daily_spend_usd`, running against `lead_review.concurrency` (both editable in an in-app modal), the 24h reconcile drift count, and three tables: the needs-review worklist per auto repo, running `lead_review` jobs, and PRs whose review failed on their current head. Reached from KANBAN → LEAD REVIEWS |
| `/chat` | Orchestrator **and per-box** conversations — target pills, per-target unread dots, polled while the tab is in front |
| `/alerts` | Open alerts across the fleet, one-tap resolve, plus FLEET ROWS — the alerts DB's own rows (read-only), with family/box/state filters in the URL |
| `/costs` | What is actually priced, and an explicit account of what is not |
| `/ideas` | The product stage's proposals — score, bucket, status, whether there is a MOCKUP to look at and a one-click way in; a WITH MOCKUPS toggle remembered per viewer; project and status filters ride the URL |
| `/ideas/:project/:slug` | One idea all the way down — PRD, desktop/mobile mockup (anchored at `#mockup`, which the list links straight to), idea chat, client ticket; POST / REVISE / KILL / CHAT buttons that queue the proposal commands (BH-2520) |
| `/outcomes` | Did the work HOLD? Revert/reopen rate and cost-per-PR per repo, the weekly burn trend, every finding on record, and which repos the review gate has parked for a judged merge. Window and repo filters ride the URL |
| `/settings/appearance` | APPEARANCE: a live preview of each built-in theme, USE to pick one for this browser, and what the fleet default is |
| `/settings/p/:project/signals` | SIGNALS (BH-9839): one card per signal key kind (Sentry, PostHog) of one project. Not set, or the stored non-secret fields, who set them and when, the last test and the rotate-by date (a warning pill past it). Set or Replace opens a sheet (labelled fields, a paste is trimmed, the prefix is checked on blur, Save runs Test); Clear asks in the in-app confirm. The key itself is never shown. Reached from SETTINGS → a project → Signals, and from a SIGNALS pill on the Fleet projects table |

## The rules this UI holds itself to

These are not style preferences; each one exists because the opposite renders a
lie an operator would act on.

- **"What it is" and "what it is doing" are two screens.** FLEET answers whether
  the machines are alive; NOW answers what the harness is doing this minute. The
  old cockpit put both on one page and the second question lost.
- **A cap is disclosed, never absorbed.** A needs list that hit its 200-row cap
  says so above the table, and the strip keeps reporting the real count. A
  history page that got a full page hands back a cursor rather than claiming it
  reached the end. The pipeline's SHIPPED column asks for `shipped_limit=50` —
  a column has to fit on a screen, and the fleet merges a few hundred PRs a
  fortnight — and renders "showing 50 of 313" beside it from the API's own
  `counts.merged_deployed_total`; when an older worker sends no total it renders
  no caveat rather than inventing one. The LIST view repeats every one of the
  board's column-head disclosures in a footnote row — the SHIPPED caveat, the
  stale-build count, the external-lane count, the DEAD archive note and its
  audit toggle — because a view that shows the rows but drops the counts beside
  them is the same omission in a quieter voice.
- **Finished is not abandoned.** A third-party lane whose PR has merged reads
  "PR #N merged · ticket not closed", not "stale branch". Eight project-4 tickets
  once carried the stale-branch warning while every one of those PRs had landed
  days earlier — a lane the snapshot could not see was reported as one somebody
  walked away from. `claimIsStaleBranch` is `kind:"branch"` only, and a PR claim
  with no state is read as OPEN, never as merged.
- **A snapshot is never presented as live.** Everything derived from the hub's
  `fleet_status` beat carries its age, and an age we never received reads
  `never`, not `0m`.
- **Missing is not zero and not smallest.** A value we do not have sorts last in
  both directions and renders `—`, never a confident number.
- **Empty states say which kind of empty.** A log that was never written, a file
  that exists and is empty, a refused request, and an unreachable box are four
  different messages — only one of them offers a retry that can help.
- **A section that cannot load names its dependency.** `gh: null`, a missing
  `BOARD_TOKEN_*`, an un-enumerated Fly app: each renders a chip saying what is
  unavailable and why, with the D1-sourced data still shown beside it.
- **Nothing is a dead end.** Every identity and every aggregate links to the next
  level down, to the atomic record.
- **No native dialogs.** `window.confirm/alert/prompt` are never used; the themed
  modal in `src/ui/Modal.js` is the only confirm surface.
- **No invented money.** No priced per-call rows reach D1, so `/costs` renders
  volume and says plainly that volume is the denominator, not the number.
- **A raised hand means a PERSON has to act.** On `/world` a body's hand goes up
  only for parked, over-budget, gone-quiet, stalled or orphaned claims and boxes
  that stopped answering. A row queued for a retry the lane will take by itself
  keeps its hand down, because a map that waves at everything is a map nobody
  glances at.
- **A slow thing is not a broken thing.** A box's Claude session is cold on its
  first turn, so `/chat` says "waking the <project> box…" and keeps polling.
  Nothing here times out into an error the operator would misread as a failure.

## Client boards come from the hub's snapshot

The BOARDS tab reads **`GET /api/dash/tickets-snapshot`** — one call carrying
every OS board, pushed by the hub every ~10 minutes. It is a snapshot, so its
age is always rendered (`generated_at_epoch` is epoch **seconds**).

**`GET /api/dash/kanban/board/:project` is dead surface for this SPA.** The
route still exists server-side, but nothing here calls it: it fetched each
client board live, one request per project, with a board token per project. The
snapshot replaced all of it, so `api.board()` and the client-side board
grouping helpers were removed rather than left as code nobody runs.

**A 200 from the snapshot route is not proof of a snapshot.** It answers `200`
with `{ok:false, unavailable:"..."}` when the watchdog read fails, and `200`
with `{ok:true, projects:{}}` before the hub's push has ever run. Both are
checked before rendering any per-project pane — otherwise the tab states "no OS
board for this project" for four projects that certainly have one, which is a
confident false claim about the client's own boards.

`triage_verdict` / `waiting_on` are read in **both field-name casings**, and
their **values** are trimmed + lower-cased before comparison (the hub normalises
names across the four board APIs but passes values verbatim, and those APIs
already disagreed on key casing). A malformed value — a number, a boolean, blank
— falls to the safe state rather than coercing into a real-looking verdict.
They resolve to three states, never two:

| state | condition | renders |
|---|---|---|
| `blocked_on_client` | `needs_clarification` + waiting on `client` | red WAITING ON CLIENT card |
| `assessed` | any other real verdict | neutral verdict chip |
| `untriaged` | the literal `"untriaged"`, **or** no verdict at all | quiet grey NOT YET ASSESSED chip |

The invariant: **untriaged is never a buildable signal.** An unassessed ticket
has to be visibly unassessed rather than quietly indistinguishable from one that
was looked at and cleared, so the chip is the faintest on the board and
deliberately not green. `waiting_on` alone is not an assessment — there is no
verdict to act on — and a block requires both halves.

## Chat targets

`/chat` talks either to the hub orchestrator (the default) or to one box's own
Claude session, chosen with the pills above the thread.

The screen polls `GET /api/dash/chat` **without** a `target` parameter. That read
is guaranteed to return every thread, each message carrying its own target, so
one request a tick covers the whole screen and every unread dot is exact from the
first poll. Filtering is client-side. `POST` omits `target` entirely for the
orchestrator, making a default-target send byte-identical to the old contract.

**The two reads have different cursor semantics, and mixing them is the bug.**
Untargeted returns one global `last_id`; `?target=X` returns that thread only and
its `last_id` is then *per-target*, so feeding it back as a shared cursor starts
the next tab too high and silently skips everything below it. Cursors are
therefore always **keyed**: the global cursor lives under a reserved
`ALL_THREADS` key that is not a legal project name, so a targeted read added
later gets its own key by construction and cannot inherit the global high-water
mark.

A reply carrying an `error` (e.g. `routing_failed`) renders as a failure bubble
with a SEND AGAIN action, never as a normal answer — and it does not count as the
box having answered, so the next turn is still treated as a first turn against a
cold session. Older rows that carry the failure only as self-describing text are
matched too, but conservatively: the pattern is anchored at the start of the
message, because painting a real answer as an error hides the answer that was
asked for.

`hub` is **not** a chat target — it is the `fetch_log`-only literal, so it is
filtered out of the target list.

A message with no `target` is treated as an orchestrator turn, so an existing
thread renders in full under HUB ORCHESTRATOR rather than disappearing.

## Layout

```
src/lib/      pure logic, unit-tested (sort, format, kanban, chat, stages, logstate, ideas, world, world3d, worldnav, webgl)
src/ui/       shared components (SortableTable, Modal, LogPane, primitives, icons)
src/screens/  one file per route
src/world3d/  the ONLY code that imports three.js — reached by dynamic import from /world alone
src/theme/    token names, the three built-in themes, the resolver, the boot script — the only JS allowed a colour literal
functions/    Cloudflare Pages Functions (the same-origin proxy)
tests/        node --test, covering the pure logic only
tests/drive/  headless chromium drive of the built bundle (not run by `npm test`)
```

### Theme tokens

Colour, font and radius live in the `:root` block of `src/styles.css` under
semantic names: `--surface-0/1/2`, `--rule`, `--text`, `--text-strong`,
`--text-dim`, `--accent`, `--ok`, `--warn`, `--err`, `--info`, `--glow`,
`--font-display/body/mono` and `--radius-sm/md/lg` (BH-4843). The older names
still work. `--bg`, `--panel`, `--line`, `--green`, `--muted` and the rest of
`LEGACY_ALIASES` in `src/theme/tokens.js` are aliases that read a semantic token.
The ramp steps with no semantic twin (`--green-lt`, `--line-active`, …) are
listed there as `EXTENDED_TOKENS`, along with the `--world-*` tones /world draws
with.

`src/theme/` is the only place in `src/` where JS may hold a colour literal.
Everything else writes a `var(--token)` string. SVG takes it through
`currentColor` or a `style` property. The three.js planet can't use a `var()`,
so it calls `readToken()` when it is created and again on the `mc:themechange`
window event (`onThemeChange()`), which the theme engine fires after every
repaint (below). `tests/theme-tokens.bh-4843.test.js`
fails on a hex literal outside `src/theme/`, on a legacy name that changed value,
and on a `var()` naming an undeclared token.

`docs/theme-tokens/` holds the before/after pairs for /now, /world (3D and the
hex fallback) and /pr/:project/:number at 1280px and 375px.
`docs/theme-tokens/capture.mjs` took them: it serves a build with the drive
fixtures, pins the clock in node and in the page, and turns on reduced motion.
It ran on main (c019d393) and on the BH-4843 build, and all 8 pairs are
byte-identical. On main alone, two of the mobile shots (world-3d, world-hex)
come out as one of two renders from run to run. Each branch shot byte-matched
one of the renders main itself produced, and that matching render is the one
committed as `before-`.

### Themes

Three built-in themes ship as token objects in `src/theme/themes.js` (BH-4844):
**Mill** (the default: warm ink and brick), **Paper** (warm paper surfaces, the
design reference's light theme; it replaced the `mill-light` theme in BH-4990, and a stored
`mill-light` in localStorage, the fleet row or a custom theme's `base` reads as
`paper` through `THEME_ALIASES`, the browser's own key rewritten on first read) and
**Phosphor** (the original green look; `src/theme/phosphor.js`, value for value
the `:root` block, which stays the no-JS fallback). Each one sets every colour
token in `:root`, and no rule outside `:root` carries a colour of its own.

Which theme a page gets, first match wins:

1. the viewer's pick, localStorage `ui.theme` (set on `/settings/appearance`, this browser only);
2. the fleet default, the `settings` row `ui.theme.default` (cached in localStorage `ui.theme.fleet`);
3. Mill.

A missing, empty or unknown value at any step falls through to the next.

There is no flash of the wrong theme. `themeBootPlugin()` in `src/theme/boot.js`
(wired in `vite.config.js`) puts an inline script straight after
`<meta name="theme-color">` in the built `index.html`, above every stylesheet.
It is generated from `themes.js` and the same `pickThemeId`/`paintTheme`
functions the app uses, so no colour is copied into `index.html` by hand. It
can't fetch, so it knows the fleet default only from the `ui.theme.fleet`
cache. After the first render `src/main.js` calls `syncFleetDefault()` once. It
reads the row, refreshes the cache (clears it when the row is gone; leaves it
alone when the read fails), and repaints only when there is no viewer pick and
the row names a different theme. The one known limit: a browser's very first
visit, with a fleet default other than Mill, paints Mill and then switches once
the read answers. Every repaint fires `mc:themechange`.

A theme also carries a `shape` (BH-4845): one value for every key in
`SHAPE_TOKENS` (`src/theme/tokens.js`): the three font roles, `--radius-sm/md/lg`,
`--radius-pill`, `--label-case`, `--display-stretch`, `--title-shadow` and
`--brand-shadow`. `paintTheme` and the boot script write it onto `:root` in the
same pass as the colours, so the first paint already has the right fonts and
corners. Mill and Paper share the Mill Floor form: Archivo condensed page
titles and brand, Geist body, Geist Mono uppercase labels, pills and column
heads, 10px panels (14px dialogs), pill buttons, no title glow. Phosphor's shape
equals `:root`, so it keeps its square JetBrains Mono look. Brick is for work in
progress only: the running step's fill (`--live`) and label (`--live-text`) on
/builds/:id, /now and /p/:project, the BUILDING card's left rule (`--accent`)
and its age. Done stays green and stale or blocked stays amber.

### Type and density

Every `font-size` in `src/styles.css` and in the screens' inline styles reads
one of ten `--fs-*` tokens declared in `:root`. That is the whole type scale,
and a readability pass moves those ten numbers rather than seventy-odd rules.
The 2026-08-29 pass moved the body from 13px to 15px and lifted the small print
(chips, ages, card meta, table cells, column heads) by 1-2px each, then took the
space back out of the padding: the same board fits in less height than before
while reading a size larger. Density lives in the layout rules themselves --
`.page`, `.section`, `.card`, `.kb__col`, `table.tbl`, `.stat`, `.tile` -- not
in tokens, because each of those is one number in one place.

Two rules the scale depends on: `.topbar__nav` scrolls inside its own box (one
link per screen, and screens keep getting added, so the nav must never push the
watchdog pill off a 1280px window), and `.tag` wraps instead of running past its
card, because a verdict is arbitrary text.

Under 600px a phone floor applies on top of the scale (BH-6001). It is one
`@media (max-width: 600px)` block in `src/phone-floor.css`, which `src/main.js`
imports right after `styles.css`. It lifts `--fs-3xs` to the 11px step, so no
text is under 11px and body stays 15px. It gives every link, button and row
action a 44x44 hit area through an empty centred `::after` sized by the
phone-only `--tap` token, so the visual size does not change. Where a clipper or
a dense neighbour would cut that area, the floor gives the box itself 44px: a
table-cell link, a block control, a bottom-nav tab, a section head with a link,
and a row that holds a control. Above 600px nothing changes.
`tests/tap-targets.bh-6001.test.js` pins the rules against the shared
components' markup. `npm run drive:tap` measures the real hit area with
`elementFromPoint` at 390px on /, /now, /alerts, /jobs, /kanban and a ticket
page.

Tables size to their columns, not to the window. `.tablewrap` is `fit-content`
capped at `max-width: 100%` and `table.tbl` is `width: auto`, so a six-column
read of short values stops where its content stops instead of spreading across a
1900px monitor. The 720px floor on the table stays: on a phone that is what
makes the wrap scroll sideways rather than crushing the columns.

A table whose rows carry a SENTENCE opts out of that, one table at a time:
`<${SortableTable} … wide/>` plus `flex: true` on the single column holding the
text. The wrap then fills the page, the content-sized columns keep their width,
and the flex column takes whatever is left over — truncating only when the row
genuinely runs out of room, with a `44ch` floor so it stays readable inside the
scrolling box on a phone. IDEAS is the one screen using it; fleet, jobs, costs
and the rest still hug their content. `npm run drive:ideas` is the proof.

That table now carries ten columns rather than nine (MOCKUP joined them), and a
tenth column is not free: every column whose cells are an em dash is as wide as
its own HEADER, and that width comes out of the one column with a sentence in
it. The pixels were bought back by running `.tablewrap--wide` at 8px side
padding instead of 12px, on this table only, mobile untouched. The sparse candidate view ends up slightly wider than it was on nine columns;
the full view gives up 20px and the margin over the drive floor is now 9px, so
an eleventh column has to pay for itself somewhere else;
`docs/ideas-mockup/README.md` carries the numbers and the shots.

### The 3D world, and why the flat one is still here

`/world` renders a planet: one territory per project (coloured by the project,
sized and raised by how busy it is), one billboard body per live claim standing
on its project's ground, a light-column beacon over anything a person has to
answer, and the idle boxes asleep on a ring in orbit. Tapping a body opens that
job, tapping a territory opens that project — the same links the flat map had.

Three rules hold it together:

- **three.js is behind a dynamic import that only `/world` reaches**, and only
  after `hasWebGL()` says the browser can use it. The main bundle does not carry
  the engine or the 3D maths; a phone that opens ALERTS never downloads either.
- **`src/lib/world3d.js` decides everything and draws nothing.** Where a body
  stands, how big an island is, which ground belongs to whom, whether a beacon
  lights — all pure functions over the scene `src/lib/world.js` already built,
  read in `tests/world3d.test.js`. `src/world3d/planet.js` only turns those
  numbers into meshes.
- **The 2D hex map from #147 is still a live path**, in `src/screens/WorldHex.js`.
  No WebGL, or a chunk that fails to load, renders it with a "2D mode" note
  instead of an apology. Both views carry the same links, and the lists under
  the scene (HANDS UP, TERRITORIES) carry them again for a keyboard.
- **The keyboard drives both renderers through one brain.** Arrow keys (and
  WASD) move a visible selection between bodies and territories, Enter or Space
  opens it exactly as a click would, Escape clears it. The move itself is
  spatial, not list order: `src/lib/worldnav.js` is pure, takes `{ id, x, y }`
  points in SCREEN coordinates and answers "what is to the left of this", and
  both renderers feed it their own numbers — the flat map its scene units, the
  planet this frame's projection, because a globe that is turning has no
  precomputable left. The input guard lives there too and is the reason typing
  in a filter box, or a keystroke inside a modal, never moves the selection.

#### Whose arrow keys are they

The window listener is bound only while `/world` is mounted, and it answers a
press only when nothing else on the page has a claim on it: focus on the body,
on nothing, or inside the scene box. Tab to a link or a table and the arrows go
back to scrolling the page. That is the deliberate trade — with nothing focused
the first arrow press selects the entity nearest the middle of the view rather
than scrolling, which is what makes the scene drivable without clicking it
first. Space is left alone until something IS selected, so page-down still
works on the way to the lists below. The scene box is a tab stop
(`tabindex="0"` + `aria-keyshortcuts`), and the selection is announced through
an `aria-live` region rather than by moving focus — the bodies are pixels in a
canvas, so there is no element to move focus to.

`node tests/drive/world-drive.mjs` serves `dist/` with the four `/world` reads
stubbed and drives it in headless chromium at 375px and 1280px: that the planet
actually renders lit pixels, that a tap opens the right page, that no WebGL
falls back, that a 403 on every read still renders the sign-in guidance, and
that the screen reads only the endpoints it read before and writes nothing.

`node tests/drive/density-drive.mjs` (`npm run drive:density`) serves `dist/`
with the jobs, pipeline and job-detail reads stubbed and drives /jobs, /kanban
and a job drill-down at 1280px and 375px: that body type is at least 15px and
the small print is off its old 9-11px floor, that no card or column head clips
its own text, and that nothing is laid out past the viewport. That last check
measures the widest box on the page rather than `documentElement.scrollWidth` --
`html, body { overflow-x: hidden }` means the document CLIPS an overflow instead
of reporting one, so the scrollWidth reading is clean even when the topbar is
half off screen. Pass `--tag before|after` to name the screenshots; the pair
under `docs/console-type/` was taken that way. `--theme mill|paper|phosphor`
(default `mill`) seeds `localStorage['ui.theme']` before the boot script runs and
also drives a /builds/:id page to check that theme's form from computed style:
title and body faces, that the theme's three faces actually loaded, `.panel` and
`.btn` radii, `.pill` case and face, the title shadow, and the running step's
`--live` fill and `--live-text` label.

`node tests/drive/world-keys.mjs` (`npm run drive:keys`) is the same idea for
the keyboard: real key events at 375px and 1280px, in BOTH renderers, checking
that the first press selects something, that the ring is actually drawn (an
ink-pixel count of the scene box, before and after), that the arrows reach
bodies as well as territories, that Enter opens exactly the link the card
points at, that typing in an input never moves the selection, and that a link
outside the scene taking focus hands the arrow keys back to the page's scroll.
The pixel counts need a still planet to mean anything, so those pages run with
`prefers-reduced-motion`; one more page runs with the frame loop going and
presses arrows 700ms apart, because a globe that has rotated between two
presses is the normal case rather than an edge one.

Tests cover `src/lib/` — the logic where a regression is silent (a sort that
floats unknowns to the top, a dedup that doubles a chat turn, a truncation note
that trusts the producer's flag). Rendering is verified by driving the built
bundle in a browser, not by snapshot tests.
