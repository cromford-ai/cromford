// settings routes — the console's knob store.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { d1Guarded, json, nowIso } from "../lib/http.js";
import {
  LANES_REGISTRY, hmacSha256Hex, PRUNE_SEED_SQL, REGISTRY_SEED_ACTOR, SEED_REGISTRY_SQL, SETTING_KEY_RE,
  ensureTable, registrySeedRows, seedRegistryPlan, strictInt, unsettableKnob,
} from "../lib/core.js";
import { CAP_KEY_PREFIX_RE, capChangeStmt } from "../lib/cost-caps.js";
import { invalidateSettings, settingsRows } from "../lib/settings-cache.js";
import { CONFIG_KINDS, configChangeStmts, listConfigChanges } from "../lib/config-changes.js";
import {
  PROTECTED_HUMAN_KEYS, PROTECTED_PREFIXES, humanTokenOk, isProtectedSetting, protectedMode, settingProof,
  settingSigMessage, settingSigMessageV2, sigKeyOf,
} from "./verdicts.js";
import {
  SEED_GATE_MAX_AGE_S, SEED_GATE_TICK_WINDOW_S, fleetGateVerdict, planFingerprint,
} from "../lib/seed-apply.js";

const ACCOUNT_KEY_RE = /^account\.[a-z0-9_.-]+$/;
const ACCOUNT_LABEL_RE = /^[A-Za-z0-9][A-Za-z0-9:._@-]{0,63}$/;
// BH-2411: the one settings key family that holds a whole document, not a knob.
const CONF_DOC_KEY_RE = /^conf\.readiness-levels(\.[a-z0-9_-]+)?$/;
// BH-4846: a console custom theme, one row per theme holding its JSON document
// (~2.3 KB). The console proxy validates the document itself; the worker caps
// it at 4096 like the conf doc, insists on a JSON object, and lets this one
// prefix be deleted (DELETE /api/settings/<key>, below).
const THEME_KEY_RE = /^ui\.theme\.custom\.[a-z0-9-]{1,40}$/;
const PLAN_FP_RE = /^[0-9a-f]{64}$/;
const SEED_RUNS_LIMIT = 20;

// The seed's plan as GET /api/settings/seed-registry/plan answers it, plan_fp
// included (BH-2521.2). One function, so the 409 plan_moved hands back exactly
// what the GET would.
async function seedPlan(env, t) {
  const rows = registrySeedRows(LANES_REGISTRY);
  const cur = await env.DB.prepare("SELECT key, value, actor FROM settings").all();
  const plan = seedRegistryPlan(rows, cur.results || []);
  return { ...plan, plan_fp: await planFingerprint(plan), actor: REGISTRY_SEED_ACTOR, as_of: t };
}

// A gate knob's settings row wins when it parses as a positive int; otherwise
// the documented fallback (the claimTtl shape in routes/restore-lab.js).
async function positiveSetting(env, key, fallback) {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first("value");
  const n = strictInt(v);
  return n !== null && n > 0 ? n : fallback;
}

// ── The registry seed (BH-1511.1) ──────────────────────────────────────
// Mirrors every registered knob's static default into `settings`, from the
// registry THIS DEPLOY BAKED IN (catalog/lanes.json, lanes + libs) — never
// from the request, so the route cannot be used to write an arbitrary key.
// One guarded upsert per row (SEED_REGISTRY_SQL): missing rows are inserted,
// the seed's own rows follow a moved default, and a row any other actor
// wrote is never touched. Idempotent: a second call changes nothing.
// Chunked so no single D1 batch carries the whole registry.
// BH-2521.2 moved this body out of the POST route so the console apply runs
// the very same seed; the CLI POST answers byte-identically.
async function runSeed(env, t) {
  const rows = registrySeedRows(LANES_REGISTRY);
  // The keys, not only the count (review round 2 of #1565): only an
  // operator's PUT /api/settings is audited in config_changes (BH-2376), never
  // the seed's own writes, so this response is still the only per-key record
  // of which rows the seed wrote, and the CLI prints it.
  const changedKeys = [];
  for (let i = 0; i < rows.length; i += 100) {
    const chunk = rows.slice(i, i + 100);
    const res = await env.DB.batch(chunk.map((r) =>
      env.DB.prepare(SEED_REGISTRY_SQL).bind(r.key, r.value, r.note, REGISTRY_SEED_ACTOR, t)));
    (res || []).forEach((x, j) => { if (Number(x?.meta?.changes || 0) > 0) changedKeys.push(chunk[j].key); });
  }
  const changed = changedKeys.length;
  // ORPHANS (BH-1511.1 review, I1): a seed-owned row whose knob left the
  // registry — renamed, removed, default set to null — is deleted, so the
  // table never goes on showing a default the code no longer has. The
  // actor guard is in PRUNE_SEED_SQL itself, so an operator's row survives
  // whatever this list says.
  const keep = new Set(rows.map((r) => r.key));
  const owned = await env.DB.prepare("SELECT key, actor FROM settings WHERE actor=?1")
    .bind(REGISTRY_SEED_ACTOR).all();
  // BH-2564: a `conf.*` row is never a registry knob — the caps seed
  // (POST /api/cost-caps/seed) owns those, so this prune leaves them alone.
  const orphans = (owned.results || [])
    .filter((r) => r.actor === REGISTRY_SEED_ACTOR && !keep.has(r.key) && !r.key.startsWith("conf."))
    .map((r) => r.key);
  for (let i = 0; i < orphans.length; i += 100) {
    await env.DB.batch(orphans.slice(i, i + 100).map((k) =>
      env.DB.prepare(PRUNE_SEED_SQL).bind(k, REGISTRY_SEED_ACTOR)));
  }
  invalidateSettings(env);   // BH-5781
  return { rows: rows.length, changed, pruned: orphans.length,
    changed_keys: changedKeys, pruned_keys: orphans };
}

// A stored key list this route wrote is a JSON array; anything else (NULL on a
// started/failed run) reads as [] rather than 500ing the whole history.
function keyList(v) {
  try { const a = JSON.parse(v); return Array.isArray(a) ? a : []; } catch { return []; }
}

// BH-3846: a protected switch's `.sig` row is never echoed. A v1 setting
// signature has no nonce, so on a key with no setting_sigs row (BH-3905) a
// signed `shadow` a reader saved could be written back over a later signed
// `enforce` and verify. Hiding it here keeps it from every bearer of
// HARNESS_SECRET; a D1 reader can still SELECT it, which is why the
// HUMAN_VERDICT_ENFORCE floor is a required rollout step, not an option.
function redactSig(row) {
  return PROTECTED_HUMAN_KEYS.some((k) => row.key === `${k}.sig`) ? { ...row, value: null, redacted: true } : row;
}

// ── The lead_* rows behind the signature (BH-4090, BH-3905 item 10) ──────
// lead_authority.* and risk_tier.* (PROTECTED_PREFIXES) are signed into
// setting_sigs on every accepted PUT (BH-4087). A row whose newest signature
// does not verify was written around the PUT (a raw D1 write), and is judged
// by human_verdict_sig_mode: shadow reads it as stored with a warn; enforce
// (or a mode that cannot be read) reads it as the strict answer.
const isLeadKey = (key) => PROTECTED_PREFIXES.some((p) => key.startsWith(p));

// proof: settingProof's answer for the row. trusted: the stored answer can be
// used as is: the row's own signature verifies, or there is no row and the key
// was never signed. A row deleted after it was signed is not trusted, and an
// unreadable setting_sigs (proof null) never is.
async function leadProof(env, key, row) {
  const proof = await settingProof(env, key, row ? row.value : null);
  return { proof, trusted: row ? proof === "proven" : proof === "none" };
}

// The effective value of a lead_* row:
//   { kind: "stored" }                    trusted, or shadow (warned)
//   { kind: "human", stored_value }       lead_authority.* unproven under enforce
//   { kind: "conflict" }                  risk_tier.* unproven under enforce
async function effectiveLead(env, key, row) {
  const { proof, trusted } = await leadProof(env, key, row);
  if (trusted) return { kind: "stored" };
  const why = proof === null ? "setting_sigs unreadable" : !row ? "deleted after signing"
    : proof === "none" ? "unsigned" : "signature mismatch";
  if (await protectedMode(env, "human_verdict_sig_mode") === "shadow") {
    console.warn(`[settings] BH-3905 unproven ${key} (${why}): reading the stored value in shadow`);
    return { kind: "stored" };
  }
  if (key.startsWith("lead_authority.")) {
    console.warn(`[settings] BH-3905 unproven ${key} (${why}): reading human`);
    return { kind: "human", stored_value: row ? row.value : null };
  }
  console.warn(`[settings] BH-3905 unproven ${key} (${why}): answering 409`);
  return { kind: "conflict" };
}

// Is `to` looser than `from` (the current value as judged; null = no row,
// undefined = unknowable)? null when a bearer may write it, else what the 403
// says. Authority is normalised the way bin/lib/lead-authority.sh reads it, with
// all whitespace removed (la_decide); risk_tier.* is a whitespace-split glob set.
function leadLoosening(key, from, to) {
  if (key.startsWith("lead_authority.")) {
    const f = from == null ? from : from.replace(/\s+/g, "");
    const t = to.replace(/\s+/g, "");
    if (t === "human") return null;
    if (t === "human:precision") return f === "human" ? {} : null;
    return f === null || f === "lane" || f === "human:precision" ? null : {};
  }
  if (from === undefined) return {};
  const globs = (v) => (v || "").split(/\s+/).filter(Boolean);
  const next = new Set(globs(to));
  const removed = [...new Set(globs(from))].filter((g) => !next.has(g));
  return removed.length ? { removed } : null;
}

export const routes = [
  // ── Operator settings (BH-283/371) ─────────────────────────────────────
  // One row per number an operator may need to change without a deploy. The
  // value is stored as TEXT and the consumer parses it; the API's whole job
  // is to refuse a key or a value that would read as something else later.
  //
  // BH-1000: all three settings routes are wrapped in d1Guarded, not just the
  // one the addendum named. They are three paths to the SAME datum (D15), and
  // the one that 500'd unnoticed for three weeks was the read of a single key.
  [
    "GET", "/api/settings",
    async ({ env, t }) => {
      return d1Guarded("settings", async () => {
      // BH-5781: the rows come from the per-isolate snapshot; the lead_* proof
      // below still reads setting_sigs live on every call.
      const { rows } = await settingsRows(env);
      // BH-4090: a lead_* row says whether its signature verifies (null =
      // setting_sigs unreadable); its value is never rewritten here.
      const settings = await Promise.all(rows.map(async (row) => {
        if (!isLeadKey(row.key)) return redactSig(row);
        const { proof } = await leadProof(env, row.key, row);
        return { ...row, proven: proof === null ? null : proof === "proven" };
      }));
      return json(200, { settings, as_of: t });
      });
    },
  ],

  // THE SEED'S DRY RUN (review round 2 of #1565): what POST
  // /api/settings/seed-registry would insert, move and prune, from the same
  // registry and the same actor guards, and it writes nothing. A GET and not a
  // flag on the POST on purpose: a worker that predates the flag would ignore
  // it and seed for real. It sits ABOVE the `/api/settings/` prefix, which
  // would otherwise answer it as a malformed key.
  [
    "GET", "/api/settings/seed-registry/plan",
    async ({ env, t }) => {
      return d1Guarded("settings", async () => json(200, await seedPlan(env, t)));
    },
  ],

  // ── The console apply (BH-2521.2) ──────────────────────────────────────
  // The console's path to the seed, with the gate the CLI enforces and a
  // human actor. In order, and every exit before (e) writes nothing:
  // (a) 400 on a blank actor or a plan_fp that is not 64 lowercase hex;
  // (b)+(c) 409 fleet_gate unless every box that ticked a lane inside the
  // window reported a harness commit recently; (d) 409 plan_moved when the
  // plan the operator looked at is not the plan the seed would run now;
  // (e) a `started` run row; (f) the seed; (g) `applied` with what it wrote,
  // or `failed` with the error and the throw rethrown (d1Guarded's 503).
  // Above the `/api/settings/` prefix, like the plan.
  [
    "POST", "/api/settings/seed-registry/apply",
    async ({ env, t, body }) => {
      return d1Guarded("settings", async () => {
      const actor = typeof body.actor === "string" ? body.actor.trim().slice(0, 128) : "";
      if (!actor) return json(400, { error: "actor is required" });
      if (typeof body.plan_fp !== "string" || !PLAN_FP_RE.test(body.plan_fp)) {
        return json(400, { error: "plan_fp must be 64 lowercase hex" });
      }
      const win = await positiveSetting(env, "seed_gate_tick_window_s", SEED_GATE_TICK_WINDOW_S);
      const maxAgeS = await positiveSetting(env, "seed_gate_max_age_s", SEED_GATE_MAX_AGE_S);
      const nowMs = Date.parse(t);
      const since = new Date(nowMs - win * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
      const ticks = await env.DB.prepare("SELECT DISTINCT box FROM lane_ticks WHERE last_tick_at >= ?1").bind(since).all();
      const boxes = await env.DB.prepare("SELECT box, harness_commit, harness_reported_at FROM box_status").all();
      const gate = fleetGateVerdict({ ticks: (ticks.results || []).map((r) => r.box), boxes: boxes.results || [],
        nowS: Math.floor(nowMs / 1000), maxAgeS });
      if (!gate.ok) return json(409, { error: "fleet_gate", boxes: gate.bad });
      const plan = await seedPlan(env, t);
      if (plan.plan_fp !== body.plan_fp) return json(409, { error: "plan_moved", plan });
      // BH-2992.2: created before the run row, so a failed create cannot leave
      // the seed applied under a run that still says `started`.
      await ensureTable(env, "config_changes");

      const ins = await env.DB.prepare(
        "INSERT INTO registry_seed_runs (actor, plan_fp, status, started_at) VALUES (?1,?2,'started',?3)")
        .bind(actor, body.plan_fp, t).run();
      const id = ins?.meta?.last_row_id;
      if (!id) throw new Error("registry_seed_runs insert returned no id");
      let result;
      try {
        result = await runSeed(env, t);
      } catch (e) {
        try {
          await env.DB.prepare("UPDATE registry_seed_runs SET status='failed', error=?1, finished_at=?2 WHERE id=?3")
            .bind(String((e && e.message) || e).slice(0, 500), nowIso(), id).run();
        } catch { /* the original error is the one to surface; the row stays 'started' */ }
        throw e;
      }
      // The `applied` update and its one `registry_seed` config_changes row
      // (BH-2992.2) go in one batch; the `failed` path above writes none.
      await env.DB.batch([
        env.DB.prepare(
          `UPDATE registry_seed_runs SET status='applied', rows=?1, changed=?2, pruned=?3, changed_keys=?4,
           pruned_keys=?5, finished_at=?6 WHERE id=?7`)
          .bind(result.rows, result.changed, result.pruned, JSON.stringify(result.changed_keys),
            JSON.stringify(result.pruned_keys), nowIso(), id),
        ...configChangeStmts(env, CONFIG_KINDS.REGISTRY_SEED, body.plan_fp, null, { plan_fp: body.plan_fp, run_id: id },
          ["plan_fp", "run_id"], actor, body.reason, t),
      ]);
      return json(200, { id, actor, ...result, as_of: t });
      });
    },
  ],

  // The console apply's history, newest first. One extra row is read so
  // `truncated` is measured, not guessed.
  [
    "GET", "/api/settings/seed-registry/runs",
    async ({ env }) => {
      return d1Guarded("settings", async () => {
      const res = await env.DB.prepare("SELECT * FROM registry_seed_runs ORDER BY id DESC LIMIT ?1")
        .bind(SEED_RUNS_LIMIT + 1).all();
      const rows = res.results || [];
      const runs = rows.slice(0, SEED_RUNS_LIMIT).map((r) => ({
        id: r.id, actor: r.actor, plan_fp: r.plan_fp, status: r.status, rows: r.rows, changed: r.changed,
        pruned: r.pruned, changed_keys: keyList(r.changed_keys), pruned_keys: keyList(r.pruned_keys),
        error: r.error, started_at: r.started_at, finished_at: r.finished_at,
      }));
      return json(200, { runs, truncated: rows.length > SEED_RUNS_LIMIT });
      });
    },
  ],

  // BH-2376: the `setting` rows PUT /api/settings writes, newest first — a
  // filtered read of config_changes (one audit store). ABOVE the prefix.
  [
    "GET", "/api/settings-changes",
    async ({ env, url, t }) => {
      return d1Guarded("settings", async () => {
      const key = url.searchParams.get("key");
      if (key !== null && !SETTING_KEY_RE.test(key)) return json(400, { error: "key must match ^[a-z0-9_.-]{1,64}$" });
      await ensureTable(env, "config_changes");
      const out = await listConfigChanges(env,
        { kind: CONFIG_KINDS.SETTING, name: key, limit: url.searchParams.get("limit") }, t);
      return json(out.error ? 400 : 200, out);
      });
    },
  ],

  [
    "GET", { prefix: "/api/settings/" },
    async ({ env, path, t }) => {
      return d1Guarded("settings", async () => {   // BH-1000: body unchanged
      // decodeURIComponent THROWS on a torn escape (`%E0%A4%A`), and an uncaught
      // throw here is a 500 — which every client, this repo's included, reads as
      // "the worker is down". A caller's own malformed URL must not send an
      // operator hunting an outage, so it lands in the same 400 as any other key
      // that could never exist.
      let key;
      try { key = decodeURIComponent(path.slice("/api/settings/".length)); } catch { key = null; }
      // A key that could never exist is a caller bug, and saying "no row" to it
      // would send that caller to its fallback forever without ever complaining.
      if (key === null || !SETTING_KEY_RE.test(key)) return json(400, { error: "key must match ^[a-z0-9_.-]{1,64}$" });
      // BH-5781: a lead_* row is read live, never from the snapshot, so its
      // signature is always judged against the row D1 holds now.
      const row = isLeadKey(key)
        ? await env.DB.prepare("SELECT * FROM settings WHERE key=?1").bind(key).first()
        : (await settingsRows(env)).byKey.get(key) ?? null;
      // BH-4090: an unproven lead_* row under sig enforce answers its strict
      // value: `human` for authority, a 409 (setting_get rc 9) for risk_tier.*.
      const eff = isLeadKey(key) ? await effectiveLead(env, key, row) : { kind: "stored" };
      if (eff.kind === "human") {
        return json(200, { key, setting: { key, value: "human", unproven: true, stored_value: eff.stored_value },
          source: "unproven", as_of: t });
      }
      if (eff.kind === "conflict") {
        return json(409, { error: `${key} signature does not verify; re-PUT it with the human token`, key });
      }
      // 200 with setting:null, not a 404, for the same reason as the retry
      // policy above: "this knob has no row" is a real answer the caller acts
      // on (it uses its documented fallback), and the client's 404 branch means
      // something else entirely (a ledger miss).
      return json(200, { key, setting: row ? redactSig(row) : null, source: row ? "settings" : "none", as_of: t });
      });
    },
  ],

  // ── The registry seed (BH-1511.1): the CLI's POST, see runSeed above ──
  [
    "POST", "/api/settings/seed-registry",
    async ({ env, t }) => {
      return d1Guarded("settings", async () =>
        json(200, { ...(await runSeed(env, t)), actor: REGISTRY_SEED_ACTOR, as_of: t }));
    },
  ],

  [
    "PUT", "/api/settings",
    async ({ req, env, t, body }) => {
      return d1Guarded("settings", async () => {   // BH-1000: body unchanged
      const key = String(body.key || "").trim();
      if (!SETTING_KEY_RE.test(key)) return json(400, { error: "key must match ^[a-z0-9_.-]{1,64}$" });
      // BH-3831: the switch that makes the human verdict token mandatory is
      // changed only by the holder of that token. With the bearer alone, any box
      // could flip enforce back to shadow and the enforcement would be decorative.
      // BH-3846: the same for human_verdict_sig_mode, and a protected key's
      // `.sig` row is written only by the worker, below, never by a caller.
      const isProtected = PROTECTED_HUMAN_KEYS.includes(key);
      // BH-3905: the keys signed into setting_sigs: the two switches and the
      // lead_* prefixes. Signing adds no gate; the rules below still decide.
      const isSigned = isProtectedSetting(key);
      if (PROTECTED_HUMAN_KEYS.some((k) => key === `${k}.sig`)) {
        return json(400, { error: `${key} is written only by the worker, alongside a human-token PUT of ${key.slice(0, -4)}` });
      }
      if (isProtected && !humanTokenOk(req, env)) {
        return json(403, { error: `${key} changes need the human verdict token (x-human-verdict-token)` });
      }
      // A LANE KNOB THE REGISTRY MARKS `settable: false` IS REFUSED HERE
      // (BH-1165 review). Wiring all 78 lanes registered every `${X:-...}` an
      // automatic script reads, and about eighty of those are the command a
      // lane runs, the host it sends `Bearer $HARNESS_SECRET` to, the path it
      // deletes under, the identity it claims, or a test seam. bin/lib/lane-gate.sh
      // exports a settings row into a lane cron runs as ROOT, so this is the
      // last of four refusals (CLI, seed, console, here) and the only one that
      // covers a caller holding the bearer directly. Unknown keys are untouched:
      // this table carries plenty that is not a lane knob.
      const unsettable = unsettableKnob(key);
      if (unsettable) {
        return json(400, {
          error: `${unsettable} is not settable from the control plane — it is a command/host/path/identity a root lane runs (catalog/lanes.json: settable:false)`,
        });
      }
      // A JSON number is the natural way to write a threshold, so it is accepted
      // and STRINGIFIED here — once, at the only place that writes the column.
      // Anything else (null, boolean, object, absent) is refused rather than
      // coerced: "true" or "[object Object]" as a threshold is a number nobody
      // chose, and it would read as a real setting for as long as it sat there.
      let value;
      if (typeof body.value === "number" && Number.isFinite(body.value)) value = String(body.value);
      else if (typeof body.value === "string") value = body.value.trim();
      else return json(400, { error: "value must be a string or a finite number" });
      // BH-2411: catalog/readiness-levels.json is ONE row holding the whole JSON
      // table (~1.7 KB), so that document key and its box row take up to 4096
      // characters. Every other key keeps 256 and its error text.
      const isTheme = THEME_KEY_RE.test(key);
      const max = CONF_DOC_KEY_RE.test(key) || isTheme ? 4096 : 256;
      if (!value || value.length > max) return json(400, { error: `value must be non-empty and <= ${max} chars` });
      // BH-4090: a bearer write that LOOSENS a lead_* row needs the human token,
      // judged against the effective current value, so a raw D1 write cannot be
      // laundered by a "tightening" on top of it. Not mode-gated. Before every write.
      if (isLeadKey(key) && !humanTokenOk(req, env)) {
        const cur = await env.DB.prepare("SELECT * FROM settings WHERE key=?1").bind(key).first();
        const eff = await effectiveLead(env, key, cur);
        const from = eff.kind === "human" ? "human" : eff.kind === "conflict" ? undefined : cur ? String(cur.value) : null;
        const loose = leadLoosening(key, from, value);
        if (loose) {
          const shown = from === undefined ? "unproven" : from;
          return json(403, {
            error: `${key} ${shown} -> ${value} loosens it and needs the human verdict token (x-human-verdict-token); use bin/protected-setting.sh`,
            key, from: shown, to: value, ...loose,
          });
        }
      }
      if (isTheme) {
        let doc = null;
        try { doc = JSON.parse(value); } catch { doc = null; }
        if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
          return json(400, { error: `${key} must hold a JSON object (a theme document)` });
        }
      }
      // AN ACCOUNT PIN HOLDS A LABEL, NEVER A TOKEN (BH-1657). `account.<project>`
      // names the file under accounts.d a box reads the project's own Claude
      // token from, or `shared` to unpin. This PUT is the one path that writes the
      // row, so a pasted token is refused here, before any write, and the
      // message does not repeat the value back.
      if (ACCOUNT_KEY_RE.test(key) && value !== "shared"
          && (/^sk-/i.test(value) || !ACCOUNT_LABEL_RE.test(value) || value.includes(".."))) {
        return json(400, {
          error: "an account.<project> value must be an account label (letters, digits, : . _ @ -, at most 64, no ..) or `shared` — never a token",
        });
      }
      // BH-2376: the change row's reason, refused over 512 before any DB touch.
      const reasonIn = body.reason == null ? null : String(body.reason).trim();
      if (reasonIn && reasonIn.length > 512) return json(400, { error: "reason must be <= 512 chars" });
      let warning = null;
      if (key === "lane.reconcile-prs.reconcile_prs_owner" && value !== "hub") {
        // BH-1609: an owner that names no fleet box would leave every box skipping the lane.
        if (value.replace(/[^A-Za-z0-9._-]/g, "") !== value) return json(400, { error: "owner must match [A-Za-z0-9._-]" });
        const boxes = await env.DB.prepare("SELECT box FROM box_status ORDER BY box").all();
        const known = (boxes.results || []).map((r) => r.box);
        if (known.length && !known.includes(value)) return json(400, { error: `${value} is not a fleet box`, known });
        if (!known.length) warning = "fleet list empty — owner not checked";
      }
      const note = body.note ? String(body.note).slice(0, 512) : null;
      const actor = body.actor ? String(body.actor).slice(0, 128) : "api";
      // THE SEED'S ACTOR IS RESERVED (BH-1511.1 review, M2). A row carrying it
      // ranks below the env on every box, is hidden from /api/lanes/status and
      // is rewritten by the next seed: an operator value written under it would
      // be invisible and would not apply. Only POST /api/settings/seed-registry
      // writes it.
      if (actor === REGISTRY_SEED_ACTOR) {
        return json(400, { error: `actor '${REGISTRY_SEED_ACTOR}' is reserved for POST /api/settings/seed-registry` });
      }
      const upsert = env.DB.prepare(
        `INSERT INTO settings (key, value, note, actor, updated_at)
         VALUES (?1,?2,?3,?4,?5)
         ON CONFLICT(key) DO UPDATE SET value=?2, note=COALESCE(?3, note),
           actor=?4, updated_at=?5`
      ).bind(key, value, note, actor, t);
      // EVERY VALUE CHANGE IS AUDITED, IN THE UPSERT'S BATCH (BH-2376). A cap
      // key (conf.cost-caps.* / conf.lane-caps.*, box rows included) keeps its
      // BH-2564 cost_cap_changes row and its `cost_cap` config_changes row
      // (BH-2992.2), and gets NO `setting` row: one audit row per write. Every
      // other key gets one `setting` row. A same-value write (the conductor's
      // republish, the wake cursor) costs this one SELECT and logs nothing.
      await ensureTable(env, "config_changes");
      const isCap = CAP_KEY_PREFIX_RE.test(key);
      if (isCap) await ensureTable(env, "cost_cap_changes");
      const was = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first();
      const before = was ? String(was.value) : null;
      const reason = reasonIn || note;
      let audit;
      if (isCap) {
        audit = before === value ? [] : [
          capChangeStmt(env, key, before, value, actor, reason, t),
          ...configChangeStmts(env, CONFIG_KINDS.COST_CAP, key, before === null ? null : { value: before },
            { value }, ["value"], actor, reason, t),
        ];
      } else {
        audit = configChangeStmts(env, CONFIG_KINDS.SETTING, key, before === null ? null : { value: before },
          { value }, ["value"], actor, reason, t);
      }
      // BH-3846: a protected switch is signed in the value's own batch, so a
      // value and its signature are never written apart. No key: written
      // unsigned, and an older signature then mismatches and reads enforce.
      // BH-3905: every signed key appends a setting_sigs row at the next seq,
      // FIRST in the batch, so a seq another PUT took in the meantime fails the
      // batch before the value is written; that race answers 409. The v1
      // `.sig` row is kept for the two switches only.
      const sk = isSigned ? sigKeyOf(env) : null;
      const stmts = [];
      let seq = null;
      if (sk) {
        await ensureTable(env, "setting_sigs");
        seq = Number((await env.DB.prepare("SELECT COALESCE(MAX(seq),0)+1 AS seq FROM setting_sigs WHERE key=?1")
          .bind(key).first()).seq);
        stmts.push(env.DB.prepare(
          "INSERT INTO setting_sigs (key, seq, sig, actor, at) VALUES (?1,?2,?3,?4,?5)"
        ).bind(key, seq, await hmacSha256Hex(sk, settingSigMessageV2(key, value, seq)), actor, t));
      }
      stmts.push(upsert);
      if (sk && isProtected) {
        stmts.push(env.DB.prepare(
          `INSERT INTO settings (key, value, note, actor, updated_at)
           VALUES (?1,?2,NULL,?3,?4)
           ON CONFLICT(key) DO UPDATE SET value=?2, actor=?3, updated_at=?4`
        ).bind(`${key}.sig`, await hmacSha256Hex(sk, settingSigMessage(key, value)), actor, t));
      }
      try {
        if (stmts.length > 1 || audit.length) await env.DB.batch([...stmts, ...audit]);
        else await upsert.run();
      } catch (e) {
        if (/UNIQUE constraint failed: setting_sigs/i.test(String((e && e.message) || e))) {
          return json(409, { error: "concurrent protected write, retry" });
        }
        throw e;
      }
      invalidateSettings(env);   // BH-5781: after the write, not before it
      const row = await env.DB.prepare("SELECT * FROM settings WHERE key=?1").bind(key).first();
      const out = warning ? { setting: row, warning } : { setting: row };
      return json(200, isSigned ? { ...out, signed: Boolean(sk), ...(sk ? { sig_seq: seq } : {}) } : out);
      });
    },
  ],

  // BH-4846: deleting a console custom theme. The only settings row a caller
  // can delete, so every other key is a 400 before any DB touch. The row's
  // delete and its `setting` config_changes row (before = the value, after =
  // null) go in one batch: no deleted row without its audit, no audit for a
  // row that stayed. A missing row is 200 deleted:false (a retried delete is
  // not an error) and writes nothing. The actor rides in the query, stamped by
  // the console proxy like the call-guard reset's.
  [
    "DELETE", { prefix: "/api/settings/" },
    async ({ env, path, url, t }) => {
      return d1Guarded("settings", async () => {
      let key;
      try { key = decodeURIComponent(path.slice("/api/settings/".length)); } catch { key = null; }
      if (key === null || !THEME_KEY_RE.test(key)) {
        return json(400, { error: "only a ui.theme.custom.<slug> row can be deleted" });
      }
      const actor = (url.searchParams.get("actor") || "").trim().slice(0, 128) || "api";
      const reason = url.searchParams.get("reason");
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first();
      if (!was) return json(200, { key, deleted: false });
      await env.DB.batch([
        env.DB.prepare("DELETE FROM settings WHERE key=?1").bind(key),
        ...configChangeStmts(env, CONFIG_KINDS.SETTING, key, { value: String(was.value) }, null, ["value"], actor, reason, t),
      ]);
      invalidateSettings(env);   // BH-5781
      return json(200, { key, deleted: true });
      });
    },
  ],
];
