# Board API contract

What your application has to expose for this harness to drive it.

The harness never reads your database and never ships a plugin into your app. It
talks to a small HTTP surface you own, over a token you issue. That surface is
the whole integration. If your app has no board at all, skip to
[GitHub Issues instead](#github-issues-instead) — that path needs nothing from
your app but a repo.

Every claim here is read from the code, and the file:line is given so you can
check it rather than trust it.

---

## Registration

One row in `fleet.conf` (`fleet.conf:2`, parsed by `bin/fleet-conf.sh:78-93`):

```
project-1  example-org/project-1  https://os.project-1.example  /api/board  2  box-1  10.0.0.1
```

Columns 3 and 4 are the two that matter here: your production origin, and the
**path prefix** your board API is served under. The prefix is a registry column
rather than a constant precisely because every app puts it somewhere different
— `/api/board`, `/api/feature-board`, `/api/accounting/requests-board` are all
live values. A literal `-` in column 4 means "this project has no board", which
routes it to the GitHub-Issues lane (`bin/fleet-conf.sh:7-12,46-48`).

Everything below is relative to `<origin><prefix>`. The child filers get it
from `fc_board_base` (`bin/lib/file-children.sh`): the `*_API_BASE` value in
`env/<project>.env` joined to column 4, never a constant. That covers the
decomposer's in-app lane (`bin/run-decompose.sh`) and the board lane module
`bin/lib/fc-board.sh`, which files rollout waves.

**One exception is a bug rather than design.** `bin/file-health-ticket.sh:14,20,25`
hardcodes `/api/board` instead of reading column 4. If your prefix is anything
else it calls a path that does not exist, prints FAIL and exits nonzero into a
cron job nobody reads. `bin/triage-gate.sh:104-105`, `bin/post-proposal.sh:23-24`,
`bin/untriaged-sweep.sh:74-75` and `bin/reopen-metrics.sh:73-74` also carry the
literal, but only in per-project arms for the two projects whose column 4 IS
`/api/board`; a new project gets no arm there at all.

---

## Authentication

**One header, every call:** `Authorization: Bearer <token>` —
`bin/board-fetch.sh:62`, `bin/triage-gate.sh:81`, `bin/post-proposal.sh:30`,
`bin/run-build.sh:546`.

**Most calls also send `User-Agent: curl/8`** — the fetchers, the snapshot push,
the build stage, and the triage prompt itself (`prompts/TEMPLATE.md:3`). It is
not universal: `bin/untriaged-sweep.sh:16,19` sends `Authorization` only. The
reason for the override is not recorded anywhere in this repo.

Treat it as a constraint rather than a suggestion: **do not put a bot rule or a
WAF in front of the board API that varies on User-Agent.** Because the header is
*almost* universal, a rule keyed on it does not fail cleanly — most lanes keep
working and one sweep goes quiet, which is the hardest shape of bug to notice.

**The token is a system actor, not an admin.** It should be able to read the
board, comment, move a ticket and flip the turn, and nothing else.

**Variable naming is the contract, not the name.** The harness discovers your
credentials by suffix, so it never needs a table of project names:

| Suffix | Holds |
|---|---|
| `*_INTERNAL_API_TOKEN` | the board token |
| `*_API_BASE` | the origin. **Use this one** |
| `*_APP_BASE` | also the origin, but only some consumers accept it |
| `MIGRATION_TOKEN` | the migration secret, if you implement that endpoint |

**Name it `*_API_BASE`.** The triage gate accepts either spelling
(`bin/triage-gate.sh:56`), but `bin/run-decompose.sh:273` and
`bin/file-health-ticket.sh:9` match `^[A-Z_]+_API_BASE` only. A config with an
`_APP_BASE` and no `_API_BASE` triages and builds normally, and then loses two
lanes: parking a parent ticket when work is decomposed, and filing a health
ticket. Neither is silent — the first logs a WARN into the build's
`pipeline.log`, the second prints FAIL and exits nonzero — but neither is
anywhere you are looking on a good day.

Discovery is by regex against the project's env file, and **the two consumers
use different character classes**:

| Consumer | Pattern | Digits allowed |
|---|---|---|
| `bin/internal-token-for.sh:39-40` | `^[A-Z0-9_]*INTERNAL_API_TOKEN=` | yes |
| `bin/triage-gate.sh:57` | `^[A-Z_]+_INTERNAL_API_TOKEN` | **no** |

**So the prefix must be letters and underscores only.** `ACME_` is fine;
`ACME2_` or `PROJECT_2_` matches one consumer and not the other.

The failure mode is expensive rather than loud. `triage-gate.sh` finds no token,
leaves `BASE` and `TOKEN` empty, and **fails open**: it prints
`RUN unknown-project` and exits 0 (`:59-61`). Failing open is deliberate — a
broken gate must spend rather than miss work — but it means a prefix with a
digit in it buys a full triage session every ten minutes, forever, with no error
anywhere. The same applies to the `_API_BASE` / `_APP_BASE` prefix, matched by
the same class on the line above.

**Exactly one `*_INTERNAL_API_TOKEN` per project**, and the fleet does not agree
about what happens if you break that rule. `bin/internal-token-for.sh:41-49`
**refuses**: two tokens and it exits nonzero with "refusing to guess which one is
live", because picking the first would be "a credential bug wearing an outage's
clothes". But `bin/triage-gate.sh:57`, `bin/run-build.sh:544,570` and
`bin/run-decompose.sh:272` each take `head -1` and carry on.

So a rotated-but-not-deleted token does not fail cleanly in one place. Some lanes
stop and say so; others quietly use whichever token sorts first, which may be the
dead one. Delete the old value rather than commenting it out.

**Your system actor's display name is part of the contract.** The harness
recognises its own comments by matching `comments[].author.name` against a known
list (`bin/triage-gate.sh:37-42`). Pick a name, tell the operator, and do not
change it — if it drifts, the harness pays for a full triage session every time
it reads something it wrote itself.

---

## Endpoints

Seven routes. Five are needed; two are optional.

| Route | Needed | What it is for |
|---|---|---|
| `GET /boards` | yes | Discover board ids |
| `GET /boards/{boardId}/tickets` | yes | The cheap per-tick read |
| `GET /tickets/{id}` | yes | One ticket with its full thread |
| `POST /tickets/{id}/comments` | yes | Say what shipped |
| `POST /tickets/{id}/move` | yes | Change status |
| `POST /tickets/{id}/turn` | recommended | Flip whose court the ticket is in |
| `POST /tickets/{id}/triage` | optional | Run your own triage agent |

Note that `/tickets/{id}` hangs off the prefix root, not under `/boards/{id}/`
(`prompts/TEMPLATE.md:5`).

### GET /boards

Return either a bare array or `{"boards":[…]}`. Both are read everywhere —
`(.boards? // .)` at `bin/triage-gate.sh:82`, and a type check at
`bin/tickets-snapshot-push.sh:51`. A bare array is a real shape in production,
so neither is "the wrong one".

The only field required on a board is **`id`**. A uuid and a slug like
`product-board` are both fine.

```json
[{ "id": "product-board", "name": "Product Board", "keyPrefix": "TK",
   "capabilities": ["dependencies"] }]
```

`capabilities` is an optional list of the optional parts of this contract your
board implements. `"dependencies"` is the only value today and means the ticket
objects carry the dependency fields below, and that
ticket create accepts `parentId` and `dependsOn`.

**The rollout lane requires it.** Before it files any wave, `bin/lib/fc-board.sh`
reads `capabilities` on board `[0]`, the board it creates into. It must be a JSON
list containing exactly `"dependencies"`. Missing, `null`, a bare string, a
near-miss spelling, or the capability on some other board all count as no. So
does a probe that errors. Without it the lane refuses with
`ROLLOUT_FAILED board lacks dependencies` and writes nothing, because waves
filed without their ordering are worse than no waves.

Nothing else gates on it. The read side feature-detects per ticket, on the type
of `blocked`, and on a ticket without that boolean it gates on the ticket's own
`Blocked-by:` / `Needs:` text lines instead (Dependencies, below). The
decompose lane reads `capabilities` through the same probe but fails open: on a
capable board it writes `parentId` and `dependsOn`, and on any board each child
body carries its `Blocked-by:` footer line, which is what the text gate reads
where the primitive is absent.

`keyPrefix` is what turns a ticket's `number` into a human key like `TK-142`.
**Serving it does nothing today** — no production code reads it. What the harness
actually reads is `key` on the ticket; when that is null it falls back to a
**hardcoded per-project prefix map** (`bin/board-invariants.sh:55`, used at
`:86,109`).

So: **serve `key` on every ticket.** Serve `keyPrefix` too if you like, for the
humans and for the day the map goes away, but do not rely on it being consulted.
An app that serves `keyPrefix` and a null `key` still needs a line added to that
map, in this repository, before its keys resolve.

**Reads and writes disagree about multiple boards, so know which you are.**
Triage **iterates every board** the discovery call returns, fingerprinting each
one separately (`bin/triage-gate.sh:82-93`). The write lanes take `[0]` and only
`[0]` — creating a ticket, filing a health ticket, posting a proposal
(`bin/post-proposal.sh:41`). So a second board is watched but never written to,
and there is no registry column to point the writes elsewhere.

### GET /boards/{boardId}/tickets

Bare array or `{"tickets":[…]}`, both accepted (`bin/triage-gate.sh:86`).

**This route is called every ten minutes and must be cheap.** Seven fields on
each row are the change-detection fingerprint (`bin/triage-gate.sh:86`):

```
id, status, waitingOn, triageVerdict, commentCount, lastActivityAt, title
```

The harness hashes those. If nothing moved, it spends nothing. Two of the seven
— `commentCount` and `lastActivityAt` — can change without buying a session,
because they move when the harness itself comments. **Any of the other five
moving costs a full LLM session** (`bin/gate-selfwrite.py:21,68-70`). So do not
touch `status`, `waitingOn`, `triageVerdict` or `title` on unrelated writes.

If a ticket row carries `blocked` as a **JSON boolean**, four more fields join
its fingerprint: `key`, `blocked`, `parentId` and the ids inside `dependsOn`. A
blocker landing therefore flips `blocked` and the fingerprint diff wakes a
scoped tick for the child it released, on the next tick rather than on the daily
sweep. **The detection is per ticket and it is the TYPE of `blocked` that
decides** — absent and JSON `null` both read as "this board has not adopted
dependencies", and such a row's fingerprint is byte-identical to what it was
before the fields existed. There is no version negotiation here: absence is the
signal, and the same rule holds everywhere else in this section.

**There is no pagination anywhere.** This route returns the whole board in one
response. The largest observed in production is 434 tickets and 135KB
(`bin/triage-gate.sh:87-92`).

### GET /tickets/{id}

The ticket plus its comments. **Two consumers read this response and they do not
accept the same set of envelopes**, so pick one shape and keep it:

| Consumer | Accepts | Cite |
|---|---|---|
| The build stage, reading the ticket object | top level, or `{"ticket":…}` | `bin/run-build.sh:547` (`.ticket // .`) |
| The thread trimmer, locating comments | `.comments`, `.ticket.comments`, `.data.comments` | `bin/board-fetch.sh:138-141` |

So `{"data":{…}}` gets its comments trimmed correctly and then hands the build
stage a ticket whose fields it cannot find. **Serve the ticket at the top level**
and both are satisfied. `{"ticket":…}` also works everywhere. `{"data":…}` does
not, despite appearing in the trimmer.

```json
{
  "id": "c0ffee…", "key": "TK-142", "number": 142,
  "title": "Monthly view on the P&L tab",
  "description": "<p>…HTML…</p>",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "needs_clarification",
  "commentCount": 2,
  "priority": "high",
  "createdAt": "2026-09-10T12:00:00Z",
  "lastActivityAt": "2026-09-11T09:30:00Z",
  "updatedAt": "2026-09-11T09:30:00Z",
  "turnChangedAt": "2026-09-11T09:30:00Z",
  "reporter": { "userId": "u_7", "name": "Dana Ruiz" },
  "type": "feature",
  "labels": [],
  "comments": [
    { "author": { "userId": "u_7", "name": "Dana Ruiz" },
      "body": "<p>…</p>",
      "createdAt": "2026-09-11T09:30:00Z",
      "isInternal": false }
  ]
}
```

Required, optional, and the cost of leaving one out:

| Field | | Read at | Leave it out and |
|---|---|---|---|
| `id` | required | everywhere | nothing works |
| `status`, `waitingOn`, `triageVerdict` | required | `bin/triage-gate.sh:86` | the gate cannot decide, and fails open to a paid session |
| `commentCount`, `lastActivityAt` | required | same | every tick looks like a change |
| `title` | required | same | part of the fingerprint |
| `key` / `number` | required | `bin/tickets-snapshot-push.sh:69` | keys collapse to bare numbers |
| **`reporter.userId`** | **effectively required** | `bin/untriaged-sweep.sh:25` | the sweep excludes `"system"` reporters, so **every ticket the harness files against itself trips the untriaged alarm** |
| `updatedAt`, `turnChangedAt` | recommended | `bin/run-build.sh:547` | the thread-stability fingerprint loses resolution and a build can race a comment |
| `type` / `ticketType` / `issueType`, `labels` | recommended | `bin/run-build.sh:573-575` | the kind classifier has nothing to go on |
| `description`, `priority`, `createdAt` | optional | various | degraded context only |
| `url` / `href` | optional | `bin/tickets-snapshot-push.sh:74` | passed through only if you return it, never guessed |

Three things about the comment object are load-bearing:

- **`author` is an object**, `{userId, name}`. A bare string is tolerated but the
  object is what the self-write check reads.
- **`isInternal` decides whether a customer actually answered.** It is the field
  the "is this buildable" judgement turns on. An earlier version of the trimmer
  rebuilt comments from an allowlist and silently dropped it; it was rewritten as
  a denylist for exactly that reason (`bin/board-fetch.sh:95-105`).
- **`createdAt` is ISO-8601 UTC.** A fractional-seconds suffix is fine, it gets
  stripped before parsing (`bin/board-invariants.sh:82`).

Heavy fields are allowed and will be discarded before the thread reaches a
model: `html`, `bodyHtml`, `renderedBody`, `attachments`, `reactions`,
`rawPayload` (`bin/board-fetch.sh:107`). Serving them costs you bandwidth, not
correctness.

### POST /tickets/{id}/comments

```json
{ "body": "<p>Shipped in <a href=\"https://github.com/…/pull/12\">PR #12</a>.</p>" }
```

HTML. One app documents the shape it accepts and it is a reasonable floor:
≤5000 characters; `<p> <br> <strong> <em> <code> <ul> <ol> <li> <a> <h1>-<h6>`;
flat lists; `http(s)` hrefs only; anything else stripped to text
(one app's prompt documents its own limits; `prompts/TEMPLATE.md` is the generic
starting point).

**A comment must not flip the turn.** Posting a team comment leaves the ball
where it is. The turn moves only on an explicit call (`prompts/TEMPLATE.md:37`).

### POST /tickets/{id}/move

```json
{ "toStatus": "review", "sortOrder": 999999 }
```

`sortOrder: 999999` means "append". **Echo the new status in the response body**
— the child filers decide success by grepping the response for the target
status (`bin/run-decompose.sh:409,442`, `bin/lib/fc-board.sh`), and so does the
parent-close lane below: a `200` that did not move the ticket is a failure
wearing a success's clothes.

The harness makes one status move on its own behalf here. When a parent's every
`children[]` entry is `done` **and** each child's own record confirms it,
`bin/decompose-parent-close.sh` comments the list of parts with their PRs and
then moves the parent to `done`. That is the only write it makes; a child it
could not read stops the whole close.

### POST /tickets/{id}/turn

```json
{ "to": "team" }
```

The other value is whatever your app calls the customer side — `client` and
`requester` are both live, and the harness tests for both rather than assuming
(`bin/stale-owed-tickets.sh:61-64`). Pick one and be consistent.

### POST /tickets/{id}/triage

No body. If your app has its own triage agent, this asks it to assess the
ticket; return `202`. Return `409` for "not eligible, leave it alone". The
harness never writes a triage verdict itself — it either asks you to, or works
without one.

### Optional extras

`POST /boards/{id}/tickets` to create (`{title, description, priority}`, plus
`parentId` and `dependsOn` from a board that advertises `dependencies`; see
[Creating a ticket](#creating-a-ticket)) —
**return `id`, and ideally `number` and `key`**, or the caller pays for a second
GET (`bin/post-proposal.sh:49-54`). The board lane module needs `key` in the
create answer itself; it does not make that second GET. `PATCH /tickets/{id}` with `{description}`
to edit. A three-step signed-upload attachment flow exists and is used by some
apps (`bin/post-proposal.sh:61-70`); nothing requires it.

---

## The ticket model

### status

`todo` · `in_progress` · `review` · `done`, with `closed` tolerated
(`bin/stale-owed-tickets.sh:56`).

| Value | What the harness takes it to mean |
|---|---|
| `todo` | Untriaged or not started. `todo` with a null verdict is the untriaged alarm (`bin/untriaged-sweep.sh:22`) |
| `in_progress` | A build owns it. Excluded from the anti-rot sweep |
| `review` | Built, awaiting the customer. **The default terminal state for the harness** — built work goes to `review`, never straight to `done` (`prompts/TEMPLATE.md:37`) |
| `done` | **Means merged.** A `done` ticket with an open PR raises an invariant alert (`bin/board-invariants.sh:9-11`) |

### waitingOn

`team` means the next move is ours. The other value is your customer side. The
harness will flip a stale turn back to `team` itself if the newest comment is
from a human on the customer side and the field disagrees
(`prompts/TEMPLATE.md:34`).

### triageVerdict

| Value | Effect |
|---|---|
| `null` | Never triaged. **JSON null, never `""`** — an empty string is indistinguishable from "assessed and clear", and the snapshot renames absence to the literal `untriaged` so nothing downstream can read it as fine (`bin/tickets-snapshot-push.sh:53-57`) |
| `needs_clarification` | **The gate.** Combined with `waitingOn` = customer, the ticket is not buildable: triage asked a question nobody answered, so the mechanism is unconfirmed (`prompts/TEMPLATE.md:21`). Needs *both* halves — a verdict alone never invents a block |
| `ready` | Assessed. **Not buildable on its own** |
| `duplicate` | Treated like `needs_clarification` |

### Dependencies

Optional, and additive. A board that does not implement them **omits all four
fields entirely** rather than serving them empty — the harness reads absence as
"not adopted" and behaves exactly as it did before they existed.

| Field | Shape | What it means |
|---|---|---|
| `parentId` | ticket id, or `null` | the master this ticket is a slice of |
| `dependsOn` | `[{id, key, status}]` | the tickets that must finish first |
| `children` | `[{id, key, status}]` | the slices this ticket was split into |
| `blocked` | boolean | **derived**: any ticket in `dependsOn` is not `done` |

**`parentId` is `null`, never `""`** — same rule as `triageVerdict` above and for
the same reason: an empty string reads as a real answer. `dependsOn` and
`children` are `[]` when the ticket genuinely has none, which is a different
statement from leaving them out. `blocked` is the boolean or it is absent.

`blocked` is the one the harness acts on, and **only a JSON boolean counts**. A
string `"true"`, a `null` and a missing key are all "no dependency primitive
here"; absent is not `false`, because reading it as `false` would turn every
un-adopted board's every ticket into "released" on the day the harness shipped.

Four things read them:

- `bin/triage-gate.sh --buildable` refuses a ticket with `blocked: true` (the
  table below);
- on a ticket that carries no `blocked` boolean, the same gate reads the
  ticket's own `Blocked-by:` / `Needs:` text lines instead
  (`bin/lib/inapp-deps/core.sh`) and refuses it while a named blocker is
  neither `done`/`closed` nor merged; a blocker with an open PR makes it
  stackable. When the boolean is present the primitive wins and the text is
  not read. The ticket is released by `bin/triage-gate.sh` step 1e and
  `bin/lib/inapp-deps/release.sh`, which put an `UNBLOCKED` or `STACKABLE`
  line in the next tick's scope; a newest human `HOLD` still wins;
- `bin/triage-gate.sh`'s fingerprint carries them, so a `true → false` flip
  names the released child in the next tick's scope
  (`bin/run-triage.sh`, the `# >>> inapp dependency release` block);
- `bin/decompose-parent-close.sh` closes a parent whose `children[]` are all
  `done`.

The board lane module `bin/lib/fc-board.sh` writes two of them, on create, and
only on a board that advertises `dependencies` (below). `children` and
`blocked` stay the board's to derive.

#### Creating a ticket

```json
POST /boards/{boardId}/tickets
Idempotency-Key: rollout-LG-9-3

{ "title": "LG-9.3: UI",
  "description": "<p>…the wave body…</p><p>---<br>Part of #LG-9<br>Order: 3 of 3<br>…</p>",
  "priority": "high",
  "parentId": "cmParent01",
  "dependsOn": ["cmChild01", "cmChild02"] }
```

- `parentId` is the master's `id` exactly as `GET /tickets/{id}` served it, and
  `dependsOn` holds the `id`s your create answers returned for the earlier
  children. The harness never coerces them: a cuid string stays a string and an
  integer stays an integer. Accept whichever type your `id` is.
- The children are created one at a time, in order, so every id in `dependsOn`
  already exists when it is referenced.
- A board that does not advertise `dependencies` gets neither key. That only
  happens on the decompose kind, because rollout refuses first.
- **Answer with the ticket, `id` and `key` both.** Either top level or
  `{"ticket":…}`. A `2xx` without them is read as a failed create and the run
  stops there. `url`/`href` is optional; when present it is the link in the
  comment on the master, and when absent there is no link.
- `Idempotency-Key` is `<kind>-<KEY>-<n>`. It is sent on every create, and no
  board honours it yet. What stops a rerun filing twice is the harness's own
  record (`children.txt` + `children-board.tsv` in the build directory): a
  child on the record is never created again.

After the last child, the lane posts one comment on the master listing them and
moves it to `in_progress` (echo the status, as `/move` says above). If either
fails, the log says so as a WARN and the children still count as filed.

### Buildability / whose court

The harness has a deterministic gate that refuses to dispatch, build, or
close-out a ticket when any of these hold:

| Condition | Why it blocks |
|---|---|
| `blocked` = `true` | A ticket in `dependsOn` is not done. **Checked first**, before the turn and the verdict, and the reason names the keys: `BLOCKED dependencies TK-1825,TK-1826` (`bin/triage-gate.sh --buildable`) |
| `waitingOn` = `client` | The team asked a question and the client has not answered yet (`bin/triage-gate.sh --buildable`) |
| `triageVerdict` != `ready` | The ticket is not assessed as buildable (`bin/triage-gate.sh --buildable`) |
| Newest comment is from a system/harness actor | The last word is the machine's, not the customer's (`bin/triage-gate.sh --buildable`) |

The gate is fail-open: if the board API cannot be reached, the ticket shape is
unrecognised, or the keymap is missing, the ticket is treated as buildable
(`OK`) rather than blocked. Blocking silently is worse than running one extra
triage shard.

This gate runs in `bin/triage-gate.sh`, is consulted before a triage shard is
launched (`bin/run-triage.sh`), before a Fly builder claims a queued job
(`bin/fly-dispatch.sh`), and before a build close-out comment is posted
(`bin/board-closeout.sh`). GitHub-Issues boards are always OK here because they
carry no `waitingOn`/`triageVerdict` fields.

A second check runs at build time, not in the triage gate: **the trigger actor
gate** (`bin/lib/trigger-actor.sh`, BH-4490).

| Condition | Why it blocks |
|---|---|
| The newest trigger was made by someone not on `trigger.actors.<p>` and not the harness | Only a listed human or the harness itself may make a ticket buildable. GitHub Issues: the actor of the newest `labeled ai-build` event (with no row, a Bot is refused and a User allowed). In-app: the `actor` of the newest `activity[]` entry with `type: "status_change"`, read only when the project has the row |

For the in-app half, serve `activity` on `GET /tickets/{id}` (top level or
under `ticket`) as entries `{id, type, actor: {userId, name}, createdAt}`. A board
with no `activity` array is treated as not adopted and builds as before. An
ignored trigger gets one comment per episode and ends the build `BUILD_REFUSED
SKIP_ACTOR`. Unlike the triage gate, this gate fails closed: an unreadable row
or board defers the build to the next tick.

**Buildable is a conclusion about the thread, not a field.** The positive rule
is: the customer's comment is the latest, the turn came back to the team, and
the thread confirms the mechanism.

**Vocabulary drift is the trap.** `Needs Clarification` with a space and capitals
is a different string; the gate silently stops matching while everything still
renders. Case is normalised downstream, separator drift is not, and the producer
logs the distinct values it saw per tick to catch exactly this
(`bin/tickets-snapshot-push.sh:165-183`).

---

## A minimal implementation

A Next.js route handler that satisfies the read half. Auth first, then shape.

```js
// app/api/board/boards/[boardId]/tickets/route.js
import { NextResponse } from 'next/server';

function authed(req) {
  const got = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  const want = (process.env.HARNESS_INTERNAL_API_TOKEN || '').trim();
  // Constant-time compare in real code. 404 rather than 401: see below.
  return want.length > 0 && got === want;
}

export async function GET(req, { params }) {
  if (!authed(req)) return new NextResponse('Not found', { status: 404 });

  const rows = await db.ticket.findMany({
    where: { boardId: params.boardId },
    select: {
      id: true, key: true, number: true, title: true,
      status: true, waitingOn: true, triageVerdict: true,
      commentCount: true, lastActivityAt: true, priority: true,
    },
  });

  // triageVerdict must be null, never "". status/waitingOn/triageVerdict are
  // part of the change fingerprint: do not touch them on unrelated writes.
  return NextResponse.json({ tickets: rows });
}
```

**Answer 404, not 401, on a bad token.** The fleet relies on this, and reads a
404 on a known app domain as "auth-gated" rather than "absent"
(`bin/verify-claims.sh:67-70`). The corollary matters when you are debugging: a
404 never proves a route is missing.

---

## GitHub Issues instead

If your project has no board, put `-` in column 4 of `fleet.conf` and the
harness drives GitHub Issues with the box's `gh` credential instead. There is
nothing to implement.

Both trackers sit behind one contract, `bin/lib/tracker.sh`, with an adapter
each under `bin/lib/tracker/`. The settings row `tracker_adapter.<project>`
(`github-issues` or `board`) chooses the adapter, and column 4 is the fallback
when there is no row (`docs/verification-map/tracker-adapter.md`).

```
bin/load-project.sh <owner>/<repo>
```

That registers the project, picks a free cron offset, renders its watcher prompt
from `prompts/TEMPLATE-GH.md`, creates the `ai-build` label, commits the
registry row and the regenerated crontab together, and bootstraps the box
(`bin/load-project.sh:53-302`).

If you enrolled by hand rather than with that script, create the label
yourself — nothing else does, and until it exists the harness has no way to be
handed anything:

```bash
gh label create ai-build -R <owner>/<repo> --color 1D76DB
```

**The label is the whole contract.** The harness acts only on issues labeled
`ai-build` and never touches an unlabeled one — the label *is* the handoff
(`prompts/TEMPLATE-GH.md:12-15`). Loading a project builds nothing until you
label something.

| Board concept | GitHub equivalent |
|---|---|
| list tickets | `gh issue list --label ai-build --state open --json number,title,labels,updatedAt,comments` |
| one ticket | `gh issue view <n> --json title,body,comments,labels,state` |
| comment | `gh issue comment <n> --body "…"` |
| move to `done` | `gh issue close <n> --comment "…"` |
| turn | nothing — there is no turn |
| triage verdict | nothing — there are no verdicts |

Ticket keys are `<PREFIX>-<issue-number>`, where the prefix defaults to the
initials of the project name (`acme-tools` → `AT`) and is overridable with
`--prefix` (`bin/load-project.sh:58-63`).

Buildability is decided differently, because there are no verdicts: labeled
`ai-build`, open, every `Blocked-by: #<n>` issue closed, and no comment saying
HOLD (`prompts/TEMPLATE-GH.md:29-30`). The issue body is the spec and the newest
comment is the latest word.

A body line `Spec-repo: <owner>/<repo>` (or `Spec-repos:` with a comma list)
lets that ticket's pool build READ another repo of the same owner. The key must
start the line; a mention in a sentence, a fenced line or a comment does not
count. The pool adds the repo to the machine's read-only token, and a machine
with that token is never reused for another ticket. The builders App must be
installed on the repo (`bin/lib/spec-repos.sh`,
`docs/notes/2026-10-14-BH-6576-spec-repos.md`).

One asymmetry worth knowing: **self-write absorption is disabled on this lane**.
On GitHub the harness's comments post as the same actor as a human's, so there
is no safe way to tell them apart, and absorbing could eat a real reply
(`bin/triage-gate.sh:218-225`).

---

## Health

`GET /api/health` on your origin, if you want the daily liveness beat
(`bin/healthcheck.sh`). Only the status code is read; the body is quoted into an
alert and never parsed.

- `2xx` — healthy.
- `5xx` — **the endpoint exists and is telling the truth about being unwell.**
  One retry after 30s, then an alert. The harness deliberately does *not* fall
  back to `/` here: doing so once let a production outage go unalerted for a day
  (`bin/healthcheck.sh:61-79`).
- Anything else (404, timeout, redirect) — treated as "no health endpoint", and
  the bare origin is checked instead, where **any 2xx, 3xx or 4xx counts as
  alive** (a 404 or a 401 redirect still proves the server is answering).

Make it mean something. It is worth a 5xx when the database is unreachable or
a provider key is dead — the homepage will keep serving in both cases.

Put `-` in column 3 of `fleet.conf` and no healthcheck runs at all.

---

## Migrations

Optional, and only worth implementing if you want the harness to apply schema
changes after a merge. The full specification with the statement classifier is
[docs/MIGRATION_ENDPOINT_SPEC.html](MIGRATION_ENDPOINT_SPEC.html); the shape:

`GET /api/internal/migrations/status` →
`{applied:[{filename}], pending:[{filename, checksum, statements}]}`

`POST /api/internal/migrations/apply` with
`{"filename":"2026-09-11-add-column.sql","actor":"watcher"}` →
`{"status": "applied" | "already-applied" | "in-progress" | "refused" | "checksum-mismatch" | "failed"}`

Besides `status`, the harness reads these from the apply response — return them
or the lane loses detail it reports on: `.ok`, `.alreadyApplied`, `.flagged[]`,
`.rlsWarnings[]`, `.reason`, `.perStatement[]`
(`bin/apply-migrations.sh:56-58,69,71`).

**If you serve more than one database**, `status` may instead be shaped
`{"targets":{"prod":{"applied":[…]},"staging":{"applied":[…]}}}`, and a file
counts as applied only when **every** target lists it
(`bin/migration-autopilot.sh:131-140`).

Four rules carry most of the safety:

1. **The filename travels, never the SQL.** Your app runs the file from its own
   deployed bundle, so a migration can only be applied if it actually shipped.
2. **Authenticate with `MIGRATION_TOKEN`, a different secret from the board
   token**, independently rotatable (`bin/apply-migrations.sh:28`).
3. **`refused` is terminal for that checksum.** The harness records it and never
   re-POSTs unchanged content (`bin/apply-migrations.sh:40-52`).
4. **Verification is the status ledger, not the apply response.** After an
   apply, the autopilot re-reads `/status` and fails the migration if the app's
   own ledger does not list it (`bin/migration-autopilot.sh:215-219`).

An absent or unreachable endpoint is a quiet no-op, not an error
(`bin/apply-migrations.sh:36`).

**One thing to know before you build this:** `bin/apply-migrations.sh:21-27`
resolves the app's base URL from a **hardcoded four-project case statement** and
`exit 0`s on anything else. So on a fresh fleet this lane does nothing at all,
whatever you serve, until that map is extended. It is a code bug rather than a
contract; implement the endpoint if you want it ready, but do not expect the
lane to exercise it yet.

---

## Things that will bite you

Each of these is a workaround that exists in the code because an app did it.

1. **Never return an error body with a 2xx.** The status code is checked
   separately from the shape, because handing an error page to a model "would
   look like a working fetch of an empty thread" — it would then judge a
   customer's request from an error message (`bin/board-fetch.sh:52-70`).
2. **Do not quietly change your response envelope.** Bare array, `{tickets:…}`
   and `{ticket:…}` are all live shapes and all handled; a *new* fourth one is
   not. Note that jq's `?` operator suppresses errors, so the wrong shape
   returns an empty thread rather than failing (`bin/board-fetch.sh:86-92`).
3. **Serve `key`, or at least `keyPrefix`.** Without them keys collapse to bare
   numbers, and a bare `"6"` once matched an unrelated PR title
   (`bin/tickets-snapshot-push.sh:104-112`).
4. **Untriaged is `null`, not `""`.**
5. **Only `commentCount` and `lastActivityAt` may move for free.** Everything
   else in the fingerprint costs a session.
6. **Do not return a URL you cannot back.** `url`/`href` are passed through only
   when you return them; a guessed pattern "would render confident dead links,
   worse than none" (`bin/tickets-snapshot-push.sh:64-65`).
7. **`done` means merged.**
8. **Keep test records off the board.** Probe tickets are prefixed `[E2E] ` and
   swept; five of them aged past 90 minutes raises its own leak alert
   (`bin/stale-owed-tickets.sh:73-88`). If your QA writes to a customer-visible
   board, that is the finding.
