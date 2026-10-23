// prompts routes — BH-7969 (BH-7940.0): prompt overrides as immutable versions
// with one head per (scope, project, kind). The store is src/lib/prompt-store.js
// and docs/PROMPTS.md has the model. bin/prompt-resolve.sh reads the list and a
// version; the console reaches these routes only through
// console-ui/functions/api/prompts/[[path]].js. Bearer-gated like every family
// in route-table.d. A missing table is a 503 (d1Guarded), never an empty list.

import { json, d1Guarded } from "../lib/http.js";
import { PROJECT_RE, parsePromptKey, saveVersion, readVersion, listHeads } from "../lib/prompt-store.js";

const VERSION_RE = /^[1-9][0-9]{0,8}$/;

export const routes = [
  // Seven rows, one per kind. No project (or '') lists fleet and repo only.
  [
    "GET", "/api/prompts",
    ({ env, url, t }) => d1Guarded("prompt_versions", async () => {
      const project = url.searchParams.get("project") ?? "";
      if (project !== "" && !PROJECT_RE.test(project)) return json(400, { error: "project must match [A-Za-z0-9][A-Za-z0-9._-]{0,99}" });
      return json(200, { project, prompts: await listHeads(env, project), as_of: t });
    }),
  ],

  // One version with its body.
  [
    "GET", /^\/api\/prompts\/([^/]+)\/([^/]+)\/([^/]+)$/,
    ({ env, url, m }) => d1Guarded("prompt_versions", async () => {
      const key = parsePromptKey(url, { scope: m[1], kind: m[2] });
      if (key instanceof Response) return key;
      if (!VERSION_RE.test(m[3])) return json(400, { error: "version must be a whole number >= 1" });
      const prompt = await readVersion(env, { ...key, version: Number(m[3]) });
      return prompt ? json(200, { prompt }) : json(404, { error: "not_found" });
    }),
  ],

  // Save {body, author, note?, base_version?} as the next version and move the head.
  [
    "POST", /^\/api\/prompts\/([^/]+)\/([^/]+)$/,
    ({ env, url, m, body }) => d1Guarded("prompt_versions", async () => {
      const key = parsePromptKey(url, { scope: m[1], kind: m[2] });
      if (key instanceof Response) return key;
      if (!body || typeof body !== "object" || Array.isArray(body)) return json(400, { error: "send a JSON object" });
      const saved = await saveVersion(env, { ...key, body: body.body, author: body.author, note: body.note, base_version: body.base_version });
      return saved instanceof Response ? saved : json(201, saved);
    }),
  ],
];
