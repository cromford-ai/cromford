// human gate routes — BH-9559 part A (BH-9580 tracer). One row per question
// the harness asks a person (schema.d/202611121730-bh-9559-human-gates.sql).
//
// POST /api/human-gates {repo, key, lane, reason, question, recommended,
//   reasons: [1..3 strings], default_answer, deadline_at?}
//   400 when question, recommended or default_answer is missing or blank,
//   when reasons is not an array of 1-3 non-blank strings, when repo, key or
//   lane fails its charset, or when a given deadline_at is not an ISO time.
//   question_fp = the first 16 hex of SHA-256 over the question, trimmed,
//   whitespace collapsed and lowercased (computed here only).
//   gate_class = classOf(reason): the human_gate.class.<reason> row when its
//   value is exactly defaultable or irreversible; anything else is irreversible.
//   deadline_at = the body's value, else now + human_gate.deadline_hours.
//   ONE upsert on UNIQUE (repo, key, lane, question_fp). A re-ask only stamps
//   asked_again_at: status, answer, deadline_at and created_at never change.
//   200 {gate: {...}, reasked}.
// Note: docs/notes/2026-11-12-BH-9580-human-gates.md.

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";

const REPO_RE = /^[A-Za-z0-9._/-]{1,100}$/;
const KEY_RE = /^[A-Z]+-[0-9]+(\.[0-9]+)?$/;
const LANE_RE = /^[a-z][a-z-]{0,39}$/;
// Field caps are input validation of a request body (the size of one text
// cell), not a limit on work, so they are not settings rows.
const QUESTION_MAX = 2000;
const ANSWER_MAX = 1000;
const REASON_TEXT_MAX = 500;
const GATE_REASON_MAX = 100;
// Fallback of the settings row human_gate.deadline_hours (seeded 24), read as
// an integer in 1..720.
const DEADLINE_HOURS_DEFAULT = 24;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z$/;

const isoSeconds = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const textOf = (v, max) => (typeof v === "string" && v.trim() !== "" && v.length <= max ? v : null);
const bad = (field) => json(400, { error: field });

// classOf(byKey, reason) — the gate class of a reason. Fail-closed: only an
// exact defaultable value reads defaultable. Exported for BH-9559.2-.9.
export function classOf(byKey, reason) {
  if (typeof reason !== "string" || reason === "") return "irreversible";
  const row = byKey.get(`human_gate.class.${reason}`);
  const v = row ? String(row.value) : "";
  return v === "defaultable" ? "defaultable" : "irreversible";
}

// questionFp(question) — the one definition of question_fp.
export async function questionFp(question) {
  const norm = String(question).trim().replace(/\s+/g, " ").toLowerCase();
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(norm));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 16);
}

export const SQL = {
  upsert: `INSERT INTO human_gates (repo, key, lane, reason, gate_class, question, question_fp, recommended,
             reasons_json, default_answer, deadline_at, status, created_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,'open',?12)
           ON CONFLICT (repo, key, lane, question_fp) DO UPDATE SET asked_again_at = excluded.created_at
           RETURNING *`,
};

const gateOut = (r) => ({
  id: r.id, repo: r.repo, key: r.key, lane: r.lane, reason: r.reason, gate_class: r.gate_class,
  status: r.status, deadline_at: r.deadline_at, created_at: r.created_at, asked_again_at: r.asked_again_at,
});

export const routes = [
  [
    "POST", "/api/human-gates",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (typeof b.repo !== "string" || !REPO_RE.test(b.repo)) return bad("repo");
      if (typeof b.key !== "string" || !KEY_RE.test(b.key)) return bad("key");
      if (typeof b.lane !== "string" || !LANE_RE.test(b.lane)) return bad("lane");
      const reason = b.reason === undefined || b.reason === null ? "" : b.reason;
      if (typeof reason !== "string" || reason.length > GATE_REASON_MAX) return bad("reason");
      const question = textOf(b.question, QUESTION_MAX);
      if (question === null) return bad("question");
      const recommended = textOf(b.recommended, ANSWER_MAX);
      if (recommended === null) return bad("recommended");
      const def = textOf(b.default_answer, ANSWER_MAX);
      if (def === null) return bad("default_answer");
      const rs = b.reasons;
      if (!Array.isArray(rs) || rs.length < 1 || rs.length > 3 || rs.some((r) => textOf(r, REASON_TEXT_MAX) === null)) {
        return bad("reasons");
      }
      let deadline = null;
      if (b.deadline_at !== undefined && b.deadline_at !== null) {
        const ms = typeof b.deadline_at === "string" && ISO_RE.test(b.deadline_at) ? Date.parse(b.deadline_at) : NaN;
        if (!Number.isFinite(ms)) return bad("deadline_at");
        deadline = isoSeconds(ms);
      }
      const fp = await questionFp(question);
      return d1Guarded("human_gates", async () => {
        const { byKey } = await settingsRows(env);
        if (deadline === null) {
          const hours = intSetting(byKey, "human_gate.deadline_hours", DEADLINE_HOURS_DEFAULT, 1, 720);
          deadline = isoSeconds(Date.parse(t) + hours * 3600e3);
        }
        const row = await env.DB.prepare(SQL.upsert).bind(
          b.repo, b.key, b.lane, reason, classOf(byKey, reason), question, fp, recommended,
          JSON.stringify(rs), def, deadline, t,
        ).first();
        if (!row) return json(503, { error: "human_gates upsert returned no row" });
        return json(200, { gate: gateOut(row), reasked: row.asked_again_at === t });
      });
    },
  ],
];
