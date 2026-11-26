// The period picker (BH-9304, BH-9120.0): preset buttons, a custom UTC range,
// and, when the screen asks for them, a bucket select and a "compare to
// previous period" toggle. It holds no period of its own: a click writes the
// URL with navigate(..., {replace: true}) and the screen reads it back.
// Other query params stay. Styles: src/period-picker.css (loaded by main.js).

import { useState, useEffect } from 'preact/hooks';
import { html, navigate, currentPath, currentSearch } from '../router.js';
import { resolvePreset, activePreset, periodQuery, BUCKETS } from '../lib/period.js';

const LABELS = {
  today: 'Today', yesterday: 'Yesterday', last_7_days: 'Last 7 days',
  last_30_days: 'Last 30 days', this_month: 'This month', last_month: 'Last month'
};
const BUCKET_LABELS = { auto: 'Auto', hour: 'Hour', day: 'Day', week: 'Week' };
const DAY_MS = 86400000;

// An ISO value as a datetime-local value (YYYY-MM-DDTHH:MM), in UTC.
const toInput = (v) => (v ? (v.length === 10 ? `${v}T00:00` : v.slice(0, 16)) : '');
// A datetime-local value read as UTC, or null.
function fromInput(v) {
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(v)) return `${v}:00Z`;
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/.test(v)) return `${v}Z`;
  return null;
}

function go(next) {
  navigate(`${currentPath()}?${periodQuery(next, new URLSearchParams(currentSearch()))}`, { replace: true });
}

export function PeriodPicker({ period, oldest, knobs, bucket = false, compare = false }) {
  const p = period || { from: null, to: null, bucket: 'auto', compare: false };
  const active = period ? activePreset(period, Date.now()) : null;
  const [custom, setCustom] = useState(active === 'custom' && Boolean(p.from));
  const [from, setFrom] = useState(toInput(p.from));
  const [to, setTo] = useState(toInput(p.to));
  const [error, setError] = useState(null);
  // The custom inputs follow the active period: a preset click or an Apply
  // changes the URL period, and the inputs then show that range. A re-render
  // with the same period keeps what the user typed.
  useEffect(() => {
    setFrom(toInput(p.from));
    setTo(toInput(p.to));
  }, [p.from, p.to]);

  const pick = (name) => {
    setCustom(false);
    setError(null);
    go({ ...resolvePreset(name, Date.now()), bucket: p.bucket, compare: p.compare });
  };
  const apply = () => {
    const f = fromInput(from);
    const t = to ? fromInput(to) : null;
    if (!f) return setError('Pick a start time.');
    if (to && !t) return setError('The end time is not a date and time.');
    if (t && Date.parse(f) >= Date.parse(t)) return setError('Start must be before end.');
    const max = knobs && Number(knobs.max_range_days);
    if (max > 0 && (t ? Date.parse(t) : Date.now()) - Date.parse(f) > max * DAY_MS) {
      return setError(`The range is over ${max} days.`);
    }
    setError(null);
    return go({ from: f, to: t, bucket: p.bucket, compare: p.compare });
  };

  return html`
    <div class="period-picker">
      <div class="period-picker__presets" role="group" aria-label="Period">
        ${Object.keys(LABELS).map((name) => html`
          <button key=${name} type="button" class="period-picker__preset"
            aria-pressed=${active === name ? 'true' : 'false'} onClick=${() => pick(name)}>${LABELS[name]}</button>`)}
        <button type="button" class="period-picker__preset period-picker__custom"
          aria-pressed=${active === 'custom' || custom ? 'true' : 'false'}
          onClick=${() => setCustom(!custom)}>Custom</button>
      </div>
      ${custom ? html`
        <div class="period-picker__range">
          <label class="period-picker__field">From
            <input type="datetime-local" name="from" value=${from} onInput=${(e) => setFrom(e.target.value)}/></label>
          <label class="period-picker__field">To
            <input type="datetime-local" name="to" value=${to} onInput=${(e) => setTo(e.target.value)}/></label>
          <span class="period-picker__tz">UTC</span>
          <button type="button" class="btn btn--sm" onClick=${apply}>Apply</button>
          ${error ? html`<span class="period-picker__error" role="alert">${error}</span>` : null}
        </div>` : null}
      ${bucket ? html`
        <label class="period-picker__field">Bucket
          <select class="period-picker__bucket" value=${p.bucket || 'auto'}
            onChange=${(e) => go({ ...p, bucket: e.target.value })}>
            ${BUCKETS.map((b) => html`<option key=${b} value=${b}>${BUCKET_LABELS[b]}</option>`)}
          </select></label>` : null}
      ${compare ? html`
        <label class="period-picker__field">
          <input type="checkbox" class="period-picker__compare" checked=${p.compare === true}
            onChange=${(e) => go({ ...p, compare: Boolean(e.target.checked) })}/>
          Compare to previous period</label>` : null}
      ${oldest ? html`<span class="period-picker__oldest">data from ${String(oldest).slice(0, 10)}</span>` : null}
    </div>`;
}
