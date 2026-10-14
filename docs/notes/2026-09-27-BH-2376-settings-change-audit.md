# Settings writes land in config_changes (BH-2376)

Doc: DB-COORDINATION-SPEC, MISSION-CONTROL

This is the settings slice of BH-2330. the operator's RESUME of 2026-09-27 said there is one audit store, so there is no `settings_changes` table. Settings writes go into the existing `config_changes` table.

- `PUT /api/settings` (`worker/jobs/src/routes/settings.js`) now reads the key's current value on every write. When the value changes, the upsert and one `config_changes` row (kind `setting`, name = the key, `before_json`/`after_json` = `{"value": ...}`, the actor, the reason) go in one `env.DB.batch`. A create has `before_json` NULL. A JSON number is logged as the string it is stored as.
- Only `value` is audited. A write with the same value (the conductor's republish, the wake cursor) costs one SELECT and logs nothing, and so does a rewrite that only changes the actor or the note.
- A cap key (`conf.cost-caps.*` / `conf.lane-caps.*`) gets no `setting` row. It keeps its `cost_cap_changes` row and its `cost_cap` config_changes row, so each write has exactly one audit row. `PUT /api/cost-caps` never goes through this route and is unchanged.
- The PUT takes an optional `reason`. It is trimmed and anything over 512 characters is a 400, which now applies to cap keys too; before this they were truncated. The row's reason is `reason`, falling back to `note`. `reason` is never written to `settings.note`. Every refusal (bad key, `settable:false`, a token in `account.*`, the reserved seed actor, a bad owner, a long reason) still returns before any DB touch, so a refused value is never logged. The PUT's response is unchanged.
- `GET /api/settings-changes[?key=][&limit=]` is `listConfigChanges` with kind `setting`: 200 `{changes, truncated, as_of}`, newest first. A `key` that fails `SETTING_KEY_RE` is a 400. It sits above `GET prefix:/api/settings/` in the route table. A cap key's history is under `GET /api/config-changes?kind=cost_cap`.
- The registry seed's own writes (`POST /api/settings/seed-registry`) are not logged. Its response is still the only per-key record of what it wrote.

No retention: `config_changes` has no pruning for any kind yet.

Pinned by `worker/jobs/test/settings-changes.bh-2376.test.js` and `worker/jobs/test/route-table.d/150-settings.txt`.
