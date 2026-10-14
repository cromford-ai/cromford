# BH-4991: the ticket page (2026-10-09)

Wave 2 of BH-4947 (Mission Control, "The Line"). Built on the Mac by a lead
assignment; the plan is `.harness/specs/BH-4991/plan.md`.

## Scope decision (lead, 2026-10-09)

This PR is read-only: the ticket page, the key links, and the agent session
feed (the newest pushed transcript as turns, plus the live marker). "Step in" is
shown disabled, labelled coming soon, and linked to issue 5839, which carries the
steer-notes design (a jobs table, a read at the agent-call step boundary, a hub
delivery for ticket comments and holds) with its acceptance tests. Issue 5820
covers the console's missing comment and hold actions. A first cut of the
step-in code is in commit 7684d3f8c on this branch's history.

## Facts found

- No guarded comment or hold action reaches GitHub from the console (5820).
- No message reaches a running build: a Chat project target goes to the box's
  own session.
- A transcript is pushed when a stage ends, so the feed cannot stream a stage
  while it runs. The live marker says the build is working.

## Limits

- Kanban pipeline cards are links to their PR or build (pinned by
  `tests/kanban-list-render.test.js`), so the key inside one is not a second
  link. The Kanban list view links it.
- Alerts and CI carry no ticket field; keys inside free-text alert lines are not
  linked, because no prefix list tells `BH-4991` from `SHA-256`.
