import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { CONTROL_KINDS, controlBody, controlHref, fieldLabel, fieldMeaning } from '../src/lib/controls.js';
import { configHref } from '../src/lib/config.js';
import { CONFIG_KIND_VALUES, isKnownKind } from '../src/lib/config-detail.js';
import { ControlsScreen, ControlsView, EditForm, saveControl } from '../src/screens/Controls.js';
import { Modal } from '../src/ui/Modal.js';

// BH-4082 (slice C0): the Projects form is a CONTROLS kind. The shared screen
// supplies the sortable table, the in-app modal and the audit-trail links;
// these cases pin that the projects kind reaches each of them with its own
// fields, and that a save goes out as one PUT to the projects route.

const noop = () => {};
const PROJECTS = CONTROL_KINDS.find((d) => d.kind === 'projects');
const loaded = (data) => ({ data, error: null, loading: false });
const view = (rows, extra = {}) =>
  render(h(ControlsView, { desc: PROJECTS, state: loaded({ projects: rows }), onReload: noop, onNew: noop, onEdit: noop, ...extra }));

const project_3 = {
  project: 'project-3', repo: 'example-org/project-3', prod_url: 'https://os.project-3.example', board_api_prefix: '/api/feature-board',
  cron_offset: 6, box: 'box-project-3-2', tailnet_ip: '10.0.0.3', note: null
};
const HARNESS = {
  project: 'cromford', repo: 'example-org/cromford', prod_url: null, board_api_prefix: null,
  cron_offset: 3, box: 'box-small', tailnet_ip: '10.0.0.7', note: null
};
const draft = (over = {}) => ({
  project: 'project-3', repo: 'example-org/project-3', prod_url: 'https://os.project-3.example', board_api_prefix: '/api/feature-board',
  cron_offset: '6', box: 'box-project-3-2', tailnet_ip: '10.0.0.3', note: '', ...over
});

test('R1 the projects kind: paths, list key, key and edit fields, audit name, explainer', () => {
  assert.ok(PROJECTS, 'CONTROL_KINDS has a projects kind');
  assert.equal(PROJECTS.title, 'Projects');
  assert.equal(PROJECTS.path, '/api/projects');
  assert.equal(PROJECTS.putPath, '/api/projects');
  assert.equal(PROJECTS.listKey, 'projects');
  assert.equal(PROJECTS.auditKind, 'project');
  assert.deepEqual(PROJECTS.keyFields, ['project']);
  assert.deepEqual(PROJECTS.editFields.map((f) => [f.name, f.type]), [
    ['repo', 'text'], ['prod_url', 'text'], ['board_api_prefix', 'text'], ['cron_offset', 'int'],
    ['box', 'text'], ['tailnet_ip', 'text'], ['note', 'text']
  ]);
  assert.equal(PROJECTS.auditName(project_3), 'project-3');
  assert.match(PROJECTS.explainer, /same columns as fleet\.conf/);
  assert.match(PROJECTS.explainer, /does not change fleet\.conf on the boxes yet/);
  assert.equal(controlHref(PROJECTS.kind), '/controls/projects');
  // Every field has a plain label and a one-sentence meaning (BH-3558.1).
  for (const name of ['project', ...PROJECTS.editFields.map((f) => f.name)]) {
    assert.doesNotMatch(fieldLabel(PROJECTS, name), /_/, `${name} label`);
    if (name !== 'note') assert.ok(fieldMeaning(PROJECTS, name).length > 0, `${name} meaning`);
  }
  // The row's history link resolves to a kind the /config page knows.
  assert.ok(CONFIG_KIND_VALUES.includes('project'));
  assert.ok(isKnownKind('project'));
});

test('R1b controlBody refuses a blank cron_offset and sends a numeric one', () => {
  assert.deepEqual(controlBody(PROJECTS, draft({ cron_offset: '' }), 'why'), { error: 'cron_offset required' });
  assert.deepEqual(controlBody(PROJECTS, draft({ cron_offset: '3.5' }), 'why'), { error: 'cron_offset must be a whole number' });
  assert.deepEqual(controlBody(PROJECTS, draft(), 'why'), {
    body: {
      project: 'project-3', repo: 'example-org/project-3', prod_url: 'https://os.project-3.example', board_api_prefix: '/api/feature-board',
      cron_offset: 6, box: 'box-project-3-2', tailnet_ip: '10.0.0.3', note: '', reason: 'why'
    }
  });
});

test('R2 two rows render both projects, their history links and NEW; zero rows render the empty state', () => {
  const out = view([project_3, HARNESS]);
  for (const r of [project_3, HARNESS]) {
    assert.ok(out.includes(`href="${configHref('project', r.project)}"`), `${r.project} links to its history`);
    assert.ok(out.includes(`>EDIT ${r.project}<`), `${r.project} has an EDIT`);
  }
  assert.match(out, />NEW</);
  assert.match(out, /href="\/controls\/projects"[^>]*aria-current="page"|aria-current="page"[^>]*href="\/controls\/projects"/);
  const empty = view([]);
  assert.match(empty, /no Projects rows on record yet/);
  assert.match(empty, />NEW</);
});

test('R2b the real /controls/projects route mounts the projects page, not NO SUCH SCREEN', () => {
  const out = render(h(ControlsScreen, { kind: 'projects' }));
  assert.doesNotMatch(out, /NO SUCH SCREEN/);
  assert.match(out, /Projects · every edit is recorded with its reason/);
});

test('R3 sortable headers per field, the wide scroll container, the in-app modal, no native dialog', () => {
  const out = view([project_3, HARNESS]);
  for (const name of ['project', ...PROJECTS.editFields.map((f) => f.name)]) {
    const label = fieldLabel(PROJECTS, name).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.match(out, new RegExp(`<th[^>]*aria-sort[^>]*><button[^>]*>\\s*${label}`), `no sortable header for ${name}`);
  }
  assert.match(out, /tablewrap--wide/);
  const modal = render(h(Modal, {
    title: 'NEW PROJECTS ROW', confirmLabel: 'SAVE', confirmBlocked: true, onConfirm: noop, onCancel: noop,
    body: () => h(EditForm, { desc: PROJECTS, value: { ...draft(), reason: '' }, isNew: true, lists: {}, serverError: null, pending: false })
  }));
  assert.match(modal, /role="dialog"/);
  assert.match(modal, /NEW PROJECTS ROW/);
  for (const name of ['project', 'repo', 'cron_offset', 'tailnet_ip']) assert.match(modal, new RegExp(`name="${name}"`));
  assert.match(modal, /name="cron_offset"[^>]*type="number"|type="number"[^>]*name="cron_offset"/);
  for (const html of [out, modal]) assert.doesNotMatch(html, /\b(confirm|alert|prompt)\(/);
});

test('R4 a save sends ONE PUT /api/coord/projects with the built body', async () => {
  const calls = [];
  const orig = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url, method: init.method, body: JSON.parse(init.body) });
    return new Response('{"project":{}}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  let done = false;
  try {
    await saveControl({
      desc: PROJECTS, draft: draft(), reason: 'adding project-3', put: api.controlsPut,
      setPending: noop, setServerError: noop, onDone: () => { done = true; }
    });
  } finally { globalThis.fetch = orig; }
  assert.equal(done, true);
  assert.deepEqual(calls.map((c) => [c.url, c.method]), [['/api/coord/projects', 'PUT']]);
  assert.equal(calls[0].body.cron_offset, 6);
  assert.equal(calls[0].body.reason, 'adding project-3');
});
