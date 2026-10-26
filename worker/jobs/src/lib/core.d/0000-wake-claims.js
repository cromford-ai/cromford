// Frozen baseline: CREATED_TABLE_OVERRIDES.wake_claims, moved byte for byte from core.js (BH-8447). A new statement is a new core.d/<ticket-key>-<name>.js.
export const CREATED_TABLE_OVERRIDES = {
  // BH-2636 — POST /api/wakes/prune now sweeps orphan claims, and the prune is
  // a daily lane that already self-creates `wakes`; without this belt it would
  // 500 on a database the deploy-time schema.sql apply has not reached. Same
  // text as schema.sql's BH-2525 block, column for column.
  wake_claims: [
    `CREATE TABLE IF NOT EXISTS wake_claims (
       wake_id INTEGER NOT NULL,
       box TEXT NOT NULL,
       claimed_at TEXT NOT NULL,
       PRIMARY KEY (wake_id, box)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_wake_claims_box_wake ON wake_claims(box, wake_id)",
  ],
};
