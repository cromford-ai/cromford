// BH-7261 owns this file.
// The weekly PM brief calls. They go through the coord proxy; the proxy
// stamps the actor on the decide. request() keeps src/api.js's error rules,
// so a lost session is an AuthError and a refusal carries err.status and err.body.
import { AuthError } from '../../api.js';

async function request(path, init) {
  let res;
  try {
    res = await fetch(path, { credentials: 'same-origin', ...init });
  } catch (e) {
    throw new Error('network unreachable');
  }
  let body = null;
  const text = await res.text();
  if (text) {
    try { body = JSON.parse(text); } catch { body = null; }
  }
  if ((res.status === 403 && !(body && body.error === 'owner_only'))
    || (res.status === 404 && body && body.error === 'unauthorized')) {
    throw new AuthError();
  }
  if (!res.ok) {
    const err = new Error(body && body.error ? body.error : `http_${res.status}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return body;
}

export const pmBrief = (project, week) =>
  request(`/api/coord/pm/briefs?${new URLSearchParams({ project, ...(week ? { week } : {}) })}`);

export const pmDecideMove = ({ project, move_id, decision }) =>
  request('/api/coord/pm/moves/decide', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ project, move_id, decision })
  });
