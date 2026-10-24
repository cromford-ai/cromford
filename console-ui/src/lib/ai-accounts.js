// AI accounts on the fleet (BH-7966, BH-7937.2): the pure half of the add
// sheet, the fleet table and the per-project choice. The token is sealed in
// the browser (lib/envelope.js) and leaves only as an envelope ciphertext; the
// account row names the envelope. src/screens/AiAccountSheet.js,
// src/screens/FleetAccounts.js and src/ui/AiAccountChoiceSheet.js render it.

import { checkAccountLabel, SHARED } from './project-accounts.js';
import { accountScope } from './envelope.js';

export const VENDORS = [
  { id: 'claude', label: 'Claude', hint: 'a Claude login token (claude setup-token) or an Anthropic API key' },
  { id: 'codex', label: 'Codex', hint: 'an OpenAI API key for the Codex runner' },
  { id: 'openrouter', label: 'OpenRouter', hint: 'an OpenRouter API key' },
  { id: 'fireworks', label: 'Fireworks', hint: 'a Fireworks API key' },
  { id: 'xai', label: 'xAI', hint: 'an xAI API key' }
];
export const USE_KINDS = [
  { id: 'pool', label: 'fleet pool', note: 'shared by every project that bills the pool' },
  { id: 'project', label: 'one project', note: 'only the project it is pinned to' },
  { id: 'fallback', label: 'fallback', note: 'used when the pool accounts are out' }
];

// Code fallbacks of the settings rows ai_account_status_poll_s and
// ai_account_status_wait_s (worker/jobs/schema.d/…-bh-7966-ai-accounts.sql).
export const POLL_S_DEFAULT = 3;
export const WAIT_S_DEFAULT = 90;

// The hub consumer's label rule (PR #8149 bin/lib/envelope.sh), the same table
// as worker/jobs/src/routes/ai-accounts.js checkAiAccountLabel.
const LABEL_RE = /^[a-z0-9._@-]{1,48}$/;
const TOKEN_PREFIX_RE = /^(sk-|sk_|xai-|fw_|or-)/i;

// checkAiAccountLabel(raw) -> {ok:true, value} | {ok:false, message}. First the
// pin rule (checkAccountLabel: its `sk-` refusal), then the stricter rule for a
// new account. The message never repeats the value.
export function checkAiAccountLabel(raw) {
  const base = checkAccountLabel(raw);
  if (!base.ok) return base;
  const value = base.value;
  if (value === SHARED) return { ok: false, message: 'that label is reserved for the fleet pool: pick another label' };
  if (TOKEN_PREFIX_RE.test(value)) {
    return { ok: false, message: 'that looks like a token: an account is named by a label, and the token goes in the token field' };
  }
  if (!LABEL_RE.test(value) || value.includes('..') || value.startsWith('.')) {
    return { ok: false, message: 'a label is lower-case letters, digits and . _ @ - (at most 48), with no ..' };
  }
  return { ok: true, value };
}

// The calls, spread into `api` (src/api.js). Reads and writes go through the
// coord proxy; the proxy stamps created_by on the account POST.
export const aiAccountsApi = ({ get, post, coordPath }) => ({
  aiAccounts: () => get(coordPath('/api/ai-accounts')),
  postEnvelope: (body) => post(coordPath('/api/secrets/envelope'), body),
  postAiAccount: (body) => post(coordPath('/api/ai-accounts'), body),
  revokeAiAccount: (id) => post(coordPath(`/api/ai-accounts/${encodeURIComponent(id)}/revoke`), {}),
  envelopeStatus: (id) => get(coordPath(`/api/secrets/envelope/${encodeURIComponent(id)}/status`))
});

const intIn = (v, lo, hi, dflt) => {
  const s = String(v ?? '').trim();
  if (!/^\d+$/.test(s)) return dflt;
  const n = Number(s);
  return n >= lo && n <= hi ? n : dflt;
};

// loadSheetConfig(api) -> {publicKey, pollS, waitS}. ONE settings read per page
// load, shared by every sheet; a failed read is not kept, so the next open retries.
let configMemo = null;
export function loadSheetConfig(api) {
  if (!configMemo) {
    configMemo = Promise.resolve().then(() => api.settings()).then((res) => {
      const rows = Array.isArray(res) ? res : (res && Array.isArray(res.settings) ? res.settings : []);
      const val = (k) => { const r = rows.find((x) => x && x.key === k); return r ? r.value : undefined; };
      return {
        publicKey: String(val('hub_envelope_public_key') ?? '').trim(),
        pollS: intIn(val('ai_account_status_poll_s'), 1, 60, POLL_S_DEFAULT),
        waitS: intIn(val('ai_account_status_wait_s'), 5, 900, WAIT_S_DEFAULT)
      };
    });
    configMemo.catch(() => { configMemo = null; });
  }
  return configMemo;
}
export function resetSheetConfig() { configMemo = null; }

const why = (e) => (e && e.message ? e.message : String(e));

// saveAccount: label, hub key, token, scope, seal, envelope POST, account POST,
// then (rotate only) the old account's revoke. Each step that fails answers
// {status:'failed', message} and no later request runs. The caller clears the
// token from its state on every exit.
export async function saveAccount({ api, seal, form, config, rotateFrom = null }) {
  const label = checkAiAccountLabel(form.label);
  if (!label.ok) return { status: 'invalid', message: label.message };
  if (!config || !config.publicKey) return { status: 'no-key', message: 'The hub key is not set yet, so nothing was sent.' };
  if (!form.token) return { status: 'invalid', message: 'paste the token' };
  const scope = accountScope({ vendor: form.vendor, label: label.value, use_kind: form.use_kind, project: form.use_kind === 'project' ? form.project : null });
  if (!scope.ok) return { status: 'invalid', message: scope.message };
  let ciphertext;
  try { ciphertext = await seal(config.publicKey, form.token); } catch (e) { return { status: 'failed', message: `not saved: the token could not be sealed (${why(e)})` }; }
  let envelope;
  try { envelope = await api.postEnvelope({ scope: scope.scope, ciphertext }); } catch (e) { return { status: 'failed', message: `not saved: the envelope store refused it (${why(e)})` }; }
  if (!envelope || typeof envelope.id !== 'string') return { status: 'failed', message: 'not saved: the envelope store gave no id' };
  let row;
  try {
    row = await api.postAiAccount({
      vendor: form.vendor, label: label.value, plan: form.plan ? String(form.plan).trim() || null : null,
      use_kind: form.use_kind, envelope_id: envelope.id
    });
  } catch (e) { return { status: 'failed', message: `not saved: ${why(e)}` }; }
  if (!row || typeof row.id !== 'string') return { status: 'failed', message: 'not saved: the account store gave no id' };
  const out = { status: 'saved', id: row.id, envelope_id: envelope.id, label: label.value };
  if (rotateFrom && rotateFrom.id) {
    try { await api.revokeAiAccount(rotateFrom.id); out.revoked = true; } catch (e) { out.revoked = false; out.message = `saved, but the old account was not revoked (${why(e)}): revoke it from the table`; }
  }
  return out;
}

// pollStatus -> 'proved' (the hub applied it) | 'failed' (apply_failed or
// expired) | 'waiting' (waitS passed with neither). A read that fails is
// polled again: it says nothing about the apply.
export async function pollStatus({ api, envelopeId, pollS, waitS, sleep, now }) {
  const start = now();
  for (;;) {
    if (now() - start >= waitS * 1000) return 'waiting';
    let state = null;
    try { state = (await api.envelopeStatus(envelopeId)).state; } catch { state = null; }
    if (state === 'applied') return 'proved';
    if (state === 'apply_failed' || state === 'expired') return 'failed';
    await sleep(pollS * 1000);
  }
}

// chooseAccount: the per-project choice. pool and account write
// account.<project> through makeAccountSetter (its confirm modal first);
// own asks the caller to open the add sheet.
export function chooseAccount({ choice, project, setter }) {
  if (!choice || choice.kind === 'own') return Promise.resolve({ status: 'open-add' });
  if (choice.kind === 'pool') return setter.set({ project }, SHARED);
  return setter.set({ project }, choice.label);
}

// The rows of the choice sheet: active accounts only.
export const activeAccounts = (data) =>
  (data && Array.isArray(data.accounts) ? data.accounts : []).filter((a) => a.state === 'active' && !a.revoked_at);
