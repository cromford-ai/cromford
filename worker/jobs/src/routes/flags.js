// flags routes — pause flags — rows the console sets, files the boxes read.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// Since BH-2377, PUT batches a `flag` config_changes row with its upsert when
// the flag is new or `active` changed, and GET /api/flag-changes reads them.
// Since BH-4153 the ported families (FLAG_PORTED_RE in lib/harness-flags.js)
// are harness_flags rows keyed (scope, name): PUT and DELETE write the row and
// the audit row in one batch, GET merges the two stores, and every other name
// answers exactly as before. Since BH-4154 a ported write no longer mirrors
// into pause_flags: every worker reader picks the store by name.
// Since BH-5635 a pause_flags row (a NON-ported name, wip-limit-* say) carries
// an optional `value` (the flag file's content), and a value change is audited
// too. The routes widen an old table with ensureColumns before they read or
// write it. A ported name's value is the harness_flags column (BH-4153).
// Since BH-7819 the legacy PUT and DELETE are inside d1OverloadGuarded too, so a
// D1 overload give-up is a 503 "pause_flags unavailable", not a thrown 500.

import { d1Guarded, d1OverloadGuarded, json } from "../lib/http.js";
import { ensureColumns, ensureTable } from "../lib/core.js";
import { isD1Overloaded } from "../lib/d1-retry.js";
import { CONFIG_KINDS, configChangeStmts, listConfigChanges } from "../lib/config-changes.js";
import {
  FLAG_NAME_RE, VALUE_MAX, isPortedFlag, validScope, projectPauseRow,
  readPortedFlag, upsertStmt, fleetFlagRows,
} from "../lib/harness-flags.js";
import { routes as mainRed } from "./main-red.js";

const LIST_MAX = 500;
const PREFIX_RE = /^[A-Za-z0-9._-]*$/;

// The legacy PUT body for a name that is NOT ported, from before BH-4153
// (DELETE of a non-ported name runs it with active 0 and no value). BH-5635:
// `value` is the flag file's content, NULL = an empty file.
async function putLegacy(env, t, name, active, actor, reason, value = null) {
  // Every write that creates the row or changes `active` appends one `flag`
  // config_changes row (actor, reason, old and new active) in the SAME batch
  // as the upsert (BH-2377; #3078 began it for `paused-*`, so a Mission
  // Control RESUME is on record). A same-value write (a box re-publishing
  // its file) is not a decision and logs nothing. `value` is audited only
  // when the old or new row has one (BH-5635), so a value-less write keeps its
  // `{"active":N}` audit JSON byte for byte.
  await ensureColumns(env, "pause_flags");
  await ensureTable(env, "config_changes");
  const was = await env.DB.prepare("SELECT active, value FROM pause_flags WHERE name=?1").bind(name).first();
  const fields = (value != null || (was && was.value != null)) ? ["active", "value"] : ["active"];
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO pause_flags (name, active, actor, reason, updated_at, value) VALUES (?1,?2,?3,?4,?5,?6)
       ON CONFLICT(name) DO UPDATE SET active=?2, actor=COALESCE(?3, actor), reason=?4, updated_at=?5, value=?6`
    ).bind(name, active, actor, reason, t, value),
    ...configChangeStmts(env, CONFIG_KINDS.FLAG, name, was, { active, value }, fields, actor, reason, t),
  ]);
  // BH-7819: the batch has committed, as in writePorted (BH-6805).
  let row;
  try {
    row = await env.DB.prepare("SELECT * FROM pause_flags WHERE name=?1").bind(name).first();
  } catch (e) {
    if (!isD1Overloaded(e)) throw e;
    console.warn(`d1-overload: pause_flags read-back ${name} after a committed write, answered 200 written:true after ${e.d1Attempts ?? "?"} attempt(s)`);
    return json(200, { flag: null, written: true });
  }
  return json(200, { flag: row });
}

// One ported write: the harness_flags upsert and the audit row, in ONE batch. The audit row is written when
// the row is new or `active`/`value` changed; `value` and `scope` join the
// audited fields only when they carry something, so a plain fleet pause audits
// as {"active":N} exactly as BH-2377 recorded it.
async function writePorted(env, t, { scope, name, active, value, actor, reason, was }) {
  const after = { active, scope, value };
  const fields = ["active"];
  if (value != null || (was && was.value != null)) fields.push("value");
  if (scope !== "fleet") fields.push("scope");
  await env.DB.batch([
    upsertStmt(env, {
      scope, name, value, actor, reason,
      setAt: active ? t : (was ? was.set_at : t),
      clearedAt: active ? null : t,
    }),
    ...configChangeStmts(env, CONFIG_KINDS.FLAG, name, was, after, fields, actor, reason, t),
  ]);
  // BH-6805: the batch has committed. An overload on the read-back must not be
  // the retryable 503 (req.sh would re-send the write, a second audit row or a
  // false 409). It is a 200 that says the write landed and has no row to show.
  let flag;
  try {
    flag = await readPortedFlag(env, scope, name);
  } catch (e) {
    if (!isD1Overloaded(e)) throw e;
    console.warn(`d1-overload: harness_flags read-back ${name} after a committed write, answered 200 written:true after ${e.d1Attempts ?? "?"} attempt(s)`);
    return json(200, { flag: null, written: true });
  }
  return json(200, { flag });
}

export const routes = [
  // ── Pause flags (phase 3) ──────────────────────────────────────────────
  // Rows, so the operator can pause a project from the console instead of ssh-ing to
  // a box to touch a file. The FILE remains what every existing reader tests
  // (see bin/jobs-client.sh `flag_active`): this table drives the file, it
  // does not replace it, so a worker outage degrades to exactly today's
  // behavior instead of un-pausing a board nobody meant to resume.
  // That still holds for every name EXCEPT the ported families (BH-4153): for
  // those the harness_flags row is the truth and the box keeps a last-good
  // cache, not a file.
  [
    "GET", "/api/flags",
    // BH-4153: both stores, merged, every row in the full shape
    // (fleetFlagRows). A ported name with a fleet harness_flags row comes from
    // that row only, so an old pause_flags mirror row never appears twice.
    async ({ env, url, t }) => {
      const qs = url.searchParams.get("scope");
      const scope = qs === null || qs === "" ? null : validScope(qs);
      if (qs !== null && qs !== "" && scope === null) return json(400, { error: "valid scope required" });
      const prefix = url.searchParams.get("prefix") || "";
      if (!PREFIX_RE.test(prefix) || prefix.length > 128) return json(400, { error: "valid prefix required" });
      const onlyOn = url.searchParams.get("active") === "1" ? 1 : 0;
      await ensureColumns(env, "pause_flags");
      const { flags, truncated } = await fleetFlagRows(env, { scope, prefix, onlyOn, limit: LIST_MAX });
      const out = { flags, as_of: t };
      if (truncated) out.truncated = true;
      return json(200, out);
    },
  ],

  [
    "GET", { prefix: "/api/flags/" },
    async ({ env, url, path, t }) => {
      const name = decodeURIComponent(path.slice("/api/flags/".length));
      if (!name) return json(400, { error: "flag name required" });
      // BH-4153: a ported name is its harness_flags row at ?scope= (fleet by
      // default); any other name is its pause_flags row, in the same shape.
      let flag;
      if (isPortedFlag(name)) {
        const scope = validScope(url.searchParams.get("scope"));
        if (scope === null) return json(400, { error: "valid scope required" });
        const got = await d1OverloadGuarded("harness_flags", async () => {
          await ensureTable(env, "harness_flags");
          return { flag: await readPortedFlag(env, scope, name) };
        }, `GET ${name}`);
        if (got instanceof Response) return got;
        flag = got.flag;
      } else {
        await ensureColumns(env, "pause_flags");
        flag = projectPauseRow(await env.DB.prepare("SELECT * FROM pause_flags WHERE name=?1").bind(name).first());
      }
      // 404 = "no row for this flag", a real answer the client maps to
      // "nothing to reconcile", never to "unpause".
      if (!flag) return json(404, { error: "not found" });
      return json(200, { flag, as_of: t });
    },
  ],

  [
    "PUT", "/api/flags",
    async ({ env, t, body }) => {
      const name = String(body.name || "").trim().slice(0, 128);
      // Flag names become file names under flags/ on every box, so the set of
      // legal characters is the set that cannot escape that directory.
      if (!name || !/^[A-Za-z0-9._-]+$/.test(name)) return json(400, { error: "valid flag name required" });
      if (body.active === undefined || body.active === null) return json(400, { error: "active required" });
      const active = (body.active === true || body.active === 1 || body.active === "1" || body.active === "true") ? 1 : 0;
      const actor = body.actor ? String(body.actor).slice(0, 128) : null;
      const reason = body.reason ? String(body.reason).slice(0, 512) : null;
      if (!isPortedFlag(name)) {
        // BH-5635: the value becomes a flag file's content on every box, so it
        // gets the file-name alphabet. Absent, null or "" is NULL (an empty
        // file). Anything else, a number included, is refused before any write.
        let value = null;
        if (body.value !== undefined && body.value !== null) {
          if (typeof body.value !== "string" || !/^[A-Za-z0-9._-]{0,64}$/.test(body.value)) {
            return json(400, { error: "value must be up to 64 characters of A-Za-z0-9._-" });
          }
          value = body.value || null;
        }
        return d1OverloadGuarded("pause_flags", () => putLegacy(env, t, name, active, actor, reason, value), `PUT ${name}`);
      }

      // BH-4153: a ported name. `expected_set_at` (the flags import, edge 7)
      // is the current row's cleared_at ?? set_at, or "" for no row; a row
      // that moved since the caller read it is a 409 and nothing is written.
      const scope = validScope(body.scope);
      if (scope === null) return json(400, { error: "valid scope required" });
      const value = body.value === undefined || body.value === null ? null : String(body.value).slice(0, VALUE_MAX);
      return d1OverloadGuarded("harness_flags", async () => {
        await ensureTable(env, "harness_flags");
        await ensureTable(env, "config_changes");
        const was = await readPortedFlag(env, scope, name);
        if (typeof body.expected_set_at === "string") {
          const cur = was ? (was.cleared_at ?? was.set_at) : "";
          if (cur !== body.expected_set_at) return json(409, { error: "flag moved", flag: was });
        }
        return writePorted(env, t, { scope, name, active, value, actor, reason, was });
      }, `PUT ${name}`);
    },
  ],

  // BH-4153: clear a flag. A ported name is soft-cleared (cleared_at=t, one
  // audit row); a row already cleared answers 200
  // and writes nothing. Any other name is exactly PUT {active:0}. No row is a
  // 404 either way: a DELETE never creates a flag.
  [
    "DELETE", "/api/flags",
    async ({ env, url, t }) => {
      const name = String(url.searchParams.get("name") || "").trim().slice(0, 128);
      if (!name || !FLAG_NAME_RE.test(name)) return json(400, { error: "valid flag name required" });
      const actor = url.searchParams.get("actor") ? String(url.searchParams.get("actor")).slice(0, 128) : null;
      const reasonIn = url.searchParams.get("reason") ? String(url.searchParams.get("reason")).slice(0, 512) : null;
      if (!isPortedFlag(name)) {
        // BH-7819: an overload on the pre-read is a 503, never a 404.
        return d1OverloadGuarded("pause_flags", async () => {
          const had = await env.DB.prepare("SELECT name FROM pause_flags WHERE name=?1").bind(name).first();
          if (!had) return json(404, { error: "not found" });
          return putLegacy(env, t, name, 0, actor, reasonIn);
        }, `DELETE ${name}`);
      }
      const scope = validScope(url.searchParams.get("scope"));
      if (scope === null) return json(400, { error: "valid scope required" });
      return d1OverloadGuarded("harness_flags", async () => {
        await ensureTable(env, "harness_flags");
        await ensureTable(env, "config_changes");
        const was = await readPortedFlag(env, scope, name);
        if (!was) return json(404, { error: "not found" });
        if (was.cleared_at != null) return json(200, { flag: was });
        return writePorted(env, t, {
          scope, name, active: 0, value: was.value, actor, reason: reasonIn ?? was.reason, was,
        });
      }, `DELETE ${name}`);
    },
  ],

  // BH-2377: the flag history, a filtered read of config_changes (kind flag).
  // A name outside the flag-name alphabet, empty included, is a 400, never an
  // unfiltered read.
  [
    "GET", "/api/flag-changes",
    async ({ env, url, t }) => {
      return d1Guarded("config_changes", async () => {
        const name = url.searchParams.get("name");
        if (name !== null && !/^[A-Za-z0-9._-]+$/.test(name)) return json(400, { error: "valid flag name required" });
        await ensureTable(env, "config_changes");
        const out = await listConfigChanges(env, { kind: CONFIG_KINDS.FLAG, name, limit: url.searchParams.get("limit") }, t);
        return json(out.error ? 400 : 200, out);
      });
    },
  ],

  // BH-2372: the main-red detail and its audited CLEAR, last in this family.
  ...mainRed,
];
