// registry write routes — per-row, audited writes to the fleet registry
// (BH-5650, slice 2 of BH-5633). bin/registry.sh calls them; the read routes,
// the bulk import, validateRegistry and applyRegistry live in registry.js.
//
// Each one: the admin gate (403) before any read, then read the whole
// registry, change a copy, validate the WHOLE copy (a project's box needs a
// boxes row, positions stay unique), and applyRegistry with deletes. One
// request = one batch = at most one version bump.

import { d1Guarded, json } from "../lib/http.js";
import {
  ACTOR_RE, BOX_GLOB_RE, HOST_RE, ID_RE, SLUG_RE, TABLES,
  applyRegistry, canon, isObj, keyOf, readAll, readMeta, registryAdminOk, tooLarge, validateRegistry,
} from "./registry.js";

const PROJECT_FIELDS = ["repo", "prod", "board_prefix", "cron_offset", "box", "position", "status"];
const BOX_PATCH_FIELDS = ["tailnet_ip", "cost_box", "standby_hub_name", "standby_hub_id", "role"];

// A segment of the path, URL-decoded and checked; null = refuse it.
function seg(raw, re) {
  let v;
  try { v = decodeURIComponent(raw); } catch { return null; }
  return re.test(v) ? v : null;
}

// Fields of `body` outside `allowed` (actor is always allowed).
const unknownFields = (body, allowed) => Object.keys(body).filter((k) => k !== "actor" && !allowed.includes(k));

// mutate(next, have) changes `next` in place and returns nothing, or returns
// a Response (an error answer) and nothing is written.
async function registryWrite({ req, env, t, body }, mutate) {
  return d1Guarded("registry", async () => {
    if (!registryAdminOk(req, env)) {
      return json(403, { error: "registry writes need the registry admin token (x-registry-admin-token)" });
    }
    if (!isObj(body)) return json(400, { error: "body must be a JSON object" });
    let actor = "registry-api";
    if (body.actor !== undefined) {
      if (typeof body.actor !== "string" || !ACTOR_RE.test(body.actor)) return json(400, { error: "actor must be 1-64 letters, digits, dots, dashes or underscores" });
      actor = body.actor;
    }
    const meta = await readMeta(env);
    const have = await readAll(env);
    if (tooLarge(have)) return json(507, { error: "registry too large" });
    const next = structuredClone(have);
    const refused = mutate(next, have);
    if (refused) return refused;
    const checked = validateRegistry({ ...next, actor });
    if (checked.error) return json(400, { error: checked.error });
    const r = await applyRegistry(env, t, actor, have, meta, checked.value, { deletes: true });
    return json(200, { ok: true, changed: r.changed, version: r.version });
  });
}

const SEG = "([^/]+)";
const reOf = (tail) => new RegExp(`^\\/api\\/registry\\/${tail}$`);

export const routes = [
  [
    "POST", "/api/registry/projects",
    async (ctx) => registryWrite(ctx, (next) => {
      const b = ctx.body;
      const bad = unknownFields(b, ["project", ...PROJECT_FIELDS]);
      if (bad.length) return json(400, { error: `unknown field(s): ${bad.join(", ")}` });
      const at = next.projects.findIndex((p) => p.project === b.project);
      const position = b.position !== undefined ? b.position
        : at >= 0 ? next.projects[at].position
          : next.projects.reduce((m, p) => Math.max(m, p.position + 1), 0);
      const row = { project: b.project, repo: b.repo, prod: b.prod, board_prefix: b.board_prefix, cron_offset: b.cron_offset, box: b.box ?? null, position, status: b.status ?? "active" };
      if (at >= 0) {
        if (canon(TABLES.projects, next.projects[at]) !== canon(TABLES.projects, row)) {
          return json(409, { error: `project ${b.project} exists with different fields; PATCH it` });
        }
        return null;
      }
      next.projects.push(row);
      return null;
    }),
  ],

  [
    "PATCH", reOf(`projects\\/${SEG}`),
    async (ctx) => registryWrite(ctx, (next) => {
      const name = seg(ctx.m[1], SLUG_RE);
      if (!name) return json(400, { error: "the project in the path is not a project name" });
      const bad = unknownFields(ctx.body, PROJECT_FIELDS);
      if (bad.length) return json(400, { error: `unknown or unpatchable field(s): ${bad.join(", ")}` });
      const fields = Object.keys(ctx.body).filter((k) => k !== "actor");
      if (!fields.length) return json(400, { error: `nothing to change; fields: ${PROJECT_FIELDS.join(", ")}` });
      const row = next.projects.find((p) => p.project === name);
      if (!row) return json(404, { error: `no project ${name}` });
      for (const f of fields) row[f] = ctx.body[f];
      return null;
    }),
  ],

  [
    "DELETE", reOf(`projects\\/${SEG}`),
    async (ctx) => registryWrite(ctx, (next) => {
      const name = seg(ctx.m[1], SLUG_RE);
      if (!name) return json(400, { error: "the project in the path is not a project name" });
      const at = next.projects.findIndex((p) => p.project === name);
      if (at < 0) return json(404, { error: `no project ${name}` });
      next.projects.splice(at, 1);
      return null;
    }),
  ],

  [
    "POST", "/api/registry/boxes",
    async (ctx) => registryWrite(ctx, (next, have) => {
      const b = ctx.body;
      const bad = unknownFields(b, ["box", "box_id", "like", ...BOX_PATCH_FIELDS]);
      if (bad.length) return json(400, { error: `unknown field(s): ${bad.join(", ")}` });
      const row = {
        box: b.box, box_id: b.box_id, tailnet_ip: b.tailnet_ip ?? null,
        cost_box: b.cost_box === undefined ? b.box_id ?? null : b.cost_box,
        standby_hub_name: b.standby_hub_name ?? null, standby_hub_id: b.standby_hub_id ?? null,
        role: b.role ?? null,
      };
      // `like` is read from the registry BEFORE this write: the copy is of an
      // existing box, never of the row this request adds.
      let like = null;
      if (b.like !== undefined) {
        if (typeof b.like !== "string" || !ID_RE.test(b.like)) return json(400, { error: "like must be an existing box_id" });
        like = have.boxes.find((x) => x.box_id === b.like);
        if (!like) return json(404, { error: `like: no box has box_id ${b.like}` });
      }
      const at = next.boxes.findIndex((x) => x.box === row.box);
      if (at >= 0) {
        if (canon(TABLES.boxes, next.boxes[at]) !== canon(TABLES.boxes, row)) {
          return json(409, { error: `box ${row.box} exists with different fields; PATCH it` });
        }
      } else {
        next.boxes.push(row);
      }
      if (!like) return null;
      // Lane membership: every lane of the like box_id. Rows already there
      // are not added twice, so a retried add-box changes nothing.
      const lanes = new Set(next.lane_boxes.map((l) => `${l.lane}/${l.box_id}`));
      for (const l of have.lane_boxes) {
        if (l.box_id !== like.box_id || lanes.has(`${l.lane}/${row.box_id}`)) continue;
        next.lane_boxes.push({ lane: l.lane, box_id: row.box_id });
        lanes.add(`${l.lane}/${row.box_id}`);
      }
      // Accounts: rows naming the like box EXACTLY by name, id or cost name,
      // mapped to the new box's value of the same kind. A glob (pool-*) is
      // never an exact match, so it is never copied.
      const map = new Map();
      if (like.cost_box !== null && row.cost_box !== null) map.set(like.cost_box, row.cost_box);
      map.set(like.box_id, row.box_id);
      map.set(like.box, row.box);
      const accounts = new Set(next.box_accounts.map((a) => keyOf(TABLES.box_accounts, a)));
      for (const a of have.box_accounts) {
        if (!map.has(a.box)) continue;
        const copy = { account: a.account, kind: a.kind, box: map.get(a.box) };
        const k = keyOf(TABLES.box_accounts, copy);
        if (accounts.has(k)) continue;
        next.box_accounts.push(copy);
        accounts.add(k);
      }
      return null;
    }),
  ],

  [
    "PATCH", reOf(`boxes\\/${SEG}`),
    async (ctx) => registryWrite(ctx, (next) => {
      const name = seg(ctx.m[1], HOST_RE);
      if (!name) return json(400, { error: "the box in the path is not a box name" });
      if (ctx.body.box_id !== undefined) return json(400, { error: "box_id cannot be patched: add a new box and move the projects" });
      const bad = unknownFields(ctx.body, BOX_PATCH_FIELDS);
      if (bad.length) return json(400, { error: `unknown or unpatchable field(s): ${bad.join(", ")}` });
      const fields = Object.keys(ctx.body).filter((k) => k !== "actor");
      if (!fields.length) return json(400, { error: `nothing to change; fields: ${BOX_PATCH_FIELDS.join(", ")}` });
      const row = next.boxes.find((x) => x.box === name);
      if (!row) return json(404, { error: `no box ${name}` });
      for (const f of fields) row[f] = ctx.body[f];
      return null;
    }),
  ],

  [
    "DELETE", reOf(`boxes\\/${SEG}`),
    async (ctx) => registryWrite(ctx, (next) => {
      const name = seg(ctx.m[1], HOST_RE);
      if (!name) return json(400, { error: "the box in the path is not a box name" });
      const at = next.boxes.findIndex((x) => x.box === name);
      if (at < 0) return json(404, { error: `no box ${name}` });
      const id = next.boxes[at].box_id;
      const projects = next.projects.filter((p) => p.box === name).map((p) => p.project);
      const lanes = next.lane_boxes.filter((l) => l.box_id === id).map((l) => l.lane);
      if (projects.length || lanes.length) {
        return json(409, { error: `box ${name} is still in use: move its projects and drain it first`, projects, lanes });
      }
      next.boxes.splice(at, 1);
      return null;
    }),
  ],

  [
    "POST", reOf(`boxes\\/${SEG}\\/drain`),
    async (ctx) => registryWrite(ctx, (next) => {
      const name = seg(ctx.m[1], HOST_RE);
      if (!name) return json(400, { error: "the box in the path is not a box name" });
      const row = next.boxes.find((x) => x.box === name);
      if (!row) return json(404, { error: `no box ${name}` });
      const projects = next.projects.filter((p) => p.box === name && p.status === "active").map((p) => p.project);
      if (projects.length) {
        return json(409, { error: `box ${name} still runs ${projects.join(", ")}: move them first`, projects });
      }
      next.lane_boxes = next.lane_boxes.filter((l) => l.box_id !== row.box_id);
      return null;
    }),
  ],

  [
    "POST", "/api/registry/lane-boxes",
    async (ctx) => registryWrite(ctx, (next) => {
      const bad = unknownFields(ctx.body, ["lane", "box_id"]);
      if (bad.length) return json(400, { error: `unknown field(s): ${bad.join(", ")}` });
      const { lane, box_id } = ctx.body;
      if (!next.lane_boxes.some((l) => l.lane === lane && l.box_id === box_id)) next.lane_boxes.push({ lane, box_id });
      return null;
    }),
  ],

  [
    "DELETE", reOf(`lane-boxes\\/${SEG}\\/${SEG}`),
    async (ctx) => registryWrite(ctx, (next) => {
      const lane = seg(ctx.m[1], ID_RE);
      const id = seg(ctx.m[2], ID_RE);
      if (!lane || !id) return json(400, { error: "the path must be /api/registry/lane-boxes/<lane>/<box_id>" });
      const at = next.lane_boxes.findIndex((l) => l.lane === lane && l.box_id === id);
      if (at < 0) return json(404, { error: `no lane membership ${lane}/${id}` });
      next.lane_boxes.splice(at, 1);
      return null;
    }),
  ],

  [
    "POST", "/api/registry/box-accounts",
    async (ctx) => registryWrite(ctx, (next) => {
      const bad = unknownFields(ctx.body, ["account", "kind", "box"]);
      if (bad.length) return json(400, { error: `unknown field(s): ${bad.join(", ")}` });
      const { account, kind, box } = ctx.body;
      if (!next.box_accounts.some((a) => a.account === account && a.kind === kind && a.box === box)) next.box_accounts.push({ account, kind, box });
      return null;
    }),
  ],

  [
    "DELETE", reOf(`box-accounts\\/${SEG}\\/${SEG}\\/${SEG}`),
    async (ctx) => registryWrite(ctx, (next) => {
      const account = seg(ctx.m[1], ID_RE);
      const kind = seg(ctx.m[2], /^[a-z_]{1,16}$/);
      const box = seg(ctx.m[3], BOX_GLOB_RE);
      if (!account || !kind || !box) return json(400, { error: "the path must be /api/registry/box-accounts/<account>/<kind>/<box>" });
      const at = next.box_accounts.findIndex((a) => a.account === account && a.kind === kind && a.box === box);
      if (at < 0) return json(404, { error: `no box account ${account}/${kind}/${box}` });
      next.box_accounts.splice(at, 1);
      return null;
    }),
  ],
];

