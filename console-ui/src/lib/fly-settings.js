// The Fly and Tailscale settings rows the fleet Machines page reads
// (BH-7978). Pure: no api import, so Onboard and ProjectReady can reuse the
// gate copy and a test can drive it with seeded rows.
//
// The hub writes `fly.token_present` and `tailscale.key_present` after it
// consumed a token envelope (BH-7939.2). A flag is set only when its value,
// trimmed, is exactly '1'. Any other value, or no row, is "not added".

export const FLY_GATE_TEXT = 'Add your Fly API token first';
export const FLY_TOKEN_HREF = '/settings/fleet/machines#fly-token';

// A Fly org slug: lower-case letters, digits and '-', 1 to 63 chars, the first
// a letter or digit. A format check, not a knob.
const FLY_ORG_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;
const FLY_ORG_RULE = 'Use 1 to 63 lower-case letters, digits and -, starting with a letter or digit.';

// The api.settings() answer is an array of rows or { settings: [rows] }.
export function flySettingsFrom(res) {
  const rows = Array.isArray(res) ? res : (res && Array.isArray(res.settings) ? res.settings : []);
  const val = (k) => { const r = rows.find((x) => x && x.key === k); return r ? r.value : undefined; };
  const isOne = (v) => String(v ?? '').trim() === '1';
  return {
    org: String(val('fly.org') ?? '').trim(),
    tokenPresent: isOne(val('fly.token_present')),
    tailscalePresent: isOne(val('tailscale.key_present'))
  };
}

export function checkFlyOrg(raw) {
  const value = String(raw ?? '').trim();
  if (!FLY_ORG_RE.test(value)) return { ok: false, message: FLY_ORG_RULE };
  return { ok: true, value };
}

// Every Fly control asks this: with no token it is disabled and says why.
export function flyGate({ tokenPresent } = {}) {
  return tokenPresent === true
    ? { enabled: true }
    : { enabled: false, reason: FLY_GATE_TEXT, href: FLY_TOKEN_HREF };
}
