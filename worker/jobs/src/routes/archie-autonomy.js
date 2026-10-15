// archie-autonomy routes — BH-4067 (BH-3966.6): Archie's earned autonomy.
//
// Every escalation Archie sends lands in archie_decisions with its decision
// class and recommendation (POST /api/archie/decisions, from bin/archie.sh's
// tick), and the operator's answer to it is recorded on the same row
// (POST /api/archie/decisions/choice, from the chat intercept). An approve on
// an unprotected, non-sensitive escalation adds one to the class's streak; a
// change or a drop is an overrule: the streak goes to 0 and a delegated class
// goes back to ask_first. A class moves to delegated ONLY through
// POST /api/archie/classes/delegation, which the intercept calls on the operator's own
// `Archie delegate <class>`, and only once the streak has reached min_streak.
// Tables: archie_decisions, archie_classes (schema.sql, BH-4067 block).
//
// Protected is never a settings row (R6: the authority list does not move
// without the operator): a class is protected when its never_delegable column says so
// OR its name matches PROTECTED_RE below, whatever the column says.
//
// Validation, idempotency and slugs follow initiatives.js: junk is a 400 naming
// the field (D11), a replay with the same payload is 200 existing and a
// different one is 409 (D16), and the class is normalised once, in classOf (D17).

import { json, d1Guarded } from "../lib/http.js";

const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const isIso = (v) => {
  if (typeof v !== "string" || !ISO_RE.test(v)) return false;
  const ms = Date.parse(v);
  return !Number.isNaN(ms) && new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z") === v;
};
const posInt = (v) => typeof v === "number" && Number.isInteger(v) && v > 0;
const CLASS_RE = /^[a-z][a-z0-9-]{1,40}$/;
const PROTECTED_RE = /client|customer|money|spend|cost|budget|billing|invoice|price|prod|merge|deploy|release|unclassified/;
const ESC_KEY_RE = /^check:(\d+):(.+)$/;
const REPLY_KEY_RE = /^reply:(\d+):[A-Za-z0-9_-]{1,64}$/;
const CHOICES = new Set(["approve", "change", "drop"]);

// THE class identity: trimmed and lowercased here and nowhere else.
const classOf = (v) => {
  if (typeof v !== "string") return null;
  const c = v.trim().toLowerCase();
  return CLASS_RE.test(c) ? c : null;
};
export const isProtectedSlug = (c) => PROTECTED_RE.test(c);
const isProtected = (row) => !row || row.never_delegable === 1 || isProtectedSlug(row.class);

const bad = (field) => json(400, { error: field });
const readClass = (env, c) => env.DB.prepare(`SELECT * FROM archie_classes WHERE class=?1`).bind(c).first();
const classState = (row) => row && ({
  class: row.class, state: row.state, streak: Number(row.streak), protected: isProtected(row),
});
const decisionOut = (r) => r && ({ ...r, sensitive: r.sensitive === 1 });

const sha1Hex16 = async (s) => {
  const d = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 16);
};

export const routes = [
  // ── POST /api/archie/decisions — record one escalation, decide ask or auto ─
  // The mode is decided INSIDE the insert (one statement reads the class row),
  // and with mode auto the same batch acts: the reply event
  // reply:<id>:auto-<sha1(due_at)> (decision approve, actor archie) and
  // initiatives.last_decision, both conditioned on the ledger row being THIS
  // insert in auto mode. A replay returns the stored row and never acts twice.
  [
    "POST", "/api/archie/decisions",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!posInt(b.initiative_id)) return bad("initiative_id");
      const km = typeof b.escalation_key === "string" ? b.escalation_key.match(ESC_KEY_RE) : null;
      if (!km || Number(km[1]) !== b.initiative_id || !isIso(km[2])) return bad("escalation_key");
      const asked = classOf(b.class);
      if (asked === null) return bad("class");
      if (typeof b.sensitive !== "boolean") return bad("sensitive");
      const rec = typeof b.recommendation === "string" ? b.recommendation.trim() : "";
      if (rec.length < 1 || rec.length > 4000) return bad("recommendation");
      const key = b.escalation_key;
      const replyKey = `reply:${b.initiative_id}:auto-${await sha1Hex16(km[2])}`;

      return d1Guarded("archie_decisions", async () => {
        const ini = await env.DB.prepare(`SELECT id FROM initiatives WHERE id=?1`).bind(b.initiative_id).first();
        if (!ini) return json(404, { error: "initiative not found" });
        const known = await readClass(env, asked);
        const cls = known ? asked : "unclassified";
        const prot = isProtectedSlug(cls) ? 1 : 0;
        const sens = b.sensitive ? 1 : 0;
        const prior = await env.DB.prepare(`SELECT * FROM archie_decisions WHERE escalation_key=?1`).bind(key).first();
        if (!prior) {
          // ?1 key ?2 initiative ?3 class ?4 sensitive ?5 rec ?6 t ?7 protected-by-name
          const insert = env.DB.prepare(
            `INSERT INTO archie_decisions (escalation_key, initiative_id, class, sensitive, recommendation, mode, auto_choice, created_at)
             SELECT ?1, ?2, ?3, ?4, ?5, m.mode, CASE WHEN m.mode = 'auto' THEN 'approve' END, ?6
               FROM (SELECT CASE WHEN ?4 = 0 AND ?7 = 0 AND EXISTS (
                       SELECT 1 FROM archie_classes c WHERE c.class = ?3 AND c.state = 'delegated' AND c.never_delegable = 0)
                     THEN 'auto' ELSE 'ask' END AS mode) m
              WHERE 1
             ON CONFLICT(escalation_key) DO NOTHING`
          ).bind(key, b.initiative_id, cls, sens, rec, t, prot);
          const mine = `EXISTS (SELECT 1 FROM archie_decisions d WHERE d.escalation_key = ?2 AND d.mode = 'auto' AND d.created_at = ?3)`;
          await env.DB.batch([
            insert,
            // sql-ident-ok: mine is a local literal EXISTS clause with ?N binds
            env.DB.prepare(
              `INSERT INTO initiative_events (initiative_id, dedupe_key, kind, status, note, attempts, actor, created_at, updated_at)
               SELECT ?1, ?4, 'reply', 'approve', NULL, 0, 'archie', ?3, ?3 WHERE ${mine}
               ON CONFLICT(dedupe_key) DO NOTHING`
            ).bind(b.initiative_id, key, t, replyKey),
            // sql-ident-ok: mine is a local literal EXISTS clause with ?N binds
            env.DB.prepare(
              `UPDATE initiatives SET last_decision = 'approve', last_decision_note = NULL, updated_at = ?3
                WHERE id = ?1 AND ${mine}`
            ).bind(b.initiative_id, key, t),
          ]);
        }
        const row = await env.DB.prepare(`SELECT * FROM archie_decisions WHERE escalation_key=?1`).bind(key).first();
        if (!row) return json(503, { error: "archie_decisions unavailable", detail: `insert of ${key} left no row` });
        const class_state = classState(await readClass(env, row.class));
        const decision = decisionOut(row);
        if (!prior) return json(201, { ok: true, created: true, decision, class_state });
        const same = row.initiative_id === b.initiative_id && row.class === cls && row.sensitive === sens
          && row.recommendation === rec;
        if (same) return json(200, { ok: true, existing: true, decision, class_state });
        return json(409, { error: `decision ${key} exists with a different payload`, decision, class_state });
      });
    },
  ],

  // ── POST /api/archie/decisions/choice — the operator's answer on the newest escalation
  // The choice is set once. The class UPDATE runs in the same batch, conditioned
  // on the row now carrying THIS choice_key and chosen_at, so two racing
  // replies count once; a replay with the same key answers the stored result.
  [
    "POST", "/api/archie/decisions/choice",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!posInt(b.initiative_id)) return bad("initiative_id");
      if (typeof b.choice !== "string" || !CHOICES.has(b.choice)) return bad("choice");
      const km = typeof b.choice_key === "string" ? b.choice_key.match(REPLY_KEY_RE) : null;
      if (!km || Number(km[1]) !== b.initiative_id) return bad("choice_key");
      const answer = (row, cs, counted, reverted) => json(200, {
        ok: true, counted, reverted, decision_id: row.id, ...(cs || { class: row.class }),
      });

      return d1Guarded("archie_decisions", async () => {
        const row = await env.DB.prepare(
          `SELECT * FROM archie_decisions WHERE initiative_id=?1 ORDER BY id DESC LIMIT 1`
        ).bind(b.initiative_id).first();
        if (!row) return json(200, { ok: true, counted: false, reverted: false });
        if (row.choice_key === b.choice_key) {
          if (row.choice !== b.choice) return json(409, { error: `choice ${b.choice_key} exists with a different payload` });
          return answer(row, classState(await readClass(env, row.class)), row.counted === 1, false);
        }
        const before = await readClass(env, row.class);
        if (row.choice !== null) return answer(row, classState(before), false, false);
        const counts = b.choice === "approve" && row.sensitive === 0 && !isProtected(before);
        const won = `EXISTS (SELECT 1 FROM archie_decisions d WHERE d.id = ?2 AND d.choice_key = ?3 AND d.chosen_at = ?4)`;
        const classUpdate = b.choice === "approve"
          // sql-ident-ok: won is a local literal EXISTS clause with ?N binds
          ? env.DB.prepare(
            `UPDATE archie_classes SET streak = streak + 1, updated_at = ?4
              WHERE class = ?1 AND ?5 = 1 AND ${won}`
          ).bind(row.class, row.id, b.choice_key, t, counts ? 1 : 0)
          // sql-ident-ok: won is a local literal EXISTS clause with ?N binds
          : env.DB.prepare(
            `UPDATE archie_classes SET streak = 0, state = 'ask_first', updated_at = ?4,
                    reverted_at = CASE WHEN state = 'delegated' THEN ?4 ELSE reverted_at END
              WHERE class = ?1 AND ${won}`
          ).bind(row.class, row.id, b.choice_key, t);
        const res = await env.DB.batch([
          env.DB.prepare(
            `UPDATE archie_decisions SET choice = ?2, choice_key = ?3, chosen_at = ?4, counted = ?5
              WHERE id = ?1 AND choice IS NULL`
          ).bind(row.id, b.choice, b.choice_key, t, counts ? 1 : 0),
          classUpdate,
        ]);
        const after = classState(await readClass(env, row.class));
        if (Number((res[0] && res[0].meta && res[0].meta.changes) || 0) !== 1) {
          // A racing reply won: this one counted nothing.
          return answer(row, after, false, false);
        }
        const reverted = b.choice !== "approve" && !!before && before.state === "delegated";
        return answer(row, after, counts, reverted);
      });
    },
  ],

  // ── POST /api/archie/classes/delegation — the operator's `Archie delegate <class>`
  // or `Archie ask first <class>`. delegate is refused for a protected class
  // (409 never_delegable), an unknown one (404), one whose streak is below
  // min_streak (409 not_earned) and for actor archie (403): Archie never moves
  // a class into his own authority. ask_first sets ask_first and streak 0.
  [
    "POST", "/api/archie/classes/delegation",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const c = classOf(b.class);
      if (c === null) return bad("class");
      if (b.decision !== "delegate" && b.decision !== "ask_first") return bad("decision");
      if (b.decision === "delegate" && !(Number.isInteger(b.min_streak) && b.min_streak >= 1 && b.min_streak <= 1000)) {
        return bad("min_streak");
      }
      const actor = typeof b.actor === "string" ? b.actor.trim() : "";
      if (actor.length < 1 || actor.length > 64) return bad("actor");
      if (b.decision === "delegate" && actor === "archie") return json(403, { error: "archie_cannot_delegate" });

      return d1Guarded("archie_classes", async () => {
        const row = await readClass(env, c);
        if (!row) return json(404, { error: `class ${c} not found` });
        if (b.decision === "ask_first") {
          await env.DB.prepare(
            `UPDATE archie_classes SET state = 'ask_first', streak = 0, updated_at = ?2, note = ?3,
                    reverted_at = CASE WHEN state = 'delegated' THEN ?2 ELSE reverted_at END
              WHERE class = ?1`
          ).bind(c, t, `ask first by ${actor}`).run();
          return json(200, { ok: true, class_state: classState(await readClass(env, c)) });
        }
        if (isProtected(row)) return json(409, { error: "never_delegable", class_state: classState(row) });
        if (row.state === "delegated") return json(200, { ok: true, existing: true, class_state: classState(row) });
        const res = await env.DB.prepare(
          `UPDATE archie_classes SET state = 'delegated', delegated_at = ?2, updated_at = ?2, note = ?4
            WHERE class = ?1 AND state = 'ask_first' AND never_delegable = 0 AND streak >= ?3`
        ).bind(c, t, b.min_streak, `delegated by ${actor}`).run();
        const after = await readClass(env, c);
        if (Number((res.meta && res.meta.changes) || 0) !== 1 && after.state !== "delegated") {
          return json(409, { error: "not_earned", streak: Number(after.streak), class_state: classState(after) });
        }
        return json(200, { ok: true, class_state: classState(after) });
      });
    },
  ],
];
