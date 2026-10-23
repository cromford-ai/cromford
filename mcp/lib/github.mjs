// The MCP's one GitHub REST seam (BH-7714). No other file under mcp/ sends a
// GitHub request. GET only. The token is HARNESS_MCP_GITHUB_TOKEN, set on the
// MCP client; without it every call answers github_auth_not_configured and
// sends nothing. HARNESS_MCP_GITHUB_URL changes the API origin (GitHub
// Enterprise, or a loopback stub in tests). A failure is an error code only:
// never a message, a header or a URL, so no reply or log can carry the token
// or a signed redirect URL.
const DEFAULT_URL = 'https://api.github.com';
// A raw text read (a job log) keeps at most its last rawCap bytes: the end
// of a log is where the failure is. Knob HARNESS_MCP_GITHUB_RAW_CAP (bytes);
// RAW_CAP is its documented fallback (BH-7945).
export const RAW_CAP = 8 * 1024 * 1024;

const optional = (v) => {
  const s = (v ?? '').trim();
  return s === '' ? null : s;
};

// A positive integer knob from the environment; unset, empty or not a
// positive integer is the fallback.
export function intKnob(env, name, fallback) {
  const s = optional(env?.[name]);
  return s !== null && /^\d+$/.test(s) && Number(s) > 0 ? Number(s) : fallback;
}

// → {url, token, rawCap}. An unparseable or non-http(s) URL is url: null,
// which every call answers as github_url_invalid.
export function githubConfig(env) {
  const token = optional(env.HARNESS_MCP_GITHUB_TOKEN);
  const rawCap = intKnob(env, 'HARNESS_MCP_GITHUB_RAW_CAP', RAW_CAP);
  const raw = optional(env.HARNESS_MCP_GITHUB_URL);
  if (!raw) return { url: DEFAULT_URL, token, rawCap };
  let u;
  try { u = new URL(raw); } catch { return { url: null, token, rawCap }; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return { url: null, token, rawCap };
  return { url: raw.replace(/\/+$/, ''), token, rawCap };
}

const REDIRECTS = new Set([301, 302, 303, 307, 308]);

function failure(res) {
  const { status } = res;
  const limited = (status === 403 || status === 429) &&
    (res.headers.get('x-ratelimit-remaining') === '0' || res.headers.get('retry-after') !== null);
  return { ok: false, status, error: limited ? 'github_rate_limited' : `github_http_${status}` };
}

// Streams the body and holds at most `cap` bytes plus one chunk: an older
// chunk is dropped as soon as the newer ones alone fill the cap.
async function body(res, raw, cap = RAW_CAP) {
  const chunks = [];
  let held = 0;
  let total = 0;
  if (res.body) {
    for await (const chunk of res.body) {
      chunks.push(chunk);
      held += chunk.byteLength;
      total += chunk.byteLength;
      while (chunks.length > 1 && held - chunks[0].byteLength >= cap) held -= chunks.shift().byteLength;
    }
  }
  const buf = new Uint8Array(held);
  let at = 0;
  for (const c of chunks) { buf.set(c, at); at += c.byteLength; }
  const truncated = total > cap;
  return { text: new TextDecoder().decode(truncated ? buf.subarray(held - cap) : buf), truncated: raw && truncated };
}

// Only a job log redirects to a signed blob URL that must not get the token.
const JOB_LOG = /^\/repos\/[^/]+\/[^/]+\/actions\/jobs\/\d+\/logs$/;

// One GET of `path` (it starts with /). → {ok, status, data, next} for JSON,
// {ok, status, text, truncated} with `raw`, or {ok:false, status, error}.
// `next` is true when the Link header names a next page. A job-log redirect
// (302 to a signed blob URL) is followed once WITHOUT the token. Any other
// redirect (301 for a renamed repo) is followed once WITH the token, and only
// to the same origin; a cross-origin one answers github_http_<status>.
export async function githubFetch(gh, path, { accept = 'application/vnd.github+json', raw = false } = {}) {
  if (!gh?.token) return { ok: false, status: 0, error: 'github_auth_not_configured' };
  if (!gh.url) return { ok: false, status: 0, error: 'github_url_invalid' };
  let res;
  try {
    res = await fetch(gh.url + path, {
      headers: { authorization: `Bearer ${gh.token}`, accept, 'x-github-api-version': '2022-11-28' },
      redirect: 'manual',
    });
    const location = res.headers.get('location');
    if (REDIRECTS.has(res.status) && location) {
      const to = new URL(location, gh.url + path);
      if (JOB_LOG.test(path)) {
        await res.arrayBuffer();
        res = await fetch(to, { headers: { accept }, redirect: 'follow' });
      } else if (to.origin === new URL(gh.url).origin) {
        await res.arrayBuffer();
        res = await fetch(to, {
          headers: { authorization: `Bearer ${gh.token}`, accept, 'x-github-api-version': '2022-11-28' },
          redirect: 'manual',
        });
      }
    }
    if (!res.ok) {
      await res.arrayBuffer();
      return failure(res);
    }
    const { text, truncated } = await body(res, raw, gh.rawCap ?? RAW_CAP);
    if (raw) return { ok: true, status: res.status, text, truncated };
    const next = /<[^>]*>\s*;\s*rel="next"/.test(res.headers.get('link') ?? '');
    try {
      return { ok: true, status: res.status, data: JSON.parse(text), next };
    } catch {
      return { ok: false, status: res.status, error: 'bad_json' };
    }
  } catch {
    return { ok: false, status: 0, error: 'github_network_error' };
  }
}

// Exact-match replacement (split/join, never a regex) of the token, raw and
// JSON-escaped.
export function scrubToken(text, gh) {
  let out = String(text);
  const v = gh?.token;
  if (!v) return out;
  out = out.split(v).join('[redacted]');
  const escaped = JSON.stringify(v).slice(1, -1);
  if (escaped !== v) out = out.split(escaped).join('[redacted]');
  return out;
}
