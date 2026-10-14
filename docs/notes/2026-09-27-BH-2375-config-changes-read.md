# /config stubs over the one audit store (BH-2375)

Doc: DB-COORDINATION-SPEC

This is the contract slice of BH-2330 (every setting and flag on one console page). the operator's RESUME of 2026-09-27 set the rule: there is one audit store, `config_changes`. This slice adds no table and no schema.

- `CONFIG_KINDS` in `worker/jobs/src/lib/config-changes.js` has two more kinds, `SETTING: 'setting'` and `FLAG: 'flag'`. Nothing writes either kind yet. The settings and flags PUTs start writing them, through the existing `configChangeStmts`, in the sibling tickets (#2376, #2377).
- `listConfigChanges(env, { kind, name, limit }, t)` in the same file is the one read over `config_changes`, newest first. A kind not in `CONFIG_KINDS`, or a name outside 1..256 characters, is `{error}` and nothing is read. `limit` works like the routing and cost-cap audit GETs: a non-number is 100, then it is clamped to 1..500. One extra row is read so `truncated` is measured. Like `configChangeStmts` it imports nothing, so the caller calls `ensureTable(env, 'config_changes')` first.
- `GET /api/config-changes[?kind=][&name=][&limit=]` (`worker/jobs/src/routes/config-changes.js`) calls `ensureTable` and then it: 200 `{changes, truncated, as_of}`, or 400 `{error}` on a bad filter. It is read-only. The coord proxy already forwards every GET, so it is untouched.
- The console has `api.configChanges({ kind, name, limit })`, `configHref(kind, name)` in `console-ui/src/lib/config.js`, and two route stubs: `/config` (ALL SETTINGS & FLAGS) and `/config/:kind/:name`. Each shows one line: loading, a failed read, "No changes recorded yet." or the count. The SETTINGS page links to `/config` beside its title, and the SETTINGS tab is highlighted on both. There is no table yet; #2378 and #2379 add it.

The `change_log.keep_per_key` retention knob is not built. `config_changes` has no pruning for any kind today.

Pinned by `worker/jobs/test/config-changes.bh-2375.test.js`, `worker/jobs/test/route-table.d/227-config-changes.txt`, `console-ui/tests/config.bh-2375.test.js` and `tests/config-console.bh-2375-test.sh`.
