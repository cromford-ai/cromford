-- ── BH-7951 (BH-7934.4): the Mill Floor console theme ──────────────────────
-- A settings row only, never a code constant (BH-7934 Decision 5). No table is
-- created here. Reader: customThemesFromSettings (console-ui/src/theme/
-- custom.js), which loads only keys ui.theme.custom.<slug>, so the key has
-- that prefix and is not theme.mill-floor. The value is the
-- exportTheme canonical JSON of the doc; an operator edits or deletes it in
-- Settings > Appearance. INSERT OR IGNORE: a re-apply never overwrites an
-- operator's edit.
-- --accent is #cd6642, not the prototype's #c8572f: #c8572f is 4.23:1 on
-- --surface-1 and 3.94:1 on --surface-2, under the 4.5:1 gate, and the reader
-- would skip the row. #cd6642 is the same hue, 9% toward white.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('ui.theme.custom.mill-floor','{"base":"mill","name":"Mill Floor","shape":{},"tokens":{"--accent":"#cd6642","--ok":"#6fae7b","--rule":"#2b2a26","--surface-0":"#0d0d0c","--surface-1":"#151513","--text":"#e7e5df","--text-dim":"#8d8a82","--text-strong":"#f2f0eb","--warn":"#d9a441"},"v":1}','BH-7934: Mill Floor console theme (custom theme row; edit in Settings > Appearance)','seed','2026-10-22T01:15:00Z');
