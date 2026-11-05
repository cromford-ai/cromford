// Cloudflare Pages Function: /qa-login/<token> (cromford #5909).
//
// The read-only QA session for browser QA of a console PREVIEW. The hub mints
// <token> from the console worker (POST /api/qa/session, Bearer
// HARNESS_SECRET); the worker answers /qa-login/<token> with a 302 and the
// `dashqa` cookie. Like /login/, this forwards the request and keeps the
// Set-Cookie, so the cookie lands on THIS origin, and rewrites the Location to
// "/". The worker refuses every write for a `dashqa` session.
//
// PREVIEWS ONLY. A QA session is for a branch-alias preview
// (<alias>.console.example.pages.dev). Refused here, before the worker is
// asked, so the session can never be set on a production-bound origin:
//   - the production host and any other host;
//   - <8 hex>.console.example.pages.dev, the URL Pages gives every single
//     deployment, production ones included (bin/lib/console-preview.sh never
//     makes an alias of that shape);
//   - main.<project>, the production branch's alias, by its host alone:
//     CF_PAGES_BRANCH is a build-time variable that a direct-upload deploy does
//     not pass to Functions at runtime, so the host check is the guard that
//     holds in production;
//   - a deployment whose CF_PAGES_BRANCH, when set, is main or is not the
//     host's alias.

const WORKER = 'https://harness-console.operator.workers.dev';
const DEPLOYMENT_HASH = /^[0-9a-f]{8}$/;

function isPreviewAlias(host, env) {
  // Configure the Pages project domain at deployment time. Never derive it
  // from a caller's Host header: that would admit arbitrary QA origins.
  const domain = String(env?.QA_PREVIEW_DOMAIN || 'console.example.pages.dev').toLowerCase();
  if (!domain.endsWith('.pages.dev') || !domain.split('.').every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return false;
  const suffix = `.${domain}`;
  if (!host.endsWith(suffix)) return false;
  const alias = host.slice(0, -suffix.length);
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(alias) || DEPLOYMENT_HASH.test(alias) || alias === 'main') return false;
  const branch = String((env && env.CF_PAGES_BRANCH) || '').toLowerCase();
  if (branch === 'main') return false;
  return !branch || branch === alias;
}

export async function onRequest(context) {
  const { request, params, env } = context;
  const host = new URL(request.url).host.toLowerCase();
  if (!isPreviewAlias(host, env)) {
    return new Response('the QA session is for console previews only', { status: 403 });
  }
  const token = Array.isArray(params.token) ? params.token[0] : params.token;

  let upstream;
  try {
    upstream = await fetch(`${WORKER}/qa-login/${encodeURIComponent(token || '')}`, {
      method: 'GET',
      redirect: 'manual'
    });
  } catch (e) {
    return new Response('console worker unreachable', { status: 502 });
  }

  const out = new Headers(upstream.headers);
  out.delete('content-encoding');
  out.delete('content-length');
  if (upstream.status >= 300 && upstream.status < 400) {
    out.set('location', '/');
    return new Response(null, { status: 302, headers: out });
  }
  out.delete('set-cookie');
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers: out });
}
