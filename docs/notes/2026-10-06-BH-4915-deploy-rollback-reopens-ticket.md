# A deploy-train revert reopens the ticket it rolled back (BH-4915)

Doc: deploy-queue-rows, tracker-adapter

## What changed

- `bin/deploy-train.sh`, rollback branch only. After the rollback PR is
  opened and enqueued, the train writes one `<merge sha>\t<build dir>` line per
  reverted merge (from the rows in rows mode, from the queue files otherwise)
  and calls `bin/deploy-rollback-board.sh <project> <revert PR> <reason>
  <members file>`. The reason is the one the `failed` deploy ledger row already
  carries: `production still not serving <sha8> after <N> polls (live=...)`.
  The call is `|| true` and the script always exits 0, so the train's outcome
  does not depend on it.
- `bin/deploy-rollback-board.sh` (new). Per reverted merge, capped at 20:
  1. a build dir with a `job.json` that names `ticket_id` and `key` maps to a
     ticket. Anything else (merge-queue, self-sourced) gets a `flagged` ledger
     row keyed `<project> <sha8>` and no tracker call;
  2. one comment through the tracker contract (`tracker_comment`), naming the
     revert PR, the merge PR from the build's `RESULT` when there is one (none
     is invented when there is not), and the reason;
  3. only after the comment is delivered: the local marker, then
     `tracker_transition` to `in_progress` (board) or `open` (GitHub Issues);
  4. one `deploy_rollback` ledger row, key `<project> <KEY>@<sha8>`, status
     `reopened`, or `commented-unmoved` when the tracker did not take the move.
  A refused comment is `comment-failed`, writes one ALERTS line, writes no
  marker and moves nothing; it is the one status a later rollback retries.
  jira/linear projects, and a board with no base or token, get a
  `flagged-unsupported` / `flagged-unconfigured` row and no tracker write.
- `worker/jobs/src/lib/daily-digest/state-sections.js`: the Tripwires section
  also lists `deploy_rollback` rows created in the window. The renderer is
  unchanged (`kind project key at`).
- The rollback branch re-fired the deploy hook with a bare
  `"$DEPLOY_HOOK_URL"`. Since the hook became optional (2026-09-12) that line
  died on `set -u` for a project without one, before the rollback beat and the
  `rollback PR ... enqueued` log line. It is now guarded like the departure's
  own hook call, and the log line and beat say "hook re-fired" / "redeploy
  fired" only when there is a hook.

## Exactly once

The batch stays queued after a rollback, so the next departure can fail and
roll the same merges back again. Two stores say a merge was handled: the
marker `state/deploy-rollback/<project>/<KEY>-<sha12>` on the box that runs the
train (written the moment the comment is delivered, so a worker outage between
the comment and the ledger write cannot cause a second comment), and the
`deploy_rollback` ledger row (fleet-visible). A ledger read that does not
answer leaves the marker to decide. Neither store is pruned.

Two merges of the same ticket in one batch are two shas, so two comments. A
ticket re-landed and reverted again is a new sha and gets one new comment.

## Choices

- Flag, never auto re-queue. A rebuild of a reverted ticket repeats the same
  plan against the same code, and a revert is usually caused by the build
  environment, so an automatic rebuild could loop merge, fail, revert. The
  ledger row puts it in Archie's daily digest; a person picks it up.
- The board changes when the rollback PR is opened and enqueued, not when it
  merges: that is the moment production is known not to serve the change.
- "The failed build's reason" is what the train knows: production never served
  the sha after N polls, and what it served instead. The train has no Vercel
  credentials, so the build log itself is not fetched.
- The comment says "We're moving the ticket back to in progress" (intent): the
  move can still be refused, and the ledger row says which happened.

## Still owed

Proving it on a real rollback needs a real failed deploy on a production
project. Until one happens this is covered by the fixture only.
