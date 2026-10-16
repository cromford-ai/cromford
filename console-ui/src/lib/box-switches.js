// BH-5934: the box switch rows for /flags. A box switch is the settings row
// `switch.<name>.<box>` that bin/lib/lane-switch.sh reads before the fleet row
// `switch.<name>` and before the flags/ file. Pure, so the tests drive it.

// The exact key _ls_box_key (bin/lib/lane-switch.sh) builds: name and box in
// [a-z0-9_-], box lowercased. A fleet row (one dot) and a three-part key do
// not match.
export const BOX_SWITCH_KEY_RE = /^switch\.([a-z0-9_-]+)\.([a-z0-9_-]+)$/;

// The ON set lane_switch uses (step 2 of bin/lib/lane-switch.sh). Anything
// else, an unreadable value included, is not ON.
export const isSwitchOn = (v) => ['1', 'on', 'true'].includes(String(v ?? '').trim().toLowerCase());

// res is the body of GET /api/coord/settings. No settings array is a failed
// read (null), never an empty list.
export function boxSwitchRows(res) {
  if (!res || !Array.isArray(res.settings)) return null;
  const out = [];
  for (const s of res.settings) {
    if (!s || typeof s.key !== 'string') continue;
    const m = BOX_SWITCH_KEY_RE.exec(s.key);
    if (!m || !isSwitchOn(s.value)) continue;
    out.push({ key: s.key, name: m[1], box: m[2], value: s.value, set_by: s.actor ?? null, set_at: s.updated_at ?? null });
  }
  return out;
}
