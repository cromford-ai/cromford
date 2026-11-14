// Cloudflare Pages root middleware (BH-9263). It runs in front of every
// Function and acts only on /api/*. Three rules, in this order:
//
// 1. SAME ORIGIN FOR A COOKIE WRITE. A method other than GET, HEAD or OPTIONS
//    that carries a `dash` or `dashqa` cookie is refused 403 when its Origin
//    is not this origin (`null` included), or, with no Origin, when
//    Sec-Fetch-Site is present and is not `same-origin`. A request with
//    neither header (a non-browser client) passes: a browser sends one of them
//    on every cross-site write, so a forged write cannot strip both. A bearer
//    call with no cookie is not checked.
//
// 2. ONE SESSION COOKIE. A request with both `dash` and `dashqa` is resolved
//    here, so every Function behind this sees one of them and the
//    qa-session.js rules (qaOnly, readOnlyRefusal) give the right answer
//    unchanged. The console worker is asked about the `dash` cookie ALONE, on
//    the same probe the coord proxy uses. 200: the operator wins and `dashqa`
//    is removed from the request (an operator browser with a stale QA cookie
//    keeps full access). Any other answer, or a throw: `dash` is removed (a
//    forged `dash=x` beside the HttpOnly `dashqa` stays a QA session). The
//    probe runs only on a two-cookie request, and nothing is cached. The
//    response sets no cookie: the worker owns the `dashqa` attributes.
//
// 3. NO-STORE. Every /api/* response leaves with Cache-Control: no-store,
//    over any value the Function set.

const CONSOLE = 'https://harness-console.operator.workers.dev';
const AUTH_PROBE = '/api/dash/fleet';
const SAFE = new Set(['GET', 'HEAD', 'OPTIONS']);

const parts = (header) => String(header || '').split(';').map((p) => p.trim()).filter(Boolean);
const nameOf = (part) => part.split('=')[0].trim();

function withNoStore(res) {
  const out = new Response(res.body, res);
  out.headers.set('cache-control', 'no-store');
  return out;
}

function crossOrigin(request, url) {
  const origin = request.headers.get('origin');
  if (origin !== null) return origin !== url.origin;
  const site = request.headers.get('sec-fetch-site');
  return site !== null && site !== 'same-origin';
}

async function dashIsValid(dashParts) {
  try {
    const res = await fetch(CONSOLE + AUTH_PROBE, { headers: { cookie: dashParts.join('; ') }, redirect: 'manual' });
    return res.status === 200;
  } catch {
    // The console being unreachable is NOT a grant: the request stays QA.
    return false;
  }
}

export async function onRequest(context) {
  const { request, next } = context;
  const url = new URL(request.url);
  if (url.pathname !== '/api' && !url.pathname.startsWith('/api/')) return next();

  const cookies = parts(request.headers.get('cookie'));
  const dash = cookies.filter((p) => nameOf(p) === 'dash');
  const qa = cookies.filter((p) => nameOf(p) === 'dashqa');

  if (!SAFE.has(String(request.method).toUpperCase()) && (dash.length || qa.length) && crossOrigin(request, url)) {
    return new Response(JSON.stringify({ error: 'a cookie-authenticated write must be same-origin' }), {
      status: 403, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
    });
  }

  let forwarded = request;
  if (dash.length && qa.length) {
    const drop = (await dashIsValid(dash)) ? 'dashqa' : 'dash';
    const keep = cookies.filter((p) => nameOf(p) !== drop);
    const headers = new Headers(request.headers);
    headers.set('cookie', keep.join('; ')); // never empty: one of dash or dashqa stays
    forwarded = new Request(request, { headers });
  }

  return withNoStore(await next(forwarded));
}
