// verdicts routes — BH-1525: head-bound lead/human/box verdicts, as rows.
//
// Same split as every other family here (BH-1195): src/index.js holds the
// ordered table, this file holds the bodies. The one reader in the fleet is
// bin/lib/verdicts.sh, which every merge lane reaches through the block gate
// (bin/lib/block-gate.sh) and the conductor's two clearance reads
// (bin/lib/mc/classify.sh). The one writer outside a test is bin/lead-verdict.sh.
//
// A source=human row also needs the human verdict token to be proven human
// (BH-3831, humanTokenOk below); the row's `auth` column records which
// credential wrote it, and human_verdict_mode decides whether an unproven one
// is recorded (shadow) or refused (enforce).
//
// BH-5352: a source=lead row may instead carry x-participant-token, the token of
// an approved participant machine with the lead-review grant (participantAuth,
// routes/participants.js). It is accepted only when that machine holds a `done`
// lead_review_requests row on the same (repo, pr, head_sha), and the row is
// written with auth='participant' and reviewer = the machine's name. A valid
// lead token takes the lead-token path whatever else is sent.
//
// BH-3846: the token proves who POSTed, not who wrote the D1 row, and a direct
// `wrangler d1 execute` can insert source=human, auth='human-token' itself. So
// the worker also signs a human-token row (verdicts.human_sig, an HMAC keyed by
// the worker-only secret HUMAN_VERDICT_SIG_KEY) and GET judges it: every row
// carries `human_proven`, and under human_verdict_sig_mode=enforce an unproven
// human MERGE `standing` is answered as source=lead. The two switches are
// signed settings rows too (protectedMode below).
//
// POST appends, GET reads. There is no edit route and the table's triggers
// refuse UPDATE/DELETE (schema.sql): a changed mind is a newer row.
//
// NOT /api/verdict. That route answers the BUILD ledger's verdict artifact on a
// job (routes/verdict.js); this table is a PR's reviewed-head record, keyed by
// (repo, pr, head) and written by whoever read the code. Two different facts.
import { d1Guarded, json } from "../lib/http.js";
import { ensureColumns, ensureTable, hexEqual, hmacSha256Hex, strictInt } from "../lib/core.js";
import { participantAuth } from "./participants.js";
import { recordLeadVerdict } from "../lib/pr-gate-intake.js";
import { STANDING_SOURCES } from "../lib/verdict-sources.js";

export const REPO_RE = /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/;
export const SHA_RE = /^[0-9a-f]{40}$/;
export const VERDICT_WORDS = ["MERGE", "MERGE-WITH-NOTES", "BLOCK"];
export const VERDICT_SOURCES = ["lead", "human", "box", "risk-tier"];
// BH-6967: the risk tier of the head a row judges, and the review that wrote it.
export const REVIEW_TIERS = ["low", "medium", "high"];
export const REVIEW_MODES = ["full", "intent", "risk-tier"];
// BH-6970: the break-it verifier's result. k is the count of failing cases, 1..999.
export const BREAK_IT_RE = /^(clean|could-not-run|failed:[1-9][0-9]{0,2})$/;
// The sources whose newest row on a head STANDS: STANDING_SOURCES, in
// lib/verdict-sources.js, the one list the PR gate's event writer reads too.
// A box row is history only. BH-5022: a risk-tier row stands too, because
// vd_standing is what every merge lane reads, not the lead-verdict status. It
// can only ever be a MERGE (validateVerdict) and a later lead/human row on the
// head is newer, so it never outranks a reviewer.
// The sources that need the lead token on top of the bearer: every source that
// stands. One list, so the auth check and STANDING_SOURCES cannot drift apart.
export const LEAD_TOKEN_SOURCES = ["lead", "human", "risk-tier"];

export function prOf(raw) {
  const n = typeof raw === "string" && /^\d+$/.test(raw.trim()) ? Number(raw.trim()) : raw;
  return Number.isInteger(n) && n > 0 && n < 1e9 ? n : null;
}

export function shaOf(raw) {
  const s = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  return SHA_RE.test(s) ? s : null;
}

// optional string field: absent/null -> null; too long or not a string -> error
export function optStr(body, key, max) {
  const v = body[key];
  if (v === undefined || v === null || v === "") return { ok: true, v: null };
  if (typeof v !== "string" || v.length > max) return { ok: false, err: `${key} must be a string, <= ${max} chars` };
  return { ok: true, v };
}

// Every field is refused by name, never clamped or mapped: a verdict row moves
// a merge, so a caller that sent APPROVE must learn the vocabulary, not have
// its word silently translated into one it did not choose.
export function validateVerdict(body) {
  const repo = typeof body.repo === "string" ? body.repo.trim() : "";
  if (!REPO_RE.test(repo)) return { err: "repo must be owner/name" };
  const pr = prOf(body.pr);
  if (pr === null) return { err: "pr must be a positive integer" };
  const head_sha = shaOf(body.head_sha);
  if (!head_sha) return { err: "head_sha must be a full 40-hex commit sha" };
  if (!VERDICT_WORDS.includes(body.verdict)) return { err: `verdict must be one of ${VERDICT_WORDS.join(", ")}` };
  if (!VERDICT_SOURCES.includes(body.source)) return { err: `source must be one of ${VERDICT_SOURCES.join(", ")}` };
  // BH-5022: the rule-based tier signs off, it never judges. Refused by name,
  // never mapped to MERGE: a classifier that tried to BLOCK has a bug to see.
  if (body.source === "risk-tier" && body.verdict !== "MERGE") {
    return { err: `source=risk-tier may only write verdict MERGE (got ${body.verdict}); a BLOCK or notes need a lead or human review` };
  }
  const out = { repo, pr, head_sha, verdict: body.verdict, source: body.source };
  for (const [key, max] of [["reviewer_model", 128], ["reviewer", 128], ["report_url", 1000], ["note", 4000]]) {
    const r = optStr(body, key, max);
    if (!r.ok) return { err: r.err };
    out[key] = r.v;
  }
  if (out.report_url && !/^https:\/\/\S+$/.test(out.report_url)) return { err: "report_url must be an https:// url" };
  // BH-6967: optional, and refused by name like the rest: never lowercased or mapped.
  for (const [key, words] of [["review_tier", REVIEW_TIERS], ["review_mode", REVIEW_MODES]]) {
    const v = body[key];
    if (v === undefined || v === null) { out[key] = null; continue; }
    if (!words.includes(v)) return { err: `${key} must be one of ${words.join(", ")}` };
    out[key] = v;
  }
  // BH-6970: the break-it verifier's result word, verbatim or refused by name.
  if (body.break_it === undefined || body.break_it === null) out.break_it = null;
  else if (typeof body.break_it !== "string" || !BREAK_IT_RE.test(body.break_it)) {
    return { err: "break_it must be clean, failed:<k> (k 1..999) or could-not-run" };
  } else out.break_it = body.break_it;
  return { row: out };
}

// THE LEAD CREDENTIAL (BH-1525 r2). HARNESS_SECRET is on every box, including
// the Fly builders that run agent code, so on its own it may write only a
// `box` row — which never stands. A lead/human row lifts a provenance hold or
// blocks every merge lane, so it also needs LEAD_VERDICT_TOKEN, a worker secret
// (`wrangler secret put LEAD_VERDICT_TOKEN`) whose value lives only on the
// lead's Mac and the hub, never in the env bundle a box is given. Unset on the
// worker is DENIED, never allowed — the same rule bearerOk follows.
export function leadTokenOk(req, env) {
  const got = req.headers.get("x-lead-verdict-token") || "";
  return Boolean(env.LEAD_VERDICT_TOKEN) && got === env.LEAD_VERDICT_TOKEN;
}

// THE HUMAN CREDENTIAL (BH-3831). The lead token is shared: the hub's lead lane
// reads the same file to post source=lead, so with it alone a row cannot prove
// a person wrote it. A source=human row is verified only when it also carries
// HUMAN_VERDICT_TOKEN, a worker secret (`wrangler secret put
// HUMAN_VERDICT_TOKEN`) whose value lives only on the operator's Mac, never on the hub,
// a box or in a bundle. Unset on the worker is DENIED, the leadTokenOk rule.
export function humanTokenOk(req, env) {
  const got = req.headers.get("x-human-verdict-token") || "";
  return Boolean(env.HUMAN_VERDICT_TOKEN) && got === env.HUMAN_VERDICT_TOKEN;
}

// BH-3846. The worker-only signing key, or null when unset. Never on the hub,
// a box or the operator's Mac: only the worker signs and only the worker verifies.
export function sigKeyOf(env) {
  const k = typeof env.HUMAN_VERDICT_SIG_KEY === "string" ? env.HUMAN_VERDICT_SIG_KEY.trim() : "";
  return k || null;
}

// The signed message. The domain prefix keeps a verdict signature and a setting
// signature (settingSigMessage) from ever verifying as each other.
export function verdictSigMessage(row, created_at) {
  return `bh-verdict-v1\n${row.repo}\n${row.pr}\n${row.head_sha}\n${row.verdict}\n${created_at}`;
}

export function settingSigMessage(key, value) {
  return `bh-setting-v1\n${key}\n${value}`;
}

// BH-3905: the setting_sigs message. seq is the row's own per-key sequence, so a
// signature only verifies at the seq it was written under.
export function settingSigMessageV2(key, value, seq) {
  return `bh-setting-v2\n${key}\n${value}\n${seq}`;
}

// null for a non-human row; otherwise true only for a human-token row whose
// human_sig verifies under the key. A NULL sig, a missing key or a missing
// column (a table ensureColumns has not widened yet) is unproven, never proven.
export async function humanProven(row, key) {
  if (!row || row.source !== "human") return null;
  if (row.auth !== "human-token" || !row.human_sig || !key) return false;
  return hexEqual(row.human_sig, await hmacSha256Hex(key, verdictSigMessage(row, row.created_at)));
}

// human_sig -> the lowest verdicts.id carrying it in this repo/pr, for every sig
// on the rows being judged. Only queried when one of them is signed, so the
// standing_only hot path for an unsigned row costs nothing. A read that throws
// (no human_sig column yet) leaves the map empty, which reads unproven.
async function firstRowBySig(env, repo, pr, rows) {
  const out = new Map();
  if (!rows.some((r) => r && r.source === "human" && r.human_sig)) return out;
  try {
    const res = await env.DB.prepare(
      `SELECT human_sig, MIN(id) AS first_id FROM verdicts
        WHERE repo=?1 AND pr=?2 AND human_sig IS NOT NULL GROUP BY human_sig`
    ).bind(repo, pr).all();
    for (const r of res.results || []) out.set(r.human_sig, r.first_id);
  } catch { /* the map stays empty: every signed row reads unproven */ }
  return out;
}

// The settings switches that decide how far a source=human row is trusted. Only
// the human token changes them, and the worker signs every such write: a
// setting_sigs row (BH-3905) and the v1 `<key>.sig` row (routes/settings.js).
export const PROTECTED_HUMAN_KEYS = ["human_verdict_mode", "human_verdict_sig_mode"];

// BH-3905: the key families that are signed into setting_sigs on every
// accepted PUT too: lead_authority.* and risk_tier.*. A code constant, not a
// settings row: a row would let a D1 writer un-protect a key. BH-5022:
// risk_tier.* decides which PRs merge with no review at all, so its globs,
// limits and modes are signed the same way.
export const PROTECTED_PREFIXES = ["lead_authority.", "risk_tier."];

export function isProtectedSetting(key) {
  return PROTECTED_HUMAN_KEYS.includes(key) || PROTECTED_PREFIXES.some((p) => key.startsWith(p));
}

// BH-3905: judge `value` against the key's NEWEST setting_sigs row (by seq).
//   "none"     no row for the key (a v1-only or never-signed key)
//   "proven"   the row's sig is the v2 HMAC of (key, value, its seq)
//   "mismatch" it is not, or there is no key to check it with
//   null       the table could not be created or read
export async function settingProof(env, key, value) {
  let row;
  try {
    await ensureTable(env, "setting_sigs");
    row = await env.DB.prepare("SELECT seq, sig FROM setting_sigs WHERE key=?1 ORDER BY seq DESC LIMIT 1")
      .bind(key).first();
  } catch {
    return null;
  }
  if (!row) return "none";
  const sk = sigKeyOf(env);
  if (!sk) return "mismatch";
  return hexEqual(row.sig, await hmacSha256Hex(sk, settingSigMessageV2(key, value ?? "", row.seq))) ? "proven" : "mismatch";
}

// A protected switch, read so that a direct D1 write can only ever make it
// stricter. First match wins:
//   1. HUMAN_VERDICT_ENFORCE === "1" (worker secret, the floor) -> enforce
//   2. a settings read that throws -> null (BH-3849: the worker cannot tell
//      which rule applies; humanVerdictMode's callers fail closed on it)
//   3. value exactly `enforce` -> enforce (the safe direction needs no proof)
//   4. the key has setting_sigs rows (BH-3905): the newest one by seq decides.
//      It verifies the value -> shadow; it does not, or there is no key to
//      verify it with -> enforce, logged; the table unreadable -> null. A
//      saved signed shadow written back is bound to its old seq and does not
//      verify. A D1 writer that can run DDL could still drop the triggers and
//      delete the newer rows; only the floor closes that.
//   5. no setting_sigs row: the BH-3846 v1 `<key>.sig` rules. A .sig that does
//      not verify, or no key -> enforce, logged; one that verifies -> shadow,
//      and logged, since a v1 sig has no nonce and can be replayed; no .sig row
//      (the unsigned seed) -> shadow. A D1 writer can delete the .sig and write
//      shadow; only the floor closes that, so it is a required rollout step
export async function protectedMode(env, key) {
  if (env.HUMAN_VERDICT_ENFORCE === "1") return "enforce";
  let rows;
  try {
    rows = (await env.DB.prepare("SELECT key, value FROM settings WHERE key IN (?1, ?2)")
      .bind(key, `${key}.sig`).all()).results || [];
  } catch {
    return null;
  }
  const value = rows.find((r) => r.key === key)?.value;
  if (value === "enforce") return "enforce";
  const sk = sigKeyOf(env);
  const mismatch = () => {
    console.warn(`[settings] BH-3846 ${key} signature mismatch${sk ? "" : " (HUMAN_VERDICT_SIG_KEY unset)"}: reading enforce`);
    return "enforce";
  };
  const proof = await settingProof(env, key, value);
  if (proof === null) return null;
  if (proof === "proven") return "shadow";
  if (proof === "mismatch") return mismatch();
  const sig = rows.find((r) => r.key === `${key}.sig`);
  if (!sig) return "shadow";
  if (!sk || !hexEqual(sig.value, await hmacSha256Hex(sk, settingSigMessage(key, value ?? "")))) return mismatch();
  console.warn(`[settings] BH-3905 ${key} carries a v1 signature with no nonce: re-PUT it with the human token`);
  return "shadow";
}

// The human_verdict_mode switch: `enforce` refuses (403) a source=human row
// without the human token and stops an already-recorded auth='lead-token' human
// row from standing on GET; shadow records it with auth='lead-token', logs it,
// and lets it stand. A read that THROWS is null, not shadow (BH-3849): a
// source=human POST is 503 and a GET &head= that carries a source=human row is
// 503 (vd_standing rc 2, a hold). BH-5773 retries and caches that read (below).
// Box and lead posts never need the mode and go through. Read through
// protectedMode, so a directly written shadow over a signed enforce still reads
// enforce (BH-3846).
// BH-5773: one slow settings read failed every verdict read and write. Read once
// more after MODE_RETRY_DELAY_MS; if that also fails, answer with the last
// good read of THIS isolate's env.DB when it is at most MODE_CACHE_TTL_MS old.
// No good read = no cache = null, so BH-3849's fail-closed still holds at cold
// start. Keyed on env.DB like ensureTable/ensureColumns (core.js). Code
// constants on purpose: they bound a fallback for a settings read that failed,
// so they cannot be read from that same table.
export const MODE_CACHE_TTL_MS = 60_000;
export const MODE_RETRY_DELAY_MS = 100;
const modeCache = new WeakMap();
async function humanVerdictMode(env) {
  let mode = await protectedMode(env, "human_verdict_mode");
  if (mode === null) {
    await new Promise((r) => setTimeout(r, MODE_RETRY_DELAY_MS));
    mode = await protectedMode(env, "human_verdict_mode");
  }
  const db = env.DB;
  const keyable = db !== null && typeof db === "object";
  if (mode !== null) {
    if (keyable) modeCache.set(db, { value: mode, at: Date.now() });
    return mode;
  }
  const c = keyable ? modeCache.get(db) : undefined;
  if (c && Date.now() - c.at <= MODE_CACHE_TTL_MS) {
    console.warn(`[verdicts] BH-5773 human_verdict_mode unreadable; using ${c.value}, read ${Math.round((Date.now() - c.at) / 1000)}s ago`);
    return c.value;
  }
  return null;
}

// THE CLIENT LEVEL (BH-3565). bin/lead-verdict.sh sends x-lead-verdict-client
// on a lead/human post (2 = it checks the head and publishes the lead-verdict
// status). A checkout older than that records a row with no status, and a
// shipped script cannot be made to refuse itself, so the worker does: below the
// lead_verdict_min_client settings row the post is 426 and nothing is written.
// Missing or junk header = level 0. The knob seeds 0 (off); an unreadable
// settings row is also off, so a D1 read failure never freezes lead verdicts.
async function leadClientMin(env) {
  try {
    const n = strictInt(await env.DB.prepare("SELECT value FROM settings WHERE key='lead_verdict_min_client'").first("value"));
    return n !== null && n > 0 ? n : 0;
  } catch {
    return 0;
  }
}

export const routes = [
  [
    "POST", "/api/verdicts",
    async ({ req, env, t, body }) => {
      return d1Guarded("verdicts", async () => {
        const v = validateVerdict(body || {});
        if (v.err) return json(400, { error: v.err });
        // BH-5352: without the lead token, a source=lead row may still come from
        // an approved participant holding the lead-review grant, but only on a
        // head it holds a `done` lead review for. Never human or risk-tier.
        let participant = null;
        const lead = leadTokenOk(req, env);
        const ptok = (req.headers.get("x-participant-token") || "").trim();
        if (v.row.source === "lead" && !lead && ptok) {
          const a = await participantAuth(req, env, "lead-review");
          if (!a.ok) return json(403, { error: `participant: ${a.why}` });
          await ensureColumns(env, "lead_review_requests");
          const claim = await env.DB.prepare(
            `SELECT id, job_id FROM lead_review_requests
              WHERE repo=?1 AND pr=?2 AND head_sha=?3 AND status='done' AND participant=?4`
          ).bind(v.row.repo, v.row.pr, v.row.head_sha, a.machine.name).first();
          if (!claim) {
            return json(403, { error: `participant ${a.machine.name} holds no done lead review on ${v.row.repo}#${v.row.pr} @ ${v.row.head_sha.slice(0, 12)}` });
          }
          participant = a.machine;
        } else if (LEAD_TOKEN_SOURCES.includes(v.row.source) && !lead) {
          return json(403, { error: `source=${v.row.source} needs the lead verdict token (x-lead-verdict-token); HARNESS_SECRET alone may write source=box only` });
        }
        if (LEAD_TOKEN_SOURCES.includes(v.row.source)) {
          const min = await leadClientMin(env);
          const got = strictInt(req.headers.get("x-lead-verdict-client") || "") ?? 0;
          if (min > 0 && got < min) {
            return json(426, {
              error: `this lead-verdict.sh is client level ${got}; the worker requires ${min} (BH-3348 head check + lead-verdict status). git pull the checkout that posted this and re-run`,
              client_level: got, required: min,
            });
          }
        }
        // BH-3831: the credential that wrote the row, kept on it (verdicts.auth).
        // A human row without the human token is refused in enforce mode and
        // recorded as auth='lead-token' in shadow: never rewritten to source=lead,
        // for the reason validateVerdict gives above.
        const r = v.row;
        let auth = "secret";
        if (r.source === "lead" || r.source === "risk-tier") auth = "lead-token";
        if (r.source === "human") auth = humanTokenOk(req, env) ? "human-token" : "lead-token";
        // BH-5352: the row names the authenticated machine, never a body reviewer.
        if (participant) {
          auth = "participant";
          r.reviewer = participant.name;
        }
        const mode = await humanVerdictMode(env);
        // BH-3849: fail closed. Before ensureTable/INSERT, so nothing is written;
        // a human-token post too, since without the mode the rule is unknown.
        if (r.source === "human" && mode === null) {
          console.warn("[verdicts] BH-3849 refused source=human: human_verdict_mode unreadable", `${r.repo}#${r.pr}`, r.head_sha.slice(0, 12), r.reviewer || "-");
          return json(503, {
            error: "human_verdict_mode could not be read; a source=human verdict is refused until it can (fail closed)",
            human_verdict_mode: null,
          });
        }
        if (r.source === "human" && auth !== "human-token" && mode === "enforce") {
          console.warn("[verdicts] BH-3831 refused unverified source=human", `${r.repo}#${r.pr}`, r.head_sha.slice(0, 12), r.reviewer || "-");
          return json(403, {
            error: "source=human needs the human verdict token (x-human-verdict-token); the lead token alone may write source=lead. human_verdict_mode=enforce",
            human_verdict_mode: "enforce",
          });
        }
        // BH-3846: a human-token row is signed before the INSERT (the table
        // refuses UPDATE, so the signature rides the row). No key: under sig
        // enforce the row could never read as proven, so nothing is written.
        const sk = sigKeyOf(env);
        let humanSig = null;
        if (auth === "human-token") {
          if (sk) humanSig = await hmacSha256Hex(sk, verdictSigMessage(r, t));
          else if (await protectedMode(env, "human_verdict_sig_mode") === "enforce") {
            return json(503, { error: "HUMAN_VERDICT_SIG_KEY unset: a human row cannot be signed, and human_verdict_sig_mode=enforce would never read it as proven" });
          } else {
            console.warn("[verdicts] BH-3846 HUMAN_VERDICT_SIG_KEY unset: human-token row written unsigned",
              `${r.repo}#${r.pr}`, r.head_sha.slice(0, 12));
          }
        }
        await ensureTable(env, "verdicts");
        await ensureColumns(env, "verdicts");
        // BH-3905: the signed message is second-grained, so a retry of the same
        // verdict in the same second signs identically, and firstRowBySig reads
        // the newer row as a replay. Still written (append-only), but loudly. A
        // failed lookup is logged and read as no duplicate: it never blocks a write.
        let dup = null;
        if (humanSig) {
          try {
            dup = await env.DB.prepare("SELECT id FROM verdicts WHERE repo=?1 AND pr=?2 AND human_sig=?3 ORDER BY id LIMIT 1")
              .bind(r.repo, r.pr, humanSig).first("id");
          } catch (e) {
            console.warn("[verdicts] BH-3905 duplicate-signature lookup failed; not flagged:", e?.message || e);
          }
          if (dup) {
            console.error(`[verdicts] BH-3905 same-second retry: this human-token row repeats the signature of #${dup} (${r.repo}#${r.pr} ${r.head_sha.slice(0, 12)} ${r.verdict}, same second); it will read UNPROVEN, so under enforce re-post after a second if #${dup} is not the one you meant`);
          }
        }
        const res = await env.DB.prepare(
          `INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer_model, reviewer,
                                 report_url, note, created_at, auth, human_sig, review_tier, review_mode, break_it)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)`
        ).bind(r.repo, r.pr, r.head_sha, r.verdict, r.source, r.reviewer_model, r.reviewer,
               r.report_url, r.note, t, auth, humanSig, r.review_tier, r.review_mode, r.break_it).run();
        const row = await env.DB.prepare("SELECT * FROM verdicts WHERE id=?1")
          .bind(res.meta.last_row_id).first();
        if (r.source === "human" && auth !== "human-token") {
          console.warn(`[verdicts] BH-3831 shadow: unverified source=human row #${res.meta.last_row_id}`,
            `${r.repo}#${r.pr}`, r.head_sha.slice(0, 12), r.reviewer || "-");
        }
        // BH-4954: a standing (lead/human) row is the PR's lead_verdict gate
        // fact. A box row is history only. Never throws; the 201 is unchanged.
        if (STANDING_SOURCES.includes(r.source) && row) await recordLeadVerdict(env, t, row);
        return json(201, {
          verdict: row, human_verified: auth === "human-token", human_signed: humanSig !== null, human_verdict_mode: mode,
          ...(dup ? { human_sig_duplicate_of: dup } : {}),
        });
      });
    },
  ],

  // ?repo=&pr= is the PR's history, newest first (capped, and the cap is
  // named). &head= adds `standing`: the newest lead/human row bound to THAT
  // head, or null. &standing_only=1 (needs &head=) skips the history read —
  // it is what every merge-lane check asks, once per candidate per tick. The merge lanes only ever ask with the live head, so a row
  // for any earlier head can never stand for the one sitting there.
  //
  // BH-3846: every row carries human_proven (null unless source=human). Under
  // human_verdict_sig_mode=enforce an unproven human MERGE/MERGE-WITH-NOTES
  // `standing` is answered as source=lead with source_recorded=human: the hub
  // can already write a lead MERGE, so a forged human one buys nothing. A BLOCK
  // stands as recorded (failure is the safe direction), and `rows` is never
  // rewritten: history, and the precision scorer that reads it, keep the truth.
  // A row repeating a signature an earlier row in the PR carries is a replay
  // and reads unproven (firstRowBySig).
  // BH-3849: under human_verdict_mode=enforce a source=human row with
  // auth='lead-token' never stands (auth NULL, pre-BH-3831, and 'human-token'
  // still do); an unreadable mode makes a &head= read 503. BH-5773: only after
// one retry and with no last good read of the mode in 60 s, and only when a
// source=human row is on that head (with none, the mode cannot change the
// answer, so it is answered). The history `rows`
  // are never filtered: they are the record, and the operator's pre-flip check
  // reads them.
  [
    "GET", "/api/verdicts",
    async ({ env, url, t }) => {
      return d1Guarded("verdicts", async () => {
        const repo = (url.searchParams.get("repo") || "").trim();
        if (!REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
        const pr = prOf(url.searchParams.get("pr") || "");
        if (pr === null) return json(400, { error: "pr must be a positive integer" });
        const rawHead = url.searchParams.get("head");
        const head = rawHead === null || rawHead === "" ? null : shaOf(rawHead);
        if (rawHead && !head) return json(400, { error: "head must be a full 40-hex commit sha" });
        const standingOnly = url.searchParams.get("standing_only") === "1";
        if (standingOnly && !head) return json(400, { error: "standing_only needs head" });
        await ensureTable(env, "verdicts");
        let rows = [];
        if (!standingOnly) {
          const hrows = await env.DB.prepare(
            "SELECT * FROM verdicts WHERE repo=?1 AND pr=?2 ORDER BY id DESC LIMIT 100"
          ).bind(repo, pr).all();
          rows = hrows.results || [];
        }
        let standing = null;
        if (head) {
          await ensureColumns(env, "verdicts");
          const mode = await humanVerdictMode(env);
          if (mode === null) {
            // BH-5773: the mode only decides whether a source=human row stands
            // (the `unproven` filter below). With none on this head the answer
            // is the same in both modes, so it is answered; with one, BH-3849.
            const human = await env.DB.prepare(
              "SELECT id FROM verdicts WHERE repo=?1 AND pr=?2 AND head_sha=?3 AND source='human' LIMIT 1"
            ).bind(repo, pr, head).first("id");
            if (human) throw new Error("human_verdict_mode could not be read; standing is not answered (fail closed)");
            console.warn("[verdicts] BH-5773 human_verdict_mode unreadable; no source=human row on this head, standing answered without it", `${repo}#${pr}`, head.slice(0, 12));
          }
          // IS, not =: an auth NULL row must never be caught by NULL logic.
          const unproven = mode === "enforce" ? "\n               AND NOT (source='human' AND auth IS 'lead-token')" : "";
          // sql-ident-ok: STANDING_SOURCES is a frozen export const in lib/verdict-sources.js; unproven is a literal picked by mode
          standing = await env.DB.prepare(
            `SELECT * FROM verdicts WHERE repo=?1 AND pr=?2 AND head_sha=?3
               AND source IN (${STANDING_SOURCES.map((s) => `'${s}'`).join(",")})${unproven}
             ORDER BY id DESC LIMIT 1`
          ).bind(repo, pr, head).first();
        }
        const sk = sigKeyOf(env);
        // A whole-row replay (INSERT ... SELECT of an old signed MERGE) copies a
        // signature that verifies, and the copy gets the newest id. A signature
        // only verifies on its own repo, pr and head, so the first row per sig
        // within this PR is the one the worker wrote; any later row carrying the
        // same sig is a copy and is unproven.
        const firstBySig = await firstRowBySig(env, repo, pr, [...rows, standing]);
        const proven = async (row) => {
          const p = await humanProven(row, sk);
          return p === true && firstBySig.get(row.human_sig) !== row.id ? false : p;
        };
        rows = await Promise.all(rows.map(async (row) => ({ ...row, human_proven: await proven(row) })));
        if (standing) {
          standing = { ...standing, human_proven: await proven(standing) };
          // BH-3905: unproven ONLY because an earlier row carries its sig (a
          // same-second retry or a replay). `has` keeps the empty map a failed
          // read leaves from reading as a duplicate.
          const first = firstBySig.get(standing.human_sig);
          if (standing.human_proven === false && firstBySig.has(standing.human_sig) && first !== standing.id
              && await humanProven(standing, sk) === true) {
            console.error(`[verdicts] BH-3905 duplicate-signature standing row #${standing.id} repeats the signature of #${first}`,
              `${repo}#${pr}`, head.slice(0, 12));
          }
          if (standing.human_proven === false && standing.verdict !== "BLOCK") {
            if (await protectedMode(env, "human_verdict_sig_mode") === "enforce") {
              standing = { ...standing, source: "lead", source_recorded: "human" };
            } else {
              console.warn(`[verdicts] BH-3846 shadow: unproven source=human standing row #${standing.id}`,
                `${repo}#${pr}`, head.slice(0, 12), standing.auth || "-");
            }
          }
        }
        return json(200, { repo, pr, head, standing: standing || null, rows, truncated: rows.length >= 100, as_of: t });
      });
    },
  ],
];
