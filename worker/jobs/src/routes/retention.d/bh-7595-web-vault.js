export default [
  // BH-7595: the web_vault audit trail is history, so it is copied to the
  // archive D1 before the delete; unbound, nothing is deleted. web_vault itself
  // has no rule: a stale entry is reported, never deleted.
  {
    rule: "web_vault_audit.age", table: "web_vault_audit", key: "retention.web_vault_audit.days", def: 90,
    archive: "web_vault_audit", quietUnbound: true,
    ids: "SELECT id FROM web_vault_audit WHERE at < ?1 ORDER BY at LIMIT ?2",
    sel: "SELECT * FROM web_vault_audit WHERE id IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM web_vault_audit WHERE id IN (SELECT value FROM json_each(?1))",
  },
  // BH-7595: the hash of a web-task claim token is a short-lived credential,
  // not history; a run past its lease has no use for it.
  {
    rule: "web_vault_run_token.age", table: "web_vault_run_token", key: "retention.web_vault_run_token.days", def: 2,
    ids: "SELECT run_id AS id FROM web_vault_run_token WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM web_vault_run_token WHERE run_id IN (SELECT value FROM json_each(?1))",
  },
];
