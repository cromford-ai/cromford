// The line's shared pieces (BH-4990, wave 1 of BH-4947), drawn from the
// Cromford mission-control-line reference: a page headline (a state sentence,
// a dim second line, a lede), a hairline stat grid, a numbered section head,
// and the eight-station track. Tokens only: every colour is a var(--…) in
// src/styles.css, so Mill, Paper, Phosphor and custom themes all paint them.

import { html, Link } from '../router.js';
import { STATIONS } from '../lib/line.js';
import { fmtNum } from '../lib/format.js';

export { STATIONS };

export function PageHeadline({ chip, asOf, line1, line2, lede, children }) {
  return html`
    <section class="line-hero">
      <div class="line-hero__text">
        ${chip || asOf ? html`
          <div class="line-hero__meta">
            ${chip ? html`<span class="line-chip"><span class="line-chip__dot"></span>${chip}</span>` : null}
            ${asOf ? html`<span class="line-hero__asof">${asOf}</span>` : null}
          </div>` : null}
        <h1 class="line-headline">${line1}<br/><span class="line-headline__dim">${line2}</span></h1>
        ${lede ? html`<p class="lede">${lede}</p>` : null}
      </div>
      ${children ? html`<div class="line-hero__side">${children}</div>` : null}
    </section>`;
}

// items: [{ label, value, sub, tone: 'live'|'warn'|undefined, to }]
export function StatGrid({ items = [] }) {
  return html`
    <div class="statgrid">
      ${items.map((it) => {
        const cls = `statgrid__cell${it.tone ? ` statgrid__cell--${it.tone}` : ''}`;
        const inner = html`
          <span class="statgrid__label">${it.label}</span>
          <span class="statgrid__value">${typeof it.value === 'number' ? fmtNum(it.value) : it.value}</span>
          ${it.sub ? html`<span class="statgrid__sub">${it.sub}</span>` : null}`;
        return it.to
          ? html`<${Link} key=${it.label} to=${it.to} class=${cls}>${inner}<//>`
          : html`<div key=${it.label} class=${cls}>${inner}</div>`;
      })}
    </div>`;
}

export function SectionHead({ num, title, note, right }) {
  return html`
    <div class="sechead">
      <span class="sechead__num">${String(num).padStart(2, '0')}</span>
      <h2>${title}</h2>
      ${note ? html`<p>${note}</p>` : null}
      ${right ? html`<div class="sechead__right">${right}</div>` : null}
    </div>`;
}

// Fill width as a fraction of the node-to-node span, rounded so the inline
// style is stable: 3/7 -> 0.428571. Nothing is filled before station 2.
const fillOf = (at, n) => (at === null || at === undefined || at <= 0
  ? '0'
  : `calc((100% - 28px) * ${Math.round((Math.min(at, n - 1) / (n - 1)) * 1e6) / 1e6})`);

// at: 0-7 or null (not known); state: 'now' | 'held' | 'fail'; times: HH:MMZ or null per station.
// stations: the station names, the ticket line's eight by default. The
// merge-queue track (ui/pr-stage-track.js) passes its own six.
// targets (BH-4991, the ticket page): an element id per station, or null. A
// station with one is a button that scrolls to it (its first event); with any
// target the track is a group of controls, not an image.
export function StationTrack({ at = null, state = 'now', times = [], label = '', compact = false, stations = STATIONS, targets = [] }) {
  const known = Number.isInteger(at) && at >= 0 && at < stations.length;
  const aria = known
    ? `${label ? `${label} at ` : ''}${stations[at]} (${state})`
    : `${label ? `${label}: ` : ''}station not known`;
  const jump = targets.some(Boolean);
  return html`
    <div class=${compact ? 'track track--compact' : 'track'} role=${jump ? 'group' : 'img'} aria-label=${aria}>
      <div class="track__fill" style=${`width:${known ? fillOf(at, stations.length) : '0'}`}></div>
      ${stations.map((name, i) => {
        const cls = !known ? 'st' : i < at ? 'st done' : i === at ? `st ${state}` : 'st';
        const inner = html`
            <span class="node">${String(i + 1).padStart(2, '0')}</span>
            <span class="lbl">${name}</span>
            ${times[i] ? html`<span class="when">${times[i]}</span>` : null}`;
        return targets[i]
          ? html`<button type="button" class=${`${cls} st--jump`} data-target=${targets[i]}
              aria-label=${`${name}: jump to its first event`} onClick=${() => scrollToId(targets[i])}>${inner}</button>`
          : html`<div class=${cls}>${inner}</div>`;
      })}
    </div>`;
}

function scrollToId(id) {
  const el = typeof document !== 'undefined' ? document.getElementById(id) : null;
  if (!el) return;
  el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  el.classList.add('flash');
  setTimeout(() => el.classList.remove('flash'), 900);
}
