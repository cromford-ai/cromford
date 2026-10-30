export default [
  // BH-6823: staff chat. A closed operator note goes with its reply past
  // retention.staff_chat.days. A pending, held or taken note never goes.
  {
    rule: "staff_chat.age", table: "staff_chat", key: "retention.staff_chat.days", def: 365,
    ids: `SELECT id FROM staff_chat WHERE role = 'operator' AND created_at < ?1
           AND state IN ('read','unanswered','failed') ORDER BY created_at LIMIT ?2`,
    pre: ["DELETE FROM staff_chat WHERE reply_to IN (SELECT value FROM json_each(?1))"],
    del: "DELETE FROM staff_chat WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
