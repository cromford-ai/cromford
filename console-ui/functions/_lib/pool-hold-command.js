// The Pages-side queue for the console's pool_hold command: hold or release
// one project's Fly pool spawns. The hub runs it with bin/cmd-pool-hold.sh.
//
// The console worker (the harness-console repo) has no pool_hold kind and
// refuses it with 400 'unknown action' before it inserts anything. The Pages
// proxy then queues the row itself, through the same path and the same
// delegated auth probe as the BH-5820 board commands (board-commands.js
// signedIn + enqueueBoardCommand). Only this module's validation differs.

export const POOL_HOLD_TYPES = new Set(['pool_hold']);
export const POOL_HOLD_REASON_MAX = 500;
const PROJECT = /^[A-Za-z0-9._-]{1,100}$/;

// The command row for a sent body, or {error} for a 400. `sent.actor` is the
// proxy's resolved identity, never the browser's. hold must be a JSON boolean.
export function poolHoldCommand(sent) {
  const type = sent.type;
  if (!POOL_HOLD_TYPES.has(type)) return { error: 'unknown action' };
  const project = typeof sent.project === 'string' ? sent.project.trim() : '';
  if (!PROJECT.test(project)) return { error: 'project required' };
  if (typeof sent.hold !== 'boolean') return { error: 'hold must be true or false' };
  const reason = String(sent.reason ?? '').trim().slice(0, POOL_HOLD_REASON_MAX);
  // The same click within one minute is the same command; the minute is UTC.
  const minute = new Date().toISOString().slice(0, 16);
  return {
    type, project,
    ckey: `${project}:${type}:${sent.hold ? 'on' : 'off'}:${minute}`,
    payload: { hold: sent.hold, reason, actor: sent.actor }
  };
}
