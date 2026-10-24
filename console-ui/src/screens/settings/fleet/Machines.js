import { html } from '../../../router.js';
import { useState, useEffect } from 'preact/hooks';
import { api } from '../../../api.js';
import { useApi } from '../../../lib/hooks.js';
import { Section, Skeleton, ErrorBox } from '../../../ui/primitives.js';
import { PageHeadline } from '../../../ui/line.js';
import { flySettingsFrom, checkFlyOrg, flyGate } from '../../../lib/fly-settings.js';

// The fleet Machines page (BH-7978, /settings/fleet/machines): the Fly org,
// whether the Fly API token and the fleet Tailscale key are added, and the
// Provision a box action. The page reads only the two *_present flags, never
// a token value. Adding the tokens and provisioning are not built here yet, so
// those rows show state and the button stays disabled with the reason.

const LATER = 'Adding it here comes with the fleet accounts update.';
const PROVISION_LATER = 'Not built yet: provisioning comes with the box station.';

// ONE read: the settings rows. The shell's project read runs in the same commit.
export function FleetMachinesScreen() {
  const res = useApi(() => api.settings(), []);
  const onSaveOrg = (value) => api.setCoordSetting({ key: 'fly.org', value, reason: 'fleet machines page: fly org' });
  return html`<${FleetMachinesView} data=${res.data} error=${res.error}
    onRetry=${res.reload} onSaveOrg=${onSaveOrg}/>`;
}

export function FleetMachinesView({ data, error, onRetry, onSaveOrg }) {
  let body;
  if (error && !data) body = html`<${ErrorBox} error=${error} onRetry=${onRetry}/>`;
  else if (!data) body = html`<${Skeleton} rows=${3}/>`;
  else {
    const s = flySettingsFrom(data);
    body = html`
      <${Section} title="FLY">
        <${OrgField} org=${s.org} onSave=${onSaveOrg} onSaved=${onRetry}/>
        <${FlagRow} id="fly-token" label="Fly API token" present=${s.tokenPresent}/>
      <//>
      <${Section} title="TAILSCALE">
        <${FlagRow} id="tailscale-key" label="Tailscale key" present=${s.tailscalePresent}/>
      <//>
      <${Section} title="BOXES">
        <${Provision} gate=${flyGate(s)}/>
      <//>`;
  }
  return html`
    <div class="page">
      <${PageHeadline} chip="Settings" line1="Machines and Tailscale." line2="Fly org, Fly API token, fleet Tailscale key."/>
      ${body}
    </div>`;
}

function OrgField({ org, onSave, onSaved }) {
  const [draft, setDraft] = useState(org);
  const [status, setStatus] = useState({ tone: '', text: '' });
  // A reload that changed the stored org wins over a stale draft.
  useEffect(() => { setDraft(org); }, [org]);
  const save = async () => {
    const check = checkFlyOrg(draft);
    if (!check.ok) { setStatus({ tone: 'bad', text: check.message }); return; }
    setStatus({ tone: '', text: 'saving…' });
    try {
      await onSave(check.value);
      setStatus({ tone: '', text: 'saved' });
      if (onSaved) onSaved();
    } catch (e) {
      setStatus({ tone: 'bad', text: `could not save — ${e && e.message ? e.message : String(e)}` });
    }
  };
  return html`
    <div style="display:flex;flex-direction:column;gap:6px;margin-bottom:12px">
      <label for="fly-org">Fly org</label>
      <span class="knob">
        <input id="fly-org" name="fly-org" class=${status.tone === 'bad' ? 'knob__input knob__input--bad' : 'knob__input'}
          style="width:100%" type="text" value=${draft} placeholder="your-fly-org" autocomplete="off" spellcheck="false"
          maxlength="63" aria-describedby="fly-org-status" aria-invalid=${status.tone === 'bad' ? 'true' : 'false'}
          onInput=${(e) => setDraft(e.target.value)}
          onKeyDown=${(e) => { if (e.key === 'Enter') save(); }}/>
        <button type="button" class="btn btn--sm" disabled=${status.text === 'saving…'} onClick=${save}>SAVE</button>
      </span>
      <span id="fly-org-status" role="status" class=${status.tone === 'bad' ? 'knob__note knob__note--bad' : 'knob__note'}>${status.text}</span>
    </div>`;
}

function FlagRow({ id, label, present }) {
  return html`
    <div id=${id} style="display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:8px">
      <span>${label}</span>
      ${present
        ? html`<span class="tag tag--green">added</span>`
        : html`<span class="tag tag--warn">not added</span>`}
      <span class="knob__note">${LATER}</span>
    </div>`;
}

// Disabled in every state for now. With no token the reason is the Fly gate
// and links to the token row on this page (a plain anchor, so it scrolls).
function Provision({ gate }) {
  return html`
    <div style="display:flex;flex-wrap:wrap;align-items:center;gap:8px">
      <button type="button" class="btn" disabled aria-describedby="provision-reason">PROVISION A BOX</button>
      <span id="provision-reason" class="knob__note">
        ${gate.enabled
          ? PROVISION_LATER
          : html`${gate.reason}. <a href=${gate.href}>Go to the Fly API token</a>`}
      </span>
    </div>`;
}
