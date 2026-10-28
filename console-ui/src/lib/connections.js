// Tracker connections (BH-7924): which tracker each project reads, whether its
// credentials are on the box, the last probe and the webhook route. The data
// is GET /api/connections (worker/jobs/src/routes/connections.js); the EDIT
// form PUTs the tracker rows back. API keys are never stored here: a key stays
// in env/<project>.env on the box, and the form refuses a token-shaped value
// with the name of the env var to set instead.
//
// Pure helpers, so the rows, the form rules and the token refusal are tested
// without a browser; src/screens/Connections.js renders them.

export const ADAPTERS = ['linear', 'jira', 'board', 'github-issues'];
export const PROBE_QUEUED = 'probe queued; the row updates when the box answers';

// The LAST PROBE stale bound (BH-8674): a probe older than this many minutes
// shows its age in amber. The lane probes hourly, so 120 is one missed run.
export const PROBE_STALE_KEY = 'connections.probe_stale_min';
export const PROBE_STALE_MIN = 120; // fallback of settings row connections.probe_stale_min

// probeStaleMin(answer) -> minutes. `answer` is the GET
// /api/coord/settings/<key> shape {key, setting: row|null, source}.
// TYPE-CHECKED, NOT COERCED: Number('') and Number(null) are 0, so only a
// finite number >= 1 (a number, or a non-blank numeric string) is the knob;
// anything else, a failed read included, is the fallback.
export function probeStaleMin(answer) {
  const s = answer && typeof answer === 'object' ? answer.setting : null;
  const v = s && typeof s === 'object' ? s.value : undefined;
  let n = NaN;
  if (typeof v === 'number') n = v;
  else if (typeof v === 'string' && v.trim() !== '') n = Number(v);
  return Number.isFinite(n) && n >= 1 ? n : PROBE_STALE_MIN;
}

// The worker's rules (plan T3), mirrored so the operator sees a refusal
// before anything is sent. The worker checks them again.
const TEAM_RE = /^[A-Z][A-Z0-9_]{0,9}$/;          // bin/lib/tracker/linear.sh
const JIRA_KEY_RE = /^[A-Z][A-Z0-9_]{1,9}$/;
const LABEL_RE = /^[A-Za-z0-9_.:-]{1,100}$/;
const SMAP_ENTRY_RE = /^[a-z0-9_-]+=[^=]+$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const CONTROL_RE = /[\u0000-\u001f\u007f]/;

// Body keys that name a secret: the form never sends one, and a draft that
// carries one is refused.
// The same list as the worker's SECRET_KEYS (compared lowercased).
const TOKEN_KEYS = new Set(['api_key', 'apikey', 'token', 'api_token', 'access_token', 'refresh_token',
  'secret', 'client_secret', 'password', 'private_key', 'webhook_secret', 'linear_api_key',
  'jira_api_token', 'linear_webhook_secret', 'jira_webhook_secret', 'github_token', 'gh_token']);
// Token shapes, the worker's rule: the ProjectAccounts `sk-` (any case, so
// `SK-1` is refused) plus the Linear, Atlassian and GitHub key formats, each
// tested at the start of a word. `SK`, `SKY`, `ai-build`, `task-1` pass.
const TOKEN_RES = [/^sk-/i, /^lin_api_/, /^lin_oauth_/, /^ATATT/, /^ghp_/, /^gho_/, /^ghs_/, /^github_pat_/];

export function isTokenShaped(v) {
  if (typeof v !== 'string') return false;
  return v.split(/[^A-Za-z0-9_-]+/).some((w) => w && TOKEN_RES.some((re) => re.test(w)));
}

// The env var a key for this adapter belongs in. A board's token var name is
// project-specific (<PREFIX>_INTERNAL_API_TOKEN); the probe reports it.
export function envVarFor(adapter, credentialVars) {
  if (adapter === 'linear') return 'LINEAR_API_KEY';
  if (adapter === 'jira') return 'JIRA_API_TOKEN';
  if (adapter === 'github-issues') return 'GH_TOKEN';
  if (adapter !== 'board') return null;
  const names = Object.keys(credentialVars || {});
  return names.find((n) => /_INTERNAL_API_TOKEN$/.test(n)) || 'INTERNAL_API_TOKEN';
}

const tokenRefusal = (envVar, project) =>
  `API keys are not stored here. Set ${envVar || 'the tracker API key'} in env/${project || '<project>'}.env on the box that runs ${project || '<project>'}.`;

// The fields each adapter's form shows and sends. webhook_route only where a
// vendor webhook exists.
const FIELDS = {
  linear: ['team', 'label', 'states', 'webhook_route'],
  jira: ['write_projects', 'read_projects', 'comment_projects', 'label', 'status_map', 'webhook_route'],
  board: [],
  'github-issues': [],
  '': []
};
export const fieldsFor = (adapter) => FIELDS[adapter] || [];

const str = (v) => (v === null || v === undefined ? '' : String(v));

function fieldError(k, v) {
  if (v === '') return null;
  if (k === 'team') return TEAM_RE.test(v) ? null : 'a Linear team key is A-Z then A-Z or 0-9, at most 10 (CRO)';
  if (k === 'write_projects' || k === 'read_projects' || k === 'comment_projects') {
    return v.split(/\s+/).every((x) => JIRA_KEY_RE.test(x)) ? null : 'Jira project keys, space-separated (SCRUM OPS)';
  }
  if (k === 'label') return LABEL_RE.test(v) ? null : 'a label is letters, digits and _ . : - (at most 100)';
  if (k === 'status_map') {
    return v.split(';').every((e) => SMAP_ENTRY_RE.test(e)) ? null : 'alias=Status;alias=Status (review=In Review;done=Done)';
  }
  if (k === 'states') {
    try {
      const o = JSON.parse(v);
      return o && typeof o === 'object' && !Array.isArray(o) ? null : 'states is a JSON object';
    } catch { return 'states is a JSON object'; }
  }
  if (k === 'webhook_route') return REPO_RE.test(v) ? null : 'owner/repo';
  return null;
}

// checkConnectionForm(draft, credentialVars?) ->
//   { ok: true, body } | { ok: false, errors: {field: msg}, message, env_var? }.
// A token-shaped value wins over every other error: its message names the env
// var, and nothing in the answer repeats the value.
export function checkConnectionForm(draft, credentialVars) {
  const d = draft || {};
  const project = str(d.project).trim();
  const adapter = str(d.adapter).trim();
  const errors = {};
  const tokenKey = Object.keys(d).find((k) => TOKEN_KEYS.has(k.toLowerCase()));
  const tokenField = tokenKey || Object.keys(d).find((k) => isTokenShaped(d[k]));
  if (tokenField) {
    // A key named like an env var (LINEAR_API_KEY) names itself, as the worker does.
    const envVar = tokenKey && /^[A-Z][A-Z0-9_]*$/.test(tokenKey) ? tokenKey : envVarFor(adapter, credentialVars);
    const message = tokenRefusal(envVar, project);
    errors[tokenField] = message;
    return { ok: false, errors, message, env_var: envVar };
  }
  for (const k of Object.keys(d)) {
    if (typeof d[k] === 'string' && CONTROL_RE.test(d[k])) errors[k] = 'no control characters';
  }
  if (!project) errors.project = 'project required';
  if (adapter && !ADAPTERS.includes(adapter)) errors.adapter = `adapter is one of ${ADAPTERS.join(', ')}`;
  const body = { project, adapter };
  for (const k of fieldsFor(adapter)) {
    const v = str(d[k]).trim();
    if (!errors[k]) {
      const e = fieldError(k, v);
      if (e) errors[k] = e;
    }
    body[k] = v;
  }
  const reason = str(d.reason).trim();
  if (!reason && !errors.reason) errors.reason = 'a reason is required: it is recorded with the change';
  body.reason = reason;
  const keys = Object.keys(errors);
  if (keys.length) return { ok: false, errors, message: errors[keys[0]] };
  return { ok: true, body };
}

// The CREDENTIAL cell: the missing var names, else how many are present.
// null when the project was never probed (the cell says "not probed").
export function credentialSummary(row) {
  if (!row || !row.status) return null;
  if (row.missingVars.length) return `missing ${row.missingVars.join(' ')}`;
  return row.presentCount ? `${row.presentCount} present` : 'none needed';
}

// connectionRows(apiData) -> one row per project, in the worker's order, with
// the fields the table shows. A row without a project is dropped.
export function connectionRows(data) {
  const list = data && Array.isArray(data.connections) ? data.connections : [];
  const secrets = (data && data.webhookSecrets) || {};
  return list.filter((c) => c && typeof c.project === 'string' && c.project).map((c) => {
    const s = c.status && typeof c.status === 'object' ? c.status : null;
    const vars = s && s.credentialVars && typeof s.credentialVars === 'object' ? s.credentialVars : {};
    const names = Object.keys(vars);
    const adapter = typeof c.adapter === 'string' ? c.adapter : null;
    // The webhook secret: the probe row's word, else the worker's flag. Only
    // linear and jira have vendor webhooks.
    let webhookSecret = null;
    if (adapter === 'linear' || adapter === 'jira') {
      if (s && (s.webhookSecret === 'present' || s.webhookSecret === 'missing')) webhookSecret = s.webhookSecret;
      else if (typeof secrets[adapter] === 'boolean') webhookSecret = secrets[adapter] ? 'present' : 'missing';
    }
    return {
      project: c.project,
      href: `/p/${encodeURIComponent(c.project)}`,
      adapter,
      adapterSource: c.adapterSource || null,
      adapterError: c.adapterError || null,
      status: s,
      ok: s ? s.ok === true : null,
      checkedAt: s && typeof s.checkedAt === 'string' ? s.checkedAt : null,
      error: s && s.ok !== true && s.error ? String(s.error) : null,
      credentialVars: vars,
      missingVars: names.filter((n) => vars[n] === 'missing'),
      presentCount: names.filter((n) => vars[n] === 'present').length,
      webhookSecret,
      route: c.webhookRoute && typeof c.webhookRoute.repo === 'string' ? c.webhookRoute.repo : null,
      team: c.team || '',
      label: c.label || '',
      states: c.states === null || c.states === undefined ? ''
        : typeof c.states === 'string' ? c.states : JSON.stringify(c.states),
      jira: c.jira && typeof c.jira === 'object' ? c.jira : {}
    };
  });
}

// The EDIT form's starting draft for a row.
export function draftFor(row) {
  const j = row.jira || {};
  return {
    project: row.project,
    adapter: row.adapter && ADAPTERS.includes(row.adapter) ? row.adapter : '',
    team: row.team || '',
    label: row.label || '',
    states: row.states || '',
    write_projects: j.write_projects || '',
    read_projects: j.read_projects || '',
    comment_projects: j.comment_projects || '',
    status_map: j.status_map || '',
    webhook_route: row.route || '',
    reason: ''
  };
}

// The PROBE NOW command for a project (the Pages fallback admits only this).
export const probeCommand = (project) =>
  ({ type: 'run_script', project, script: 'connection-probe.sh', args: [project] });

// What the PROBE NOW answer may claim: queued only on a command_id or ok.
export function probeNote(project, answer, err) {
  if (err) return { ok: false, text: `${project}: probe refused — ${err.message || err}` };
  if (answer && (answer.command_id !== undefined && answer.command_id !== null || answer.ok === true)) {
    return { ok: true, text: `${project}: ${PROBE_QUEUED}` };
  }
  return { ok: false, text: `${project}: the probe was not confirmed; the console answered with no command id` };
}
