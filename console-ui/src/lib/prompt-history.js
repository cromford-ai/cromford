// The prompt history calls (BH-7972, BH-7940.4; docs/PROMPTS.md, "Markers,
// versions and restore"): the version list, a restore and a dropped head,
// through the same-origin proxy functions/api/prompts/ and the shared call()
// of lib/prompts.js. The proxy adds the bearer and the author.

import { call } from './prompts.js';

const keyPath = (scope, kind, action, extra = {}) => {
  const q = new URLSearchParams();
  if (scope === 'project') q.set('project', extra.project || '');
  if (extra.version !== undefined) q.set('version', String(extra.version));
  const s = q.toString();
  return `/api/prompts/${scope}/${kind}/${action}${s ? `?${s}` : ''}`;
};

// -> [{id, version, author, note, created_at}], newest first.
export async function listVersions({ scope, project, kind }) {
  const body = await call(keyPath(scope, kind, 'versions', { project }));
  if (!Array.isArray(body.versions)) throw new Error('bad response');
  return body.versions;
}

// -> {id, version, restored_from}: version n saved again as the next version.
export function restoreVersion({ scope, project, kind, version }) {
  return call(keyPath(scope, kind, 'restore', { project, version }), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{}'
  });
}

// -> {dropped: 0 | 1}. The versions stay; the level above is in use.
export function dropHead({ scope, project, kind }) {
  return call(keyPath(scope, kind, 'head', { project }), { method: 'DELETE' });
}
