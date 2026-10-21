// Lane runs placed on a named box (BH-7636). A PROJECT row
//   lane_placement.<lane>.<project> = box:<name>
// of lane merge-conductor or fly-pool sends that (lane, project) row to the box
// <name>: the box runs bin/lane-run-worker.sh --box <name> from its own cron,
// and its claim takes only the rows placed on it. A claim without `box` (every
// Fly machine) never takes such a row. The hub reads the same row with
// bin/lib/lane-placement.sh (lp_decide), and the two parse it by ONE rule,
// pinned by tests/fixtures/bh-7636/box-placement-cases.tsv:
//   - delete every whitespace character, lowercase A-Z (only ASCII, as `tr`);
//   - match ^box:[a-z0-9][a-z0-9._-]{0,63}$;
//   - a lane row, the default row, another lane, or a non-empty
//     lane_placement.<lane>.hub_only row is not a box placement.
//
// The dedicated lane host (BH-7716). The value `fly-dedicated` places a lane
// on the box `fly-dedicated` (the machine of lane_fleet.group.dedicated). It is
// valid on the LANE row and on a project row, only for a lane in the settings
// row lane_dedicated.lanes (comma list, whitespace deleted, A-Z lowercased; no
// row = DEDICATED_LANES_DEFAULT). A lane row covers every project with no
// project row of its own: its key is "<lane>|*", and every project row of that
// lane with another value is an exception ("<lane>|<project>" in `except`),
// as on the hub, where the project row wins. A dedicated row of a lane in
// `fallback` (every dedicated lane except merge-conductor, which the hub takes
// back itself, BH-7636) goes to the default Fly fleet after
// lane_run.group_fallback_s. The rule is pinned by
// tests/fixtures/bh-7716/dedicated-placement-cases.tsv.

import { laneName } from "./core.js";

export const BOX_LANES = ["merge-conductor", "fly-pool"];
export const DEDICATED_BOX = "fly-dedicated";
export const DEDICATED_LANES_KEY = "lane_dedicated.lanes";
export const DEDICATED_LANES_DEFAULT = ["merge-conductor", "blocked-resolver"];
// A dedicated row of these lanes never falls back to the Fly fleet: the hub
// takes it back itself when the box goes silent (bin/lib/mc/project-placement.sh).
const NO_FALLBACK_LANES = new Set(["merge-conductor"]);
const PREFIX = "lane_placement.";
const BOX_RE = /^box:[a-z0-9][a-z0-9._-]{0,63}$/;
// The shell's _setting_key_ok (bin/lib/jobs/settings.sh): a key the hub can read.
const KEY_RE = /^[a-z0-9_.-]{1,64}$/;
// Every lane_placement.* key sorts in [prefix, prefix + '~'): the settings
// primary key serves the range.
// The allow-list row is the one key outside the range, in the same statement.
const ROWS_SQL = "SELECT key, value FROM settings WHERE (key >= ?1 AND key < ?2) OR key = ?3";
// The shell's normalisation (tr -d '[:space:]' | tr 'A-Z' 'a-z'): ASCII only.
const norm = (raw) => String(raw ?? "").replace(/\s/g, "").replace(/[A-Z]/g, (c) => c.toLowerCase());

// parseBoxValue <raw> -> the box name, or null when the value is not box:<name>.
export function parseBoxValue(raw) {
  const v = norm(raw);
  return BOX_RE.test(v) ? v.slice(4) : null;
}

// dedicatedLanesOf <raw|undefined> -> the lanes that may be placed fly-dedicated.
export function dedicatedLanesOf(raw) {
  if (raw === undefined || raw === null) return [...DEDICATED_LANES_DEFAULT];
  return norm(raw).split(",").filter((l) => l !== "" && laneName(l) === l);
}

// boxNameOf <raw> -> a claim's `box` field as a box name, or null when invalid.
export const boxNameOf = (raw) => (typeof raw === "string" ? parseBoxValue(`box:${raw}`) : null);

const hubOnlyOf = (byKey, lane) => {
  const v = byKey.get(`${PREFIX}${lane}.hub_only`);
  return v !== undefined && v !== null && String(v).replace(/\n+$/, "") !== "";
};
// projectRows <byKey> <lane> -> [[project, value]] of the lane's valid project rows.
function projectRows(byKey, lane) {
  const head = `${PREFIX}${lane}.`;
  const out = [];
  for (const [key, value] of byKey) {
    if (!key.startsWith(head) || !KEY_RE.test(key)) continue;
    const project = key.slice(head.length);
    if (project === "hub_only" || laneName(project) !== project) continue;
    out.push([project, value]);
  }
  return out;
}

// placementsFrom <rows [{key, value}]> -> { boxes, except, fallback }:
//   boxes    Map "lane|project" (or "lane|*", a dedicated lane row) -> box name
//   except   the "lane|project" keys a "lane|*" key does not cover
//   fallback the dedicated keys whose rows fall back to the Fly fleet
export function placementsFrom(rows) {
  const byKey = new Map(rows.map((r) => [r.key, r.value]));
  const boxes = new Map();
  const except = [];
  const fallback = [];
  for (const lane of BOX_LANES) {
    if (hubOnlyOf(byKey, lane)) continue;
    for (const [project, value] of projectRows(byKey, lane)) {
      const box = parseBoxValue(value);
      if (box !== null) boxes.set(`${lane}|${project}`, box);
    }
  }
  for (const lane of new Set(dedicatedLanesOf(byKey.get(DEDICATED_LANES_KEY)))) {
    if (hubOnlyOf(byKey, lane)) continue;
    const add = (k) => { boxes.set(k, DEDICATED_BOX); if (!NO_FALLBACK_LANES.has(lane)) fallback.push(k); };
    const wild = norm(byKey.get(`${PREFIX}${lane}`)) === DEDICATED_BOX;
    if (wild) add(`${lane}|*`);
    for (const [project, value] of projectRows(byKey, lane)) {
      if (norm(value) === DEDICATED_BOX) add(`${lane}|${project}`);
      else if (wild) except.push(`${lane}|${project}`);
    }
  }
  return { boxes, except, fallback };
}

// boxPlacementsFrom <rows> -> the Map of placementsFrom (BH-7636's shape).
export const boxPlacementsFrom = (rows) => placementsFrom(rows).boxes;

// placementOf <placements> <lane> <project> -> the box of a (lane, project)
// row, or null: the rule the claim SQL applies (boxMatch below).
export function placementOf({ boxes, except }, lane, project) {
  const k = `${lane}|${project}`;
  if (boxes.has(k)) return boxes.get(k);
  if (boxes.has(`${lane}|*`) && !except.includes(k)) return boxes.get(`${lane}|*`);
  return null;
}

// readBoxPlacements <env> -> placementsFrom, in ONE settings read.
export async function readBoxPlacements(env) {
  const rows = (await env.DB.prepare(ROWS_SQL).bind(PREFIX, `${PREFIX}~`, DEDICATED_LANES_KEY).all()).results || [];
  return placementsFrom(rows);
}

// The keys as a JSON array, or null when there are none.
const keysJson = (keys) => (keys.length > 0 ? JSON.stringify([...keys].sort()) : null);
export const boxKeysFor = ({ boxes }, box) => keysJson([...boxes].filter(([, b]) => b === box).map(([k]) => k));
export const allBoxKeys = ({ boxes }) => keysJson([...boxes.keys()]);
export const exceptKeys = ({ except }) => keysJson(except);
export const fallbackKeys = ({ fallback }) => keysJson(fallback);

// boxMatch <list bind> <except bind> -> the SQL test "this row is routed by a
// key of <list>": its exact "lane|project" key, or its "lane|*" key when the
// project is not an exception. Every list is json_each over at most a few
// dozen keys, the shape of the prefix tests next to it.
export const boxMatch = (list, ex) => `((lane || '|' || project) IN (SELECT value FROM json_each(${list}))
       OR ((lane || '|*') IN (SELECT value FROM json_each(${list}))
           AND (${ex} IS NULL OR (lane || '|' || project) NOT IN (SELECT value FROM json_each(${ex})))))`;
