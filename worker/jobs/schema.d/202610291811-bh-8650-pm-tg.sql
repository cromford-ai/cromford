-- BH-8650: Telegram Approve/Reject buttons for the moves of a PM brief
-- (worker/jobs/src/routes/pm-tg.js). No table: the buttons read pm_moves and
-- pm_briefs (202610280601-bh-7261-pm-briefs.sql) and the existing ledgers row
-- kind pm_tg_buttons. Two knob rows (BH-7945): pm.tg_buttons_max (pm-tg.js
-- falls back to 25) and pm.tg_buttons_enabled (bin/pm-groom.sh falls back to
-- 0). Set pm.tg_buttons_enabled to 1 only in the change set that ships the
-- cromford-console forward of `pm:` callbacks to POST /api/pm/moves/tg.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('pm.tg_buttons_max','25','BH-8650: proposed moves that get Telegram Approve/Reject buttons in one brief (1..50); the rest keep their Mission Control link','seed','2026-10-27T21:58:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('pm.tg_buttons_enabled','0','BH-8650: 1 sends the Telegram Approve/Reject message after the PM brief (0..1); keep 0 until the console forwards pm: callbacks to POST /api/pm/moves/tg','seed','2026-10-28T00:00:00Z');
