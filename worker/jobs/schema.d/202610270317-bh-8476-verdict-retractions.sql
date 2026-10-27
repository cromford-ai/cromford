-- BH-8476: verdict_retractions. A lead BLOCK row whose review report was empty
-- (no finding line) is not a verdict. POST /api/verdicts/<id>/retract (lead
-- token, reason empty-report, routes/verdict-retractions.js) records one row
-- here per retracted verdict id. GET /api/verdicts treats a retracted row as
-- absent for `standing` (id NOT IN this table) and keeps it in history with
-- retracted_at and retract_reason (a LEFT JOIN on verdict_id). The verdicts
-- table stays append-only: a retraction annotates a row, it never edits one.
-- Only a source=lead verdict=BLOCK row can be retracted (409 otherwise).
-- Retention: history beside the append-only verdicts table, kept for ever. A
-- few rows a month. Never deleted, so no retention lane.
-- no-index: verdict_retractions the INTEGER PRIMARY KEY (rowid) serves every read: the NOT IN on verdict_id and the LEFT JOIN on verdict_id
CREATE TABLE IF NOT EXISTS verdict_retractions (
  verdict_id INTEGER PRIMARY KEY,
  reason TEXT NOT NULL,
  actor TEXT,
  created_at TEXT NOT NULL
);
