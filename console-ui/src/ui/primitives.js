import { html, Link } from '../router.js';
import { Dot } from './icons.js';
import { agoFromMinutes, healthFromAge, fmtNum } from '../lib/format.js';

const HEALTH_COLOR = { ok: 'var(--green)', warn: 'var(--amber)', dead: 'var(--red)', unknown: 'var(--faint)' };
export const healthColor = (h) => HEALTH_COLOR[h] || HEALTH_COLOR.unknown;

export const Section = ({ title, note, right, children }) => html`
  <div class="section">
    <div class="section__head">
      <span class="section__title">${title}</span>
      ${note ? html`<span class="section__note">${note}</span>` : null}
      ${right ? html`<span style="margin-left:auto">${right}</span>` : null}
    </div>
    ${children}
  </div>`;

// A number `value` is grouped (4,823, BH-9119); a string or vnode shows as given.
// `to` makes a tile a real link — an aggregate a user would click should go
// somewhere rather than just sit there.
export const Stat = ({ label, value, unit, tone, to }) => {
  const inner = html`
    <span class="stat__label">${label}</span>
    <span class=${`stat__value${tone === 'green' ? ' stat__value--green' : ''}${tone === 'amber' ? ' stat__value--amber' : ''}${tone === 'sm' ? ' stat__value--sm' : ''}`}>
      ${typeof value === 'number' ? fmtNum(value) : value}${unit ? html`<span class="stat__unit">${unit}</span>` : null}
    </span>`;
  const cls = `stat${tone === 'warn' ? ' stat--warn' : ''}${to ? ' stat--link' : ''}`;
  return to
    ? html`<${Link} to=${to} class=${cls}>${inner}<//>`
    : html`<div class=${cls}>${inner}</div>`;
};

export const HealthPill = ({ ageMin, labelOverride }) => {
  const h = healthFromAge(ageMin);
  const cls = h === 'ok' ? 'pill' : h === 'warn' ? 'pill pill--warn' : h === 'dead' ? 'pill pill--dead' : 'pill pill--muted';
  const label = labelOverride || (h === 'ok' ? 'HEALTHY' : h === 'warn' ? 'STALE' : h === 'dead' ? 'DOWN' : 'UNKNOWN');
  return html`<span class=${cls}><${Dot} color=${healthColor(h)} size=${7}/>${label}</span>`;
};

// A section whose backing dependency is down names the dependency and the
// reason, so nobody reads an empty pane as "nothing is happening".
export const UnavailableChip = ({ what, reason }) => html`
  <span class="tag tag--warn" title=${reason || ''}>${what} unavailable${reason ? ` · ${reason}` : ''}</span>`;

export const Skeleton = ({ rows = 3, height = 14 }) => html`
  <div style="display:flex;flex-direction:column;gap:8px">
    ${Array.from({ length: rows }, (_, i) => html`
      <div class="skel" key=${i} style=${`height:${height}px;width:${100 - (i % 3) * 12}%`}></div>`)}
  </div>`;

export const Empty = ({ title, note, children }) => html`
  <div class="empty">
    <span class="empty__title">${title}</span>
    ${note ? html`<span class="empty__note">${note}</span>` : null}
    ${children}
  </div>`;

export const ErrorBox = ({ error, onRetry }) => html`
  <div class="banner">
    <span>could not load — <b>${String(error && error.message ? error.message : error)}</b></span>
    ${onRetry ? html`<button class="btn btn--sm" style="margin-left:auto" onClick=${onRetry}>RETRY</button>` : null}
  </div>`;

export const Age = ({ min, warnAt = 30 }) => {
  if (min === null || min === undefined) return html`<span class="na">—</span>`;
  const hot = Number(min) >= warnAt;
  return html`<span style=${hot ? 'color:var(--amber)' : ''}>${agoFromMinutes(min)}</span>`;
};

// Nothing renders as a dead row: an identity cell is always a link somewhere.
export const ProjectLink = ({ project, class: cls = 'cell-name' }) =>
  html`<${Link} to=${`/p/${encodeURIComponent(project)}`} class=${cls}>${project}<//>`;

export const Cursor = ({ small = false }) => html`<span class=${small ? 'cursor cursor--sm' : 'cursor'}></span>`;

// Explanations that only live in title= are invisible on a phone. A legend sits
// under the table and says, in one sentence per term, what the columns mean.
// items: [{ term, text }]; none renders nothing.
export const Legend = ({ items }) => (items && items.length ? html`
  <dl class="legend">
    ${items.map((it) => html`<div class="legend__row" key=${it.term}><dt>${it.term}</dt><dd>${it.text}</dd></div>`)}
  </dl>` : null);
