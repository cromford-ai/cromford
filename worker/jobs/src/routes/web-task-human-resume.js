// web-task human-step resume — a later answer starts a new run that resumes
// (BH-8314, slice C0). Contract and decision table:
// docs/notes/2026-10-25-BH-8314-web-task-human-resume.md. Client:
// wh_resume_human in bin/lib/web-human.sh. The step table and the ask, poll
// and answer routes are web-task-human.js (BH-7598); this file adds no table.
//
// POST /api/web-task/human/resume {run_id, machine, project, site, step_id}   a lane-run machine
//   Bearer-gated, plus the header x-web-vault-run-token of the NEW run (the
//   same run binding as a vault read). A new claimed web-task run of the same
//   project and site takes over an open or answered step of a run that has
//   stopped, so the existing poll route (its check is step.run_id = run)
//   serves it. Four parallel reads (the new run and its token row by PK, the
//   settings, the step joined to its old run by PK), then at most ONE
//   conditional UPDATE. First failing check wins:
//     400 bad form; 403 a readRefusal of the new run; 404 no_step;
//     403 other_task (the step's project or site is not the body's);
//     200 the step is already this run's (nothing written);
//     409 old_nonce / already_answered / cancelled (superseded / consumed / cancelled);
//     410 expired (expires_at <= now); 409 run_live (the old run is claimed
//     and its lease has not passed); 409 raced (the UPDATE changed 0 rows).
//   Else 200 {ok, step_id, status, kind}. The answer never holds a code or a nonce.
//   lane_runs_live allows one queued or claimed run per (lane, project), so
//   run_live and raced cannot happen for one project today; both guards stay.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { RUN_SQL, RUN_TOKEN_SQL, allowedSites, readRefusal, sameText, sha256Hex, siteName } from "./web-vault.js";

const ID_RE = /^[1-9]\d{0,15}$/;
// Both sides are PRIMARY KEY lookups.
export const STEP_RESUME_SQL = `SELECT s.id, s.run_id, s.project, s.site, s.kind, s.status, s.expires_at, r.status AS old_status, r.lease_until AS old_lease
 FROM web_task_human_step s LEFT JOIN lane_runs r ON r.id = s.run_id WHERE s.id = ?1`;
// ?1 new run, ?2 step, ?3 old run, ?4 t. The PRIMARY KEY; the old run_id makes
// it a compare-and-swap, so two resume runs cannot both take one step.
export const REBIND_SQL = `UPDATE web_task_human_step SET run_id=?1
 WHERE id=?2 AND run_id=?3 AND status IN ('open','answered') AND expires_at > ?4`;
const CLOSED = { superseded: [409, "old_nonce"], consumed: [409, "already_answered"], cancelled: [409, "cancelled"] };

const refused = (status, why) => json(status, { error: "refused", refused: why });
function idOf(v) {
  const s = typeof v === "number" || typeof v === "string" ? String(v).trim() : "";
  return ID_RE.test(s) ? Number(s) : null;
}

export const routes = [
  [
    "POST", "/api/web-task/human/resume",
    ({ req, env, t, body }) => d1Guarded("web_task_human_step", async () => {
      const b = body || {};
      const project = laneName(b.project), site = siteName(b.site), machine = laneName(b.machine);
      const runId = idOf(b.run_id), stepId = idOf(b.step_id);
      if (!project || !site || !machine || runId === null || stepId === null) {
        return json(400, { error: "run_id, machine, project, site and step_id are required" });
      }
      const presented = req.headers.get("x-web-vault-run-token") || "";
      const [run, tok, hash, { byKey }, step] = await Promise.all([
        env.DB.prepare(RUN_SQL).bind(runId).first(),
        env.DB.prepare(RUN_TOKEN_SQL).bind(runId).first(),
        sha256Hex(presented),
        settingsRows(env),
        env.DB.prepare(STEP_RESUME_SQL).bind(stepId).first(),
      ]);
      const tokenOk = !!(presented && tok && tok.machine === machine && sameText(hash, String(tok.token_hash)));
      const why = readRefusal(run, { project, site, machine, t, allowed: allowedSites(byKey, project), tokenOk });
      if (why) return refused(403, why);
      if (!step) return refused(404, "no_step");
      if (step.project !== project || step.site !== site) return refused(403, "other_task");
      const answer = { ok: true, step_id: stepId, status: step.status, kind: step.kind };
      if (Number(step.run_id) === runId) return json(200, answer);
      if (CLOSED[step.status]) return refused(...CLOSED[step.status]);
      if (String(step.expires_at) <= t) return refused(410, "expired");
      if (step.old_status === "claimed" && step.old_lease && String(step.old_lease) > t) return refused(409, "run_live");
      const r = await env.DB.prepare(REBIND_SQL).bind(runId, stepId, Number(step.run_id), t).run();
      if (!r || !r.meta || r.meta.changes !== 1) return refused(409, "raced");
      return json(200, answer);
    }),
  ],
];
