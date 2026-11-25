// GET /api/webhook-dead-letters?vendor=github — BH-9934 (BH-9926.2).
// The dead letters the receiver wrote (routes/webhooks.js: a throw after the
// signature check is one webhook_deliveries row of vendor `<vendor>:dead`).
// Answer {vendor, count, newest_at, newest: {delivery_id, event, error} | null,
// as_of}. Reader: bin/doorbell-coverage-check.sh, one alert while count > 0.
// Bearer-gated like every /api/* route. Index: the primary key
// (vendor, delivery_id) serves both reads (test X2). Rows age out through
// pruneDeliveries (webhook_delivery_keep_s).
import { d1Guarded, json } from "../lib/http.js";
import { ensureColumns } from "../lib/core.js";

export const DEAD_COUNT_SQL = "SELECT COUNT(*) AS n, MAX(at) AS newest_at FROM webhook_deliveries WHERE vendor = ?1";
export const DEAD_NEWEST_SQL = "SELECT delivery_id, event, error FROM webhook_deliveries WHERE vendor = ?1 AND at = ?2 LIMIT 1";
const VENDOR_RE = /^[a-z]{1,16}$/;

export const routes = [
  [
    "GET", "/api/webhook-dead-letters",
    ({ env, url, t }) => d1Guarded("webhook_deliveries", async () => {
      const vendor = url.searchParams.get("vendor") || "";
      if (!VENDOR_RE.test(vendor)) return json(400, { error: "invalid_field", field: "vendor" });
      await ensureColumns(env, "webhook_deliveries");
      const dead = `${vendor}:dead`;
      const c = await env.DB.prepare(DEAD_COUNT_SQL).bind(dead).first();
      const count = Number((c && c.n) || 0);
      const newestAt = (c && c.newest_at) || null;
      const r = count > 0 && newestAt ? await env.DB.prepare(DEAD_NEWEST_SQL).bind(dead, newestAt).first() : null;
      return json(200, {
        vendor, count, newest_at: newestAt,
        newest: r ? { delivery_id: r.delivery_id, event: r.event ?? null, error: r.error ?? null } : null,
        as_of: t,
      });
    }),
  ],
];
