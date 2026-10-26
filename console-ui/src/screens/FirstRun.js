// The first-run screen of a new fleet (BH-7977, BH-7939.3). `/` renders it in
// place of the Fleet list while a required account is missing and the gate row
// first_run.gate is on (src/lib/first-run.js showFirstRun). Four cards: the two
// AI cards open the existing add sheet (AiAccountSheet, BH-7966); GitHub App and
// Telegram have no setup sheet yet, so each links to its settings row.
// The cards reuse .tiles / .tile, which stack in one column at <= 768px.

import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { FIRST_RUN_CARDS } from '../lib/first-run.js';
import { AiAccountSheet } from './AiAccountSheet.js';

function cardTag(card, added) {
  if (added) return html`<span class="tag tag--green">added</span>`;
  return card.required
    ? html`<span class="tag tag--warn">not added</span>`
    : html`<span class="tag tag--idle">optional</span>`;
}

// FirstRunView({state, onOpenSheet}): pure render of the four cards.
export function FirstRunView({ state, onOpenSheet }) {
  const s = state || {};
  return html`
    <${PageHeadline} chip="Fleet" line1="Set up the fleet accounts"
      line2="before the first project" lede="Add the three required accounts to open the projects list."/>
    <div class="tiles first-run">
      ${FIRST_RUN_CARDS.map((card) => html`
        <div class="tile" data-card=${card.id} key=${card.id}>
          <div style="display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap">
            <b>${card.title}</b>
            ${cardTag(card, s[card.id] === true)}
          </div>
          ${card.action === 'sheet'
            ? html`<div style="margin-top:8px">
                <button class="btn btn--sm" type="button" onClick=${() => onOpenSheet && onOpenSheet(card.id)}>ADD ACCOUNT</button>
              </div>`
            : html`<div class="footnote" style="margin-top:8px">
                <span>The setup sheet is not built yet.</span>
                <${Link} to=${card.href}>See the row<//>
              </div>`}
        </div>`)}
    </div>`;
}

// FirstRun({state, onChanged}): owns the sheet. A save re-reads first-run.
export function FirstRun({ state, onChanged }) {
  const [sheetOpen, setSheetOpen] = useState(false);
  return html`
    <${FirstRunView} state=${state} onOpenSheet=${() => setSheetOpen(true)}/>
    <${AiAccountSheet} open=${sheetOpen} mode="add" onClose=${() => setSheetOpen(false)}
      onSaved=${() => { if (onChanged) onChanged(); }}/>`;
}
