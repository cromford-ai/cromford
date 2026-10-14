# A head-moved merge_pr refusal no longer holds the command key once the moved head is re-reviewed (BH-4439)

Doc: MERGE-CONDUCTOR

## What changed

- `console-ui/src/screens/PR.js`: the MERGE button's body is built by
  `mergeCommandFor`. When the verdicts answer has a standing verdict for the
  PR's live 40-hex head (`standingShaOf` in `console-ui/src/ui/PRVerdicts.js`),
  the body carries that verdict's sha as `verdict_sha`. It's deliberately not
  `sha`. `bin/poll-commands.sh` reads `.sha` as the reviewed sha it binds a
  merge to, and it ignores `verdict_sha`, so the merge stays bound to the ledger.
- `console-ui/functions/_lib/merge-pr-rekey.js` (new) and the Pages catch-all
  `console-ui/functions/api/[[path]].js`: before a `merge_pr` is forwarded to the
  console worker, one guarded UPDATE on `CONSOLE_DB` renames the row under
  `<project>:<ticket>:merge_pr` to `<key>:refused:<id>`. It only does that when
  the row is a `merge_pr` with `status='refused'` and
  `result LIKE 'refused: head moved%'`, and the sha it was bound to differs
  from the click's `verdict_sha` (first 8 hex compared). The bound sha is the
  one the box wrote into the result (`since sha <8>`). A row without one falls
  back to its payload `verdict_sha`, and a row with neither counts as different.
  The worker then finds no row under the key and mints a fresh command.
- Every other case forwards the click exactly as before: no binding, no or
  invalid `verdict_sha` (no fresh verdict yet), any other refusal, any other
  status or type. A D1 error is logged as `merge_pr rekey skipped: <message>`
  and the click is still forwarded.

## Why the verdict and not the live head

The box refuses with rc 4 because the PR's live head H is not the reviewed sha
R. The refused click already carried H as its live head, and so does the click
after H is re-reviewed. A live-head discriminator therefore never fires in the
real sequence. The only thing that differs between those two clicks is the
standing verdict: there's none for H before the re-review, and there's one on H
after it. That is also the ticket's own wording ("a call on head B with a fresh
verdict").

## Why

The console worker keys merge_pr on `<project>:<ticket>:merge_pr` and returns
the row already under the key. After a `head moved` refusal (poll-commands rc 4,
acked terminal per BH-932), every later click returned that refusal, even after
the new head was re-reviewed (project-3 #396, TK-225).

## Owed

- The real fix is in `example-org/cromford-console`: key merge_pr on the
  reviewed sha. That repo is not readable from the build box. Once it ships,
  this proxy UPDATE never matches and can be deleted.
- The key format is taken from the ticket, not read from the worker source, and
  so is the assumption that the worker stores the full body as `payload`. If the
  key differs, the UPDATE matches nothing and behavior is unchanged. The live
  check (project-3 #396: re-click MERGE after a fresh verdict on the moved head,
  expect a new merge_pr row and the old one suffixed `:refused:<id>`) is still
  owed.
- This is the first Pages function that writes `CONSOLE_DB`; until now Pages
  only read it.
