import { useState, useEffect } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Legend } from '../ui/primitives.js';
import { IdeaActions } from '../ui/IdeaActions.js';
import { whenLabel, safeHttpsUrl, fmtBytes, minutesSince, agoFromMinutes, fmtNum } from '../lib/format.js';
import { statusLabel, statusTone, awaitingDecision, dusLabel, scoreExplain, assetUrl, MOCKUP_HASH } from '../lib/ideas.js';
import { IDEA_LEGEND } from './Ideas.js';

// One idea, all the way down: what it scored and why, the PRD the drafting
// stage wrote, the mockup it shot, the chat that shaped it, and the client
// ticket if it ever got posted. Below this there is nothing left in the console
// to click into — the PRD and the shots ARE the atomic records the beat carried.

const TONE_CLASS = { warn: 'pill pill--warn', dead: 'pill pill--dead', ok: 'pill', muted: 'pill pill--muted' };

export function IdeaScreen({ project, slug }) {
  const d = useApi(() => api.idea(project, slug), [project, slug]);
  const [shot, setShot] = useState(null);

  // The MOCKUP column on the IDEAS list links here at #mockup, so honour it:
  // land on the shots rather than at the top of a page that carries them three
  // sections down. The router scrolls to the top on every navigation and the
  // section only exists once the read lands, so this waits for both.
  useEffect(() => {
    if (!d.data || typeof window === 'undefined') return;
    if (window.location.hash !== MOCKUP_HASH) return;
    const el = document.getElementById('mockup');
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'start' });
  }, [d.data]);

  if (d.loading && !d.data) return html`<div class="page"><${PageHeadline} chip="Idea" line1=${slug} line2="Reading the proposal."/><${Skeleton} rows=${6} height=${20}/></div>`;
  if (d.error && !d.data) {
    return html`<div class="page">
      <${Link} to="/ideas" class="crumb">← IDEAS<//>
      <${PageHeadline} chip="Idea" line1=${slug} line2="The proposal read failed."/>
      <${ErrorBox} error=${d.error} onRetry=${d.reload}/>
    </div>`;
  }

  return html`<${IdeaView} data=${d.data} project=${project} slug=${slug} shot=${shot} onShot=${setShot} onReload=${d.reload}/>`;
}

// The page itself, apart from the read and the scroll, so a render test can
// hand it a payload.
export function IdeaView({ data, project, slug, shot, onShot, onReload, nowMs = Date.now() }) {
  const p = data.proposal || {};
  const assets = data.assets || [];
  const chat = data.chat || [];
  const kinds = assets.map((a) => a.kind);
  const showing = shot && kinds.includes(shot) ? shot : kinds[0] || null;
  const ticket = safeHttpsUrl(p.ticket_url);
  const mockup = safeHttpsUrl(p.mockup_url);

  return html`
    <div class="page">
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/ideas" class="crumb">← IDEAS<//>
        <span class="crumb-sep">/</span>
        <${Link} to=${`/ideas?project=${encodeURIComponent(p.project || project)}`} class="crumb">
          ${p.project || project}<//>
        <span class=${TONE_CLASS[statusTone(p.status)]}>${statusLabel(p.status)}</span>
      </div>

      <${PageHeadline} chip="Idea" line1=${p.title || slug} line2=${`${statusLabel(p.status)}. ${fmtNum(assets.length)} ${assets.length === 1 ? 'asset' : 'assets'}.`}/>
      ${p.summary ? html`<p style="margin:8px 0 0;max-width:80ch;color:var(--soft);font-size:var(--fs-md);line-height:1.7">${p.summary}</p>` : null}

      ${awaitingDecision(p) ? html`
        <div class="banner banner--warn" style="margin-top:12px">
          <span>
            <b>This one is sitting at the gate.</b>
            ${` It has been waiting ${agoFromMinutes(minutesSince(p.updated_at))} for a post, revise or kill. `}
            Nothing reaches the client board until that call is made, and the buttons below make it.
          </span>
        </div>` : null}

      <${IdeaActions} proposal=${p} project=${p.project || project} onQueued=${onReload}/>

      <div class="stats stats--6" style="margin:12px 0">
        <${Stat} label="PROJECT" value=${p.project || project} tone="sm"
          to=${`/p/${encodeURIComponent(p.project || project)}`}/>
        <${Stat} label="SCORE" value=${p.score === null || p.score === undefined ? '—' : p.score}/>
        <${Stat} label="IMPACT" value=${p.impact ?? '—'} unit=${p.impact == null ? null : '/10'}/>
        <${Stat} label="EFFORT" value=${p.effort ?? '—'} unit=${p.effort == null ? null : ' sessions'}/>
        <${Stat} label="CONFIDENCE" value=${p.confidence ?? '—'} unit=${p.confidence == null ? null : '/10'}/>
        <${Stat} label="REV" value=${p.rev ?? '—'} tone="sm"/>
      </div>

      <div class="footnote" style="gap:12px;flex-wrap:wrap">
        <span>${scoreExplain(p) || 'score inputs incomplete on this row'}</span>
        ${p.department ? html`<span class="tag">${p.department}</span>` : null}
        ${p.role ? html`<span class="tag">${p.role}</span>` : null}
        ${p.process ? html`<span class="tag">${p.process}</span>` : null}
        ${p.aaa ? html`<span class="tag">${p.aaa}</span>` : null}
        ${dusLabel(p.dus) ? html`<span class="tag">${dusLabel(p.dus)}</span>` : null}
        <span>first drafted ${whenLabel(p.created_at, nowMs)} · updated ${whenLabel(p.updated_at, nowMs)}</span>
      </div>
      <${Legend} items=${IDEA_LEGEND}/>

      ${p.dus_why ? html`
        <${Section} title=${`WHY ${dusLabel(p.dus) || 'THIS BUCKET'}`}>
          <p style="margin:0;color:var(--soft);font-size:var(--fs-md);line-height:1.7">${p.dus_why}</p>
        <//>` : null}

      ${ticket || mockup || p.ticket_key ? html`
        <${Section} title="WHERE IT LANDED" note="the client-facing artefacts this proposal produced">
          <div class="tabs">
            ${ticket
              ? html`<a class="tab" href=${ticket} target="_blank" rel="noopener noreferrer">
                  TICKET ${p.ticket_key || ''}</a>`
              : p.ticket_key ? html`<span class="tag">ticket ${p.ticket_key} (no link on file)</span>` : null}
            ${mockup
              ? html`<a class="tab" href=${mockup} target="_blank" rel="noopener noreferrer">MOCKUP ON THE BOARD</a>`
              : null}
          </div>
        <//>` : null}

      <div id="mockup" style="scroll-margin-top:12px">
      <${Section} title="MOCKUP"
        note=${assets.length
          ? `${fmtNum(assets.length)} shot${assets.length === 1 ? '' : 's'} as the drafting stage rendered them`
          : 'none on file'}>
        ${assets.length ? html`
          <div class="tabs" style="margin-bottom:10px">
            ${assets.map((a) => html`
              <button key=${a.kind} type="button" class=${a.kind === showing ? 'tab tab--on' : 'tab'}
                onClick=${() => onShot(a.kind)}>
                ${a.kind.toUpperCase()} · ${fmtBytes(Math.round((a.b64_len || 0) * 0.75))}
              </button>`)}
          </div>
          <div style="border:1px solid var(--line);border-radius:4px;background:var(--panel);padding:8px;overflow:hidden">
            <img src=${assetUrl(p.project || project, p.slug || slug, showing)}
              alt=${`${showing} mockup for ${p.title || slug}`} loading="lazy"
              style="display:block;width:100%;height:auto;border-radius:2px"/>
          </div>
          <div class="footnote" style="margin-top:8px">
            <span>shot ${whenLabel(assets.find((a) => a.kind === showing)?.updated_at, nowMs)} ·
              served from the console's own asset store, never a third-party host</span>
          </div>`
          : html`<${Empty} title="NO MOCKUP SHOT"
              note="Only proposals that reached the drafting stage carry screenshots. A candidate that never
                got past scoring has none, and that is the expected shape — not a failed upload."/>`}
      <//>
      </div>

      <${Section} title="PRD" note="what the drafting stage wrote, as the beat carried it (first ~7KB)">
        ${p.detail
          ? html`<pre class="term term--artifact">${p.detail}</pre>`
          : html`<${Empty} title="NO PRD ON THIS ROW"
              note="Candidates below the selection threshold are beaten to the console with their score only;
                the PRD is written at the drafting stage, which this one has not reached."/>`}
      <//>

      ${p.notes ? html`
        <${Section} title="DECISION NOTES" note="what was said when this proposal was killed or sent back">
          <pre class="term">${p.notes}</pre>
        <//>` : null}

      <${Section} title="IDEA CHAT" note=${chat.length ? `${fmtNum(chat.length)} turn${chat.length === 1 ? '' : 's'}` : 'none'}>
        ${chat.length ? html`
          <div style="display:flex;flex-direction:column;gap:10px">
            ${chat.map((c) => html`
              <div key=${c.id} style="border:1px solid var(--line);border-radius:4px;background:var(--panel);padding:10px 12px">
                <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:6px">
                  <span class="tag">${(c.role || 'unknown').toUpperCase()}</span>
                  ${c.origin ? html`<span class="tag tag--idle">via ${c.origin}</span>` : null}
                  ${c.idea_updated ? html`<span class="tag tag--green">EVOLVED THE IDEA</span>` : null}
                  <span style="font-size:var(--fs-xs);color:var(--fainter)" title=${c.created_at}>${whenLabel(c.created_at, nowMs)}</span>
                </div>
                <div style="white-space:pre-wrap;word-break:break-word;color:var(--soft);font-size:var(--fs-md);line-height:1.7">${c.body}</div>
              </div>`)}
          </div>`
          : html`<${Empty} title="NOBODY HAS TALKED TO THIS IDEA"
              note="The idea chat runs a full-context session on the owning box. Nothing has been asked of this one." />`}
      <//>
    </div>`;
}
