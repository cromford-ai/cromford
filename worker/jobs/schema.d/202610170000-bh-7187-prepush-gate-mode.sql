-- ── BH-7187: the pre-push gate's off switch is a settings row ─────────────────
-- prepush.gate_mode: block | warn | off. Read by the `prepush gate` span in
-- bin/lib/rb/pr.sh through setting_get, `prepush.gate_mode.<project>` first,
-- then `prepush.gate_mode`.
--   block = the default. A red component of bin/prepush-gate.sh refuses the
--           push (REVIEW_BLOCKED, exit 6).
--   warn  = the gate runs, the findings go to the build log and the PR body,
--           and the push goes on.
--   off   = the gate does not run.
-- A row that cannot be read, or holds any other value, is block (fail closed).
-- D1 is SQLite, not Supabase: RLS does not apply. No new table, so no new
-- index. INSERT OR IGNORE seeds only, so a re-apply keeps an operator's value.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('prepush.gate_mode','block','BH-7187: block = a red pre-push gate component refuses the push; warn = run and note it in the PR, push anyway; off = do not run. Unreadable = block. Per project: prepush.gate_mode.<project>','seed','2026-10-17T00:00:00Z');
