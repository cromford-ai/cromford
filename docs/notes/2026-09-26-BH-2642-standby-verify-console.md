# Standby VERIFY from Mission Control: the console half (BH-2642, BH-2519.4)

Doc: HUB-RECOVERY-MCP

## What changed

- `console-ui/functions/api/coord/[[path]].js` admits one more write:
  `POST hub/standby/verify` with body fields `box` and `confirm`. The proxy
  stamps `actor` as it does for every write, so a browser `actor` or `of_hub`
  never reaches the worker. The box-side routes (`hub/standby/verify/claim`,
  `hub/standby/verify/<id>/result`, `hub/standby/heartbeat`) are not in the
  table and answer 405 from a browser.
- New pure lib `console-ui/src/lib/standby-verify.js`: `verifyBody(box)` is
  exactly `{box, confirm:true}`; `verifyOutcome` says "Queued" only when the
  worker hands back a run id, reads `deduped:true` as "already queued", and
  reads a 409 `unknown_standby`, any other error and an answer with no id as
  failure; `submitVerify(ask, api, box)` sends one POST and only when the
  dialog answers literally `true`; `historyView` refuses a payload with no
  `runs` array; `lastVerifyByBox` picks each box's newest run by
  `requested_at`, then id, whatever the input order.
- The three BH-2519 contract stubs in `console-ui/src/screens/hub/StandbyVerify.js`
  are filled in, with their signatures unchanged:
  - `useStandbyVerifyRuns(reloadKey)` loads `GET hub/standby/verify` on mount,
    on a `reloadKey` change and on `reload()`. Each load takes a sequence
    number and only the newest may land, so a slow earlier answer never
    overwrites a newer one. A failed refresh keeps the last good runs and sets
    `error` beside them.
  - `StandbyVerifyCell` shows the last run's status pill and age (or "never
    verified"), and a VERIFY button that asks in the in-app `useConfirm`
    dialog. The button is disabled while the dialog and the POST are in
    flight. Any answer, failure included, calls `onQueued` so the caller can
    reload the history.
  - `StandbyVerifyDetail` lists one box's runs in the shared `SortableTable`
    (newest first); the STATUS cell expands a run to all its columns. A load
    error with nothing loaded renders the error with RETRY, never "Never
    verified". An optional `truncated` prop shows "showing the last 20 runs
    across all standbys".
- `tests/standby-contract.bh-2519-test.sh` now pins the hook's five-key return
  instead of the stub's literal empty values.

## Why

BH-2519 lets an operator drill a standby's restore from the console. This is
the console half; the worker routes are BH-2639's and mounting these in the
STANDBY panel is BH-2641's. Until BH-2639 lands the POST fails and reads as
failure text, and until BH-2641 lands nothing new renders on `/hub`.

## Known limits

- Before the first history answer the hook returns `runs: []` with no error,
  so a mounted cell reads "never verified" for that first moment. The
  contract's return shape has no loading flag.
