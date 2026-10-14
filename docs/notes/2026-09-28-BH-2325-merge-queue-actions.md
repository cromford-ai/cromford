# Merge-queue HOLD / RESUME / DROP and held-page RELEASE in the console (BH-3159)

Doc: VERIFICATION-MAP

## What changed

- `console-ui/src/screens/merge-queue-actions.js` replaces the BH-3155 stubs.
  `MqRowActions({row, rowsOnly, onDone})` renders HOLD/DROP on a `queued` row,
  RESUME/DROP on `blocked` and RESUME on `dropped`. `HeldReleaseButton({row,
  onDone})` renders RELEASE when the held row carries its full key. Anything
  else still returns `null` before any hook runs, so the contract test stays as
  it was.
- `console-ui/src/lib/merge-queue-actions.js` holds the pure half: the action →
  status map, the request bodies (null on a blank reason), the per-mode effect
  sentence and the `makeMqAction` / `makeReleaseAction` factories.
- Every action asks through the in-app `useConfirm` modal with a required
  REASON. A reason is required for RESUME too.
- Success is recorded only from the worker's answer: `merge.status` equal to
  the target status, or a numeric `released`. `released: 0` is reported as
  "nothing was held under that key (already released)" and still reloads,
  because the list on screen is stale either way. A thrown error (404, 409, the
  proxy's 502, network) or a 2xx without the field is a failure and does not
  call `onDone`.

## Where the effect sentences come from

The modal says what the action does on the boxes, not what the row says.

- HOLD, rows-only off: `bin/merge-queue.sh:136-148` materialises a `queued`
  row as `$Q/<pr>` only when neither `<pr>` nor `<pr>.blocked` exists, and the
  queue is then the files (`mq_queue_list`, :165-168). A `blocked` row only
  stops a PR that has no file yet; one already on disk is still merged.
- HOLD, rows-only on: `mq_queue_list` (:176-187) is queued rows plus files on
  disk, minus `blocked` rows and `<n>.blocked`, so a blocked row is skipped even
  when its file is still there.
- DROP, either mode: `dropped` is not subtracted in `mq_queue_list` and nothing
  deletes the file, so a PR already materialised as a file is still offered.
- RESUME, either mode: a `queued` row is re-offered next tick (materialised when
  off, read as a row when on), except where the box parked it with a
  `<pr>.blocked` file, which both paths skip.
- Rows-only `unread`: the sentence states both cases. It is never shown as on
  or off.
- RELEASE: a held row is a page owed, and `mc_hold_flush_one`
  (`bin/lib/mc/log.sh`) goes page → mark → release. A manual release deletes the
  row first, so that page is not sent. `mc_hold_page` (:384) PUTs again on a
  later tick if the PR is still aged, so it can be held again.
