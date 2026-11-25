// core.d/bh-9934-webhook-deliveries.js — BH-9934 (BH-9926.2): three
// webhook_deliveries columns. The table exists in the live database, so only
// these ALTERs reach it. Nullable, never backfilled.
//   claim  the random id the GitHub receiver writes with a NEW delivery row
//          (routes/webhooks.js deliveryStmt). The PR record statements in the
//          same batch run only while the row holds THEIR claim
//          (lib/webhook-receiver.js CLAIM_GUARD_SQL), so a duplicate delivery
//          writes no record. Index: the primary key (vendor, delivery_id).
//   error  a dead letter's error text (vendor `github:dead`, routes/webhooks.js).
//   event  a dead letter's X-GitHub-Event.
// Readers: GET /api/webhook-dead-letters (routes/webhook-dead-letters.js),
// bin/doorbell-coverage-check.sh through that route. Retention: pruneDeliveries
// (routes/webhooks.js) deletes every vendor's rows older than webhook_delivery_keep_s.
export const ADDED_COLUMNS = {
  webhook_deliveries: [["claim", "TEXT"], ["error", "TEXT"], ["event", "TEXT"]],
};
