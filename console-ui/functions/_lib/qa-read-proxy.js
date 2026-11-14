// The coord proxy's QA read (BH-9263). A QA session (a `dashqa` cookie with no
// valid `dash`) never gets the operator's pass-through GET: it reads only the
// routes in qa-read-policy.js, with only their listed query parameters, and the
// answer is cut to the listed fields. functions/api/coord/[[path]].js calls
// qaRead first for every GET; null means "not a QA read, go on as before".
import { qaOnly } from './qa-session.js';
import { qaReadPolicy, qaReadQuery, projectQaBody } from './qa-read-policy.js';

// BH-9263: one GET from a QA session (functions/_lib/qa-read-policy.js). A
// route off the list is 403 and harness-jobs is never called. On the list, the
// forward carries only the allowed query parameters, and the answer is cut to
// the listed fields. The bearer is QA_READ_TOKEN when this Pages project has
// it (and it is not HARNESS_SECRET). Until then it is HARNESS_SECRET with a
// warn line, and the projection here keeps the fields as narrow. Log lines
// name the route, never the query string or a token.
const noStoreJson = (status, body) => new Response(JSON.stringify(body), {
  status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
});
async function qaAllowlistRead(rest, url, env, JOBS) {
  const row = qaReadPolicy(rest);
  if (!row) {
    console.log(`qa-read: refused GET ${rest}`);
    return noStoreJson(403, { error: 'not available to a QA session' });
  }
  const target = new URL(`/api/${rest}`, JOBS);
  target.search = qaReadQuery(row, url.searchParams).toString();
  const qaToken = String(env.QA_READ_TOKEN || '').trim();
  const useQa = Boolean(qaToken) && qaToken !== String(env.HARNESS_SECRET).trim();
  if (!useQa) console.warn(`qa-read: QA_READ_TOKEN unset; GET ${rest} under HARNESS_SECRET, projected here`);
  const send = (bearer) => fetch(target.toString(), { method: 'GET', headers: { authorization: `Bearer ${bearer}` } });
  let upstream;
  try {
    upstream = await send(useQa ? qaToken : env.HARNESS_SECRET);
    if (useQa && upstream.status === 401) {
      console.warn(`qa-read: QA_READ_TOKEN refused by harness-jobs; GET ${rest} retried under HARNESS_SECRET, projected here`);
      upstream = await send(env.HARNESS_SECRET);
    }
  } catch {
    return noStoreJson(502, { error: 'harness-jobs unreachable' });
  }
  let body = null;
  try { body = JSON.parse(await upstream.text()); } catch { body = null; }
  if (upstream.status !== 200) {
    const error = body && typeof body.error === 'string' ? body.error : `harness-jobs answered ${upstream.status}`;
    return noStoreJson(upstream.status, { error });
  }
  const out = projectQaBody(rest, body);
  if (!out) return noStoreJson(502, { error: 'unexpected body' });
  console.log(`qa-read: allowed GET ${rest}`);
  return noStoreJson(200, out);
}

// qaRead <request> <rest> <cookie> <url> <env> <jobs> — the Response for a QA
// session's GET (whoami excepted: the proxy answers it itself), or null.
export function qaRead(request, rest, cookie, url, env, jobs) {
  if (request.method !== 'GET' || rest === 'whoami' || !qaOnly(cookie)) return null;
  return qaAllowlistRead(rest, url, env, jobs);
}
