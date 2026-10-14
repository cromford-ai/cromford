# The Idea screen posts, revises, kills and chats

Doc: CONSOLE

## What changed

`/ideas/<project>/<slug>` in Mission Control now carries a row of buttons for
the four proposal commands. Until now they were only on the legacy `/product`
page of the harness-console worker, and the screen's gate banner sent the
operator there.

- POST shows only on a `gate_pending` row. `bin/post-proposal.sh` has no status
  check and no dedupe, so the screen is the only thing between a double click
  and a second ticket on the client's board. After a POST queues, its button
  stays disabled for as long as the screen is open ("POST QUEUED #N").
- REVISE shows on `gate_pending`, `candidate` and `vetoed`. It needs notes.
- KILL shows on `gate_pending` and `candidate`. Notes are optional.
- CHAT shows on every row with a slug. It needs a message.

Every click asks in the in-app dialog (`useConfirm`). On confirm the screen
sends one command through `api.action` (`POST /api/dash/action`) and reads the
idea again. The line it shows is "queued as command #N": the poller acts on the
command later, on the project's owning box, so the screen never says the idea
was revised or posted. An answer with no command id is shown as an error.

## Wire

No new command type. The payloads are the ones `bin/poll-commands.sh` already
reads: `{type:"post_proposal"|"kill_proposal"|"revise_proposal", project, slug,
notes?}` and `{type:"chat_proposal", project, slug, message, origin:"console"}`.
The Pages proxy stamps the actor. A slug outside `[A-Za-z0-9_-]` gets no buttons,
because the poller refuses it.

## Where

`console-ui/src/lib/idea-actions.js` (status matrix, payloads, copy),
`console-ui/src/ui/IdeaActions.js` (buttons and dialogs),
`console-ui/src/screens/Idea.js` (mount and banner). Pinned by
`console-ui/tests/idea-actions.bh-2520.test.js` and
`tests/idea-actions.bh-2520-test.sh`, which sends a revise from the lib through
the real `proposal_gate` handler and the real `bin/product-cmd.sh` and reads the
ledger row back at rev 2 with the notes.
