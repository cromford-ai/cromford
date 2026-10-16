stages: preplan plan execute fix review qa prodqa

PERFORMANCE BY DEFAULT (iron law, 2026-10-13). Every screen must feel instant. Plan, build, test and review speed like any other requirement.
- One context setup per request, not per read (one statement sets tenant/role settings; reads share the transaction or pooled connection).
- Independent reads run in parallel (Promise.all / parallel server components). A `for … await` over independent loaders is a defect.
- Layouts and shells read counts/EXISTS, never lists.
- Every route has `loading.tsx`; slow sections stream in `<Suspense>`.
- Config, spec, company and user reads go through a per-request memo (React.cache).
- Ship only what the screen shows: needed columns, paginated lists, a payload budget.
- Every list filter + sort has an index, checked with EXPLAIN at seeded volume.
- Function region = DB region; explicit pool config. No live auth-provider call per load where verified session claims suffice (bounded staleness + revocation test).
- Budgets are tests: a statement-count test per page loader on a seeded DB; Lighthouse mobile LCP <= 2.5 s, CLS <= 0.1 on key screens. A perf ticket's claim needs before/after numbers; other tickets are not asked for a perf proof. A data-layer change keeps a wrong-tenant test (0 rows).
- PLAN must list: the reads, which run in parallel, the expected statement count, the indexes, the skeleton.
- REVIEW notes (a BLOCK only over the REVIEW LEVELS speed thresholds, or on a perf ticket): a new sequential await over independent reads; a list read in a layout/shell; a route without loading.tsx; an unmemoized repeated config read; an unindexed list query; unbounded rows to the client; a speed claim without numbers.

BUILDING FROM A DESIGNER'S PROTOTYPE (iron law, 2026-10-13).
- The reference is the designer's RENDERED prototype (computed styles), not the token file alone; prototype stylesheets override their own tokens. Compare with getComputedStyle at 1440 and 390 px, light and dark. Non-token values go in a scoped per-component override file, never global token edits, never hex in app CSS.
- UI PRs carry side-by-side screenshots and a computed-value table; a visual check to a person's eye on core-flow screens; px deltas and copy are PR-body notes, never a human step. A prototype defect is flagged, not copied.
- A redesign of an existing product is a reduction/re-presentation: reuse existing components, loaders and analysis; never rebuild what exists; core parts (integrations, analysis, data) do not change unless the ticket says so. Old screens are hidden behind a DB switch, never deleted.
- Tests check what a user can see: assert toBeVisible() and open menus/drawers; toHaveText on hidden DOM is not proof. When a UI element or landing route moves, grep the e2e suite for every dependent locator/redirect assertion and fix them in the same PR with one shared helper.
