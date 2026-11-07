// The console HTTP client and the redactor every outbound string goes through.

// The console's dash cookie per config object, held in process memory only (a
// restart just logs in again). `pending` is the in-flight login concurrent
// calls share, so two calls never race two logins.
const jar = new WeakMap();

// A fetch that threw: one redacted stderr line, then network_error.
function networkError(cfg, method, path, err) {
  const cause = err?.cause ? ` (${err.cause.message ?? err.cause})` : '';
  process.stderr.write(redact(`cromford-mcp: console ${method} ${path} failed: ${err?.message ?? err}${cause}`, cfg) + '\n');
  return { ok: false, status: 0, error: 'network_error' };
}

// GET /login/<secret> answers with Set-Cookie: dash=<value>. No dash value is a
// failed login, never a request sent without auth.
async function login(cfg) {
  const path = '/login/' + encodeURIComponent(cfg.secret);
  let res;
  try {
    res = await fetch(cfg.url + path, { redirect: 'manual' });
    await res.arrayBuffer();
  } catch (err) {
    return networkError(cfg, 'GET', path, err);
  }
  const dash = res.headers.getSetCookie().map((c) => /^dash=([^;]*)/.exec(c)).find(Boolean);
  if (!dash || dash[1] === '') return { ok: false, status: res.status, error: 'console_login_failed' };
  return { ok: true, cookie: dash[1] };
}

function session(cfg) {
  let s = jar.get(cfg);
  if (!s) jar.set(cfg, (s = { cookie: null, pending: null }));
  if (s.cookie) return { ok: true, cookie: s.cookie };
  s.pending ??= login(cfg).then((r) => {
    s.pending = null;
    if (r.ok) s.cookie = r.cookie;
    return r;
  });
  return s.pending;
}

// A refusal (a 4xx other than 401/404) carries the console's own `error`
// text, redacted and capped, so the MCP user can see why. A 403 is a refusal
// too (BH-5820: the board-command fallback answers {"error":"unauthorized"}).
// 401 stays bare: it drives the re-login. Every other failure is the bare code.
function httpError(cfg, status, text) {
  const code = 'http_' + status;
  if (status < 400 || status >= 500 || [401, 404].includes(status)) return code;
  let reason = null;
  try { reason = JSON.parse(text)?.error; } catch { return code; }
  if (typeof reason !== 'string' || !reason.trim()) return code;
  return code + ': ' + redact(reason, cfg).slice(0, 200);
}

async function send(cfg, method, path, body, auth) {
  const headers = { ...auth, accept: 'application/json' };
  if (auth.cookie && !['GET', 'HEAD', 'OPTIONS'].includes(method.toUpperCase())) {
    headers.origin = new URL(cfg.url).origin;
  }
  const init = { method, headers };
  if (body !== undefined) {
    headers['content-type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  let res, text;
  try {
    res = await fetch(cfg.url + path, init);
    text = await res.text();
  } catch (err) {
    return networkError(cfg, method, path, err);
  }
  const { status } = res;
  if (!res.ok) return { ok: false, status, error: httpError(cfg, status, text) };
  if (text === '') return { ok: true, status, data: null };
  try {
    return { ok: true, status, data: JSON.parse(text) };
  } catch {
    return { ok: false, status, error: 'bad_json' };
  }
}

// A token wins. A secret alone logs in for a dash cookie; a 401 on the cookie
// gets one fresh login and one retry, never more.
export async function consoleFetch(cfg, method, path, body) {
  if (cfg.token) return send(cfg, method, path, body, { authorization: `Bearer ${cfg.token}` });
  if (!cfg.secret) return { ok: false, status: 0, error: 'console_auth_not_configured' };
  let s = await session(cfg);
  if (!s.ok) return s;
  const r = await send(cfg, method, path, body, { cookie: 'dash=' + s.cookie });
  if (r.status !== 401) return r;
  const held = jar.get(cfg);
  if (held.cookie === s.cookie) held.cookie = null;
  s = await session(cfg);
  if (!s.ok) return s;
  return send(cfg, method, path, body, { cookie: 'dash=' + s.cookie });
}

// Exact-match replacement (split/join, never a regex) of the token, the secret
// (raw and URL-encoded) and the cached cookie, in raw form and in their
// JSON-escaped form. The login path goes first, so it reads /login/[redacted].
export function redact(text, cfg) {
  let out = String(text);
  const cookie = jar.get(cfg)?.cookie;
  const encoded = cfg.secret ? encodeURIComponent(cfg.secret) : null;
  for (const v of [cfg.secret, encoded]) {
    if (v) out = out.split('/login/' + v).join('/login/[redacted]');
  }
  for (const v of [cfg.token, cfg.secret, encoded, cookie]) {
    if (!v) continue;
    out = out.split(v).join('[redacted]');
    const escaped = JSON.stringify(v).slice(1, -1);
    if (escaped !== v) out = out.split(escaped).join('[redacted]');
  }
  return out;
}
