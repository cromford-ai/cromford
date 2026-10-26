// Frozen baseline: CREATED_TABLE_OVERRIDES.setting_sigs, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-3905 — schema.sql's setting_sigs block is the comment; the triggers live
  // only here, the same way as verdicts above.
  setting_sigs: [
    `CREATE TABLE IF NOT EXISTS setting_sigs (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       key TEXT NOT NULL,
       seq INTEGER NOT NULL,
       sig TEXT NOT NULL,
       actor TEXT,
       at TEXT NOT NULL,
       UNIQUE(key, seq)
     )`,
    "CREATE TRIGGER IF NOT EXISTS setting_sigs_no_update BEFORE UPDATE ON setting_sigs BEGIN SELECT RAISE(ABORT, 'setting_sigs is append-only'); END",
    "CREATE TRIGGER IF NOT EXISTS setting_sigs_no_delete BEFORE DELETE ON setting_sigs BEGIN SELECT RAISE(ABORT, 'setting_sigs is append-only'); END",
  ],
};
