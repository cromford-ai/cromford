## Building Software (when a ticket IS ready)

- Work in a feature branch in the project repo; one ticket = one branch = one PR.
- **Verify before PR:** `npm install` if needed, then typecheck/build (`npm run build` or the project's stricter `tsconfig.build.json` path). Never open a PR you haven't built locally.
- **Estimation is in AI coding sessions, never human time.**
- PR bodies: what/why, verify evidence, and end with the standard Claude Code attribution footer.

### Data & config iron laws
- **Additive-only schema changes**; every migration that CREATEs a table must `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` (Supabase projects are deny-by-default RLS as standing policy).
- **DB-driven assumptions:** model inputs, business parameters, targets, rates, thresholds, and mappings are DATABASE-driven, not hardcoded — editable in the app, code constant only as documented fallback. If you touch code with a hardcoded assumption, convert it as part of the change.
- **AI model config:** agents never hardcode `claude-*` model strings — resolve through the project's DB-backed resolver (seed a config row for new agents). A hardcoded model string in agent code is a bug; convert it.
- **Data independence:** any integration with an external API keeps its OWN local copy of the data it reads (idempotent + resumable ingestion, raw payload snapshots, honest per-record status). Ask: "if this vendor cut us off tomorrow, what would we lose?"
- **Exactly-once/idempotent writes** everywhere money or records move.
- **Indexes and retention, every table from day one (the operator, 2026-10-14; BH-6730):**
  - Every new table ships with the indexes its queries need, in the same migration: name the index that serves each WHERE, JOIN, ORDER BY and GROUP BY.
  - A test runs `EXPLAIN QUERY PLAN` (SQLite/D1) or `EXPLAIN` (Postgres) on seeded data at realistic volume and asserts the hot queries use an index (no full `SCAN` of a large table). A later index goes in a new additive migration (`CREATE INDEX IF NOT EXISTS`).
  - No correlated subquery that re-runs per row over a large table. A poll or dashboard that recomputes an aggregate over all history gets a summary table or a short cache.
  - Every growing table has a retention rule: what the rows are for, how long they keep value, and a scheduled job that deletes or archives the rest (window in a settings row, dry-run first, one audit row per run). Money and history rows are archived, never silently deleted.
  - Reviews BLOCK on a new per-row correlated subquery over a large table; a missing index or retention rule is a review note that names the fix (BH-7123).
- **De-AI voice** on every AI→human text surface (use the project's `withHumanVoice`-style wrapper if present; a new LLM call site without it is a review note).
- **Never hand-append to a shared index.** If a build needs to register itself in a repo-wide table, list or registry, it writes its OWN file keyed by the ticket and a generator concatenates them. N concurrent builds appending to one file is N guaranteed conflicts on a hunk no ticket is about. Any file every build touches is a serialization point in a system designed to be parallel.

### UI/UX standards (every interface, no exceptions)
- **Mobile-optimized by default:** responsive flex/grid, relative units, touch-friendly targets, readable at ~375px, NO horizontal body scroll (wide content scrolls inside its own `overflow-x:auto` container). Check a narrow viewport before calling UI done.
- **Never native browser dialogs** (`confirm`/`alert`/`prompt`) — always an in-app modal styled to the project theme (reuse the project's confirm-dialog component; Escape-to-cancel, focus handling). Swap natives for modals when touching a file that has them.
- **Sortable table headers on EVERY data table:** click to sort asc, again for desc, visible direction indicator, aria-sort/keyboard a11y. Use the project's shared sortable-table component; retrofit tables you touch; never ship a new table without it. Client-side sort for loaded data; for server-paginated tables the header click drives the server `orderBy` (never sort just the current page and imply it sorted the whole set).
- **List/table over big cards for any browse/index/library/triage page** — dense rows beat card walls. Big cards only for a genuine dashboard/hero or single featured object. Convert card-grid index pages to list/table when you touch them.
- **No dead rows:** every identity cell links to its detail view.
- **Full recursive drill-down:** every level of detail the system holds must be reachable by clicking — detail pages are themselves drillable down to the atomic record. The test on any page: "what's the next question a user would click into?" — make it clickable. An aggregate we store components for but can't expand is a finding; fix it.
- Severity in review (BH-7123): the UI rules above are build defaults. A reviewer notes a miss; it is a BLOCK only when a user cannot finish a core flow.

### Performance by default (the operator, 2026-10-15; BH-6946)
- PERFORMANCE BY DEFAULT (BH-6946): a plan for a screen or loader lists its reads, which of them run in parallel, the expected statement count, the indexes they use, and the loading skeleton.
- PERFORMANCE BY DEFAULT (BH-6946), each one a [NOTE] (a BLOCK only on a measured regression on a key screen over the REVIEW LEVELS thresholds, or on a perf ticket): a new sequential await over independent reads; a list read in a layout where a count would do; a route without loading.tsx; a repeated config read without a request memo; a list query without a matching index at seeded volume; unbounded rows to the client; a speed claim without before and after numbers; a client snapshot that holds a token, is not keyed by user and company, or survives sign-out; a key screen with two or more independent requests in sequence before its first content.

### Code-level gotchas that bite in PRs (from the operator's global rules)
- **Never use `VERCEL_URL`/`.vercel.app` for serverless self-fetch** — Deployment Protection 401s it. Always the custom production domain for internal `fetch()` from crons/webhooks.
- **`CRON_SECRET` comparisons: always `.trim()`** — trailing-newline env values silently break header equality.
- **Prisma:** never `prisma db push` toward prod; confirm the target DB before any schema command. Turso/libsql doesn't support `db push` at all — manual SQL there.
- **New env var → every environment**: if a change introduces an env var, the PR body must list where it needs setting (Vercel prod/preview, CI workflows) — an unset var in one environment is a shipped bug.
- **Supabase**: new tables get RLS enabled in the same migration; anon/authenticated grants stay revoked.

### Database bulk work (when a ticket involves data migration/backfill)
- Multi-row INSERTs (up to `floor(65535/numCols)` rows/statement) with `ON CONFLICT` upserts — never row-at-a-time loops.
- Never OFFSET-paginate big tables — cursor on an indexed id (`WHERE id > $cursor ORDER BY id LIMIT n`).
- Make backfills resumable + idempotent (ID-diff pattern: read source ids, diff against dest, fetch+insert only the missing).

### Coding discipline (execute stage)
- Think before coding: state assumptions; if the ticket thread allows multiple interpretations, that's a PLAN_BLOCKED, not a guess.
- Simplicity first: minimum code that solves the ticket; no speculative flexibility; would-a-senior-engineer-approve is the bar.
- Surgical changes: touch only what the ticket needs; match existing style; don't refactor adjacent code; every changed line traces to the request.
- Goal-driven: turn the ticket into verifiable checks and loop until they pass. Update relevant repo docs/CLAUDE.md in the same PR when behavior changes.
- **A test suite that sources a helper handles the failure on the same line**: `. "$(dirname "$0")/lib/scratch.sh" || exit 1`. Never a bare CWD-relative `. tests/lib/...` (it only resolves when the suite is run from the repo root) and never a source with no handler — an unhandled source dies mid-suite and reads as an ordinary test failure. In cromford this is enforced: CI's `tests/ sourcing lint` step is a hard red on either shape.

### Honest claims
- Never claim "tested as a user" unless a real UI was driven by hand and the real outcome observed. Build-proof (`npm run build`, unit tests) is stated as exactly that. If verification is partial, the PR and board comment say so plainly — a failed check is the headline, not a footnote.
