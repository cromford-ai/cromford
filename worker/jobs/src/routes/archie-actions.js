// archie-actions routes — BH-4583 (BH-4574.1): Archie's factory-manager ledger.
//
// The factory-manager lane (bin/archie-fm.sh) writes one row per action it
// takes on a PR, in either mode: 'on' acts, 'observe' records what it would
// have done. The row is a CLAIM made before any git or GitHub write: the lane
// POSTs /api/archie/actions with outcome 'started' (or 'would' in observe),
// and only a 201 lets it act. It then reports the result through
// POST /api/archie/actions/outcome, and the daily digest and the day cap read
// GET /api/archie/actions?day=. A grandchild's restack reads its merged
// parent's own rows across days with ?repo=&pr= (BH-4784: the head the parent
// had before Archie replayed it is the grandchild's fork point). Table:
// archie_actions (schema.sql, BH-4583 block).
//
// Every supplied field is validated and a junk one is a 400 naming the field —
// never clamped, never defaulted (D11). `day` is the server clock's, never the
// caller's. The dedupe_key binds to its payload: a replay with the same
// (project, repo, pr, playbook, mode) is 200 existing, a different one is a
// 409 (D16). An outcome move is a compare-and-swap on the stored updated_at AND
// outcome, so two racing reports can never both move the same row.
//
// BH-4927 (BH-4920.4) adds the second playbook, `data-lane`: one pre-merge
// migration apply per PR head (actions apply / would_apply, and no_path /
// not_candidate on the terminal outcome `skipped`). summary=1 carries its own
// data_lane block; the restack counters never count a data-lane row as
// restacked (that needs action restack).

import { json, d1Guarded } from "../lib/http.js";

const KEY_RE = /^[A-Za-z0-9._:/#@-]{1,300}$/;
const PROJECT_RE = /^[a-z0-9-]{1,64}$/;
const REPO_RE = /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
// BH-4585: rebase-repair, a conductor park a merge of main could not get past.
// BH-4584 adds the queue doctor's (bin/archie-fm-queue.sh): queue-culprit
// (a head-bound BLOCK on a batch member that reproduces alone), queue-solo (its
// CI-pool solo runs, a playbook of their own so archie.cap.queue-solo caps the
// CI minutes separately), queue-enqueue and queue-reconcile.
// BH-4586 adds the whole-factory watch's (bin/archie-fm-watch.sh): one
// watch-<class> playbook per finding class, each with its own day cap, and
// watch-ticket for the escalation issue. Its rows are about an incident, not a
// PR, so they alone may carry pr 0 (archie_actions.pr is NOT NULL).
const WATCH_PLAYBOOKS = ["watch-build-stuck", "watch-review-unrescued", "watch-pool-idle", "watch-disk",
  "watch-cron-install", "watch-deploy-drift", "watch-main-red", "watch-pause-waiting", "watch-triage-skip",
  "watch-cost-anomaly", "watch-ticket", "watch-session", "watch-owed-overdue", "watch-metric-unreadable"];
// BH-4927: data-lane, a reviewed migration this lane applies ahead of merge.
// BH-4587 adds the self-improvement loop's (bin/archie-fm-improve.sh): improve,
// one row per ticket filed, comment, reopen, merged fix tracked and fix
// verified. Its rows are about a cause, not a PR, so they may carry pr 0 too.
const PLAYBOOKS = new Set(["stacked-parent-merged", "rebase-repair", "data-lane", "queue-culprit", "queue-solo", "queue-enqueue",
  "queue-reconcile", "improve", ...WATCH_PLAYBOOKS]);
const MODES = new Set(["on", "observe"]);
const QUEUE_ACTIONS = ["solo_run", "block_verdict", "enqueue", "settle_merged", "release_dep_hold", "report_dep_hold", "kick_ci"];
const WATCH_ACTIONS = ["kick_lane", "run_cleanup", "rerun_deploy", "ack_alert", "file_ticket", "session", "note"];
const IMPROVE_ACTIONS = ["comment", "reopen", "track_merged", "verified"];
const ACTIONS = new Set(["restack", "fix_round", "would_restack", "noop", "repair", "would_repair",
  "apply", "would_apply", "no_path", "not_candidate",
  ...QUEUE_ACTIONS, ...QUEUE_ACTIONS.map((a) => `would_${a}`),
  ...WATCH_ACTIONS, ...WATCH_ACTIONS.map((a) => `would_${a}`),
  ...IMPROVE_ACTIONS, ...IMPROVE_ACTIONS.map((a) => `would_${a}`)]);
const OUTCOMES = new Set(["started", "done", "requested", "would", "deferred", "failed", "skipped"]);
// stored outcome -> the outcomes it may move to. Everything else is terminal.
const TRANSITIONS = {
  started: new Set(["done", "requested", "would", "deferred", "failed", "skipped"]),
  deferred: new Set(["started", "failed"]),
};
const EVIDENCE_MAX = 16384;

const posInt = (v) => typeof v === "number" && Number.isInteger(v) && v > 0;
// pr: a positive PR number, or exactly 0 on a watch-* or improve playbook's row.
const prOk = (pr, playbook) => posInt(pr)
  || (pr === 0 && typeof playbook === "string" && (playbook.startsWith("watch-") || playbook === "improve"));
const isKey = (v) => typeof v === "string" && KEY_RE.test(v);
const inSet = (set, v) => typeof v === "string" && set.has(v);
// A trimmed string of lo..hi chars, or null.
const str = (v, lo, hi) => {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s.length >= lo && s.length <= hi ? s : null;
};
// A plain object whose JSON is at most EVIDENCE_MAX chars -> that JSON; else null.
const evidenceJson = (v) => {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return null;
  const s = JSON.stringify(v);
  return s.length <= EVIDENCE_MAX ? s : null;
};

const bad = (field) => json(400, { error: field });
const notFound = (what) => json(404, { error: `${what} not found` });

const rowOut = (r) => (r ? { ...r, evidence: JSON.parse(r.evidence) } : null);
const readByKey = async (env, key) =>
  rowOut(await env.DB.prepare(`SELECT * FROM archie_actions WHERE dedupe_key=?1`).bind(key).first());
const readByIdKey = async (env, id, key) =>
  rowOut(await env.DB.prepare(`SELECT * FROM archie_actions WHERE id=?1 AND dedupe_key=?2`).bind(id, key).first());

export const routes = [
  // ── POST /api/archie/actions — claim one action, idempotent on dedupe_key ──
  // ON CONFLICT DO NOTHING then read back: two racing claims answer 201 and
  // 200, never a 500, and only the 201 may act. action, outcome, why, evidence
  // and actor are not part of the payload identity: the row has moved on since
  // the claim, and a replay is still the same claim.
  [
    "POST", "/api/archie/actions",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!isKey(b.dedupe_key)) return bad("dedupe_key");
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return bad("project");
      if (typeof b.repo !== "string" || !REPO_RE.test(b.repo)) return bad("repo");
      if (!prOk(b.pr, b.playbook)) return bad("pr");
      if (!inSet(PLAYBOOKS, b.playbook)) return bad("playbook");
      if (!inSet(MODES, b.mode)) return bad("mode");
      if (!inSet(ACTIONS, b.action)) return bad("action");
      if (!inSet(OUTCOMES, b.outcome)) return bad("outcome");
      const why = str(b.why, 1, 500);
      if (why === null) return bad("why");
      let evidence = "{}";
      if (b.evidence !== undefined) {
        evidence = evidenceJson(b.evidence);
        if (evidence === null) return bad("evidence");
      }
      const actor = str(b.actor, 1, 64);
      if (actor === null) return bad("actor");
      const key = b.dedupe_key;
      const day = t.slice(0, 10);

      return d1Guarded("archie_actions", async () => {
        const r = await env.DB.prepare(
          `INSERT INTO archie_actions (dedupe_key, day, project, repo, pr, playbook, mode, action, outcome,
                                       why, evidence, attempts, actor, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 1, ?12, ?13, ?13)
           ON CONFLICT(dedupe_key) DO NOTHING`
        ).bind(key, day, b.project, b.repo, b.pr, b.playbook, b.mode, b.action, b.outcome,
          why, evidence, actor, t).run();
        const action = await readByKey(env, key);
        if (!action) return json(503, { error: "archie_actions unavailable", detail: `insert of ${key} left no row` });
        if (r.meta && r.meta.changes === 1) return json(201, { ok: true, created: true, action });
        const same = action.project === b.project && action.repo === b.repo && Number(action.pr) === b.pr
          && action.playbook === b.playbook && action.mode === b.mode;
        if (same) return json(200, { ok: true, existing: true, action });
        return json(409, { error: `archie action ${key} exists with a different payload`, action });
      });
    },
  ],

  // ── POST /api/archie/actions/outcome — move one row's outcome ─────────────
  // Legal moves: started -> done|requested|would|deferred|failed|skipped, and
  // deferred -> started|failed. deferred -> started is a retry and the ONLY
  // thing that grows attempts. The UPDATE is a CAS on the stored updated_at
  // and the outcome the move was validated against: a racing report gets 409
  // stale and writes nothing.
  [
    "POST", "/api/archie/actions/outcome",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!posInt(b.id)) return bad("id");
      if (!isKey(b.dedupe_key)) return bad("dedupe_key");
      if (typeof b.expect_updated_at !== "string" || b.expect_updated_at.length < 1
          || b.expect_updated_at.length > 40) return bad("expect_updated_at");
      if (!inSet(OUTCOMES, b.outcome)) return bad("outcome");
      if (b.action !== undefined && !inSet(ACTIONS, b.action)) return bad("action");
      let why = null;
      if (b.why !== undefined) {
        why = str(b.why, 1, 500);
        if (why === null) return bad("why");
      }
      let evidence = null;
      if (b.evidence !== undefined) {
        evidence = evidenceJson(b.evidence);
        if (evidence === null) return bad("evidence");
      }
      const action = b.action === undefined ? null : b.action;

      return d1Guarded("archie_actions", async () => {
        const before = await readByIdKey(env, b.id, b.dedupe_key);
        if (!before) return notFound("archie action");
        const from = before.outcome;
        if (!(TRANSITIONS[from] && TRANSITIONS[from].has(b.outcome))) {
          return json(409, { error: `illegal transition ${from} -> ${b.outcome}`, action: before });
        }
        const bump = from === "deferred" && b.outcome === "started" ? 1 : 0;
        const r = await env.DB.prepare(
          `UPDATE archie_actions SET outcome = ?5, action = COALESCE(?6, action), why = COALESCE(?7, why),
                  evidence = COALESCE(?8, evidence), attempts = attempts + ?9, updated_at = ?10
            WHERE id = ?1 AND dedupe_key = ?2 AND updated_at = ?3 AND outcome = ?4`
        ).bind(b.id, b.dedupe_key, b.expect_updated_at, from, b.outcome, action, why, evidence, bump, t).run();
        const after = await readByIdKey(env, b.id, b.dedupe_key);
        if (!(r.meta && r.meta.changes === 1)) return json(409, { error: "stale", action: after });
        return json(200, { ok: true, action: after });
      });
    },
  ],

  // ── GET /api/archie/actions?dedupe_key= | ?day=&project=&playbook=&repo=&pr=&limit=&count_by=&summary=1 ──
  // The list is newest first and reads limit+1, so a capped answer says
  // truncated:true (D12). counts is a GROUP BY over the SAME filter with no
  // limit, so the cap never shortens a count. summary=1 answers counts only,
  // plus no_local_suites: the on-mode restacks that pushed with no local suite
  // run (evidence.local_suites false, BH-4784).
  // repo and pr come together or not at all; with both, day is optional (one
  // PR's ledger across days). count_by=action keys counts by action instead of
  // outcome and echoes count_by:"action", so a caller can tell this answer
  // from an older worker's that ignored the param (the day cap fails closed
  // without the echo).
  [
    "GET", "/api/archie/actions",
    async ({ env, url }) => {
      const q = url.searchParams;
      if (q.has("dedupe_key")) {
        const key = q.get("dedupe_key");
        if (!isKey(key)) return bad("dedupe_key");
        return d1Guarded("archie_actions", async () => {
          const action = await readByKey(env, key);
          return action ? json(200, { action }) : notFound("archie action");
        });
      }
      const hasRepo = q.has("repo");
      const hasPr = q.has("pr");
      if (hasRepo && !hasPr) return bad("pr");
      if (hasPr && !hasRepo) return bad("repo");
      const day = q.get("day");
      if (day === null ? !(hasRepo && hasPr) : !DAY_RE.test(day)) return bad("day");
      const where = [];
      const binds = [];
      if (day !== null) { binds.push(day); where.push(`day = ?${binds.length}`); }
      if (hasRepo) {
        const r = q.get("repo");
        if (!REPO_RE.test(r)) return bad("repo");
        const n = q.get("pr");
        if (!/^\d{1,9}$/.test(n) || Number(n) < 1) return bad("pr");
        binds.push(r); where.push(`repo = ?${binds.length}`);
        binds.push(Number(n)); where.push(`pr = ?${binds.length}`);
      }
      if (q.has("project")) {
        const p = q.get("project");
        if (!PROJECT_RE.test(p)) return bad("project");
        binds.push(p); where.push(`project = ?${binds.length}`);
      }
      if (q.has("playbook")) {
        const p = q.get("playbook");
        if (!PLAYBOOKS.has(p)) return bad("playbook");
        binds.push(p); where.push(`playbook = ?${binds.length}`);
      }
      let limit = 100;
      if (q.has("limit")) {
        const v = q.get("limit");
        if (!/^\d{1,3}$/.test(v) || Number(v) < 1 || Number(v) > 500) return bad("limit");
        limit = Number(v);
      }
      let summary = false;
      if (q.has("summary")) {
        if (q.get("summary") !== "1") return bad("summary");
        summary = true;
      }
      let byAction = false;
      if (q.has("count_by")) {
        if (q.get("count_by") !== "action") return bad("count_by");
        byAction = true;
      }

      return d1Guarded("archie_actions", async () => {
        // sql-ident-ok: where holds literal column = ?N clauses, every value a bind
        const groups = (await env.DB.prepare(
          `SELECT playbook, mode, action, outcome, COUNT(*) AS n FROM archie_actions
            WHERE ${where.join(" AND ")} GROUP BY playbook, mode, action, outcome`
        ).bind(...binds).all()).results || [];

        if (summary) {
          // sql-ident-ok: where holds literal column = ?N clauses, every value a bind
          const nls = await env.DB.prepare(
            `SELECT COUNT(*) AS n FROM archie_actions WHERE ${where.join(" AND ")}
               AND mode = 'on' AND action = 'restack' AND outcome = 'done'
               AND json_extract(evidence, '$.local_suites') = 0`
          ).bind(...binds).first();
          const out = {
            ok: true, day, total: 0, by_outcome: {}, by_mode: {},
            restacked: 0, repaired: 0, fix_rounds: 0, would: 0, deferred: 0, failed: 0,
            no_local_suites: Number((nls && nls.n) || 0),
            // applied: an on-mode apply that closed done. escalated: an apply
            // that failed (the apply script alerted) or found no apply path.
            data_lane: { total: 0, applied: 0, escalated: 0, would: 0 },
          };
          for (const g of groups) {
            const n = Number(g.n);
            out.total += n;
            out.by_outcome[g.outcome] = (out.by_outcome[g.outcome] || 0) + n;
            out.by_mode[g.mode] = (out.by_mode[g.mode] || 0) + n;
            if (g.mode === "on" && g.action === "restack" && g.outcome === "done") out.restacked += n;
            if (g.mode === "on" && g.action === "repair" && g.outcome === "done") out.repaired += n;
            if (g.outcome === "requested") out.fix_rounds += n;
            if (g.outcome === "would") out.would += n;
            if (g.outcome === "deferred") out.deferred += n;
            if (g.outcome === "failed") out.failed += n;
            if (g.playbook === "data-lane") {
              const dl = out.data_lane;
              dl.total += n;
              if (g.mode === "on" && g.outcome === "done") dl.applied += n;
              if (g.outcome === "failed" || (g.outcome === "skipped" && g.action === "no_path")) dl.escalated += n;
              if (g.outcome === "would") dl.would += n;
            }
          }
          return json(200, out);
        }

        const counts = {};
        for (const g of groups) {
          const byMode = (counts[g.playbook] ||= {});
          const by = (byMode[g.mode] ||= {});
          const k = byAction ? g.action : g.outcome;
          by[k] = (by[k] || 0) + Number(g.n);
        }
        // sql-ident-ok: where holds literal column = ?N clauses, every value a bind; the LIMIT is a ?N index
        const rows = (await env.DB.prepare(
          `SELECT * FROM archie_actions WHERE ${where.join(" AND ")}
            ORDER BY created_at DESC, id DESC LIMIT ?${binds.length + 1}`
        ).bind(...binds, limit + 1).all()).results || [];
        return json(200, {
          ok: true, day,
          actions: rows.slice(0, limit).map(rowOut),
          counts,
          truncated: rows.length > limit,
          ...(byAction ? { count_by: "action" } : {}),
        });
      });
    },
  ],
];
