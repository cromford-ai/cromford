export default [
  // BH-7711: the MCP's lead_review_request and lead_review_reset, the same
  // asks bin/lead-verdict.sh request and reset make. Both carry the Pages
  // LEAD_VERDICT_TOKEN (leadToken), which the worker needs for each.
  // requested_by is stamped here as console:<actor>, never a client value
  // (and never the inbuild: shape a build box files with). review-tier: and
  // review-mode: in scope_notes become review-tier= and review-mode=, as
  // lv_request does (BH-6967: only the enqueue lane writes those tokens).
  // head_authors, prior_verdict_ref and every other key are dropped.
  // reclaim-stale, start, claim, result, heartbeat and promoted have no row
  // here, so they stay 405 from the console.
  { method: 'POST', path: 'lead-reviews', body: ['repo', 'pr', 'head_sha', 'scope_notes', 'priority'], build: leadRequestBody, leadToken: true },
  { method: 'POST', path: isResetPath, body: [], leadToken: true }
];

function leadRequestBody(sent, _env, actor) {
  const body = {};
  for (const k of ['repo', 'pr', 'head_sha', 'scope_notes', 'priority']) {
    if (Object.prototype.hasOwnProperty.call(sent, k)) body[k] = sent[k];
  }
  if (typeof body.scope_notes === 'string') {
    body.scope_notes = body.scope_notes.split('review-tier:').join('review-tier=').split('review-mode:').join('review-mode=');
  }
  body.requested_by = ('console:' + actor).slice(0, 128);
  return { body };
}

// lead-reviews/<id>/reset, one id segment, never `.` or `..`.
function isResetPath(rest) {
  const m = /^lead-reviews\/([A-Za-z0-9._-]+)\/reset$/.exec(rest);
  return Boolean(m) && m[1] !== '.' && m[1] !== '..';
}
