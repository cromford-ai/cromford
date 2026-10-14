# In-app ticket dependencies: the read side, and why a board webhook is not the fast path

Doc: EVENTS, BOARD-API-CONTRACT

**What changed.** The in-app boards are growing a dependency primitive
(`parentId`, `dependsOn`, `children`, and a derived `blocked` boolean). The
harness reads it and writes none of it. The field contract — shapes, the
`null`-never-`""` rule, `[]`-versus-absent, and the boolean-only feature
detection — lives in `docs/BOARD-API-CONTRACT.md`, "### Dependencies" (line
368). It is not restated here; one copy is the point.

The read side is five lanes, split across #899-#903 under parent #815:

- **the fingerprint** (#899, landed) — `bin/triage-gate.sh` `fetch_fingerprint`
  carries `blocked`, `parentId` and `dependsOn` per ticket, and only when
  `blocked` is a JSON boolean, so an un-adopted board's bytes do not move;
- **the `--buildable` refusal** (#900) — a ticket with `blocked: true` is
  refused before the `waitingOn` and `triageVerdict` checks, because it is the
  block that clears itself;
- **the release line** (#901) — a `true → false` flip between the consumed and
  the live fingerprint becomes an `UNBLOCKED` scope line, in
  `bin/run-triage.sh` and its twin `bin/lib/rt/scope.sh`;
- **the parent close** (#902) — `bin/decompose-parent-close.sh` closes a parent
  whose `children[]` are all `done` and whose children's own records confirm it;
- **the prompt rule** (#903, this note's PR) — one line in each of the seven
  in-app triage prompts, next to their `needs_clarification` rule: a
  `blocked: true` ticket is not actionable, is not stale, is not owed, and
  releases itself when the board flips the flag.

**The webhook finding (documented, not coded).** The boards intend to send
`releasedChildren: [ids]` on a status change, so a child released by its
blocker finishing could wake a tick immediately instead of waiting for the next
cron. Two shapes were considered: carry those ids into the tick's scope, or
force an unscoped tick. Neither is reachable from a board today.

`docs/EVENTS.md` section 3, "What the receiver believes" (line 113), is the
whole receiving surface, and its only route is `POST /webhooks/github`
(`worker/jobs/src/index.js:2008`). That route is HMAC-bound to
`GITHUB_WEBHOOK_SECRET` and answers 503 when the secret is unset
(`worker/jobs/src/index.js:2010`) — inert until an operator arms it, never
allow-on-missing-secret. It verifies GitHub's `x-hub-signature-256` over the raw
body. No in-app board holds that secret, and none of them signs that way, so no
board can deliver to this receiver at all: a `releasedChildren` payload has
nowhere to arrive.

**So the fast path is the cron tick.** The next per-project triage tick (at most
~10 minutes out, offsets from `fleet.conf`) diffs the fingerprint and emits the
`UNBLOCKED` scope line through the `# >>> inapp dependency release` block that
#901 ships. That block is not on main as this note is written. Nothing waits on
a webhook, which is the same property `docs/EVENTS.md` already claims for every
wake path: the shortcut is never a dependency.

A board-facing receiver — its own route, its own shared secret per board, its
own idempotency key — is a worker change with real security surface, and it is
NOT built here. It belongs on its own ticket, and until it exists the release
latency is one cron tick.

**What it touches.** `prompts/TEMPLATE.md`, `prompts/project-4.md`,
`prompts/project-1.md`, `prompts/project-2.md`, `prompts/project-3.md`,
`prompts/project-8.md`, `prompts/project-9.md` (one line each), and
`docs/verification-map/entries/BH-903.md`. No `bin/`, no `worker/`, and no edit
to `docs/EVENTS.md` or `docs/BOARD-API-CONTRACT.md` — this note is where the
finding goes (D37).
