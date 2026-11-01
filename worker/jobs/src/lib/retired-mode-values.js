// BH-5035: settings values that were removed and are refused on PUT.
//
// The `human` value of tier_gate_mode and lead_authority_mode (global, or per
// project / per repo with a `.<suffix>`) is gone: the tier and the lead lane no
// longer wait on a person. bin/lib/lead-authority.sh refuses a stored `human`
// row at read time; this refuses it at the write, before any DB read, so
// nothing is stored, audited or signed.

export const RETIRED_MODE_KEYS = ["tier_gate_mode", "lead_authority_mode"];

// The value each key family takes instead.
const USE_INSTEAD = { tier_gate_mode: "off", lead_authority_mode: "lane" };

// retiredModeRefusal(key, value) -> null, or the error text for a 400.
// The value is trimmed and case-folded, the same way the bash readers fold it.
export function retiredModeRefusal(key, value) {
  if (typeof key !== "string" || typeof value !== "string") return null;
  if (value.trim().toLowerCase() !== "human") return null;
  const base = RETIRED_MODE_KEYS.find((b) => key === b || key.startsWith(b + "."));
  if (!base) return null;
  return `${key}=human was removed by BH-5035: the tier and the lead lane no longer wait on a person. Delete the row, or set ${key} to ${USE_INSTEAD[base]}.`;
}
