// otp inbox read — the newest one-time code a vendor emailed to an address on
// otp.example.com (BH-7732). The Email Worker worker/otp-inbox writes the
// otp_messages rows; a web-task lane reads them with bin/otp-wait.sh.
// Note: docs/notes/2026-10-20-BH-7732-otp-inbox.md.
//
// GET /api/otp?to=<address>&since=<ts>
//   to is trimmed and lowercased, the way the Email Worker stores it.
//   since is YYYY-MM-DDTHH:MM:SSZ or epoch seconds; required. 400 on either.
//   ONE statement: the newest row with a code for that address received at
//   or after since. 200 {code, sender, subject, received_at}; 404 when there
//   is none. Both answers are no-store.
//
// The code is a short-lived secret. No line here logs it, and it leaves only
// in the 200 body to a HARNESS_SECRET bearer (index.js checks it before any
// gated family runs).
import { d1Guarded } from "../lib/http.js";

// ?1 recipient, ?2 since. idx_otp_messages_recipient (recipient, received_at).
export const OTP_READ_SQL = `SELECT code, sender, subject, received_at FROM otp_messages
 WHERE recipient=?1 AND received_at>=?2 AND code IS NOT NULL
 ORDER BY received_at DESC, id DESC LIMIT 1`;

const TO_RE = /^[^@\s/]{1,64}@[a-z0-9.-]{1,190}$/;
const ISO_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const EPOCH_RE = /^\d{1,11}$/;

const noStore = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
});

// since as the stored ISO shape, or "" when it is neither form.
function sinceIso(raw) {
  const s = String(raw || "").trim();
  if (ISO_RE.test(s)) return s;
  if (EPOCH_RE.test(s)) return new Date(Number(s) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
  return "";
}

export const routes = [
  [
    "GET", "/api/otp",
    ({ env, t, url }) => d1Guarded("otp_messages", async () => {
      const to = String(url.searchParams.get("to") || "").trim().toLowerCase();
      if (!TO_RE.test(to)) return noStore(400, { error: "to must be an email address" });
      const since = sinceIso(url.searchParams.get("since"));
      if (!since) return noStore(400, { error: "since is required: YYYY-MM-DDTHH:MM:SSZ or epoch seconds" });
      const row = await env.DB.prepare(OTP_READ_SQL).bind(to, since).first();
      if (!row) return noStore(404, { error: "no code", as_of: t });
      return noStore(200, { code: row.code, sender: row.sender, subject: row.subject, received_at: row.received_at, as_of: t });
    }),
  ],
];
