# In-app text dependencies: hold and release (BH-3946, slices BH-3963 and BH-3964)

Doc: BOARD-API-CONTRACT, BUILD-CONCURRENCY, EVENTS

## What changed

An in-app board ticket whose own text says `Blocked-by: TK-12` is now held
until TK-12 is done or its PR merged. When that happens it is released into the
next tick on its own, the same way a GitHub-Issues child is released by
`bin/unblocked-children.sh`. Before this, no board served a dependency
primitive, so such a ticket was buildable at once, and nothing woke the tick
when its blocker merged.

## The reader (`bin/lib/inapp-deps/core.sh`, BH-3963)

- A dependency line starts, after markdown noise, with `Blocked by`,
  `Blocked-by` or `Needs`. Its refs are board keys (`TK-12`) or `#N`. A
  `build after <KEY>` line counts only on a decompose child, meaning a
  description that also has `Order: n of N` and `Part of #KEY`.
- Code spans, fenced blocks, `<pre>` and `<code>` are removed before matching,
  so an example in prose is not a dependency.
- The newest comment that carries a dependency line decides the whole set. A
  comment counts only when it is not internal and not written by a self actor.
  If no comment carries one, the description decides. `Blocked-by: none` is a
  dependency line with an empty set, so it clears. A `Needs:` line with no ref
  is not a dependency line.
- **The primitive wins.** A ticket that carries a JSON boolean `blocked` is
  judged on it, and its text is not read.
- A ref is satisfied by status `done`/`closed`, a merged PR whose head is
  `ticket/<key>` or `ticket/<key>-rN`, or split-chain's merged record. One open
  blocker whose PR is open and not a draft makes the ticket STACKABLE on that
  branch. A ref the board cannot resolve is decided by `DEP_UNKNOWN_MODE`:
  soft releases it, hard holds it.
- `bin/triage-gate.sh --buildable` answers `BLOCKED dependencies <keys>` and
  touches `state/inapp-deps/<p>/<id>.held` for a BLOCKED or STACKABLE ticket.

## The release (`bin/lib/inapp-deps/release.sh`, BH-3964)

`inapp_deps_gate`, called by `bin/triage-gate.sh` step 1e, works one pass at a
time:

- It walks the `.held` markers oldest first, at most `INAPP_DEPS_MAX_LOOKUPS`
  of them per pass. Each one is a `board-fetch.sh --full` read. The pass also
  makes one board listing read and one PR list read. If the cap is hit, the
  pass logs `inapp-deps: lookup cap hit (<N> by-id reads) — <M> deferred to the
  next pass`, and the unvisited markers stay.
- A marker that is visited and kept is touched. That moves it to the back of
  the walk, so blocked markers cannot starve newer ones.
- A ticket that has moved (`in_progress`/`review`/`done`/`closed`, or its own
  `ticket/<key>` PR open or merged) loses its marker and gets no line. So does a
  ticket whose text no longer declares a dependency.
- A CLEAR or STACKABLE ticket gets its offered stamp, but only if it was not
  offered inside `INAPP_DEPS_REMIND_S` and its hold check is `clear`. The writes
  happen in this order, and the first failure stops the chain:
  `offered/<id>`, then `<id>\t<verdict>\t<base>\t<pr>` appended to
  `state/inapp-deps-ready-<p>`, then the `INAPP_DEP_READY` log line. The gate
  then prints the id, which makes step 1e answer `RUN inapp-deps-ready`. On
  CLEAR the marker is removed. STACKABLE keeps it, so the ticket is offered
  again as UNBLOCKED once the window has passed.
- A failed read stamps nothing and keeps the marker. A failed read is a listing
  read, a ticket fetch, or a PR list while fleet-conf names a repo.

`inapp_deps_take_lines`, called by `bin/lib/rt/scope.sh` `inapp_released_lines`,
handles the take side:

- It reads the ready file and deletes it. A ready file older than the window is
  deleted unread.
- It re-judges each id with the same pass, and the hold check runs again. It
  prints a line only when the ticket is still releasable:
  `board <bid>: UNBLOCKED <id> "<title>" (<KEY> — text dependency <keys>
  satisfied (done or PR merged); …)` or `board <bid>: STACKABLE <id> "<title>"
  base=<branch> parent-pr=<url> (<KEY> — Blocked-by <key> is still open but its
  PR is open too — …)`.
- An id it does not hand over has `offered/<id>` cleared, so the gate looks at
  it again next pass.
- `bin/run-triage.sh` sets no board credentials, so this side resolves them
  itself. The board prefix comes from `fleet-conf.sh`, and the base and token
  variables come from `bin/lib/board-creds.sh`, read from the project env file.
- Its self actors are `SELF_ACTORS`, or else `${BOARD_SELF_ACTORS:-System}
  Harness`. On the four named boards that is not the gate's per-project
  actor, so there a non-internal harness comment counts as a person's. The
  safe direction is a HOLD that suppresses the line.

**HOLD wins.** `inapp_deps_hold_check` maps the in-app thread onto
`bin/lib/hold.sh` `hold_classify`:

- The ticket becomes an open issue carrying `ai-build`, so only the thread,
  title and body decide.
- A comment is a Bot when it is internal or a self actor wrote it.
- `held` logs `INAPP_DEP_HELD <KEY> — automatic release suppressed: <why>` at
  most once per window, rate-limited by `heldlog/<id>`, and stamps nothing.
- An unreadable ticket is `unreadable`, never `clear`.

Nothing on either path writes to the board or GitHub, and nothing calls a model.

## Events (logs/<p>.log)

- `INAPP_DEP_READY <KEY> (<keys> satisfied)` / `(stackable on <base>)`
- `INAPP_DEP_HELD <KEY> — automatic release suppressed: <why>`
- `inapp-deps: lookup cap hit (<N> by-id reads) — <M> deferred to the next pass`

## State (box-local, every file a re-derivable watermark)

- `state/inapp-deps/<p>/<id>.held`
- `state/inapp-deps/<p>/offered/<id>`
- `state/inapp-deps/<p>/heldlog/<id>`
- `state/inapp-deps-ready-<p>` (one-shot)

Losing any of them costs at most one delayed release, because `--buildable`
re-judges at launch.

## Switch and knobs

- `inapp-deps-off`: a settings row `switch.inapp-deps-off[.<box>]`, else
  `flags/inapp-deps-off`. It makes the buildable arm, step 1e and the scope
  hook inert.
- `INAPP_DEPS_REMIND_S` (21600) and `INAPP_DEPS_MAX_LOOKUPS` (10) come from
  `catalog/lanes.d/_lib.inapp-deps.json`.

## Tests

- `tests/inapp-text-deps.bh-3963-test.sh` covers the reader and the buildable
  arm.
- `tests/inapp-text-deps-release.bh-3964-test.sh` covers the release through the
  real `bin/triage-gate.sh p1` and `inapp_released_lines`.
