import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { Skeleton } from '../ui/primitives.js';
import { api as realApi } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { readyCards, readyActions } from '../lib/ready-cards.js';
import { AiAccountChoiceSheet } from '../ui/AiAccountChoiceSheet.js';

// /projects/:project/ready — the "project is ready" screen (BH-7997 seam,
// built by BH-8744). One read, api.onboardReady (GET
// /api/onboarding/ready/<project>), gives the nine cards of
// lib/ready-cards.js. Eight card buttons open /config; the AI account card
// opens AiAccountChoiceSheet in place, and a written pin reads the screen
// again. Styles: project-ready.css, imported by main.js (node cannot load CSS).
// owner BH-7935.3
export function ProjectReadyScreen({ project, api = realApi }) {
  const res = useApi(() => api.onboardReady(project), [project]);
  const [sheet, setSheet] = useState(false);
  const actions = readyActions(project, res.data && res.data.repo);
  const missing = res.error && res.error.status === 404;

  const onDone = (r) => {
    setSheet(false);
    if (r && r.status === 'written') res.reload();
  };

  let band;
  if (res.loading && !res.data) {
    band = html`<${Skeleton} rows=${9} />`;
  } else if (missing) {
    band = html`<p class="project-ready__note">This project is not in the registry yet.</p>`;
  } else if (res.error && !res.data) {
    band = html`
      <div class="project-ready__note project-ready__note--bad" role="alert">
        <span>The ready read failed.</span>
        <button type="button" class="btn" onClick=${res.reload}>Retry</button>
      </div>`;
  } else {
    band = html`
      <div class="project-ready__grid">
        ${readyCards(res.data).map((c) => html`
          <article class="project-ready__card" key=${c.id} data-card=${c.id}>
            <div class="project-ready__card-head">
              <h3 class="project-ready__title">${c.title}</h3>
              <span class=${`tag tag--${c.tone}`}>${c.tag}</span>
            </div>
            <p class="project-ready__sentence">${c.sentence}</p>
            ${c.action.kind === 'sheet'
              ? html`<button type="button" class="btn project-ready__action" onClick=${() => setSheet(true)}>Choose</button>`
              : html`<${Link} to=${c.action.href} class="btn project-ready__action">Set up<//>`}
          </article>`)}
      </div>`;
  }

  return html`
    <div class="project-ready">
      <${PageHeadline} line1=${`Ready: ${project}`} line2="Connect the rest when you need it." />
      <div class="project-ready__actions">
        ${missing ? null : actions.ticket
          ? html`<a class="btn" href=${actions.ticket} target="_blank" rel="noopener noreferrer">File the first ticket</a>`
          : res.data ? html`<span class="project-ready__note">No repo on record.</span>` : null}
        <${Link} to=${actions.project} class="btn">Open the project<//>
      </div>
      <section class="project-ready__band" aria-label="Connect when you need it">
        <h2 class="project-ready__band-title">Connect when you need it</h2>
        ${band}
      </section>
      ${sheet ? html`<${AiAccountChoiceSheet} project=${project} api=${api} onDone=${onDone} />` : null}
    </div>`;
}
