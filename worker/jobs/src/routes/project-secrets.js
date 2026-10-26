// Project secret NAMES — the manifest bin/project-secrets.sh keeps for each
// project's build secrets (BH-8317, MKF-2). The values live only in Fly app
// secrets, which the hub can set and never read back; this table holds the
// names, the apps each one was staged into, and when delivery was proved.
// Note: docs/notes/2026-10-25-BH-8317-secret-store.md.
//
// GET    /api/project-secrets/names?project=P   ONE batch of 3 reads:
//   200 {project, names:[{name,apps,need,set_at,set_by,digest}], pending,
//   limit, truncated}. A project with no rows is 200 with names:[]. Cap:
//   settings project_secrets.list_limit (1..5000, else 500).
// PUT    /api/project-secrets/names {project,name,apps,need?,set_by,digest?,stamp?}
//   upsert + one config_changes row (kind project_secret) in ONE batch.
//   stamp:true sets set_at; otherwise set_at keeps the old value (NULL on a
//   new row). A body with a `value` or `secret` field is 400. 200 {project,name,set_at}.
// DELETE /api/project-secrets/names?project=P&name=N[&actor=A]
//   delete + one config_changes row (after_json 'null') in ONE batch. No row is 404.
//
// No error text here repeats a project, a name, an app or anything a body carried.
import { d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

export const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
// R1, the same rule as name_ok in bin/project-secrets.sh.
const NAME_RE = /^[A-Z_][A-Z0-9_]{0,127}$/;
const NAME_RESERVED = new Set(["GH_TOKEN", "GH_TOKEN_INSTALLATION_ID"]);
const NAME_RESERVED_PREFIX = ["HBUNDLE_", "SEED_", "FLY_"];
const APP_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;
const ACTOR_RE = /^[A-Za-z0-9._@:+-]{1,128}$/;
const DIGEST_MAX = 128;
const NEEDS = ["required", "optional"];
const AUDIT_FIELDS = ["apps", "need", "set_at", "digest"];
// Fallback of the settings row project_secrets.list_limit
// (schema.d 202610260157-bh-8317-project-secret-names.sql).
const LIST_LIMIT_DEFAULT = 500;
const LIST_LIMIT_MAX = 5000;

const noStore = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
});

// The three reads of GET, exported for the EXPLAIN test.
export const LIMIT_SQL = "SELECT value FROM settings WHERE key = 'project_secrets.list_limit'";
// The PRIMARY KEY (project, name) serves the range and the ORDER BY. The cap
// is the same rule as listLimitFrom, plus one row so `truncated` is measured.
export const LIST_SQL =
  "SELECT project, name, apps, need, set_at, set_by, digest FROM project_secret_names WHERE project = ?1 ORDER BY name "
  + "LIMIT COALESCE((SELECT CAST(trim(value) AS INTEGER) FROM settings WHERE key = 'project_secrets.list_limit' "
  + `AND trim(value) <> '' AND trim(value) NOT GLOB '*[^0-9]*' AND CAST(trim(value) AS INTEGER) BETWEEN 1 AND ${LIST_LIMIT_MAX}), ${LIST_LIMIT_DEFAULT}) + 1`;
// ix_project_secret_names_project_set_at.
export const PENDING_SQL =
  "SELECT COUNT(*) AS n FROM project_secret_names WHERE project = ?1 AND set_at IS NULL";
const ROW_SQL =
  "SELECT project, name, apps, need, set_at, set_by, digest FROM project_secret_names WHERE project = ?1 AND name = ?2";

// checkSecretName(raw) -> {ok:true, value} | {ok:false, message}. The message
// never contains the name.
export function checkSecretName(raw) {
  const value = typeof raw === "string" ? raw : "";
  if (!value) return { ok: false, message: "name is required" };
  if (!NAME_RE.test(value)) {
    return { ok: false, message: "name must be upper-case letters, digits and _ (at most 128), not starting with a digit" };
  }
  if (NAME_RESERVED.has(value) || NAME_RESERVED_PREFIX.some((p) => value.startsWith(p))) {
    return { ok: false, message: "name is reserved: the pool owns the two GitHub token names and the bundle, seed and Fly prefixes" };
  }
  return { ok: true, value };
}

// checkApps(raw) -> {ok:true, value:[...]} deduped, order kept | {ok:false, message}.
export function checkApps(raw) {
  if (!Array.isArray(raw) || raw.length === 0) return { ok: false, message: "apps must be a non-empty array of Fly app names" };
  const out = [];
  for (const a of raw) {
    if (typeof a !== "string" || !APP_RE.test(a)) {
      return { ok: false, message: "apps must hold Fly app names: lower-case letters, digits and - (at most 63)" };
    }
    if (!out.includes(a)) out.push(a);
  }
  return { ok: true, value: out };
}

function checkDigest(raw) {
  if (raw === undefined || raw === null) return { ok: true, value: null };
  if (typeof raw !== "object" || Array.isArray(raw)) return { ok: false, message: "digest must be an object of app -> digest" };
  for (const [k, v] of Object.entries(raw)) {
    if (!APP_RE.test(k) || typeof v !== "string" || v.length > DIGEST_MAX) {
      return { ok: false, message: `digest must map Fly app names to digests of at most ${DIGEST_MAX} chars` };
    }
  }
  return { ok: true, value: raw };
}

// The same rule LIST_SQL applies in SQL, so `limit` is the cap that cut the rows.
function listLimitFrom(value) {
  const s = String(value ?? "").trim();
  if (!/^\d+$/.test(s)) return LIST_LIMIT_DEFAULT;
  const n = Number(s);
  return n >= 1 && n <= LIST_LIMIT_MAX ? n : LIST_LIMIT_DEFAULT;
}

const parseJson = (text) => {
  if (text === null || text === undefined) return null;
  try { return JSON.parse(text); } catch { return null; }
};

const rowOut = (r) => ({
  name: r.name,
  apps: parseJson(r.apps) || [],
  need: r.need,
  set_at: r.set_at,
  set_by: r.set_by,
  digest: parseJson(r.digest),
});

async function ensureTables(env) {
  await ensureTable(env, "project_secret_names");
  await ensureTable(env, "config_changes");
}

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

export const routes = [
  [
    "GET", "/api/project-secrets/names",
    ({ env, url }) => d1Guarded("project_secret_names", async () => {
      const project = url.searchParams.get("project") || "";
      if (!PROJECT_RE.test(project)) return noStore(400, { error: "project must be a project key: lower-case letters, digits and . _ -" });
      await ensureTables(env);
      const db = env.DB;
      const [limitRes, listRes, pendingRes] = await db.batch([
        db.prepare(LIMIT_SQL),
        db.prepare(LIST_SQL).bind(project),
        db.prepare(PENDING_SQL).bind(project),
      ]);
      const limit = listLimitFrom(limitRes.results?.[0]?.value);
      const rows = listRes.results || [];
      return noStore(200, {
        project,
        names: rows.slice(0, limit).map(rowOut),
        pending: Number(pendingRes.results?.[0]?.n) || 0,
        limit,
        truncated: rows.length > limit,
      });
    }),
  ],
  [
    "PUT", "/api/project-secrets/names",
    ({ env, t, body }) => d1Guarded("project_secret_names", async () => {
      const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
      if (has(b, "value") || has(b, "secret")) return noStore(400, { error: "this route stores names only: send the value to Fly, never here" });
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) {
        return noStore(400, { error: "project must be a project key: lower-case letters, digits and . _ -" });
      }
      const nc = checkSecretName(b.name);
      if (!nc.ok) return noStore(400, { error: nc.message });
      const ac = checkApps(b.apps);
      if (!ac.ok) return noStore(400, { error: ac.message });
      if (b.need !== undefined && !NEEDS.includes(b.need)) return noStore(400, { error: "need must be required or optional" });
      if (typeof b.set_by !== "string" || !ACTOR_RE.test(b.set_by)) {
        return noStore(400, { error: "set_by must be 1 to 128 of letters, digits and . _ @ : + -" });
      }
      const dc = checkDigest(b.digest);
      if (!dc.ok) return noStore(400, { error: dc.message });
      if (b.stamp !== undefined && typeof b.stamp !== "boolean") return noStore(400, { error: "stamp must be true or false" });
      await ensureTables(env);
      const db = env.DB;
      const was = await db.prepare(ROW_SQL).bind(b.project, nc.value).first();
      const after = {
        apps: JSON.stringify(ac.value),
        need: b.need ?? was?.need ?? "required",
        set_at: b.stamp === true ? t : (was?.set_at ?? null),
        digest: dc.value ? JSON.stringify(dc.value) : (was?.digest ?? null),
      };
      await db.batch([
        db.prepare(
          "INSERT INTO project_secret_names (project, name, apps, need, set_at, set_by, digest, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) "
          + "ON CONFLICT(project, name) DO UPDATE SET apps = excluded.apps, need = excluded.need, set_at = excluded.set_at, "
          + "set_by = excluded.set_by, digest = excluded.digest, updated_at = excluded.updated_at",
        ).bind(b.project, nc.value, after.apps, after.need, after.set_at, b.set_by, after.digest, t),
        ...configChangeStmts(env, CONFIG_KINDS.PROJECT_SECRET, `${b.project}/${nc.value}`, was, after, AUDIT_FIELDS, b.set_by, null, t),
      ]);
      return noStore(200, { project: b.project, name: nc.value, set_at: after.set_at });
    }),
  ],
  [
    "DELETE", "/api/project-secrets/names",
    ({ env, t, url }) => d1Guarded("project_secret_names", async () => {
      const project = url.searchParams.get("project") || "";
      if (!PROJECT_RE.test(project)) return noStore(400, { error: "project must be a project key: lower-case letters, digits and . _ -" });
      const nc = checkSecretName(url.searchParams.get("name") || "");
      if (!nc.ok) return noStore(400, { error: nc.message });
      const actorIn = url.searchParams.get("actor") || "";
      const actor = ACTOR_RE.test(actorIn) ? actorIn : "api";
      await ensureTables(env);
      const db = env.DB;
      const was = await db.prepare(ROW_SQL).bind(project, nc.value).first();
      if (!was) return noStore(404, { error: "no manifest row for that project and name" });
      await db.batch([
        db.prepare("DELETE FROM project_secret_names WHERE project = ?1 AND name = ?2").bind(project, nc.value),
        ...configChangeStmts(env, CONFIG_KINDS.PROJECT_SECRET, `${project}/${nc.value}`, was, null, AUDIT_FIELDS, actor, null, t),
      ]);
      return noStore(200, { deleted: true });
    }),
  ],
];
