# PROTECTED PATHS on Mission Control SETTINGS (BH-4147, BH-4140.2)

The lead's protected-path globs, one table per repo, editable from the console.
The rows are `lead_protected_paths` in the jobs D1 (BH-4146). The lead lane
(`bin/lib/lead-authority.sh`) reads these rows (BH-4148), so a row added here
gates the next la_decide.

## Where it is

- Nav: **SETTINGS** → the **HUB** tab → the **PROTECTED PATHS** section (below
  TOKEN HEALTH). It is not on a project tab.
- Route: `/settings` (hub tab only, no `?project=`).
- Reads: `GET /api/coord/lead-protected-paths?repo=<owner/name>` (the coord
  proxy passes the GET through to `GET /api/lead-protected-paths`) and
  `GET /api/coord/settings/lead_authority_mode`.
- Writes: `PUT /api/coord/lead-protected-paths` `{repo, glob, op: add|remove}`.
  The proxy's `WRITES` row (`console-ui/functions/api/coord/[[path]].js`,
  `protectedPathBody`) refuses a non-string repo/glob or any other op with a
  400, and stamps `added_by` and `actor` with the session actor (the Access
  email, or `console`). POST/DELETE/PATCH are 405. The mode's SET button writes
  `PUT /api/coord/settings` `{key: lead_authority_mode, value, note}`.

## Selectors

- Section: the `PROTECTED PATHS` section title.
- Mode hint: the line starting `lead_authority_mode:` and its `SET human` /
  `SET lane` button (no button when the row cannot be read).
- Inputs: `input[aria-label="repo"]` (starts at `example-org/cromford`; Enter
  or blur loads it) and `input[aria-label="glob"]` (Enter adds).
- Buttons: `ADD`; one `REMOVE` per row; the modal's `REMOVE` / `CANCEL`.
- Table headers: REPO, GLOB, ADDED BY, ADDED AT (each sorts, `aria-sort` on the
  `th`); REMOVE is unsortable.

## States

- Loading: a skeleton.
- Read failure: a banner `could not load — protected paths for <repo>: <error>`
  with RETRY. Never the empty state.
- Zero rows: `NO PROTECTED PATHS` naming the repo.
- Add: `added <glob> to <repo>` on `created:true`, `<glob> is already
  protected` on `created:false`, the worker's error verbatim otherwise.
- Remove: `removed <glob> from <repo>`; a 404 reads `already removed`.

## QA screens

1. `/settings` desktop: sort by GLOB twice and watch the order and arrow flip.
   Add `example-org/cromford` + `tmp/**`; the row appears with your actor as
   ADDED BY. REMOVE it: the in-app modal opens, Escape cancels and the row stays;
   REMOVE then confirm and the row is gone.
   `GET /api/coord/lead-protected-paths?repo=example-org/cromford&all=1`
   shows it with `removed_at` set.
2. `/settings` at 375px: the same flow; the table scrolls inside its own
   `overflow-x:auto` box and `document.documentElement.scrollWidth <= 375`.

## Tests

`cd console-ui && node --test tests/protected-paths.bh-4140.test.js` and
`tests/protected-paths-console.bh-4147-test.sh`.

**Not yet driven in a browser.** The suite mounts the real panel in a fake DOM
with a faked fetch and drives the real proxy `onRequest`. Nothing here has been
run against the deployed console or the live worker.
