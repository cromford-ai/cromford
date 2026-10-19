// Lane-run fleet groups (BH-7434). A group is ONE settings row
//   lane_fleet.group.<name> = {app, vm_size, vm_memory, max_machines,
//                              warm_floor, projects:[...]}
// bin/lane-fleet.sh runs one scale pass per group against the group's own Fly
// app; a machine of the group claims only the group's projects
// (only_prefixes), and the default `lane-run` fleet skips them. No row = no
// group = today's single fleet. The worker reads and validates the rows here,
// in one place, for the claim, the stats and the groups routes.
//
// A row that does not validate groups nothing: its projects stay with the
// default fleet, and GET /api/lane-fleet/groups names it under `invalid`.
//   name        the key suffix, [a-z0-9][a-z0-9-]{0,29}
//   app         lane-run-[a-z0-9][a-z0-9-]{0,39}, unique across groups (the
//               prefix is what catalog/fly-idle-signals.json matches)
//   projects    1..64 project names, each in at most one group (rows are
//               read in key order; a later row that repeats a project is invalid)
//   vm_size     optional, [a-z0-9-]{1,40}
//   vm_memory   optional, MB, 256..65536
//   max_machines REQUIRED, 1..1000: a group app always has a ceiling (the
//               global lane_fleet.max_machines default is 0 = none, and a
//               performance-class app without one is an open spend)
//   warm_floor  optional, 0..100; absent = the global lane_fleet.warm_floor
//               (seed 1 = one machine started 24/7), so set 0 for a costly app
// Absent optional fields answer null: the hub uses the lane_fleet.* rows.

import { laneName } from "./core.js";

export const GROUP_KEY_PREFIX = "lane_fleet.group.";
const NAME_RE = /^[a-z0-9][a-z0-9-]{0,29}$/;
const APP_RE = /^lane-run-[a-z0-9][a-z0-9-]{0,39}$/;
const SIZE_RE = /^[a-z0-9-]{1,40}$/;
const PROJECTS_MAX = 64;
export const FALLBACK_KEY = "lane_run.group_fallback_s";
export const FALLBACK_DEFAULT_S = 900;
const FALLBACK_MAX_S = 86400;
// Every key with the prefix sorts in [prefix, prefix + '~'): key characters are
// below '~'. The settings primary key serves the range.
const ROWS_SQL = `SELECT key, value FROM settings
  WHERE (key >= ?1 AND key < ?2) OR key = ?3 ORDER BY key`;

const intIn = (v, lo, hi) => (Number.isInteger(v) && v >= lo && v <= hi ? v : undefined);

// optional <obj> <key> <check> -> { v } (null when absent) or { err }.
function optional(o, k, check) {
  if (o[k] === undefined || o[k] === null) return { v: null };
  const v = check(o[k]);
  return v === undefined ? { err: `${k} is out of range` } : { v };
}

// parseGroup <name> <raw value> <taken projects Set> <taken apps Set>
//   -> { group } or { err }.
export function parseGroup(name, raw, projects, apps) {
  if (!NAME_RE.test(name)) return { err: "name must match [a-z0-9][a-z0-9-]{0,29}" };
  let o;
  try { o = JSON.parse(raw); } catch { return { err: "value is not JSON" }; }
  if (!o || typeof o !== "object" || Array.isArray(o)) return { err: "value is not a JSON object" };
  if (typeof o.app !== "string" || !APP_RE.test(o.app)) return { err: "app must match lane-run-[a-z0-9][a-z0-9-]{0,39}" };
  if (apps.has(o.app)) return { err: `app ${o.app} is already another group's` };
  const p = o.projects;
  if (!Array.isArray(p) || p.length < 1 || p.length > PROJECTS_MAX || !p.every((x) => laneName(x) === x)) {
    return { err: `projects must be 1..${PROJECTS_MAX} project names` };
  }
  const dupe = p.find((x) => projects.has(x));
  if (dupe) return { err: `project ${dupe} is already another group's` };
  const f = {
    vm_size: optional(o, "vm_size", (v) => (typeof v === "string" && SIZE_RE.test(v) ? v : undefined)),
    vm_memory: optional(o, "vm_memory", (v) => intIn(v, 256, 65536)),
    max_machines: optional(o, "max_machines", (v) => intIn(v, 0, 1000)),
    warm_floor: optional(o, "warm_floor", (v) => intIn(v, 0, 100)),
  };
  const bad = Object.values(f).find((x) => x.err);
  if (bad) return { err: bad.err };
  if (f.max_machines.v === null || f.max_machines.v < 1) return { err: "max_machines is required, 1..1000" };
  return {
    group: {
      name, app: o.app, vm_size: f.vm_size.v, vm_memory: f.vm_memory.v,
      max_machines: f.max_machines.v, warm_floor: f.warm_floor.v, projects: [...new Set(p)],
    },
  };
}

// fallbackOf <raw|undefined> -> lane_run.group_fallback_s: digits 0..86400,
// else the code default. 0 = a grouped row never falls back.
function fallbackOf(raw) {
  const s = raw === undefined || raw === null ? "" : String(raw).trim();
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= 0 && n <= FALLBACK_MAX_S ? n : FALLBACK_DEFAULT_S;
}

// readGroups <env> -> { groups, invalid, fallback_s } in ONE settings read.
export async function readGroups(env) {
  const rows = (await env.DB.prepare(ROWS_SQL)
    .bind(GROUP_KEY_PREFIX, `${GROUP_KEY_PREFIX}~`, FALLBACK_KEY).all()).results || [];
  const groups = [];
  const invalid = [];
  const projects = new Set();
  const apps = new Set();
  let fallback;
  for (const r of rows) {
    if (r.key === FALLBACK_KEY) { fallback = r.value; continue; }
    const name = r.key.slice(GROUP_KEY_PREFIX.length);
    const g = parseGroup(name, String(r.value), projects, apps);
    if (g.err) { invalid.push({ name, error: g.err }); continue; }
    g.group.projects.forEach((x) => projects.add(x));
    apps.add(g.group.app);
    groups.push(g.group);
  }
  return { groups, invalid, fallback_s: fallbackOf(fallback) };
}

// The prefixes a project list claims: `<project>.`, compared with
// `project || '.'`, so it names the project and its `<project>.<pr>.<head>` rows.
export const prefixesOf = (projects) => projects.map((p) => `${p}.`);
