// prompt-history routes — BH-7972 (BH-7940.4): the version list, restore and
// drop head for one (scope, project, kind). docs/PROMPTS.md, "Markers, versions
// and restore". The store is src/lib/prompt-store.js; a restore saves through
// saveVersion, so the same marker lint, size cap and 409 apply.
//
// Fragment test/route-table.d/bh-7940-prompt-history.txt sorts before
// bh-7940-prompts.txt, so GET …/versions matches here before the contract's
// GET …/:version matcher answers 400 for it. Bearer-gated like every family in
// route-table.d. A missing table is a 503 (d1Guarded).

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { parsePromptKey, saveVersion, readVersion } from "../lib/prompt-store.js";

const VERSION_RE = /^[1-9][0-9]{0,8}$/;
// The documented fallback when the prompts.versions_list_max row is absent or
// not a whole number in 1..1000.
const LIST_MAX_FALLBACK = 200;

// Every statement these routes run, so the EXPLAIN test plans the same text.
export const PROMPT_HISTORY_SQL = Object.freeze({
  listVersions: "SELECT id, version, author, note, created_at FROM prompt_versions "
    + "WHERE scope = ?1 AND project = ?2 AND kind = ?3 ORDER BY version DESC LIMIT ?4",
  maxVersion: "SELECT MAX(version) AS m FROM prompt_versions WHERE scope = ?1 AND project = ?2 AND kind = ?3",
  dropHead: "DELETE FROM prompt_heads WHERE scope = ?1 AND project = ?2 AND kind = ?3",
});

async function listMax(env) {
  const row = (await settingsRows(env)).byKey.get("prompts.versions_list_max");
  const v = row ? String(row.value).trim() : "";
  if (!/^[1-9][0-9]*$/.test(v)) return LIST_MAX_FALLBACK;
  const n = Number(v);
  return n <= 1000 ? n : LIST_MAX_FALLBACK;
}

export const routes = [
  // Newest first, no body column.
  [
    "GET", /^\/api\/prompts\/([^/]+)\/([^/]+)\/versions$/,
    ({ env, url, m }) => d1Guarded("prompt_versions", async () => {
      const key = parsePromptKey(url, { scope: m[1], kind: m[2] });
      if (key instanceof Response) return key;
      const limit = await listMax(env);
      const { results } = await env.DB.prepare(PROMPT_HISTORY_SQL.listVersions)
        .bind(key.scope, key.project, key.kind, limit).all();
      const versions = (results || []).map((r) => ({
        id: Number(r.id), version: Number(r.version), author: r.author, note: r.note, created_at: r.created_at,
      }));
      return json(200, { ...key, versions, limit });
    }),
  ],

  // ?version=n, body {author}: save version n's body as the next version.
  [
    "POST", /^\/api\/prompts\/([^/]+)\/([^/]+)\/restore$/,
    ({ env, url, m, body }) => d1Guarded("prompt_versions", async () => {
      const key = parsePromptKey(url, { scope: m[1], kind: m[2] });
      if (key instanceof Response) return key;
      const raw = url.searchParams.get("version") ?? "";
      if (!VERSION_RE.test(raw)) return json(400, { error: "version must be a whole number >= 1" });
      if (!body || typeof body !== "object" || Array.isArray(body)) return json(400, { error: "send a JSON object" });
      if (typeof body.author !== "string" || body.author.trim() === "") return json(400, { error: "author must be a non-blank string" });
      const n = Number(raw);
      const row = await readVersion(env, { ...key, version: n });
      if (!row) {
        // Versions are numbered 1..MAX with no gap, so a missing n at or
        // below MAX is one the retention rule moved to the archive.
        const max = await env.DB.prepare(PROMPT_HISTORY_SQL.maxVersion).bind(key.scope, key.project, key.kind).first("m");
        return json(404, { error: max !== null && max !== undefined && n <= Number(max) ? "archived" : "not_found" });
      }
      const saved = await saveVersion(env, { ...key, body: row.body, author: body.author, note: `restored from v${n}` });
      return saved instanceof Response ? saved : json(201, { ...saved, restored_from: n });
    }),
  ],

  // Drop this level's head; the versions stay. The level above takes over.
  [
    "DELETE", /^\/api\/prompts\/([^/]+)\/([^/]+)\/head$/,
    ({ env, url, m }) => d1Guarded("prompt_heads", async () => {
      const key = parsePromptKey(url, { scope: m[1], kind: m[2] });
      if (key instanceof Response) return key;
      const res = await env.DB.prepare(PROMPT_HISTORY_SQL.dropHead).bind(key.scope, key.project, key.kind).run();
      return json(200, { ...key, dropped: Number((res.meta && res.meta.changes) || 0) });
    }),
  ],
];
