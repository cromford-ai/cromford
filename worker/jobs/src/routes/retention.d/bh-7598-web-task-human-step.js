export default [
  // BH-7598: a web-task human step is a short-lived request that can hold a
  // code ciphertext; not money or history. The window outlives the answer TTL.
  {
    rule: "web_task_human_step.age", table: "web_task_human_step", key: "retention.web_task_human_step.days", def: 30,
    ids: "SELECT id FROM web_task_human_step WHERE created_at < ?1 ORDER BY created_at LIMIT ?2",
    del: "DELETE FROM web_task_human_step WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
