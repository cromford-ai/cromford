// The QA read token (BH-9263). A console QA preview session reads this worker
// with QA_READ_TOKEN, never with HARNESS_SECRET. That token opens only the
// GET routes in the shared QA read policy, with only their listed query
// parameters, and every answer is projected to the listed fields. Everything
// else is 403: a write, an unknown route, otp, settings.
//
// index.js asks qaReadOk only after bearerOk failed, so HARNESS_SECRET keeps
// its full power and this file never widens it.
//
// UNSET IS DENIED. An unset or blank QA_READ_TOKEN opens nothing, and a token
// equal to HARNESS_SECRET is treated as unset (that bearer already passed
// bearerOk, so it never gets here).
import { matchRoute } from "./router.js";
import { qaReadPolicy, qaReadQuery, projectQaBody } from "./qa-read-policy.js"; // a copy of console-ui/functions/_lib/qa-read-policy.js

const noStore = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
});

// qaReadOk <req> <env> — true when the bearer is the QA read token.
export function qaReadOk(req, env) {
  const tok = String((env && env.QA_READ_TOKEN) || "").trim();
  if (!tok || tok === String((env && env.HARNESS_SECRET) || "").trim()) return false;
  const auth = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
  return auth === tok;
}

// qaReadDispatch <ctx> <routes> — the QA answer for one request that carries
// the QA read token. Runs the real GET handler with the allowed query only.
export async function qaReadDispatch({ req, env, url, path, t }, routes) {
  const refuse = () => noStore(403, { error: "not allowed for the QA read token" });
  if (req.method !== "GET" || !path.startsWith("/api/")) return refuse();
  const rest = path.slice("/api/".length);
  const row = qaReadPolicy(rest);
  if (!row) return refuse();
  const hit = matchRoute(routes, "GET", path);
  if (!hit) return refuse();
  const narrowed = new URL(url.toString());
  narrowed.search = qaReadQuery(row, url.searchParams).toString();
  const res = await hit.handler({ req, env, url: narrowed, path, t, body: {}, m: hit.m });
  let body = null;
  try { body = JSON.parse(await res.text()); } catch { body = null; }
  if (res.status !== 200) {
    const error = body && typeof body.error === "string" ? body.error : `answered ${res.status}`;
    return noStore(res.status, { error });
  }
  const out = projectQaBody(rest, body);
  if (!out) return noStore(502, { error: "unexpected body" });
  return noStore(200, out);
}
