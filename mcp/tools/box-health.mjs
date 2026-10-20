// Box health tools (BH-7710): find a hung box and restart it. Both read ONE
// console route, GET /api/coord/box-health: per registry box, the hub's last
// ssh probe of it, the pool's recent ssh failures for its address, its newest
// lane heartbeat, the VM host's state for it, and the box-commands body that
// restarts it. A failed sub-read is named in the answer's `partial`; its
// fields stay null here, never false or 0.
//
// box_restart never calls the VM host. It queues that restart command through
// POST /api/coord/box-commands, the same audited path as the console's RESTART
// button: the hub runs it with the host key the hub holds, and the worker
// writes the audit row. No key is ever read or returned here.
import { consoleFetch, redact } from '../lib/console.mjs';
import { checkArgs } from './lib/schema.mjs';

const HEALTH = '/api/coord/box-health';
const COMMANDS = '/api/coord/box-commands';
// The ticket's "answered ssh in the last 5 minutes".
const ANSWERED_S = 300;
// A probe older than this says nothing about now: the probe lane runs every
// 2 minutes, so 10 minutes is 5 missed runs.
const STALE_S = 600;
const RESTART_TYPE_RE = /^[a-z][a-z0-9_]{0,40}_restart$/;

const obj = (properties, required) => ({
  type: 'object', properties, ...(required ? { required } : {}), additionalProperties: false,
});
const str = (maxLength) => ({ type: 'string', minLength: 1, maxLength });
const BOOL = { type: 'boolean' };

const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const fail = (t) => ({ content: [{ type: 'text', text: t }], isError: true });
const nullable = (v) => (v === undefined ? null : v);
const norm = (v) => String(v ?? '').trim().toLowerCase();

// The redacted text is the one source: structuredContent is parsed back from
// it, so neither half can carry what the other scrubbed.
function reply(ctx, value) {
  const text = redact(JSON.stringify(value), ctx.cfg);
  return { content: [{ type: 'text', text }], structuredContent: JSON.parse(text) };
}

// The one GET. → {ok, data} or {ok:false, error}. A body without a boxes list
// is a bad payload, never an empty fleet.
async function readHealth(ctx) {
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'GET', HEALTH);
  if (!r.ok) return { ok: false, error: r.status === 404 ? `console route not available: ${HEALTH}` : r.error };
  if (!isPlain(r.data) || !Array.isArray(r.data.boxes)) return { ok: false, error: `bad_payload: ${HEALTH}` };
  return { ok: true, data: r.data };
}

// Seconds from an ISO time to now, or null.
function ageS(iso, now) {
  const t = typeof iso === 'string' ? Date.parse(iso) : NaN;
  return Number.isFinite(t) ? Math.max(0, Math.round((now - t) / 1000)) : null;
}

// One box's facts and its state. `now` is the worker's as_of, so the ages do
// not depend on this machine's clock.
//   ok          a fresh probe answered (rc 0).
//   hung        a fresh probe failed, the last answer is older than 300 s or
//               never, and the VM host says the box is running.
//   unknown     no fresh probe row, or the VM state is unknown or ambiguous.
//   unreachable any other failed fresh probe (stopped VM, no VM, an answer
//               inside 300 s).
function shape(b, top, now) {
  const partial = Array.isArray(top.partial) ? top.partial : [];
  const sshRead = !partial.includes('ssh');
  const s = sshRead && isPlain(b.ssh) && Number.isInteger(b.ssh.rc) ? b.ssh : null;
  const probedAge = s ? ageS(s.probed_at, now) : null;
  const stale = s ? probedAge === null || probedAge > STALE_S : null;
  const okAge = s ? ageS(s.last_ok_at, now) : null;
  const ssh = {
    reachable: s ? s.rc === 0 && !stale : null,
    last_rc: s ? s.rc : null,
    probed_at: s ? nullable(s.probed_at) : null,
    last_ok_at: s ? nullable(s.last_ok_at) : null,
    last_ok_age_s: okAge,
    probe_stale: stale,
  };

  const vmRead = !partial.includes('vm') && isPlain(b.vm) && Array.isArray(b.vm.live);
  const live = vmRead ? b.vm.live.filter(isPlain) : [];
  const vm = { hosted: null, status: null, seen_at: null, account: null };
  if (vmRead && live.length === 1) {
    Object.assign(vm, { hosted: true, status: nullable(live[0].status), seen_at: nullable(live[0].seen_at), account: nullable(live[0].account) });
  } else if (vmRead && live.length > 1) {
    vm.ambiguous = live.length;
  } else if (vmRead && top.vm_complete === true) {
    vm.hosted = false;
  }

  const lf = isPlain(b.lane_ssh_failures) ? b.lane_ssh_failures : null;
  const lane_ssh_failures = sshRead && lf
    ? { count: nullable(lf.count), window_s: nullable(lf.window_s), last_at: nullable(lf.last_at) }
    : null;
  const beatRead = !partial.includes('heartbeat');
  const heartbeat = {
    last_beat_at: beatRead ? nullable(b.last_beat_at) : null,
    age_s: beatRead ? ageS(b.last_beat_at, now) : null,
  };

  let state;
  if (!s || stale) state = 'unknown';
  else if (s.rc === 0) state = 'ok';
  else if (vm.hosted === null) state = 'unknown';
  else if (vm.hosted && vm.status === 'running' && (okAge === null || okAge > ANSWERED_S)) state = 'hung';
  else state = 'unreachable';

  return {
    out: { box: nullable(b.box), box_id: nullable(b.box_id), role: nullable(b.role), state, ssh, heartbeat, vm, lane_ssh_failures },
    okAge,
  };
}

const nowOf = (data) => {
  const t = Date.parse(data.as_of);
  return Number.isFinite(t) ? t : Date.now();
};
const find = (data, box) => {
  const want = norm(box);
  return data.boxes.filter(isPlain).find((b) => norm(b.box) === want || norm(b.box_id) === want) ?? null;
};

async function boxHealth(a, ctx) {
  const r = await readHealth(ctx);
  if (!r.ok) return fail(r.error);
  const now = nowOf(r.data);
  let list = r.data.boxes.filter(isPlain);
  if (a.box !== undefined) {
    const one = find(r.data, a.box);
    if (!one) return fail('unknown_box');
    list = [one];
  }
  const boxes = list.map((b) => shape(b, r.data, now).out)
    .sort((x, y) => String(x.box).localeCompare(String(y.box)));
  const out = {
    boxes,
    hung: boxes.filter((b) => b.state === 'hung').map((b) => b.box),
    vm_complete: nullable(r.data.vm_complete),
    truncated: nullable(r.data.truncated),
    as_of: nullable(r.data.as_of),
  };
  const partial = Array.isArray(r.data.partial) ? r.data.partial.filter((p) => typeof p === 'string') : [];
  if (partial.length) out.partial = partial;
  return reply(ctx, out);
}

// The restart gate. Every refusal returns before the one POST, so a refusal
// sends nothing. force lifts only the ssh checks: a box the VM host does not
// hold, or whose state is unknown, is never restarted.
async function boxRestart(a, ctx) {
  const r = await readHealth(ctx);
  if (!r.ok) return fail(`registry_unavailable: ${r.error}`);
  const b = find(r.data, a.box);
  if (!b) return fail('unknown_box');
  if (b.box_id === 'hub') return fail('not_vm_hosted');
  const { out, okAge } = shape(b, r.data, nowOf(r.data));
  if (out.vm.ambiguous) return fail('vm_ambiguous');
  if (out.vm.hosted === null) return fail('vm_state_unknown');
  if (out.vm.hosted === false) return fail('not_vm_hosted');
  const cmd = b.restart;
  if (!isPlain(cmd)) return fail('not_vm_hosted');
  if (cmd.box !== 'hub' || cmd.target !== b.box_id || typeof cmd.type !== 'string' || !RESTART_TYPE_RE.test(cmd.type)) {
    return fail('bad_payload: restart');
  }
  const force = a.force === true;
  if (!force) {
    if (out.ssh.last_rc === null) return fail('ssh_state_unknown');
    if (out.ssh.probe_stale) return fail('ssh_state_stale');
    if (okAge !== null && okAge <= ANSWERED_S) return fail(`box_answered_ssh: ${okAge}s ago`);
  }
  const body = {
    box: cmd.box, type: cmd.type, target: cmd.target,
    reason: a.reason ?? `box_restart (mcp): ssh rc ${out.ssh.last_rc ?? 'unknown'}, last answer ${out.ssh.last_ok_at ?? 'never'}`,
    confirm: true,
  };
  if (typeof cmd.account === 'string' && cmd.account) body.account = cmd.account;
  const p = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'POST', COMMANDS, body);
  if (!p.ok) return fail(p.status === 404 ? `console route not available: ${COMMANDS}` : p.error);
  if (!isPlain(p.data) || p.data.id === undefined || p.data.id === null) return fail(`bad_payload: ${COMMANDS}`);
  return reply(ctx, {
    queued: true, id: p.data.id, status: nullable(p.data.status), deduped: nullable(p.data.deduped),
    box: out.box, box_id: out.box_id, forced: force,
  });
}

const restartSchema = obj({ box: str(64), confirm: BOOL, force: BOOL, reason: str(500) }, ['box', 'confirm']);
const restartCheck = checkArgs(restartSchema);
const healthSchema = obj({ box: str(64) });

export const tools = [
  {
    name: 'box_health',
    description: "Each box's health: does the hub reach it over ssh, its last heartbeat age, its VM host state, and the pool's recent ssh failures for it. `hung` lists boxes whose ssh fails while the VM host says running.",
    kind: 'read',
    inputSchema: healthSchema,
    precheck: checkArgs(healthSchema),
    handler: boxHealth,
  },
  {
    name: 'box_restart',
    description: "Queue a restart of a VM-hosted box on the hub's box-ops lane (it writes an audit row). Needs confirm: true. Refuses a box the VM host does not hold, and a box that answered ssh in the last 5 minutes unless force: true.",
    kind: 'guarded',
    inputSchema: restartSchema,
    precheck: (args) => {
      if (args.confirm !== true) return 'confirm_required';
      return restartCheck(args);
    },
    handler: boxRestart,
  },
];
