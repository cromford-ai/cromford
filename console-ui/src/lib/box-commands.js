// BH-2518.4: the console's half of a box/machine op. The console only ever
// REQUESTS a command (POST /api/coord/box-commands); the box's own box-ops lane
// runs it later. So nothing here may say an op is done, and nothing may be
// guessed: a blank reason, an unknown type or a Fly target we cannot name is
// refused, never filled in.

// BH-5750: the worker's list is worker/jobs/src/lib/box-command-types.js; the
// Pages build cannot import it, so worker/jobs/test/box-command-types-drift
// .bh-5750.test.js holds the two lists and the schema CHECK equal.
export const ORGO_TYPES = ['orgo_restart', 'orgo_stop', 'orgo_resize_quote', 'orgo_resize', 'orgo_retire', 'orgo_launch_quote', 'orgo_launch'];
export const FLY_POOL_TYPES = ['fly_pool_cap', 'fly_onboard'];
export const BOX_COMMAND_TYPES = ['backup_now', 'harness_sync', 'cli_update', 'fly_machine_stop', 'fly_machine_destroy', ...ORGO_TYPES, ...FLY_POOL_TYPES];
export const FLY_TYPES = ['fly_machine_stop', 'fly_machine_destroy'];

export const COMMAND_LABELS = {
  backup_now: 'BACKUP NOW',
  harness_sync: 'SYNC',
  cli_update: 'CLI UPDATE',
  fly_machine_stop: 'STOP',
  fly_machine_destroy: 'DESTROY',
  orgo_restart: 'RESTART',
  orgo_stop: 'STOP BOX',
  orgo_resize_quote: 'RESIZE PRICE',
  orgo_resize: 'RESIZE',
  orgo_retire: 'RETIRE',
  orgo_launch_quote: 'LAUNCH PRICE',
  orgo_launch: 'LAUNCH',
  fly_pool_cap: 'POOL CAP',
  fly_onboard: 'ONBOARD TO POOL'
};

// The args each Orgo / Fly pool type sends, beyond box, type, target and
// reason. Required ones are refused when blank, never filled in.
const ORGO_FIELDS = {
  orgo_restart: { opt: ['account'] },
  orgo_stop: { opt: ['account'] },
  orgo_resize_quote: { req: ['account'], spec: 'any' },
  orgo_resize: { req: ['account', 'quote_id', 'confirm_monthly_usd'], spec: 'any' },
  orgo_retire: { opt: ['to', 'ip', 'delete'] },
  orgo_launch_quote: { req: ['account', 'project'], spec: 'all' },
  orgo_launch: { req: ['account', 'project', 'quote_id', 'confirm_monthly_usd'], spec: 'all' },
  fly_pool_cap: { req: ['cap'] },
  fly_onboard: { opt: ['cap'] }
};
const SPECS = ['vcpus', 'mem_gb', 'disk_gb'];
const absent = (v) => v === undefined || v === null || (typeof v === 'string' && !v.trim());
const tidy = (v) => (typeof v === 'string' ? v.trim() : v);

// The body for an Orgo / Fly pool type. The target is ctx.box (the Orgo box
// id) or, for the Fly pool types, ctx.project; the body's box is always
// 'hub', which runs them. quote_id and confirm_monthly_usd are passed
// through as received: this module never computes a price.
function ownerCommandFor(type, ctx) {
  const id = FLY_POOL_TYPES.includes(type) ? ctx.project : ctx.box;
  if (blank(id)) return { error: FLY_POOL_TYPES.includes(type) ? 'project required' : 'box required' };
  const f = ORGO_FIELDS[type];
  const body = { box: 'hub', type, target: id.trim() };
  for (const k of f.req || []) {
    if (absent(ctx[k])) return { error: `${k} required` };
    body[k] = tidy(ctx[k]);
  }
  for (const k of f.opt || []) if (!absent(ctx[k])) body[k] = tidy(ctx[k]);
  if (f.spec) {
    for (const k of SPECS) {
      if (absent(ctx[k])) { if (f.spec === 'all') return { error: `${k} required` }; continue; }
      body[k] = ctx[k];
    }
    if (!SPECS.some((k) => k in body)) return { error: 'vcpus, mem_gb or disk_gb required' };
  }
  return { ...body, reason: ctx.reason.trim(), confirm: true };
}

const STATUS_RANK = { requested: 0, claimed: 1, fail: 2, ok: 3 };

const blank = (v) => typeof v !== 'string' || !v.trim();

// The exact POST body, or { error } when any part of it would be a guess.
export function boxCommandFor(type, ctx = {}) {
  const { box, reason, project, app, machineId } = ctx;
  if (!BOX_COMMAND_TYPES.includes(type)) return { error: `unknown type ${type}` };
  if (blank(reason)) return { error: 'reason required' };
  if (ORGO_FIELDS[type]) return ownerCommandFor(type, ctx);
  if (FLY_TYPES.includes(type)) {
    for (const [field, v] of [['project', project], ['app', app], ['machineId', machineId]]) {
      if (blank(v)) return { error: `${field} required` };
    }
    return { box: 'hub', type, target: machineId.trim(), project: project.trim(), app: app.trim(), reason: reason.trim(), confirm: true };
  }
  if (blank(box)) return { error: 'box required' };
  return { box: box.trim(), type, target: '', project: '', app: '', reason: reason.trim(), confirm: true };
}

// The Fly app a machine lives in: its own, else the project's only app. With
// no app and zero or several candidates it is unknown (null), never picked.
export function flyAppFor(machine, apps) {
  if (machine && typeof machine.app === 'string' && machine.app.trim()) return machine.app;
  return Array.isArray(apps) && apps.length === 1 ? apps[0] : null;
}

export function flyStopText(r, app) {
  const job = r && r.job ? (r.job.key || r.job.ticket_id) : null;
  return `Stop machine ${r.id} in ${app}?` + (job ? ` It is building ${job}. Stopping it kills that build.` : '');
}

export function flyDestroyText(r, app) {
  return `Destroy machine ${r.id} in ${app}? This cannot be undone. The machine and its disk are deleted.`;
}

// What the banner says after a 2xx. It is a request rung, so "queued".
export function boxCommandResultText(res, box) {
  return res && res.deduped === true ? `already queued (#${res.id})` : `queued for ${box}`;
}

// Confirm first, then build the body, then post. `ask(form)` resolves true
// only on CONFIRM and writes the typed reason into form.reason. Returns null
// on cancel (nothing sent) or { ok, text } for the banner.
export async function requestBoxCommand(type, ctx, { ask, post }) {
  const label = COMMAND_LABELS[type] || type;
  const form = { reason: '' };
  const confirmed = await ask(form);
  if (!confirmed) return null;
  const cmd = boxCommandFor(type, { ...ctx, reason: form.reason });
  if (cmd.error) return { ok: false, text: `${label} refused: ${cmd.error}` };
  try {
    const res = await post(cmd);
    return { ok: true, text: boxCommandResultText(res, cmd.box) };
  } catch (e) {
    return { ok: false, text: `${label} failed: ${e && e.message ? e.message : String(e)}` };
  }
}

// GET /api/coord/box-commands -> table rows. An unreadable payload throws so
// the screen shows an error, never "no box commands yet".
export function shapeBoxCommands(payload, now = Date.now()) {
  if (!payload || typeof payload !== 'object' || !Array.isArray(payload.commands)) {
    throw new Error('box commands: unreadable payload');
  }
  const rows = payload.commands.map((c) => {
    const t = typeof c.requested_at === 'string' ? Date.parse(c.requested_at) : NaN;
    return {
      ...c,
      ageMin: Number.isFinite(t) ? Math.max(0, Math.floor((now - t) / 60000)) : null,
      statusRank: Object.prototype.hasOwnProperty.call(STATUS_RANK, c.status) ? STATUS_RANK[c.status] : 4
    };
  });
  return { rows, truncated: payload.truncated === true, asOf: payload.as_of || null };
}
