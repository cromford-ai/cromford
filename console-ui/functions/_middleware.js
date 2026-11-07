// Apply capability and browser-origin checks before any privileged API reader
// or writer, including readers backed directly by D1.
const QA_READS = new Set(['/api/coord/jobs', '/api/coord/flags']);
const SAFE = new Set(['GET', 'HEAD', 'OPTIONS']);
const refusal = (error) => new Response(JSON.stringify({ error }), {
  status: 403, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
});
export async function onRequest({ request, next }) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith('/api/')) return next();
  const cookie = request.headers.get('cookie') || '';
  if (/(?:^|;\s*)dashqa=/.test(cookie) &&
      (request.method !== 'GET' || !QA_READS.has(url.pathname))) {
    return refusal('this read is not available to a QA session');
  }
  if (!SAFE.has(request.method) && /(?:^|;\s*)dash=/.test(cookie) &&
      request.headers.get('origin') !== url.origin) {
    return refusal('cookie-authenticated writes require the same origin');
  }
  const response = await next();
  const headers = new Headers(response.headers);
  headers.set('cache-control', 'no-store');
  return new Response(response.body, {
    status: response.status, statusText: response.statusText, headers,
  });
}
