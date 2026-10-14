# A head-moved merge_pr refusal frees its command key on every entry point (BH-4917)

Doc: MERGE-CONDUCTOR

## What changed

- New Pages Function `console-ui/functions/api/merge-pr/release.js`,
  `POST /api/merge-pr/release {id}`, authed with `Bearer $HARNESS_SECRET`. It
  calls `releaseHeadMovedRefusal` (`console-ui/functions/_lib/merge-pr-rekey.js`,
  next to #4439's `rekeyHeadMovedRefusal`), which renames one console
  `commands` row from `<project>:<ticket>:merge_pr` to `<key>:refused:<id>`
  through the console's own `CONSOLE_DB` binding. The UPDATE re-checks
  `type = 'merge_pr'`, `status = 'refused'`, a `refused: head moved%` result and
  a key not already renamed, so a replay or a row the console does not hold as a
  terminal head-moved refusal changes nothing. The row is kept.
- New `bin/lib/merge-pr-release.sh`, `mpr_release_head_moved <command-id> <log>`.
  It POSTs the id to that endpoint at `console_pages_url`, with the secret on
  curl's stdin.
- `bin/poll-commands.sh` sources the lib and, in a new `merge_pr key release`
  block right after the ack, calls it for a merge_pr acked `refused` whose
  result starts `refused: head moved`. That covers the REST ladder's rc 4 and
  the Mergify lane's head-moved refusal. Ack first, release second.

## Why

The console worker hands an existing row under `<project>:<ticket>:merge_pr`
back to every later merge_pr. #4439 freed a head-moved refusal only in the Pages
proxy, for a request carrying `verdict_sha`. A merge_pr from the MCP tool,
Telegram or a box command kept getting the old refusal, and project-3 #467 had
to merge under a new ticket key. Every merge_pr, whatever sent it, is executed
by this poller, so this is the one place that sees all of them.

The write goes through the console's Pages surface, not the D1 REST API from
the hub. BH-3905 took D1 access away from the hub on purpose
(`docs/notes/2026-10-03-BH-3905-deploy-off-hub.md`), and a hub-to-D1 write
would only work by giving it back.

## Behaviour now

- The next merge_pr under that key is a new command. The poller evaluates it
  against the live head and the ledger's reviewed sha, as before: it merges if
  the moved head has a verdict and is refused again if it does not.
- A repeat merge_pr on the same unmoved head with no new verdict now gets a
  fresh command that is refused again with the same text, where before it got
  the old row back.
- The console path (#4439, `rekeyHeadMovedRefusal`) is unchanged. It runs
  before forwarding and will usually find the row already renamed.

## Outcomes and failure

One line per call in `logs/console-commands.log`:
`merge_pr <id> key release: released | no-match | not-configured (...) | failed (HTTP n[, why])`.
`not-configured` (no `HARNESS_SECRET` or console-pages lib) never alerts: the
key stays sticky as before. `failed` writes one ALERTS line through
`bin/alert-line.sh` (id `merge-pr-release`) naming the cause: unreachable, the
Pages project refusing the secret (401/403), the endpoint not deployed yet
(404), a missing `CONSOLE_DB` or `HARNESS_SECRET` on Pages (503). It is never
counted as released. The release is `|| true`, so a console outage never stops
the poller.

## Owed

- Live, after the console-ui deploy that carries this (`bin/console-pages-deploy.sh`
  runs on the hub after merge): a probe from the hub,
  `POST <console_pages_url>/api/merge-pr/release {"id":-1}` with the hub's
  secret, expecting HTTP 400 (authed, bad id, nothing written). A 401 means the
  Pages project's `HARNESS_SECRET` differs from the hub's; a 404 means the
  deploy has not landed. Until it answers, each head-moved refusal alerts once
  and merges behave as they did.
- On the next real head-moved refusal, `/history/commands` shows the row as
  `<project>:<ticket>:merge_pr:refused:<id>`, and the next merge_pr mints a new id.
- The real fix belongs in example-org/cromford-console: key a merge_pr on
  the head or the reviewed sha. Once it does, this UPDATE never matches.
