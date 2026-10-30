export default [
  // BH-7732: an OTP row is a short-lived secret with no reader after minutes; not money or history.
  {
    rule: "otp_messages.age", table: "otp_messages", key: "retention.otp_messages.days", def: 1,
    ids: "SELECT id FROM otp_messages WHERE received_at < ?1 ORDER BY received_at LIMIT ?2",
    del: "DELETE FROM otp_messages WHERE id IN (SELECT value FROM json_each(?1))",
  },
];
