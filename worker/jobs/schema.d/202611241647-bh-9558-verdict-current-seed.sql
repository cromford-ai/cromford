-- ── BH-9558: the cap of POST /api/verdict/current ───────────────────────────
-- Reader: routes/verdict-current.js maxPrs (code fallback
-- VERDICT_CURRENT_MAX_PRS_DEFAULT = 200 in lib/verdict-rounds.js). The kanban
-- Pages Function asks for the current verdict of every open build card's PR;
-- over the cap the first N are answered and the answer says truncated.
-- No table is created here, so no index, RLS or retention rule applies.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('verdict.current.max_prs','200','BH-9558: most PR urls POST /api/verdict/current answers per call; over it the first N are answered with truncated:true. No row or not a positive integer = 200 (lib/verdict-rounds.js VERDICT_CURRENT_MAX_PRS_DEFAULT)','seed','2026-11-24T16:47:00Z');
