// harness-otp-inbox — the Email Worker behind Cloudflare Email Routing on
// otp.example.com (catch-all), BH-7732. A vendor emails a one-time code to
// <anything>@otp.example.com; this worker parses the message and writes ONE
// otp_messages row to the harness-jobs D1. A web-task lane reads the code
// with bin/otp-wait.sh through the jobs route GET /api/otp.
// Note: docs/notes/2026-10-20-BH-7732-otp-inbox.md.
//
// email(message, env)
//   1. rawSize over MAX_RAW_BYTES: the row is written with status too_large
//      and no code, from the envelope and the headers; the body is not read.
//   2. Else the raw message is read, parsed (src/mime.js) and matched
//      (src/code.js): status code or no_code.
//   3. ONE insert, ON CONFLICT(recipient, message_id) DO NOTHING: a second
//      delivery of the same message to the same address writes no row.
//   4. ONE log line: to, from, status and dup. The code is never in it.
//   5. A failed insert logs the error name only and rethrows: the handler
//      fails, it never returns as if the row were stored.
// It is a separate worker from harness-jobs on purpose: a parser crash here
// never touches the coordination API.
import { parseMime, decodeWords } from "./mime.js";
import { extractCode } from "./code.js";

export const MAX_RAW_BYTES = 1048576;
const SUBJECT_MAX = 300;

// ?1 recipient ?2 message_id ?3 sender ?4 subject ?5 code ?6 parse_status ?7 received_at.
// uq_otp_messages_msg (recipient, message_id).
export const INSERT_SQL = `INSERT INTO otp_messages (recipient, message_id, sender, subject, code, parse_status, received_at)
 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(recipient, message_id) DO NOTHING`;

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

async function sha256Hex(s) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readRaw(stream) {
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export async function email(message, env) {
  const recipient = String(message.to || "").trim().toLowerCase();
  const sender = String(message.from || "").trim().toLowerCase();
  const receivedAt = iso(Date.now());
  let headers, code = null, status;
  if (Number(message.rawSize) > MAX_RAW_BYTES) {
    const h = message.headers;
    headers = new Map(["subject", "message-id", "date"].map((k) => [k, decodeWords(h?.get(k) || "")]));
    status = "too_large";
  } else {
    const m = parseMime(await readRaw(message.raw));
    headers = m.headers;
    ({ code, status } = extractCode(headers.get("subject"), m.bodyText));
  }
  const subject = String(headers.get("subject") || "").slice(0, SUBJECT_MAX);
  const messageId = String(headers.get("message-id") || "").trim()
    || `fp:${await sha256Hex([sender, recipient, subject, String(headers.get("date") || "").trim()].join("|"))}`;
  let res;
  try {
    res = await env.DB.prepare(INSERT_SQL).bind(recipient, messageId, sender, subject, code, status, receivedAt).run();
  } catch (e) {
    console.error(`otp-inbox: store failed to=${recipient} err=${(e && e.name) || "Error"}`);
    throw e;
  }
  const dup = Number(res?.meta?.changes) === 0 ? 1 : 0;
  console.log(`otp-inbox: stored to=${recipient} from=${sender} status=${status} dup=${dup}`);
}

export default {
  email,
  // No HTTP surface: the route that reads the rows is on harness-jobs.
  async fetch() {
    return new Response("not found", { status: 404 });
  },
};
