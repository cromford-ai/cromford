import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import {
  BOX_COMMAND_TYPES, COMMAND_LABELS, boxCommandFor, flyAppFor, requestBoxCommand,
  shapeBoxCommands, flyStopText, flyDestroyText
} from '../src/lib/box-commands.js';
import { FlyProject, FlyActions, BoxActions, BoxCommandsSection } from '../src/screens/Machines.js';
import { Modal } from '../src/ui/Modal.js';
import { PauseReasonForm } from '../src/ui/PauseForms.js';
import { flyProjectProps } from '../src/lib/fly.js';

// BH-2518.4 (BH-2662): the Machines screen can now ASK a box or a Fly machine
// to do something (backup, sync, CLI update, stop, destroy). STOP and DESTROY
// are irreversible for a running build, so the cases below hold the three
// things that must never slip: nothing is sent before CONFIRM with a real
// reason, nothing is guessed (app, project, machine), and a failed request is
// never shown as queued. The screen halves render the REAL components.

const noop = () => {};

test('C1: a blank reason is refused, never defaulted', () => {
  for (const reason of ['', '   ', '\t', undefined, null, 7]) {
    const r = boxCommandFor('backup_now', { box: 'hub-1', reason });
    assert.deepEqual(r, { error: 'reason required' }, `reason=${JSON.stringify(reason)}`);
    assert.equal('confirm' in r, false, 'a refusal is not a body');
  }
});

test('C2: the schema types (BH-5750: fourteen), each labelled; an unknown type is refused', () => {
  assert.deepEqual(BOX_COMMAND_TYPES, ['backup_now', 'harness_sync', 'cli_update', 'fly_machine_stop', 'fly_machine_destroy',
    'orgo_restart', 'orgo_stop', 'orgo_resize_quote', 'orgo_resize', 'orgo_retire', 'orgo_launch_quote', 'orgo_launch', 'fly_pool_cap', 'fly_onboard']);
  for (const t of BOX_COMMAND_TYPES) assert.equal(typeof COMMAND_LABELS[t], 'string', t);
  assert.match(boxCommandFor('rm_rf', { box: 'hub-1', reason: 'x' }).error, /unknown type rm_rf/);
});

test('C3: a Fly type names every missing field and never defaults one; the valid body is exact', () => {
  const ok = { project: 'p', app: 'p-pool', machineId: 'abc12345', reason: '  stray ' };
  assert.deepEqual(boxCommandFor('fly_machine_destroy', { ...ok, app: '' }), { error: 'app required' });
  assert.deepEqual(boxCommandFor('fly_machine_destroy', { ...ok, project: undefined }), { error: 'project required' });
  assert.deepEqual(boxCommandFor('fly_machine_destroy', { ...ok, machineId: '' }), { error: 'machineId required' });
  assert.deepEqual(boxCommandFor('fly_machine_stop', { ...ok, app: '  ' }), { error: 'app required' });
  assert.deepEqual(boxCommandFor('fly_machine_destroy', ok), {
    box: 'hub', type: 'fly_machine_destroy', target: 'abc12345', project: 'p', app: 'p-pool', reason: 'stray', confirm: true
  });
});

test('C4: a box body is exact; the Fly app comes from the row, else the single app, else nobody', () => {
  assert.deepEqual(boxCommandFor('backup_now', { box: 'hub-1', reason: ' nightly ' }), {
    box: 'hub-1', type: 'backup_now', target: '', project: '', app: '', reason: 'nightly', confirm: true
  });
  assert.deepEqual(boxCommandFor('harness_sync', { box: ' ', reason: 'x' }), { error: 'box required' });
  assert.equal(flyAppFor({ app: 'x' }, ['a', 'b']), 'x');
  assert.equal(flyAppFor({}, ['a']), 'a');
  assert.equal(flyAppFor({}, ['a', 'b']), null);
  assert.equal(flyAppFor({}, []), null);
  assert.equal(flyAppFor({ app: '' }, undefined), null);
});

test('C5: never POST before CONFIRM; a failure is never "queued"; nothing says done', async () => {
  const texts = [];
  const run = async (reason, answer, confirmed = true) => {
    const sent = [];
    const r = await requestBoxCommand('backup_now', { box: 'hub-1' }, {
      ask: async (form) => { form.reason = reason; return confirmed; },
      post: async (b) => { sent.push(b); if (answer instanceof Error) throw answer; return answer; }
    });
    if (r) texts.push(r.text);
    return { r, sent };
  };

  const cancelled = await run('x', { id: 1 }, false);
  assert.equal(cancelled.r, null);
  assert.equal(cancelled.sent.length, 0, 'cancel sends nothing');

  const blank = await run('  ', { id: 1 });
  assert.equal(blank.r.ok, false);
  assert.match(blank.r.text, /refused/);
  assert.equal(blank.sent.length, 0, 'a whitespace reason sends nothing');

  const fresh = await run('x', { id: 7, status: 'requested', deduped: false });
  assert.deepEqual(fresh.r, { ok: true, text: 'queued for hub-1' });
  assert.deepEqual(fresh.sent, [{ box: 'hub-1', type: 'backup_now', target: '', project: '', app: '', reason: 'x', confirm: true }]);

  const dup = await run('x', { id: 7, deduped: true });
  assert.deepEqual(dup.r, { ok: true, text: 'already queued (#7)' });

  const failed = await run('x', new Error('http 409'));
  assert.equal(failed.r.ok, false);
  assert.match(failed.r.text, /failed: http 409/);
  assert.doesNotMatch(failed.r.text, /queued/);

  for (const t of texts) assert.doesNotMatch(t, /done|ok\b|finished/i, t);
});

test('C6: the confirm dialog holds CONFIRM disabled until a reason is typed', () => {
  const confirmButton = (out) => {
    const m = out.match(/<button[^>]*>DESTROY<\/button>/);
    assert.ok(m, `no DESTROY button in ${out}`);
    return m[0];
  };
  const dialog = (reason, blocked) => render(h(Modal, {
    title: 'DESTROY', confirmLabel: 'DESTROY', tone: 'danger', confirmBlocked: blocked,
    body: ({ setBlocked }) => h(PauseReasonForm, { text: 'Destroy?', value: { reason }, onBlocked: setBlocked }),
    onConfirm: noop, onCancel: noop
  }));
  const blank = dialog('', true);
  assert.match(confirmButton(blank), /disabled/);
  assert.match(confirmButton(blank), /btn--danger/);
  assert.match(blank, /A reason is required/);
  const typed = dialog('x', false);
  assert.doesNotMatch(confirmButton(typed), /disabled/);
});

// The props come out of flyProjectProps on a whole /api/dash/machines payload,
// the call MachinesScreen makes (fly-render.test.js pattern).
const machine = (id, state, extra = {}) => ({ id, role: 'pool', state, region: 'iad', created_at: '2026-09-26T18:00:00Z', ...extra });
const flyProps = (machines, apps) => {
  const block = { machine_count: machines.length, machines, apps, orphan_jobs: [], jobs: [] };
  const all = flyProjectProps({ boxes: {}, fly: { 'cromford': block }, fly_errors: [], snapshot_age_min: 1 });
  return all.find((p) => p.project === 'cromford');
};
const rowOf = (out, id) => {
  const m = out.match(new RegExp(`<tr[^>]*>(?:(?!</tr>).)*${id}(?:(?!</tr>).)*</tr>`, 's'));
  assert.ok(m, `no row for ${id}`);
  return m[0];
};
const buttons = (row) => row.match(/<button[^>]*>[^<]*<\/button>/g) || [];
const btn = (row, label) => buttons(row).find((b) => b.endsWith(`>${label}</button>`));

test('C7: STOP only on a started machine; DESTROY on every row', () => {
  const out = render(h(FlyProject, { ...flyProps([machine('m1aaaa', 'started', { app: 'bh-pool' }), machine('m2bbbb', 'stopped', { app: 'bh-pool' })], ['bh-pool']), onAction: noop }));
  assert.match(out, />ACTIONS</);
  const m1 = rowOf(out, 'm1aaaa'); const m2 = rowOf(out, 'm2bbbb');
  assert.ok(btn(m1, 'STOP'), 'started m1 has STOP');
  assert.ok(btn(m1, 'DESTROY'), 'm1 has DESTROY');
  assert.equal(btn(m2, 'STOP'), undefined, 'stopped m2 has no STOP');
  assert.ok(btn(m2, 'DESTROY'), 'm2 has DESTROY');
  assert.doesNotMatch(btn(m1, 'STOP'), /disabled/);
});

test('C8: STOP on a building machine warns it kills the build; DESTROY is danger and irreversible', () => {
  const r = machine('m1aaaa', 'started', { app: 'bh-pool', job: { key: 'BH-77', ticket_id: 77 } });
  assert.match(flyStopText(r, 'bh-pool'), /kills/);
  assert.match(flyStopText(r, 'bh-pool'), /BH-77/);
  assert.doesNotMatch(flyStopText({ ...r, job: null }, 'bh-pool'), /kills/);
  assert.match(flyDestroyText(r, 'bh-pool'), /cannot be undone/);

  // The real button's click is what the screen wires; drive it through onAction.
  const calls = [];
  const onAction = (...a) => calls.push(a);
  const vnode = h(FlyProject, { ...flyProps([r], ['bh-pool']), onAction });
  const out = render(vnode);
  assert.match(btn(rowOf(out, 'm1aaaa'), 'DESTROY'), /btn--danger/);
  // preact-render-to-string runs no handlers, so call the real cell component
  // and press its buttons the way the DOM would.
  const cell = FlyActions({ project: 'cromford', apps: ['bh-pool'], r, onAction });
  const press = (label) => {
    const kids = [].concat(cell.props.children).flat(Infinity).filter((k) => k && k.props);
    const b = kids.find((k) => [].concat(k.props.children).join('') === label);
    assert.ok(b, `no ${label} vnode`);
    b.props.onClick();
  };
  press('DESTROY'); press('STOP');
  assert.deepEqual(calls.map((c) => [c[0], c[1], c[3]]), [
    ['fly_machine_destroy', { project: 'cromford', app: 'bh-pool', machineId: 'm1aaaa' }, 'danger'],
    ['fly_machine_stop', { project: 'cromford', app: 'bh-pool', machineId: 'm1aaaa' }, 'warn']
  ]);
  assert.match(calls[1][2], /kills/);
});

test('C9: an app that cannot be resolved disables the buttons; it is never guessed', () => {
  const two = render(h(FlyProject, { ...flyProps([machine('m1aaaa', 'started')], ['a', 'b']), onAction: noop }));
  const row = rowOf(two, 'm1aaaa');
  for (const label of ['STOP', 'DESTROY']) {
    assert.match(btn(row, label), /disabled/, label);
    assert.match(btn(row, label), /title="machine&#39;s app unknown"|title="machine's app unknown"/, label);
  }
  const one = render(h(FlyProject, { ...flyProps([machine('m1aaaa', 'started')], ['a']), onAction: noop }));
  for (const label of ['STOP', 'DESTROY']) assert.doesNotMatch(btn(rowOf(one, 'm1aaaa'), label), /disabled/, label);

  // No onAction (the fly-render.test.js path): renders, rows present, buttons inert.
  const bare = render(h(FlyProject, flyProps([machine('m1aaaa', 'started', { app: 'a' })], ['a'])));
  assert.match(btn(rowOf(bare, 'm1aaaa'), 'DESTROY'), /disabled/);
});

test('C10: every ORGO box gets BACKUP NOW, SYNC and CLI UPDATE, each asking for its own type', () => {
  const calls = [];
  const out = render(h(BoxActions, { box: 'hub-1', onAction: (...a) => calls.push(a) }));
  const labels = (out.match(/<button[^>]*>[^<]*<\/button>/g) || []).map((b) => b.replace(/<[^>]*>/g, ''));
  assert.deepEqual(labels, ['BACKUP NOW', 'SYNC', 'CLI UPDATE']);
  const vnode = BoxActions({ box: 'hub-1', onAction: (...a) => calls.push(a) });
  [].concat(vnode.props.children).flat(Infinity).filter((k) => k && k.props && k.props.onClick).forEach((k) => k.props.onClick());
  assert.deepEqual(calls.map((c) => [c[0], c[1]]), [
    ['backup_now', { box: 'hub-1' }], ['harness_sync', { box: 'hub-1' }], ['cli_update', { box: 'hub-1' }]
  ]);
  assert.match(calls[0][2], /hub-1/);
});

const now = Date.parse('2026-09-26T12:00:00Z');
const cmd = (id, extra = {}) => ({
  id, box: 'hub-1', type: 'backup_now', target: '', status: 'requested', reason: `r${id}`,
  requested_by: 'console', requested_at: new Date(now - id * 60000).toISOString(), detail: null, ...extra
});

test('C11: newest first, BOX links to its filter, nine headers with eight sortable', () => {
  const data = shapeBoxCommands({ commands: [cmd(3), cmd(1, { box: 'hub 1' }), cmd(2)], truncated: false, as_of: 't' }, now);
  const out = render(h(BoxCommandsSection, { state: { data, error: null, loading: false, reload: noop }, box: null }));
  const ids = [...out.matchAll(/<tr[^>]*>\s*<td[^>]*>\s*<span>(\d+)</g)].map((m) => Number(m[1]));
  assert.deepEqual(ids, [3, 2, 1]);
  assert.match(out, /href="\/machines\?box=hub%201"/);
  assert.match(out, /href="\/machines\?box=hub-1"/);
  const heads = [...out.matchAll(/<th[^>]*>([\s\S]*?)<\/th>/g)].map((m) => m[1]);
  const names = heads.map((x) => x.replace(/<[^>]*>/g, '').replace(/[↑↓]/g, '').trim());
  assert.deepEqual(names, ['ID', 'BOX', 'TYPE', 'TARGET', 'STATUS', 'REASON', 'BY', 'AGE', 'DETAIL']);
  assert.equal(heads.filter((x) => /<button/.test(x)).length, 8);
  assert.match(out, /BOX COMMANDS/);
});

test('C12: the history shaper measures age, ranks status, and refuses an unreadable payload', () => {
  const s = shapeBoxCommands({ commands: [{ id: 1, status: 'ok', requested_at: new Date(now - 5 * 60000).toISOString() }], truncated: true, as_of: 't' }, now);
  assert.equal(s.rows[0].ageMin, 5);
  assert.equal(s.rows[0].statusRank, 3);
  assert.equal(s.truncated, true);
  assert.equal(s.asOf, 't');
  assert.equal(shapeBoxCommands({ commands: [{ id: 2, requested_at: 'garbage' }] }, now).rows[0].ageMin, null);
  assert.equal(shapeBoxCommands({ commands: [{ id: 2 }] }, now).rows[0].ageMin, null);
  assert.throws(() => shapeBoxCommands({}), /unreadable/);
  assert.throws(() => shapeBoxCommands(null), /unreadable/);
  const rank = (status) => shapeBoxCommands({ commands: [{ id: 1, status }] }, now).rows[0].statusRank;
  assert.ok(rank('requested') < rank('claimed') && rank('claimed') < rank('fail') && rank('fail') < rank('ok'));
  assert.equal(rank('weird'), 4);
});

test('C13: a load failure is an error with RETRY, not empty; empty and truncated say so', () => {
  const err = render(h(BoxCommandsSection, { state: { data: null, error: new Error('http 404'), loading: false, reload: noop }, box: null }));
  assert.match(err, /http 404/);
  assert.match(err, />RETRY</);
  assert.doesNotMatch(err, /no box commands yet/);

  const empty = render(h(BoxCommandsSection, { state: { data: { rows: [], truncated: false, asOf: null }, error: null, loading: false, reload: noop }, box: null }));
  assert.match(empty, /no box commands yet/);
  assert.doesNotMatch(empty, /could not load/);

  const emptyOne = render(h(BoxCommandsSection, { state: { data: { rows: [], truncated: false, asOf: null }, error: null, loading: false, reload: noop }, box: 'hub-1' }));
  assert.match(emptyOne, /hub-1/);
  assert.match(emptyOne, /href="\/machines"/, 'a filtered view links back to all boxes');

  const data = shapeBoxCommands({ commands: [cmd(1)], truncated: true }, now);
  const trunc = render(h(BoxCommandsSection, { state: { data, error: null, loading: false, reload: noop }, box: null }));
  assert.match(trunc, /banner--warn/);
  assert.match(trunc, /showing the newest 1; older commands are not listed/);
});
