-- BH-9308: range indexes for the console's log screens on harness-console-db.
-- Applied by bin/console-db-schema.sh, which bin/console-pages-deploy.sh runs
-- after each Pages deploy. Only CREATE INDEX IF NOT EXISTS is accepted here.
--
-- idx_runs_started          HISTORY (and LANES) range read with no project:
--                           WHERE started_at >= ? AND started_at < ? ORDER BY started_at, id
-- idx_runs_project_started  the same range read with a project filter:
--                           WHERE project = ? AND started_at >= ? AND started_at < ?
-- idx_commands_created      COMMAND LOG range read:
--                           WHERE created_at >= ? AND created_at < ? ORDER BY created_at, id
-- The id column is the cursor tie-break, so a page boundary reads the index too.
CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at, id);
CREATE INDEX IF NOT EXISTS idx_runs_project_started ON runs(project, started_at, id);
CREATE INDEX IF NOT EXISTS idx_commands_created ON commands(created_at, id);
