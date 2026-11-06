# Hosted board

The jobs worker (`worker/jobs`) can serve the Board API for a project that has
no product board of its own. The API is the contract in
[BOARD-API-CONTRACT.md](BOARD-API-CONTRACT.md). The harness lanes read it through
the existing in-app board path, the same way they read any app's board.

This is wave 1 of BH-7913 (BH-8918): the API, its tokens, and a name guard. There
is no screen yet. The /t/<KEY> page does not change.

## Connect a project: the three rows

| Where | Row | Value |
|---|---|---|
| `fleet.conf` column 4 | the board prefix | `/api/hosted-board/<project>` |
| settings | `tracker_adapter.<project>` | `board` |
| `env/<project>.env` | `<P>_API_BASE` and `<P>_INTERNAL_API_TOKEN` | the jobs worker origin, and the token from the command below |

`<P>` is the project name in capitals, with `-` written as `_`. It must be letters
and underscores only (BOARD-API-CONTRACT.md, "Authentication").

## Issue and revoke a token

On a box that holds `HARNESS_SECRET` and `JOBS_URL`:

```bash
bin/jobs-client.sh hosted-board-token issue <project> <KEY_PREFIX>
```

1. The command makes 32 random bytes on the box, as hex. That is the token.
2. It sends only the sha256 of the token to `POST /api/hosted-board-admin/setup`.
   The worker never holds the token.
3. The worker creates the board `product-board` (name "Product Board", the key
   prefix you gave) if it is not there, and stores the token row.
4. After a 200, the command prints one `issued <tokenId>` line, then the two env
   lines, once. Put them in `env/<project>.env`. Nothing else keeps the token.
5. Any other answer prints no token. rc 1 (or 9 for a hash that is already a
   token).

The token is a system actor for that one project. Its comments and tickets carry
the author `{userId: "system", name: "System Harness"}`, which
`bin/triage-gate.sh` reads as the harness's own write.

An operator token opens every project. It is for the console worker (wave 2):

```bash
bin/jobs-client.sh hosted-board-token issue --operator
```

To revoke a token (it stays in the table with `revoked_at` set):

```bash
bin/jobs-client.sh hosted-board-token revoke <project|*> <tokenId>
```

The two admin routes sit behind `HARNESS_SECRET`. A hosted-board token never
opens them.

## Check it

```bash
curl -s "$JOBS_URL/api/hosted-board/<project>/health"
```

It answers `{"ok":true}` after a D1 `SELECT 1`, and needs no token. A D1 error
answers 503 `{"ok":false}`. Then:

```bash
bin/board-conformance.sh <project>
```

On a hosted board, `internal.version` and `internal.migrations` are `unverified`
(the jobs worker serves no app internals). That is not a gap.

## Routes

All under `/api/hosted-board/<project>`. Every route but health needs
`Authorization: Bearer <token>`. `HARNESS_SECRET` is refused on every route. A
wrong, revoked or other-project token is 401. A path under the prefix that is not
a route is 404 `{"error":"unknown endpoint"}`.

| Route | Answer |
|---|---|
| `GET /health` | `{"ok":true}` |
| `GET /boards` | `{"boards":[{id, name, keyPrefix, capabilities:["dependencies"]}]}` |
| `GET /boards/{b}/tickets[?cursor=<id>]` | `{"tickets":[…], "nextCursor": <id or null>}`, newest `updatedAt` first |
| `POST /boards/{b}/tickets` | 201, the ticket. Body `{title, description?, priority?, type?, labels?, parentId?, dependsOn?}` |
| `GET /tickets/{id or key}` | the ticket at the top level, with `comments` oldest first |
| `POST /tickets/{id}/comments` | 201 `{id, ticketId, createdAt}`. Body `{body, isInternal?}` |
| `POST /tickets/{id}/move` | 200, the ticket (its `status` echoed). Body `{toStatus}` |
| `POST /tickets/{id}/turn` | 200, the ticket. Body `{to: "team" or "client"}` |
| `POST /tickets/{id}/assign` | 200, the ticket. Body `{kind: "person", "agent" or null, id}` |

The ticket shape is the contract's, with the dependency fields (`parentId`,
`dependsOn`, `children`, `blocked`). `blocked` is true when any `dependsOn` ticket
is not `done`, or no longer resolves. `triageVerdict` is JSON `null` until a
verdict is set. This wave has no verdict writer.

A comment never changes `status`, `waitingOn`, `triageVerdict` or `title`. A move
to the status the ticket already has writes nothing.

Every POST honours `Idempotency-Key`. The same key and the same request answer
the stored status and body, and write nothing more. The same key with another
request is 409 `{"error":"idempotency_key_reused"}`.

The list is a page: at most `hosted_board.list_page_max` rows (500). When more
wait, `nextCursor` is the last row's id. Today's lanes read the first page only.
So a board with more than 500 open tickets shows its 500 newest to triage.

## Knobs and retention

Settings rows (the code default is in brackets):

| Key | What |
|---|---|
| `hosted_board.list_page_max` [500] | rows on one list page |
| `hosted_board.title_max_chars` [300] | longest title |
| `hosted_board.description_max_chars` [20000] | longest description |
| `hosted_board.comment_max_chars` [5000] | longest comment |
| `hosted_board.depends_on_max` [50] | ids in one `dependsOn` |
| `hosted_board.create_retries` [3] | tries when two creates take one ticket number |
| `retention.hosted_board_events.days` [180] | days an event row is kept |
| `retention.hosted_board_idem.days` [180] | days an Idempotency-Key answer is kept |

The hourly retention lane (`bin/d1-retention.sh`, `POST /api/retention/run`)
deletes events and Idempotency-Key rows past their window.
`retention.dry_run` applies. Tickets and comments are never deleted. They
archive by `archived_at`.

## Where it lives

- Schema: `worker/jobs/schema.d/202611040340-bh-8918-hosted-board.sql`. The
  header names the index of each query.
- Routes: `worker/jobs/src/routes/hosted-board.js` (open, own token check) and
  `worker/jobs/src/routes/hosted-board-admin.js` (gated).
- Shared SQL, auth, knobs and shapes: `worker/jobs/src/lib/hosted-board.js`.
- Retention: `worker/jobs/src/routes/retention.d/bh-8918-hosted-board.js`.
- Token command: `bin/jobs-client.d/bh-8918-hosted-board-token.sh`.
- Seams for later waves (empty): `worker/jobs/src/routes/hosted-board-{members,intake,webhooks}.js`,
  `console-ui/src/screens/Board.js`, `console-ui/src/screens/board/`,
  `bin/hosted-board-intake.sh` (lane `board-intake`, no cron line).
- Product names are checked by the name guard (`bin/name-guard.py`, see
  [PRODUCT-BOARD-PROVENANCE.md](PRODUCT-BOARD-PROVENANCE.md)).
