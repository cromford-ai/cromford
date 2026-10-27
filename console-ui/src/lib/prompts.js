// The prompts screens' data half (BH-7940.5; docs/PROMPTS.md): the list, read
// and save calls through the same-origin proxy functions/api/prompts/, the two
// read rounds of the editor, the line diff and the client marker lint.
// The server is the authority on markers; the lint here only shows them early.

import { AuthError } from '../api.js';
import { itemHref } from './settings-menu.js';

// The order of PROMPT_KINDS in worker/jobs/src/lib/prompt-store.js.
export const PROMPT_KINDS = Object.freeze(['rules', 'watcher', 'plan', 'execute', 'review', 'fix-round', 'qa']);

export const SOURCE_LABEL = Object.freeze({ repo: 'repo default', fleet: 'fleet override', project: 'project override' });

// The settings page of the list; the editor is the same page with ?kind=.
export const listHref = (scope, project) => itemHref(scope, 'prompts', project);
export const editorHref = (scope, project, kind) => `${listHref(scope, project)}?kind=${encodeURIComponent(kind)}`;

// The repo default a kind falls back to (docs/PROMPTS.md, "Resolution order").
export function repoPath(kind, project) {
  if (kind === 'rules') return 'rules/CLAUDE.md';
  if (kind === 'watcher') return `prompts/${project || '<project>'}.md`;
  return `prompts/stages/${kind}.md`;
}

// The one fetch helper of the prompts calls (lib/prompt-history.js uses it
// too): a 403 is the console AuthError, any other failure carries status and body.
export async function call(path, init) {
  let res;
  try {
    res = await fetch(path, { credentials: 'same-origin', ...init });
  } catch {
    throw new Error('network unreachable');
  }
  let body = null;
  const text = await res.text();
  if (text) {
    try { body = JSON.parse(text); } catch { body = null; }
  }
  // The proxy answers 403 when the sign-in probe fails.
  if (res.status === 403) throw new AuthError();
  if (!res.ok) {
    const err = new Error(body && body.error ? body.error : `http_${res.status}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return body;
}

const projectQuery = (project) => (project ? `?project=${encodeURIComponent(project)}` : '');

// Seven rows: a project's list has its own head, else the fleet head, else
// repo. With no project the list has the fleet head, else repo.
export async function listPrompts(project) {
  const body = await call(`/api/prompts${projectQuery(project)}`);
  if (!Array.isArray(body.prompts)) throw new Error('bad response');
  return body.prompts;
}

export async function readPrompt({ scope, kind, version, project }) {
  const q = scope === 'project' ? projectQuery(project) : '';
  return (await call(`/api/prompts/${scope}/${kind}/${version}${q}`)).prompt;
}

// -> {id, version}. The proxy sets the author; the client never sends one.
export function savePrompt({ scope, kind, project, body, note, baseVersion }) {
  const q = scope === 'project' ? projectQuery(project) : '';
  return call(`/api/prompts/${scope}/${kind}${q}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ body, note, base_version: baseVersion })
  });
}

// A version retention archived reads as a 404: say so, do not fail the editor.
const orArchived = (version, p) => p.catch((e) => {
  if (e && e.status === 404) return { version, archived: true };
  throw e;
});

// The editor's reads in two rounds. Round 1: the heads (this scope's list and,
// for a project, the fleet list) in parallel. Round 2 needs their version
// numbers: the head body, the version before it and the fleet body, in
// parallel. A read with nothing to read is skipped.
//
// -> {baseVersion, startText, head, previous, above}
//   previous: null (no head), {version: 0} (head is v1), {version, body} or
//             {version, archived: true}
//   above:    {level: 'fleet', version, body} or {level: 'repo', path}
export async function loadEditor({ scope, project, kind }) {
  const isProject = scope === 'project';
  const [ownList, fleetList] = await Promise.all([
    listPrompts(isProject ? project : ''),
    isProject ? listPrompts('') : null
  ]);
  const own = ownList.find((r) => r.kind === kind && r.source === scope) || null;
  const fleetRow = isProject ? fleetList.find((r) => r.kind === kind && r.source === 'fleet') || null : null;

  const [head, previous, fleetBody] = await Promise.all([
    own ? readPrompt({ scope, kind, version: own.version, project }) : null,
    own && own.version > 1
      ? orArchived(own.version - 1, readPrompt({ scope, kind, version: own.version - 1, project }))
      : null,
    fleetRow ? readPrompt({ scope: 'fleet', kind, version: fleetRow.version }) : null
  ]);

  const above = fleetRow
    ? { level: 'fleet', version: fleetRow.version, body: fleetBody.body }
    : { level: 'repo', path: repoPath(kind, isProject ? project : '') };
  let prev = null;
  if (own) prev = own.version > 1 ? { ...previous, version: own.version - 1 } : { version: 0 };
  return {
    baseVersion: own ? own.version : 0,
    // With no head here, a project override starts from the fleet text in effect.
    startText: head ? head.body : (fleetRow ? fleetBody.body : ''),
    head: head ? { version: own.version, body: head.body } : null,
    previous: prev,
    above
  };
}

// -> [{op: ' ' | '+' | '-', text}], old `a` to new `b`, line by line. A trailing
// \r is not part of a line, so CRLF and LF bodies compare equal. The common
// prefix and suffix are cut before the LCS, so a small edit to a long body
// costs only the changed middle.
export function lineDiff(a, b) {
  const lines = (s) => (s === '' || s === null || s === undefined ? [] : String(s).split('\n').map((l) => l.replace(/\r$/, '')));
  const x = lines(a);
  const y = lines(b);
  let pre = 0;
  while (pre < x.length && pre < y.length && x[pre] === y[pre]) pre++;
  let suf = 0;
  while (suf < x.length - pre && suf < y.length - pre && x[x.length - 1 - suf] === y[y.length - 1 - suf]) suf++;
  const xm = x.slice(pre, x.length - suf);
  const ym = y.slice(pre, y.length - suf);
  const n = xm.length;
  const m = ym.length;
  // lcs[i * (m + 1) + j] = LCS length of xm[i..] and ym[j..].
  const lcs = new Uint32Array((n + 1) * (m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i * (m + 1) + j] = xm[i] === ym[j]
        ? lcs[(i + 1) * (m + 1) + j + 1] + 1
        : Math.max(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1]);
    }
  }
  const out = x.slice(0, pre).map((text) => ({ op: ' ', text }));
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && xm[i] === ym[j]) { out.push({ op: ' ', text: xm[i] }); i++; j++; }
    else if (j >= m || (i < n && lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1])) { out.push({ op: '-', text: xm[i] }); i++; }
    else { out.push({ op: '+', text: ym[j] }); j++; }
  }
  for (const text of x.slice(x.length - suf)) out.push({ op: ' ', text });
  return out;
}

// The markers of `kind` in `catalog` (catalog/prompt-markers.json) that `body`
// does not hold: a case-sensitive substring check, the server's rule.
export function missingMarkers(kind, body, catalog) {
  const list = catalog && Array.isArray(catalog[kind]) ? catalog[kind] : [];
  const text = String(body || '');
  return list.filter((m) => !text.includes(m));
}
