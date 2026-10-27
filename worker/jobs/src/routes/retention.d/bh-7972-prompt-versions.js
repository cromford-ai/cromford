export default [
  // BH-7972 (BH-7940.4): prompt versions are history: an old version is copied
  // to the archive D1, then deleted, never only deleted. Eligible: outside the
  // newest prompts.retention.keep_versions of its (scope, project, kind), older
  // than retention.prompt_versions.days, and not pointed at by any head. Rank
  // "> keep" is "version <= MAX - keep" because versions are numbered 1..MAX
  // with no gap above the archived ones. A keep_versions row that is not a
  // whole number >= 1 is the documented fallback 200, never "archive all".
  // The GROUP BY reads prompt_versions_key once per run; prompt_heads is
  // bounded at (1 + projects) x 7 rows.
  {
    rule: "prompt_versions.archive", table: "prompt_versions", key: "retention.prompt_versions.days", def: 30,
    archive: "prompt_versions", quietUnbound: true,
    ids: `WITH keep AS (
             SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM settings
               WHERE key = 'prompts.retention.keep_versions'
                 AND trim(value) GLOB '[1-9]*' AND trim(value) NOT GLOB '*[^0-9]*'), 200) AS n),
           cut AS (
             SELECT scope, project, kind, MAX(version) - (SELECT n FROM keep) AS upto
             FROM prompt_versions GROUP BY scope, project, kind)
           SELECT v.id FROM cut JOIN prompt_versions v
             ON v.scope = cut.scope AND v.project = cut.project AND v.kind = cut.kind AND v.version <= cut.upto
           WHERE v.created_at < ?1 AND v.id NOT IN (SELECT version_id FROM prompt_heads)
           ORDER BY v.id LIMIT ?2`,
    sel: "SELECT * FROM prompt_versions WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM prompt_versions WHERE id IN (SELECT value FROM json_each(?1)) AND id NOT IN (SELECT version_id FROM prompt_heads)",
  },
];
