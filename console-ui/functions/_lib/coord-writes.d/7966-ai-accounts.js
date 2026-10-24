import { isStr } from '../coord-writes.js';

export default [
  // BH-7966: the AI account add sheet. The browser seals the token and sends
  // only the envelope (scope + ciphertext, strings). No row carries the hub
  // token header, so the console can store an envelope and never read one back.
  { method: 'POST', path: 'secrets/envelope', body: ['scope', 'ciphertext'], ok: isStr },
  // The account row. created_by is stamped here as console:<actor>; a
  // browser created_by and every other key are dropped.
  { method: 'POST', path: 'ai-accounts', body: ['vendor', 'label', 'plan', 'use_kind', 'envelope_id'], build: aiAccountBody },
  // Revoke one account: ai-accounts/<uuid>/revoke, no body.
  { method: 'POST', path: isRevokePath, body: [] }
];

function aiAccountBody(sent, _env, actor) {
  const body = {};
  for (const k of ['vendor', 'label', 'plan', 'use_kind', 'envelope_id']) {
    if (Object.prototype.hasOwnProperty.call(sent, k) && (sent[k] === null || typeof sent[k] === 'string')) body[k] = sent[k];
  }
  body.created_by = ('console:' + actor).slice(0, 128);
  return { body };
}

// ai-accounts/<uuid>/revoke, one id segment, never `.` or `..`.
function isRevokePath(rest) {
  return /^ai-accounts\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/revoke$/.test(rest);
}
