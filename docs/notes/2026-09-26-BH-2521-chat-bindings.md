# /hub CHAT BINDINGS table with edit (BH-2521 slice 3, BH-2678)

Doc: DB-COORDINATION-SPEC

## What changed

- **`GET /api/telegram-topics` also answers `rows`**:
  `[{project, thread_id, actor, updated_at}]`, ordered by project. `actor` is
  `null` when the PUT that wrote the row carried none. `topics` and `as_of`
  are unchanged. `PUT` is unchanged.
- **The `ChatBindingsPanel` stub on /hub is filled in**
  (`console-ui/src/screens/hub/ChatBindings.js`, pure half in
  `console-ui/src/lib/chat-bindings.js`). It lists the rows in a sortable table
  and lets an operator move one project to another thread: EDIT, type the id,
  SAVE, confirm "Move <project> from thread A to B?" in the in-app dialog, and
  it sends one `PUT /api/coord/telegram-topics` (the coord proxy stamps
  `actor`) and reloads. An id that is not a positive integer, or is the current
  one, is refused inline and sends nothing. There is no add and no delete.
- It loads once on mount and on REFRESH. It does not poll.

## Why `topics` is untouched

`bin/lib/jobs/jobs.sh` (`telegram_topics_get`, `telegram_topics_sync`) reads
`.topics // {}` into `state/telegram-topics.json`, and `bin/poll-commands.sh`
reads `(.topics // .)` from that file. Neither reads any other key, so the new
`rows` key changes nothing for them. A console move reaches a box on its next
`telegram_topics_sync`, the same as any other PUT.

## Tests

`worker/jobs/test/routes/telegram-topics.bh-2521.test.js` (real schema in
node:sqlite through `worker.fetch`), `console-ui/tests/chat-bindings.bh-2521.test.js`,
`console-ui/tests/chat-bindings-panel.bh-2521.test.js` and
`tests/chat-bindings-console.bh-2521-test.sh`.
`tests/hub-seed-chat-contract.bh-2521-test.sh` no longer calls
`ChatBindingsPanel` outside a render (it has hooks now); it checks it is a
function.
