# /config/:kind/:name shows the current row and its history (BH-2379)

Doc: DB-COORDINATION-SPEC

BH-2330.4 replaces the `/config/:kind/:name` stub from BH-2375. The page still reads the one audit store, `config_changes`. It adds no table, no route and no api method.

- HISTORY reads `api.configChanges({ kind, name, limit: 500 })` every 30 s and shows the rows in the shared `SortableTable`: AT, BEFORE → AFTER, WHO, WHY, newest first, every header sortable over the loaded rows. `before_json` NULL reads "(created)" and `after_json` `'null'` reads "(deleted)". `truncated: true` adds "showing the newest N changes; sorting covers only these". Zero rows is the Empty "no changes recorded yet". A failed read is an ErrorBox with RETRY, above the last rows when there were any. A body without a `changes` array is an ErrorBox too, never Empty.
- CURRENT: a `setting` reads `api.coordSetting(name)` (value, last writer, updated age, note, or "no row"). A `flag` reads `api.coordFlags()` and finds the name (state, last writer, updated age, reason). A flag absent from a full 500-row list reads "not in the first 500 flags", not "no row". Every other kind in `CONFIG_KINDS` shows "history only". A failed current read is its own ErrorBox and the history still renders.
- A kind outside `CONFIG_KINDS` (the console's copy is `CONFIG_KIND_VALUES` in `console-ui/src/lib/config-detail.js`, pinned equal to the worker's) shows "unknown kind: <kind>" and makes no request.
- A read started for the previous `(kind, name)` never settles, so it cannot paint over the current record or keep polling it. `usePolledApi` shares one alive flag across dependency changes, so the screen guards this itself.

Pinned by `console-ui/tests/config-detail-render.bh-2330.test.js`, `console-ui/tests/config.bh-2375.test.js` (C5, C6, C6b now pin this page) and `tests/config-detail-console.bh-2379-test.sh`.
