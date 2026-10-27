// onboarding repo routes — BH-7997 (BH-7935 wave 2, order 1): the console's
// "which repo?" step. The worker has no GitHub credential, so it files a
// hub-probe row and answers what that row holds; the hub reads GitHub through
// bin/lib/onboard-github.sh when it claims the row.
//
//   GET /api/onboarding/repo?slug=<owner/repo | https://github.com/owner/repo[.git][/...]>
//       400 for a slug parseRepoSlug refuses, before any D1 statement. Else one
//       repo-detect row per slug per minute (ticket_key onb-repo-<epoch/60>),
//       and the answer is the row's state:
//         {state:"pending"[, note]} | {state:"ok", visible:true, facts, install_url}
//         | {state:"ok", visible:false, install_url} | {state:"error", error}
//   GET /api/onboarding/repos
//       one app-installation-repos row per 10 minutes (onb-repos-<epoch/600>):
//         {state:"ok", repos:[full_name...], total_count, incomplete} or the
//         pending / error shapes above.
//
// THE CACHE IS THE LEDGER. hub_probe_requests' UNIQUE(project, ticket_key,
// probe, args_hash) makes a second GET in the same bucket read the first GET's
// row, so a polling screen costs GitHub one read per bucket. The buckets are the
// spec's cache windows, not business parameters, so they are constants here.
//
// fileScreenProbe is the one way an onboarding route files a row. It calls the
// POST /api/hub-probe handler itself (canonical args, sha256 args_hash, INSERT
// ON CONFLICT DO NOTHING + SELECT), so there is one copy of that SQL.
import { json, nowIso } from "../lib/http.js";
import { routes as hubProbeRoutes } from "./hub-probe.js";

const PROJECT = "onboarding";
const REPO_BUCKET_S = 60;
const REPOS_BUCKET_S = 600;
const SLUG_RAW_MAX = 2048;
const ERROR_MAX = 200;
const OWNER_RE = /^[A-Za-z0-9-]{1,39}$/;
const NAME_RE = /^[A-Za-z0-9_.-]{1,100}$/;
const URL_RE = /^https:\/\/github\.com\/([^/]+)\/([^/]+)(\/[^\s?#]*)?$/;
const BARE_RE = /^([^/]+)\/([^/]+)$/;
const FULL_NAME_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const BAD_SLUG = "slug must be owner/repo or https://github.com/owner/repo";

// {owner, repo, slug} for owner/repo or https://github.com/owner/repo[.git][/...]
// (trimmed, a trailing .git dropped), else null. Pure.
export function parseRepoSlug(raw) {
  if (typeof raw !== "string" || raw.length > SLUG_RAW_MAX) return null;
  const s = raw.trim();
  const m = s.startsWith("https://github.com/") ? URL_RE.exec(s) : BARE_RE.exec(s);
  if (!m) return null;
  const owner = m[1];
  const repo = m[2].endsWith(".git") ? m[2].slice(0, -4) : m[2];
  if (!OWNER_RE.test(owner) || !NAME_RE.test(repo) || repo === "." || repo === "..") return null;
  return { owner, repo, slug: `${owner}/${repo}` };
}

const handlerOf = (method, path) => hubProbeRoutes.find((r) => r[0] === method && r[1] === path)[2];
const fileHubProbe = handlerOf("POST", "/api/hub-probe");

// The stored hub_probe_requests row for (onboarding, ticket_key, probe, args),
// filed first if it is not there. null when the row could not be filed or read.
export async function fileScreenProbe(env, { t = nowIso(), ticket_key, probe, args }) {
  try {
    const res = await fileHubProbe({
      env, t, body: { project: PROJECT, ticket_key, probe, args, requested_by: "console" },
    });
    if (res.status !== 200) return null;
    const out = await res.json();
    return out && out.row ? out.row : null;
  } catch {
    return null;
  }
}

const bucket = (t, seconds) => Math.floor(Date.parse(t) / (seconds * 1000));

function pendingOf(row) {
  return row.note ? { state: "pending", note: row.note } : { state: "pending" };
}

function errorOf(row, fallback) {
  const text = String(row.output ?? "").trim().slice(0, ERROR_MAX);
  return { state: "error", error: text || fallback || row.status };
}

// One JSON object, or null. A line of text before the object is not an object.
function objectOf(text) {
  try {
    const v = JSON.parse(String(text ?? ""));
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

export function repoAnswer(row) {
  if (row.status === "pending" || row.status === "claimed") return pendingOf(row);
  if (row.status === "pass") {
    const o = objectOf(row.output);
    if (o && o.visible === true) {
      const { visible, install_url, ...facts } = o;
      return { state: "ok", visible, facts, install_url: install_url ?? null };
    }
    if (o && o.visible === false) return { state: "ok", visible: false, install_url: o.install_url ?? null };
    return errorOf({ ...row, output: "" }, "unparseable probe output");
  }
  return errorOf(row);
}

export function reposAnswer(row) {
  if (row.status === "pending" || row.status === "claimed") return pendingOf(row);
  if (row.status === "pass") {
    const lines = String(row.output ?? "").split("\n").map((l) => l.trim());
    const total = lines.map((l) => /^total_count=(\d+)$/.exec(l)).find(Boolean);
    if (!total) return errorOf({ ...row, output: "" }, "unparseable probe output");
    return {
      state: "ok",
      repos: lines.filter((l) => FULL_NAME_RE.test(l)),
      total_count: Number(total[1]),
      incomplete: lines.some((l) => l.startsWith("incomplete:")),
    };
  }
  return errorOf(row);
}

const NOT_FILED = { error: "the hub-probe request could not be filed" };

export const routes = [
  [
    "GET", "/api/onboarding/repo",
    async ({ env, t, url }) => {
      const p = parseRepoSlug(url.searchParams.get("slug"));
      if (!p) return json(400, { error: BAD_SLUG });
      const row = await fileScreenProbe(env, {
        t, ticket_key: `onb-repo-${bucket(t, REPO_BUCKET_S)}`, probe: "repo-detect", args: [p.slug],
      });
      if (!row) return json(503, NOT_FILED);
      return json(200, repoAnswer(row));
    },
  ],

  [
    "GET", "/api/onboarding/repos",
    async ({ env, t }) => {
      const row = await fileScreenProbe(env, {
        t, ticket_key: `onb-repos-${bucket(t, REPOS_BUCKET_S)}`, probe: "app-installation-repos", args: [],
      });
      if (!row) return json(503, NOT_FILED);
      return json(200, reposAnswer(row));
    },
  ],
];
