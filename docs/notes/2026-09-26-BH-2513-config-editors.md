# CONTROLS: one console screen for the editable config kinds (BH-2513.4, BH-2621)

Doc: CONSOLE, mission-control-settings

## What changed

- **New screen `/controls/<kind>`** (`console-ui/src/screens/Controls.js`,
  routed in `console-ui/src/app.js`). It knows no kind by name. Tabs, columns,
  fields and routes all come from `CONTROL_KINDS` in
  `console-ui/src/lib/controls.js`, which ships four kinds: review-gate,
  rules, retry-policies and contracts. The page is keyed by kind, so switching
  kinds (a tab, Back, Forward) remounts it and an open edit does not carry over.
- **The list** is one `SortableTable` with a sortable column per key field and
  edit field, default sort on the first key. The identity cell is an EDIT
  button, and NEW opens a blank row.
- **An edit** happens in the shared in-app Modal. On EDIT the key fields are
  read-only. On NEW they are editable, and a key named in the kind's
  `keySelect` is a select over that list from the GET response. REASON is
  required. SAVE stays disabled while `controlBody` answers an error, so a
  blank reason or a blank or non-numeric number field sends nothing.
- **The paths.** The descriptors hold the worker's paths (`/api/review-gate`).
  The coord proxy forwards `/api/coord/<rest>` to the worker's `/api/<rest>`,
  so `api.controlsList` and `api.controlsPut` drop the leading `/api` and call
  `GET /api/coord/review-gate`, `PUT /api/coord/review-gate/thresholds` and so
  on. Sending the descriptor path as is would reach `/api/api/review-gate`.
- **The write** is one PUT, never retried. The modal closes only on a 2xx and
  then reloads the list. A refusal, whether it is the worker's 400 `error`, a
  proxy 405 or a network failure, stays inside the modal as
  "not saved — <error>", and the draft is kept.
- **SETTINGS** shows a CONTROLS link row to each kind, and the SETTINGS nav tab
  stays lit on `/controls/*`.

## Saving needs BH-2619

The coord proxy's WRITES table does not admit these four PUTs yet. That is
BH-2619 (PR #2775). Until it lands, the lists load and every SAVE shows
"not saved — method PUT not allowed on /api/coord/…" in the modal. Nothing in
this screen changes when it lands.

## Tests

`console-ui/tests/controls-render.bh-2621.test.js` renders every load state
for each of the four kinds, drives the save path against the real
`api.controlsPut` and `controlBody` with fetch captured, sends each kind's
list read through the real coord proxy to check the worker route it reaches,
and checks the production route table and the SETTINGS row.
`tests/controls-screen.bh-2513-test.sh` names the screen for the orphan
ratchet, pins the shared table, the modal, no native dialogs and no hardcoded
kind, and runs the node suite and the console build when the console-ui
dependencies are installed.
