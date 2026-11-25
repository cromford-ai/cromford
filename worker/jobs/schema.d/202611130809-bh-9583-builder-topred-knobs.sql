-- BH-9583 (BH-9559 part D, item 10): the knobs of the builder gate's `topred`
-- tier (bin/test-impact-gate.sh) and of GET /api/gate-red/top
-- (src/routes/gate-red-rank.js). Settings rows only: no table, no index.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('builder_gate.topred.enabled','1','BH-9583: 1 = the builder gate runs the top GATE_RED suites as tier topred, 0 = off. Reader: bin/test-impact-gate.sh (no row = 1; any value but 0 or 1 = off).','seed','2026-11-13T08:00:00Z'),
  ('builder_gate.topred_n','5','BH-9583: how many GATE_RED suites the topred tier asks for. Readers: bin/test-impact-gate.sh, routes/gate-red-rank.js (positive integer, fallback 5).','seed','2026-11-13T08:00:00Z'),
  ('builder_gate.topred_window_days','14','BH-9583: the window in days of GATE_RED build rows the ranking counts. Readers: bin/test-impact-gate.sh, routes/gate-red-rank.js (positive integer, fallback 14).','seed','2026-11-13T08:00:00Z');
