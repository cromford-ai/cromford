// BH-7243.4 owns this file.
// The wave's file bar, under the wave view. On a draft wave: APPROVE AND FILE
// and REJECT, each behind the shared in-app Modal. On an approved or filing
// wave: a status line and a bounded poll of the issues read. On a filed wave:
// the list of the issues the filing lane opened.
import { useEffect, useRef, useState } from 'preact/hooks';
import { html } from '../../router.js';
import { api, AuthError } from '../../api.js';
import { Modal } from '../../ui/Modal.js';

// The poll of an approved or filing wave: every `ms`, at most `max` polls.
// A module object so a test can shorten it; the screen mounts WaveActions
// without props.
export const WAVE_POLL = { ms: 10000, max: 60 };

const BAR = 'display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin:14px 0';
const TAP = 'min-height:44px;min-width:44px';

const errText = (e) => {
  if (e instanceof AuthError) return 'refused: this session may not change this wave';
  const why = e && e.body && e.body.error ? e.body.error : (e && e.message) || String(e);
  return e && e.status ? `${why} (http ${e.status})` : why;
};

function RejectReason({ form }) {
  const [v, setV] = useState(form.reason);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>The wave is set to rejected. No issues are filed.</span>
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON (OPTIONAL)</span>
        <textarea class="knob__input" style="width:100%;box-sizing:border-box;min-height:4em" rows="3"
          aria-label="Reason" maxlength="500" value=${v}
          onInput=${(e) => { form.reason = e.target.value; setV(form.reason); }}></textarea>
      </label>
    </div>`;
}

export function WaveActions({ project, wave: initial }) {
  const id = initial && initial.id;
  const [wave, setWave] = useState(initial || {});
  const [issues, setIssues] = useState([]);
  const [loadError, setLoadError] = useState(null);
  const [actionError, setActionError] = useState(null);
  const [dialog, setDialog] = useState(null);
  const [busy, setBusy] = useState(false);
  const [gaveUp, setGaveUp] = useState(false);
  const live = useRef(true);
  // One write per wave: the Modal's confirm is not disabled by itself, and a
  // stale confirm handler can fire again after the dialog closed.
  const inFlight = useRef(false);
  const rejectForm = useRef({ reason: '' });

  const apply = (out) => {
    if (!out) return;
    if (out.wave) setWave((w) => ({ ...w, ...out.wave }));
    if (Array.isArray(out.issues)) setIssues(out.issues);
  };

  useEffect(() => {
    live.current = true;
    return () => { live.current = false; };
  }, []);

  // The first read: once per mount.
  useEffect(() => {
    let off = false;
    api.roadmapWaveIssues(id, project).then(
      (out) => { if (!off) { setLoadError(null); apply(out); } },
      (e) => {
        if (off) return;
        // A read refused as signed out is a lost session, as on every screen.
        if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
        setLoadError(errText(e));
      });
    return () => { off = true; };
  }, [id, project]);

  // The poll: runs while the wave is approved or filing. A move to filed (or
  // any other status) and an unmount both run the cleanup, which stops it.
  const polling = wave.status === 'approved' || wave.status === 'filing';
  useEffect(() => {
    if (!polling) return undefined;
    let off = false;
    let n = 0;
    let timer = null;
    const tick = async () => {
      if (off) return;
      if (n >= WAVE_POLL.max) { setGaveUp(true); return; }
      n += 1;
      try {
        const out = await api.roadmapWaveIssues(id, project);
        if (off) return;
        apply(out);
      } catch (e) {
        if (off) return;
        setLoadError(errText(e));
      }
      timer = setTimeout(tick, WAVE_POLL.ms);
    };
    timer = setTimeout(tick, WAVE_POLL.ms);
    return () => { off = true; clearTimeout(timer); };
  }, [polling, id, project]);

  const write = async (call, fallbackStatus) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setDialog(null);
    setBusy(true);
    setActionError(null);
    try {
      const out = await call();
      if (!live.current) return;
      if (out && out.wave) apply(out);
      else setWave((w) => ({ ...w, status: fallbackStatus }));
    } catch (e) {
      // A refused write may be retried; a done one may not.
      inFlight.current = false;
      if (!live.current) return;
      setActionError(errText(e));
      // A 409 carries the wave as it is now: show that, not the stale draft.
      if (e && e.body && e.body.wave) apply({ wave: e.body.wave });
    } finally {
      if (live.current) setBusy(false);
    }
  };

  const approve = () => write(() => api.roadmapApproveWave({ id, project }), 'approved');
  const reject = () => write(() => api.roadmapRejectWave({ id, project, reason: rejectForm.current.reason.trim() }), 'rejected');

  const status = wave.status;
  if (!status && !loadError) return '';

  const n = wave.slice_count;
  const repo = wave.repo || 'this project\'s repo';
  let body;
  if (!status) {
    body = null;
  } else if (status === 'draft') {
    body = html`
      <div style=${BAR} role="group" aria-label="wave actions">
        <button class="btn btn--primary" type="button" style=${TAP} data-action="approve" disabled=${busy}
          onClick=${() => setDialog('approve')}>APPROVE AND FILE</button>
        <button class="btn" type="button" style=${TAP} data-action="reject" disabled=${busy}
          onClick=${() => { rejectForm.current = { reason: '' }; setDialog('reject'); }}>REJECT</button>
      </div>`;
  } else if (status === 'approved' || status === 'filing') {
    body = html`
      <div style=${BAR}>
        <span role="status">Approved. Filing ${n} issues.</span>
        ${wave.error ? html`<span class="knob__note knob__note--bad" style="max-width:none">${wave.error}</span>` : null}
        ${gaveUp ? html`<span class="knob__note">still filing, reload to check</span>` : null}
      </div>`;
  } else if (status === 'filed') {
    body = html`
      <div style="margin:14px 0">
        <span role="status">Filed ${issues.length} issues in ${repo}.</span>
        <ul data-wave-issues style="margin:8px 0;padding-left:20px">
          ${issues.map((i) => html`
            <li key=${`${i.repo}#${i.issue}`} style="min-height:44px;display:flex;align-items:center;gap:10px;flex-wrap:wrap">
              <a href=${i.url} target="_blank" rel="noopener">${i.repo}#${i.issue}</a>
              <span class="knob__note">${i.issue_state}</span>
            </li>`)}
        </ul>
      </div>`;
  } else {
    body = html`<div style=${BAR}><span role="status">This wave is ${status}.</span></div>`;
  }

  return html`
    <section data-wave-actions class="page" style="padding-top:0">
      ${loadError ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="alert">Could not load the wave's file status: ${loadError}</span>` : null}
      ${actionError ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="alert">${actionError}</span>` : null}
      ${body}
      ${dialog === 'approve' ? html`
        <${Modal} title="File this wave?"
          body=${`This files ${n} slices as ai-build issues in ${repo}.`}
          confirmLabel="APPROVE AND FILE"
          onConfirm=${approve} onCancel=${() => setDialog(null)} />` : null}
      ${dialog === 'reject' ? html`
        <${Modal} title="Reject this wave?" tone="danger"
          body=${html`<${RejectReason} form=${rejectForm.current} />`}
          confirmLabel="REJECT"
          onConfirm=${reject} onCancel=${() => setDialog(null)} />` : null}
    </section>`;
}
