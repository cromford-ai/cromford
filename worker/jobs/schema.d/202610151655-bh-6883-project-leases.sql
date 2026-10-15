-- BH-6883 (BH-6881.1): the project lease. One row per (lane, project): who may
-- act for that lane on that project, until when, and the fence token a writer
-- shows before each write. Routes: worker/jobs/src/routes/project-leases.js.
-- Contract: docs/notes/2026-10-15-BH-6883-project-lease.md. Additive only.
--
-- Retention: none. The table holds one row per (lane, project), so it never
-- grows past lanes x fleet projects. A row is never deleted: release only
-- moves lease_until. A deleted row would restart the fence at 1, and a stale
-- holder's old fence could then match again.
CREATE TABLE IF NOT EXISTS project_leases (
  lane TEXT NOT NULL,
  project TEXT NOT NULL,
  holder TEXT NOT NULL,
  fence INTEGER NOT NULL,
  lease_until TEXT NOT NULL,
  acquired_at TEXT NOT NULL,
  PRIMARY KEY (lane, project)
);
-- no-index: project_leases every read and write is WHERE lane=? AND project=? or ON CONFLICT(lane,project), served by the PRIMARY KEY (tests/project-lease.bh-6883-test.sh case 5)
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('project_lease.ttl_s','180','BH-6883: seconds a project lease lives after acquire or renew when the caller sends no ttl_s (10..900); the code default is 180','seed','2026-10-15T00:00:00Z');
