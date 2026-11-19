-- BH-9800 (slice C0): the signal key store, one encrypted vendor key per
-- (project, kind). routes/signal-keys.js writes and reads it; contract:
-- docs/notes/2026-11-17-BH-9800-signal-keys.md. The crypto is the web vault's
-- (lib/web-vault-crypto.js, Worker secrets WEB_VAULT_KEY_<n>, setting
-- web_vault.key_id), with its own AAD `signal_keys\n<project>\n<kind>`.

-- The kinds catalog: one row per kind. fields_json is the ordered field list
-- [{name, label, placeholder, re, secret (0|1), prefixes (secret field only)}]:
-- the set route checks each field with it and the console renders it.
-- test_template is the probe URL, with {field} placeholders. host_field names
-- the field that holds the host (or NULL). host_allow is the comma list of
-- hosts the probe may call. An operator adds a kind or a prefix with SQL.
-- no-index: signal_key_kinds catalog of 2 rows; every read is the PRIMARY KEY or the whole table
-- no-retention: signal_key_kinds is a catalog of one row per kind (2 rows today); a row is edited in place, so the table does not grow
CREATE TABLE IF NOT EXISTS signal_key_kinds (
  kind TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  fields_json TEXT NOT NULL,
  test_template TEXT NOT NULL,
  host_field TEXT,
  host_allow TEXT NOT NULL,
  scope_note TEXT NOT NULL,
  sort INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

INSERT OR IGNORE INTO signal_key_kinds (kind, label, fields_json, test_template, host_field, host_allow, scope_note, sort, updated_at) VALUES
  ('sentry', 'Sentry',
   '[{"name":"org","label":"Organization slug","placeholder":"my-org","re":"^[a-z0-9][a-z0-9_-]{0,63}$","secret":0},{"name":"project","label":"Project slug","placeholder":"my-project","re":"^[a-z0-9][a-z0-9_-]{0,63}$","secret":0},{"name":"token","label":"API token","placeholder":"sntryu_…","re":"^[A-Za-z0-9_=+/.-]+$","secret":1,"prefixes":["sntryu_","sntrys_"]}]',
   'https://sentry.io/api/0/organizations/{org}/projects/', NULL, 'sentry.io',
   'Sentry: read scopes plus event:write, no admin.', 10, '2026-11-17T00:00:00Z'),
  ('posthog', 'PostHog',
   '[{"name":"host","label":"Host","placeholder":"https://us.posthog.com","re":"^https://[^\\s]{1,200}$","secret":0},{"name":"project_id","label":"Project id","placeholder":"12345","re":"^[0-9]{1,12}$","secret":0},{"name":"key","label":"Personal API key","placeholder":"phx_…","re":"^[A-Za-z0-9_=+/.-]+$","secret":1,"prefixes":["phx_"]}]',
   '{host}/api/projects/{project_id}/', 'host', 'us.posthog.com,eu.posthog.com,app.posthog.com',
   'PostHog: read scopes plus annotation write, scoped to the one project.', 20, '2026-11-17T00:00:00Z');

-- One row per (project, kind). fields_json holds the NON-secret fields, in
-- clear. ciphertext/iv: AES-GCM of the secret field; key_id names the Worker
-- secret it was written with. No column holds a plain secret. last_test_*
-- is written by the test route and reset to NULL by a set.
-- no-retention: signal_keys holds at most one row per project and kind (about 40 rows); a set overwrites its row and a clear deletes it, so the table does not grow
CREATE TABLE IF NOT EXISTS signal_keys (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  kind TEXT NOT NULL,
  fields_json TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  iv TEXT NOT NULL,
  key_id INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  updated_by TEXT NOT NULL,
  last_used_at TEXT,
  last_test_at TEXT,
  last_test_status INTEGER,
  last_test_result TEXT
);
-- The set upsert (ON CONFLICT), the clear, every read by (project, kind), the
-- project list (project=? ORDER BY kind) and the fleet list (ORDER BY project, kind).
CREATE UNIQUE INDEX IF NOT EXISTS uq_signal_keys_entry ON signal_keys(project, kind);

-- One row per set, clear, test, read and hub read, ok or refused. Never a
-- value, never a token.
-- RETENTION: rule signal_key_audit.age (routes/retention.d/bh-9800-signal-keys.js),
-- window retention.signal_key_audit.days (90), under retention.dry_run. Rows
-- are history, so they are copied to the archive D1 before the delete.
CREATE TABLE IF NOT EXISTS signal_key_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('set','clear','test','read','hub_read')),
  outcome TEXT NOT NULL,
  project TEXT NOT NULL,
  kind TEXT NOT NULL,
  actor TEXT NOT NULL,
  run_id INTEGER,
  key_id INTEGER
);
-- The retention id read: at < ? ORDER BY at LIMIT ?.
CREATE INDEX IF NOT EXISTS idx_signal_key_audit_at ON signal_key_audit(at);
-- The per-entry history: project=? AND kind=? ORDER BY at DESC.
CREATE INDEX IF NOT EXISTS idx_signal_key_audit_entry ON signal_key_audit(project, kind, at);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('signal_keys.read_lanes','','BH-9800: comma list of lane-run lanes whose claim mints a run token for POST /api/signal-keys/read and whose enqueue needs the operator token; empty = the lane read refuses every run; the code default is empty','seed','2026-11-17T00:00:00Z'),
  ('signal_keys.test_timeout_ms','10000','BH-9800: ms the signal key test route waits for the vendor (1000..30000); the code default is 10000','seed','2026-11-17T00:00:00Z'),
  ('signal_keys.rotate_days','90','BH-9800: days after a set that GET /api/signal-keys reports as rotate_by (1..3650); the code default is 90','seed','2026-11-17T00:00:00Z'),
  ('signal_keys.list_limit','500','BH-9800: rows GET /api/signal-keys answers at most (1..5000); the code default is 500','seed','2026-11-17T00:00:00Z'),
  ('signal_keys.value_max_bytes','4096','BH-9800: largest secret field a signal key set accepts, in bytes (64..16384); the code default is 4096','seed','2026-11-17T00:00:00Z'),
  ('retention.signal_key_audit.days','90','BH-9800: days a signal_key_audit row is kept before the hourly retention run archives it (0 = off); the code default is 90','seed','2026-11-17T00:00:00Z');
