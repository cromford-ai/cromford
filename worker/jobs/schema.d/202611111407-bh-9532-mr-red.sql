-- ── BH-9532 (C0, #9539): Mr Red, the staff agent that owns red minutes ──────
-- mr_red_actions is Mr Red's audit row: one row per (lever, target,
-- fingerprint, approach), the natural key action_key =
-- sha256(lever|target|fingerprint|approach), computed by the route
-- (worker/jobs/src/routes/mr-red.js). Writers: POST and PATCH
-- /api/mr-red/actions (bin/lib/mr-red.sh mrr_action_post, mrr_action_patch,
-- called by bin/staff/mr-red.sh tick). Readers: GET /api/mr-red/actions and
-- the sibling slices (#9540 to #9543).
-- D1, so no RLS. Add-only: IF NOT EXISTS and INSERT OR IGNORE, no DROP,
-- ALTER or DELETE.
-- Note: docs/notes/2026-11-11-BH-9532-mr-red.md.
CREATE TABLE IF NOT EXISTS mr_red_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action_key TEXT NOT NULL UNIQUE,
  fingerprint TEXT NOT NULL,
  project TEXT,
  repo TEXT NOT NULL,
  target_kind TEXT NOT NULL DEFAULT 'pr',
  target TEXT NOT NULL,
  lever TEXT NOT NULL,
  approach TEXT NOT NULL DEFAULT 'none',
  dry_run INTEGER NOT NULL DEFAULT 0,
  red_check TEXT,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  state TEXT NOT NULL,
  verified_red_at TEXT,
  verified_green_at TEXT,
  green_since TEXT,
  cleared_at TEXT,
  returned_at TEXT,
  charged_minutes INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
-- GET /api/mr-red/actions with no filter (and lever= alone): ORDER BY
-- created_at DESC, id DESC and the keyset cursor.
CREATE INDEX IF NOT EXISTS ix_mr_red_actions_created ON mr_red_actions(created_at DESC, id DESC);
-- GET fingerprint= (+ target=): the loop check of #9541 reads by fingerprint and target.
CREATE INDEX IF NOT EXISTS ix_mr_red_actions_fp ON mr_red_actions(fingerprint, target, created_at);
-- GET state=: the judge of #9543 reads open rows by state and green_since.
CREATE INDEX IF NOT EXISTS ix_mr_red_actions_state ON mr_red_actions(state, green_since);
-- GET repo=: one repo's rows newest first, so a repo with no rows reads no rows.
CREATE INDEX IF NOT EXISTS ix_mr_red_actions_repo ON mr_red_actions(repo, created_at DESC, id DESC);
-- The UNIQUE on action_key (sqlite_autoindex_mr_red_actions_1) serves the
-- POST replay read and the PATCH lookup.
-- no-retention: mr_red_actions the retention rule (terminal rows past retention.mr_red_actions.days, dry-run first) ships in BH-9532.4 (#9543), which deletes this line when it adds the rule

-- Mr Red on the staff roster. Its items reach it only through
-- bin/staff/mr-red.sh: bin/staff/mr-red-collect.sh prints nothing unless
-- MRR_TICK=1, so bin/staff.sh tick-all claims nothing for it and makes no
-- model call.
INSERT OR IGNORE INTO staff_agents (name, role, accountable, autonomy, cap, status, soul_path, updated_at, note) VALUES
  ('mr-red','red','operator@example.com','automation','autonomy','active','prompts/staff/mr-red-soul.md','2026-11-11T14:07:00Z','BH-9532 seed: red minutes');
INSERT OR IGNORE INTO staff_lanes (agent, lane, created_at) VALUES
  ('mr-red','staff-mr-red','2026-11-11T14:07:00Z');

-- The core knobs. Each fallback in the reader is the same value as the seed.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.mr-red.level','act','BH-9532: observe | file | act. Reader bin/staff/mr-red.sh (staff_level; fallback observe). At act the tick walks bin/staff/mr-red.d/ for a lever; in C0 no lever matches, so every finding is an observe row.','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.metric','red_minutes','BH-9532: the metric Mr Red owns. Reader GET /api/staff/levers/scorecard; the judge (BH-9532.4) samples it.','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.target','0','BH-9532: the red_minutes target. Reader GET /api/staff/levers/scorecard and the judge (BH-9532.4).','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.authority.merge','off','BH-9532: on | off. At off a lever that would merge records a dry_run=1 row with the command. Read by the sibling levers (BH-9532.1 to .3); fallback off.','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.authority.prod_apply','off','BH-9532: on | off. At off a lever that would apply to production records a dry_run=1 row. Read by the sibling levers; fallback off.','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.authority.force_push','off','BH-9532: on | off. At off a lever that would force-push records a dry_run=1 row. Read by the sibling levers; fallback off.','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.authority.secrets','off','BH-9532: on | off. At off a lever that would touch a secret records a dry_run=1 row. Read by the sibling levers; fallback off.','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.max_items_tick','50','BH-9532: the most findings one tick handles; the rest are deferred= to the next tick. Reader bin/staff/mr-red.sh (staff_knob; fallback 50).','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.lookback_h','24','BH-9532: the collector reads drafts closed in the last this many hours. Reader bin/staff/mr-red.sh, passed to bin/staff/mr-red-collect.d/ (fallback 24).','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.tick_timeout_s','240','BH-9532: one tick stops after this many seconds (inside the */5 cadence). Reader bin/staff/mr-red.sh (fallback 240).','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.loop_same_fix_max','3','BH-9532: the same fix on the same finding at most this many times. Read by mrr_loop_check (BH-9532.2); fallback 3.','seed','2026-11-11T14:07:00Z'),
  ('staff.mr-red.migration_gate_checks','migration-gate','BH-9532: comma list of the check names that mean the migration is not in production. Read by levers 20 and 60 (BH-9532.2, .3); source: assumed (the run-build gate file name).','seed','2026-11-11T14:07:00Z');
