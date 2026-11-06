import { html } from '../router.js';
import { SortableTable } from '../ui/SortableTable.js';
import { fmtNum } from '../lib/format.js';
import { LEGACY_ALIASES } from '../theme/tokens.js';
import {
  COLOR_KEYS, FONT_CHOICES, FONT_ROLES, RADIUS_KEYS, RADIUS_MAX, MIN_CONTRAST,
  validateThemeDoc, contrastFailures, mergedTokens, previewTheme, pickerHex
} from '../theme/custom.js';

// THE THEME EDITOR (BH-4846): an inline panel on /settings/appearance, not a
// route. It edits one theme doc ({v, name, base, tokens, shape}, see
// src/theme/custom.js) and hands every change up through onChange; the screen
// owns the doc and the save. Every value it shows comes from the doc, so this
// file holds no colour of its own.
//
// SAVE is disabled while the validator has anything to say, and a contrast
// failure is listed pair by pair above it.

const FONT_LABEL = { '--font-display': 'Titles', '--font-body': 'Body', '--font-mono': 'Labels and code' };
const RADIUS_LABEL = { '--radius-sm': 'Small', '--radius-md': 'Panels', '--radius-lg': 'Large' };

// The preview's inline style: the edited tokens and shape, plus every legacy
// alias re-pointed at its semantic token here, so shared components (the
// table) inside the preview read the edited theme rather than the page's.
function previewStyle(doc) {
  const { tokens, shape } = previewTheme(doc);
  const decl = Object.entries({ ...tokens, ...shape }).map(([k, v]) => `${k}:${v}`);
  for (const [legacy, semantic] of Object.entries(LEGACY_ALIASES)) decl.push(`${legacy}:var(${semantic})`);
  return decl.join(';');
}

const SAMPLE_ROWS = [
  { project: 'board-a', stage: 'review', minutes: 4, state: 'ok' },
  { project: 'board-b', stage: 'build', minutes: 12, state: 'warn' },
  { project: 'board-c', stage: 'plan', minutes: 31, state: 'err' }
];
const STATE_LABEL = { ok: 'MERGED', warn: 'WAITING', err: 'FAILED' };
const SAMPLE_COLUMNS = [
  { key: 'project', label: 'Project', cell: (r) => html`<span class="theme-card__strong">${r.project}</span>` },
  { key: 'stage', label: 'Stage', cell: (r) => r.stage },
  { key: 'minutes', label: 'Time', unit: 'min', align: 'right', cell: (r) => r.minutes },
  { key: 'state', label: 'State', cell: (r) => html`<span class=${`theme-card__pill theme-card__pill--${r.state}`}>${STATE_LABEL[r.state]}</span>` }
];

function ColourRow({ k, value, onToken }) {
  const hex = pickerHex(value);
  return html`
    <label class="theme-editor__swatch">
      <span class="theme-editor__key">${k}</span>
      ${hex
        ? html`<input type="color" value=${hex} data-token=${k} aria-label=${k} onInput=${(e) => onToken(k, e.target.value)} />`
        : html`<input type="text" class="theme-editor__text" value=${value} data-token=${k} aria-label=${k} spellcheck="false"
            onInput=${(e) => onToken(k, e.target.value)} />`}
    </label>`;
}

export function ThemeEditorView({ doc, saving = false, saveError = null, onChange, onSave, onCancel, onExport }) {
  const tokens = mergedTokens(doc);
  const shape = { ...previewTheme(doc).shape, ...(doc.shape || {}) };
  const v = validateThemeDoc(doc);
  const contrast = contrastFailures(tokens);
  const other = v.errors.filter((e) => !e.startsWith('contrast:'));
  const set = (part, k, val) => onChange({ ...doc, [part]: { ...(doc[part] || {}), [k]: val } });
  const onToken = (k, val) => set('tokens', k, val);
  const radiusPx = (k) => { const m = /^(\d+)px$/.exec(String(shape[k] || '')); return m ? Number(m[1]) : 0; };

  return html`
    <section class="theme-editor" data-theme-editor="open" aria-label="Theme editor">
      <div class="theme-editor__head">
        <span class="section__title">THEME EDITOR</span>
        <label class="theme-editor__name">
          <span>Name</span>
          <input type="text" value=${doc.name} maxlength="40" data-theme-name="name"
            onInput=${(e) => onChange({ ...doc, name: e.target.value })} />
        </label>
        <span class="section__note">from ${doc.base}</span>
      </div>
      <div class="theme-editor__body">
        <div class="theme-editor__controls">
          <fieldset class="theme-editor__group">
            <legend>FONTS</legend>
            ${FONT_ROLES.map((role) => html`
              <label class="theme-editor__field" key=${role}>
                <span>${FONT_LABEL[role]}</span>
                <select value=${shape[role]} data-font-role=${role} onChange=${(e) => set('shape', role, e.target.value)}>
                  ${FONT_CHOICES.map((f) => html`<option value=${f.stack} selected=${f.stack === shape[role]}>${f.label}</option>`)}
                </select>
              </label>`)}
          </fieldset>
          <fieldset class="theme-editor__group">
            <legend>CORNERS</legend>
            ${RADIUS_KEYS.map((k) => html`
              <label class="theme-editor__field" key=${k}>
                <span>${RADIUS_LABEL[k]}</span>
                <input type="range" min="0" max=${RADIUS_MAX} step="1" value=${radiusPx(k)} data-radius=${k}
                  onInput=${(e) => set('shape', k, `${Number(e.target.value)}px`)} />
                <span class="theme-editor__px">${radiusPx(k)}px</span>
              </label>`)}
          </fieldset>
          <fieldset class="theme-editor__group">
            <legend>COLOURS</legend>
            <div class="theme-editor__swatches">
              ${COLOR_KEYS.map((k) => html`<${ColourRow} key=${k} k=${k} value=${tokens[k]} onToken=${onToken} />`)}
            </div>
          </fieldset>
        </div>
        <div class="theme-editor__preview" data-theme-preview="live" style=${previewStyle(doc)}>
          <div class="theme-card__panel">
            <div class="theme-card__panel-head">BUILDING NOW</div>
            <div class="theme-card__row">
              <span class="theme-card__strong">board-a</span>
              <span class="theme-card__dim">sample build · 4m</span>
              <span class="theme-card__pill theme-card__pill--live">LIVE</span>
            </div>
          </div>
          <${SortableTable} columns=${SAMPLE_COLUMNS} rows=${SAMPLE_ROWS} rowKey=${(r) => r.project} />
          <div class="theme-card__pills">
            <span class="theme-card__pill theme-card__pill--ok">OK</span>
            <span class="theme-card__pill theme-card__pill--warn">WARN</span>
            <span class="theme-card__pill theme-card__pill--err">ERR</span>
            <span class="theme-card__pill theme-card__pill--live">LIVE</span>
            <span class="theme-card__pill theme-card__pill--info">INFO</span>
          </div>
          <p class="theme-card__text">Body text, <span class="theme-card__accent">a link</span> and <span class="theme-card__dim">a quieter note</span>.</p>
        </div>
      </div>
      ${contrast.length ? html`
        <div class="theme-editor__warn" data-contrast-warn="1" role="alert">
          <span>Text needs ${MIN_CONTRAST}:1 against every surface. These pairs are under it, so SAVE is off until they're fixed:</span>
          <ul>${contrast.map((f) => html`<li key=${`${f.fg}${f.bg}`}>${f.fg} on ${f.bg}: ${f.ratio === null ? 'not an opaque colour' : `${fmtNum(f.ratio, { decimals: 2 })}:1`}</li>`)}</ul>
        </div>` : null}
      ${other.length ? html`
        <div class="theme-editor__warn" data-theme-errors="1">
          <ul>${other.map((e) => html`<li key=${e}>${e}</li>`)}</ul>
        </div>` : null}
      ${saveError ? html`<div class="theme-editor__warn" role="alert">Couldn't save: ${saveError}</div>` : null}
      <div class="theme-editor__actions">
        <button type="button" class="btn btn--primary" data-theme-save="1" disabled=${!v.ok || saving} onClick=${onSave}>
          ${saving ? 'SAVING…' : 'SAVE'}
        </button>
        <button type="button" class="btn" data-theme-export-draft="1" disabled=${!v.ok} onClick=${onExport}>EXPORT</button>
        <button type="button" class="btn" data-theme-cancel="1" onClick=${onCancel}>CANCEL</button>
      </div>
    </section>`;
}
