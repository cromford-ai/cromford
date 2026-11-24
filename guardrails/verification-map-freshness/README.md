# Guardrail: verification-map freshness

**Principle:** a PR that changes what the app *does* changes the map that says
how to reach and drive it, in the same diff. "Without enforcement, the principle
decays in months."

**What it catches:** a diff touching route/screen files (`src/app/**`,
`app/**`, `pages/**`, `src/pages/**` by default) with no accompanying change
under `docs/verification-map/`.

**Tool:** shell (`check.sh`). Wave B of the SDLC plan builds the map itself; this
is its freshness half, built generically ahead of it so the map lands with a
working gate instead of a TODO.

**The other half now exists:** `bin/verification-map.sh` (`render` writes the
PLAN primer at `state/<project>-context.md` from a repo's map; `orient` is the
one-line availability note injected into plan/execute/review), the per-feature
shape in `docs/verification-map/TEMPLATE.md`, and the backfill ticket in
`docs/VMAP-BACKFILL-TICKET.md`. Adopt this check in the same wave as that ticket.

```bash
guardrails/verification-map-freshness/check.sh origin/main   # CI form
VMAP_FILES=list.txt guardrails/verification-map-freshness/check.sh  # testable form
```

**Configuration (env):**

| var | default | what |
|---|---|---|
| `VMAP_ROUTE_GLOBS` | `src/app/* app/* pages/* src/pages/*` | what counts as a behavior change |
| `VMAP_MAP_PREFIX` | `docs/verification-map/` | where the map lives |
| `VMAP_FILES` | — | a changed-file list; set it and no git call is made |

**Three honest no-ops, each printed rather than silent:** the repo has no
`docs/verification-map/` yet (not adopted), the diff touches no route files, or
the base ref could not be diffed. Each exits 0 saying which — a check that
cannot run must never look like a check that passed.

**Adoption detection reads the CHECKOUT, not the diff.** Reading it off the
changed-file list would mean a PR that deletes the map reports "not adopted" and
passes — the exact PR this check exists to stop.

**Applicability:** any repo with a user-facing app. Adopt it in the same wave as
the map backfill ticket, not before: on a repo with no map it is a no-op by
design, so turning it on early is harmless but also pointless.

**Escape hatch:** `skip-guardrail` label + `GUARDRAIL_JUSTIFICATION` (see
`../README.md`). This is the check that will legitimately need it most often —
pure refactors and typo fixes under `src/app/**` are real.
On a Mergify batch draft the hatch reads each source PR and exempts only the
files a hatched source PR changed; the step needs the `GUARDRAIL_HEAD_REF`,
`GUARDRAIL_PR_AUTHOR`, `GUARDRAIL_DRAFT_BODY` and `GH_TOKEN` env lines (see
`../README.md`, "On a Mergify batch draft").

## Adoption per repo

Filled only from probes, never from memory. `map` is
`gh api repos/<slug>/contents/docs/verification-map --jq length` and `workflow`
is `gh api repos/<slug>/contents/.github/workflows/verification-map-freshness.yml --jq .name`;
a 404 reads `n` only when the same token can see the repo itself
(`gh api repos/<slug>`). The slugs come from `bin/fleet-conf.sh <project> repo`.

| repo | map | workflow | as of | probe |
|---|---|---|---|---|
| example-org/project-3 | unknown (probe failed) | unknown (probe failed) | 2026-09-24 | both contents probes 404, and so does `gh api repos/example-org/project-3`: the build box's token cannot see the repo |
| example-org/project-1 | unknown (probe failed) | unknown (probe failed) | 2026-09-24 | both contents probes 404, and so does `gh api repos/example-org/project-1`: the build box's token cannot see the repo |
| example-org/project-4 | unknown (probe failed) | unknown (probe failed) | 2026-09-24 | both contents probes 404, and so does `gh api repos/example-org/project-4`: the build box's token cannot see the repo |
| example-org/project-5 | unknown (probe failed) | unknown (probe failed) | 2026-09-24 | both contents probes 404, and so does `gh api repos/example-org/project-5`: the build box's token cannot see the repo |
| example-org/project-2 | unknown (probe failed) | unknown (probe failed) | 2026-09-24 | both contents probes 404, and so does `gh api repos/example-org/project-2`: the build box's token cannot see the repo |

Re-run the probes with a token that can read the app repos, and replace a row
only with what they answer.

**The adoption path for a repo with no map:** `bin/feature-map-draft.sh <project>`
(or `--all`), run by an operator on a builder box. It drafts the map by driving
the app, adopts this workflow if it is absent, and opens a PR on
`feature-map/draft`. It never merges. The PR body says `FRESHNESS: wired` or
`FRESHNESS: NOT wired, adopt before relying on the map`.
