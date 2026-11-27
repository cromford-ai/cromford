## Navigation registry (BH-10233)

NAVIGATION REGISTRY (iron law, BH-10233, 2026-11-26). A project with an app menu builds its navigation on ONE page registry. A page address is never hard-coded across files. Lesson: project-3 OS had 3 navigation lists and 1,877 literal page addresses in 685 files. One page move touched up to 110 files, and menu labels drifted from page headings. project-3 PR #1728 fixed it with one registry, `hrefOf(id)` helpers and ratchet guards.
1. Each page is listed once in the project's page registry: id, route, label (= page heading), section, parent, access roles, old routes.
2. The sidebar, section menus, quick links, breadcrumbs, back links, redirects and `revalidatePath` calls read the registry through a helper such as `hrefOf("<id>")`. A new literal page address is a finding.
3. A page move is one registry row: the new route, with the old route in its legacy list. The redirect comes from that list.
4. A project with a menu and no registry: the first navigation ticket adds the registry and its guards first, additively (no consumer changes), with today's counts as ceilings.
5. Guards: every page has 1 row; every menu item resolves to a row; menu label = page heading; a NEW file holds no registered page address; every old route redirects; the total of literals never rises.
6. Do not add a second navigation list (tabs, hubs, route constants). Extend the registry.
- PLAN for a navigation change names the registry rows it adds or changes, or adds the registry first (item 4).
- REVIEW, each a `[NOTE]`: a new hard-coded page address in the diff; a page move done by search-and-replace across files instead of one registry row; a menu label that differs from its page heading; a second navigation list. A moved page whose old route does not redirect, or a menu link that goes nowhere, stays `[BLOCK core-flow-broken]`.
