# VERIFICATION MAP BACKFILL TICKET (draft — NOT filed)

The ready-to-file `ai-build` body that puts a verification map into a repo that
does not have one. It is the initial producer of `docs/verification-map/`: the
harness never copies a map in, because a map assembled by a script that never
opened the app is a map of the router, not of the product.

Same body serves both paths:

- **new projects** — `bin/load-project.sh <owner/repo> --vmap-ticket` files it
  automatically at onboarding (it substitutes `<PROJECT>` and `<REPO_SLUG>`),
- **existing projects** — file it by hand:

```bash
gh issue create -R <owner/repo> \
  --title "verification map: explore the app and draft docs/verification-map/" \
  --label ai-build --body-file docs/VMAP-BACKFILL-TICKET.md
```

Everything below the line is the issue body.

---

## Scope

This repo has no `docs/verification-map/`. Build the first one: the record of
every user-facing feature, how a person reaches it, and how it is driven and
verified. It is what the harness PLAN stage reads as its project primer (via
`state/<project>-context.md`) and what a QA session takes its screens and
selectors from instead of rediscovering them every run.

Deliverable — a PR adding:

- `docs/verification-map/README.md` — an index table (feature → entry file →
  primary route) plus a `## Driving conventions` section. Both are read by name:
  `bin/verification-map.sh` copies the index into the primer and extracts the
  conventions by that heading, so keep the heading.
- `docs/verification-map/<feature>.md` — one per user-facing feature, in the
  shape defined by `docs/verification-map/TEMPLATE.md` in cromford: what it
  is, how a user reaches it, key routes/screens, selectors (ARIA first, then
  `data-*`, never class chains), preconditions/seed needs, the observable
  end-state that proves it worked, 1-3 bullets on what usually lies (the ways
  it looks right but isn't), and an honest **manual-only** section for
  anything a script must not or cannot drive.

## How to build it (the part that decides whether this is worth anything)

1. **Enumerate routes mechanically** — the route tree (`src/app/**`, `pages/**`,
   or this repo's equivalent) is the completeness check: every user-facing route
   is accounted for by exactly one entry, or is explicitly listed as
   not-user-facing (API handlers, redirects, layouts).
2. **Then open the app.** Sign in, navigate, and write each entry from what the
   screen actually does. An entry written from source alone describes the
   router; the map's whole value is that someone reached the feature once and
   wrote down how.
3. **Group by feature, not by file.** A feature that spans four routes is one
   entry with four routes in it, not four entries.
4. **State absences honestly.** A screen you could not reach (no seed data, no
   entitlement, an external redirect) gets an entry that says so and names what
   would be needed. Silence there reads as coverage.

## Acceptance tests

In this repo's own framework (see its `CLAUDE.md` verification contract; if it
has none, say so in the PR and provide a manual checklist instead):

- a test asserting **every** entry file in `docs/verification-map/` has the
  required sections (what it is / how a user reaches it / routes / selectors /
  preconditions / what usually lies) — a stub entry with a heading and nothing
  under it must FAIL it;
- a test asserting `README.md` lists every entry file and that every listed file
  exists — an entry added without an index row, and an index row pointing at a
  missing file, must both FAIL it;
- a test asserting every top-level user-facing route in the route tree appears
  in at least one entry, with an explicit, commented exclusion list for the
  routes that are deliberately not user-facing.

Red before green: write these first against the empty map and record the failing
output. A map test that passes before the map exists is testing nothing.

## Freshness (why this does not rot)

The harness guardrail `verification-map-freshness` fails any PR that changes
route/screen files without touching `docs/verification-map/`, with the standard
escape hatch (`skip-guardrail` label **plus** a written
`Guardrail-Justification:` line). If this repo has not adopted the guardrail
pack yet, adopt this one check in the same PR and wire it into CI — a map with
no enforcement is a map that is wrong within a month, and a wrong map is worse
than none because agents and QA sessions drive it as if it were true.

## QA screens

None of its own — this ticket adds documentation. The proof is the entries
themselves: the PR body names, for at least three entries, the screen that was
actually opened while writing it.

## Out of scope

- Changing app behavior. If the exploration turns up bugs, file them separately
  and link them here.
- Writing entries for features that do not exist yet.
