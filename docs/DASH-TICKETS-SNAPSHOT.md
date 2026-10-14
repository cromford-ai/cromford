# Mission Control kanban: truthful ticket statuses (2026-08-24)

The hub pushes a compact all-boards ticket snapshot to the watchdog worker
every 10 minutes (bin/tickets-snapshot-push.sh, hub cron). No board tokens
leave the fleet; the CF side only ever holds the rendered snapshot.

Store: watchdog KV key `tickets-snapshot`.
  GET  https://harness-watchdog.operator.workers.dev/api/tickets-snapshot?s=<secret>
  POST same URL (hub only) replaces it.
Shape:
  {"generated_at": <epoch-seconds>,
   "projects": {"project-1": {"board_id": "...",
      "tickets": [{"key":"TK-166","status":"done","title":"...","updatedAt":"..."}]}, ...}}
Statuses are the boards' own values: todo | in_progress | review | done.

## Console-worker pass-through (fold into local source)
The SPA must read same-origin (dash cookie), so add to harness-console:

    app.get("/api/dash/tickets-snapshot", async (c) => {
      // reuse the dash-cookie auth your other /api/dash routes use
      const r = await fetch(
        `https://harness-watchdog.operator.workers.dev/api/tickets-snapshot?s=${c.env.HARNESS_SECRET}`);
      return new Response(r.body, { headers: { "content-type": "application/json" } });
    });

(HARNESS_SECRET is already a binding on harness-console. If the watchdog's
ping secret rotates away from HARNESS_SECRET someday, mirror the new value as
a console binding.)

Kanban then renders projects[*].tickets grouped by status, with
generated_at driving the "snapshot Xm ago" banner. First push verified live
2026-08-24; the GET returns ~all four boards (659 tickets at first push).

## Lane enrichment: third-party harnesses on the dash (2026-08-24)

Third-party harnesses (collaborator-1's partner lane on project-1, external teams)
never ping our watchdog, so they can't be boxes — but their work is visible
on GitHub, and the hub now joins it into the same snapshot. No watchdog
worker change was needed (the blob passes through KV verbatim).

New fields, additive to the existing shape:

- Every `in_progress`/`review` ticket whose key matches an open PR (or,
  failing that, a branch) carries:
    "claim": {"actor":"collaborator-1","fleet":false,"kind":"pr",
              "ref":"agent/TK-249-r2","pr":597,"pr_url":"...","at":"...Z"}
  `fleet:true` means the actor is the shared operator PAT — i.e. one of OUR
  harness lanes (they are indistinguishable from each other by design).
  `fleet:false` is a third-party lane or a human dev. `kind:"branch"` means
  no PR yet; `at` is then the branch tip's commit date (an old date = a
  stale branch, render it honestly).
- Each project gains `external_lanes`: the non-fleet claims rolled up,
  `[{"ticket":"TK-249","actor":"collaborator-1","kind":"pr","pr":597,...}]`.

### Console rendering (fold into local harness-console source)

1. Pipeline tab: rows for tickets with `claim.fleet === false` render as
   BUILDING (external — <actor>) with the branch/PR link and `at` as "last
   activity". This fixes "we approved a PRD but the pipeline shows nothing"
   when the other project-1 harness claimed it.
2. Fleet page: synthesize one pseudo-box row per distinct external actor
   (union of all projects' external_lanes), e.g.
   "partner (collaborator-1) — project-1 — PR #597 — active 14:01Z".
   No ping data exists for these rows; show snapshot age, not up/down.
3. Kanban cards: a small badge with claim.actor on claimed cards; fleet
   claims can render as "harness" without naming a box (the PAT is shared).

Actor map (maintain console-side): operator = our fleet (any lane);
collaborator-1 / partner-dev = partner (collaborator-1). Anything else: render the
login raw.
