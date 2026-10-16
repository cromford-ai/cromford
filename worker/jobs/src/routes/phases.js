// phases routes — one row per stage attempt, a child of the claim.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  PHASE_STATUS, PHASE_TRANSITIONS, checkTransition, contractBreach,
} from "../lib/core.js";

export const routes = [
  // ── Phases (phase 5) ───────────────────────────────────────────────────
  // A phase is a CHILD of a job, not a claim of its own. Opening one never
  // guards, never 409s and never asks permission: the job already holds the
  // claim, and making a stage re-ask between plan and execute would turn one
  // decision into three chances to deadlock a build over a network blip.
  // What these rows buy is ATTRIBUTION — which stage died, on which runner,
  // at what rc, having spent what — which through phase 4 lived nowhere.
  [
    "POST", /^\/api\/jobs\/([^/]+)\/phases\/close$/,
    async ({ env, t, body, m: phCloseMatch }) => {
      const id = decodeURIComponent(phCloseMatch[1]);
      const status = String(body.status || "failed");
      if (!PHASE_STATUS.includes(status)) return json(400, { error: `status must be one of ${PHASE_STATUS.join(", ")}` });
      // Read the open rows BEFORE closing them: the caller (the watchdog, or a
      // pipeline closing out a stage that was killed mid-flight) has to be able
      // to NAME the phase it just judged, and after the UPDATE there is nothing
      // left to name.
      const open = await env.DB.prepare(
        "SELECT id, phase, runner, started_at FROM job_phases WHERE job_id=?1 AND status='running' ORDER BY id ASC"
      ).bind(id).all();
      const rc = Number.isInteger(Number(body.rc)) ? Number(body.rc) : null;
      const note = body.note ? String(body.note).slice(0, 512) : null;
      const rows = open.results || [];

      // ── Phase 7: the contract binds here too ──────────────────────────────
      // This route is the pipeline's cleanup hook, and a done-close through it
      // is still a done-close: run-build.sh calling it after a successful build
      // must not be a way around a contract that agent-call.sh would have been
      // held to. Checked PER PHASE, because a bulk close can carry two phase
      // names and only one of them may have a row.
      // A breach is NOT a refusal to write. The phase lands in `contract_unmet`
      // with the reason on it, so the guarantee ("no `done` without the
      // artifact") is kept without inventing a new silence — a phase left
      // `running` forever is the failure this table exists to remove.
      let closed = 0;
      const breaches = [];
      for (const ph of rows) {
        let st = status, n = note;
        if (status === "done") {
          const breach = await contractBreach(env, id, ph.phase);
          if (breach) {
            st = "contract_unmet";
            n = `CONTRACT_UNMET: ${breach.reason}`.slice(0, 512);
            breaches.push({ phase_id: ph.id, phase: ph.phase, ...breach });
            await env.DB.prepare(
              `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
               VALUES (?1,?2,'CONTRACT_UNMET',?3,?4,?5)`
            ).bind(id, ph.phase, body.actor ? String(body.actor).slice(0, 128) : "harness-jobs",
              breach.reason, t).run();
          }
        }
        const r = await env.DB.prepare(
          `UPDATE job_phases SET status=?2, finished_at=?3,
                  rc=COALESCE(?4, rc), note=COALESCE(?5, note)
            WHERE id=?1 AND status='running'`
        ).bind(ph.id, st, t, rc, n).run();
        closed += r.meta.changes;
      }
      if (breaches.length) {
        return json(409, {
          job_id: id, closed, status: "contract_unmet", requested: status,
          contract_unmet: true, breaches, phases: rows, as_of: t,
        });
      }
      return json(200, { job_id: id, closed, status, phases: rows, as_of: t });
    },
  ],

  [
    "POST", /^\/api\/jobs\/([^/]+)\/phases$/,
    async ({ env, t, body, m: phMatch }) => {
      const id = decodeURIComponent(phMatch[1]);
      const job = await env.DB.prepare("SELECT id, status FROM jobs WHERE id=?1").bind(id).first();
      // A phase without its job is not a thing this table should hold: it would
      // be an orphan by construction, invisible on every screen that starts
      // from a job. 404 is the honest answer, and the client is fail-open.
      if (!job) return json(404, { error: "no such job" });
      const phase = String(body.phase || "").trim().slice(0, 64);
      if (!phase) return json(400, { error: "phase required" });
      const r = await env.DB.prepare(
        `INSERT INTO job_phases (job_id, phase, runner, model, status, started_at, note)
         VALUES (?1,?2,?3,?4,'running',?5,?6)`
      ).bind(
        id, phase,
        body.runner ? String(body.runner).slice(0, 64) : null,
        body.model ? String(body.model).slice(0, 128) : null,
        t,
        body.note ? String(body.note).slice(0, 512) : null
      ).run();
      const row = await env.DB.prepare("SELECT * FROM job_phases WHERE id=?1").bind(r.meta.last_row_id).first();
      return json(201, { phase: row || { id: r.meta.last_row_id, job_id: id, phase, status: "running", started_at: t } });
    },
  ],

  [
    "GET", /^\/api\/jobs\/([^/]+)\/phases$/,
    async ({ env, t, m: phMatch }) => {
      const id = decodeURIComponent(phMatch[1]);
      const rows = await env.DB.prepare(
        "SELECT * FROM job_phases WHERE job_id=?1 ORDER BY id ASC LIMIT 500"
      ).bind(id).all();
      return json(200, { job_id: id, phases: rows.results || [], as_of: t });
    },
  ],

  // Close (or correct) ONE phase by its row id. The rc is the stage's real
  // exit code and is stored as given — a stage that died on rc=137 says 137,
  // because the whole point of this table is that the ledger can answer which
  // phase died and how, and a laundered rc answers neither.
  [
    "PATCH", /^\/api\/phases\/(\d+)$/,
    async ({ env, path, t, body, m: phIdMatch }) => {
      const pid = Number(phIdMatch[1]);
      const sets = [], binds = [];
      const set = (frag, val) => { binds.push(val); sets.push(frag.replace("?", `?${binds.length}`)); };
      // Phase 7 reads the row BEFORE writing, which phases 5-6 did not have to:
      // both the transition graph and the outcome contract are judgements about
      // where the phase IS, and a blind UPDATE cannot make either of them.
      let current = null, contractNote = null, breach = null;
      if (body.status !== undefined) {
        let status = String(body.status);
        // The allowlist is checked BEFORE the row is read: a status this ledger
        // has never heard of is a 400 whether or not the phase exists, and
        // answering 404 to a typo'd status would send the caller hunting for a
        // missing row that is sitting right there.
        if (!PHASE_STATUS.includes(status)) return json(400, { error: `status must be one of ${PHASE_STATUS.join(", ")}` });
        current = await env.DB.prepare("SELECT * FROM job_phases WHERE id=?1").bind(pid).first();
        if (!current) return json(404, { error: "no such phase" });

        // ── Phase 7: outcome contract ──────────────────────────────────────
        // A phase may not read `done` without the artifact its contract
        // declares. The close is NOT refused — it lands as `contract_unmet`
        // with the reason on the row, because a phase stuck at `running`
        // forever is the exact silence job_phases exists to remove. The caller
        // gets a 409 so it can say so in its log; recording the artifact and
        // closing again is the repair path, and it re-runs this check.
        if (status === "done") {
          breach = await contractBreach(env, current.job_id, current.phase);
          if (breach) {
            status = "contract_unmet";
            contractNote = `CONTRACT_UNMET: ${breach.reason}`.slice(0, 512);
          }
        }

        // ── Phase 7: enforced transitions ──────────────────────────────────
        const bad = checkTransition(PHASE_TRANSITIONS, String(current.status), status, "phase");
        if (bad) return json(409, { ...bad, phase_id: pid, job_id: current.job_id });

        set("status=?", status);
        // A close is what stamps finished_at, so a row can never read "done" at
        // a time nobody recorded. Re-opening a phase leaves it null again.
        if (status === "running") { sets.push("finished_at=NULL"); } else { set("finished_at=?", t); }
      }
      if (body.rc !== undefined && Number.isInteger(Number(body.rc))) set("rc=?", Number(body.rc));
      if (body.spend_usd !== undefined && Number.isFinite(Number(body.spend_usd))) set("spend_usd=?", Number(body.spend_usd));
      if (body.runner) set("runner=?", String(body.runner).slice(0, 64));
      if (body.model) set("model=?", String(body.model).slice(0, 128));
      // The contract's own words outrank the caller's note: the caller believed
      // this phase succeeded, so its note would say so, and the row has to
      // carry why it did not.
      if (contractNote !== null) set("note=?", contractNote);
      else if (body.note !== undefined && body.note !== null) set("note=?", String(body.note).slice(0, 512));
      if (sets.length === 0) return json(400, { error: "nothing to update" });
      binds.push(pid);
      // sql-ident-ok: sets are literal col=? strings from the set() calls in this handler
      const r = await env.DB.prepare(`UPDATE job_phases SET ${sets.join(", ")} WHERE id=?${binds.length}`)
        .bind(...binds).run();
      if (r.meta.changes === 0) return json(404, { error: "no such phase" });
      const row = await env.DB.prepare("SELECT * FROM job_phases WHERE id=?1").bind(pid).first();
      if (breach) {
        await env.DB.prepare(
          `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
           VALUES (?1,?2,'CONTRACT_UNMET',?3,?4,?5)`
        ).bind(current.job_id, current.phase, "harness-jobs", breach.reason, t).run();
        return json(409, {
          phase: row, contract_unmet: true, requested: "done",
          contract: breach.contract, reason: breach.reason,
        });
      }
      return json(200, { phase: row });
    },
  ],
];
