// Owner and human-only proof (BH-9262). The fleet bearer (HARNESS_SECRET) is on
// every box, and a body `actor` is whatever the caller typed, so neither one
// proves that the owner or a person made a request. An owner command
// (routes/box-commands.js, the OWNER_ONLY types) and a human-only staff
// decision in the direction that raises authority accept exactly two proofs:
//
//   1. the Mac human token: x-human-verdict-token = HUMAN_VERDICT_TOKEN
//      (humanTokenOk in routes/verdicts.js, unchanged), or
//   2. the Pages proof: x-box-ops-token = BOX_OPS_TOKEN (a worker secret that
//      only the console Pages project also holds; SHA-256 of both sides, then a
//      constant-time compare) AND x-box-ops-identity, the Cloudflare Access
//      email Pages verified (console-ui/functions/_lib/box-ops-proof.js), in
//      BOX_OPS_OWNERS. Pages sends the two headers only for a verified Access
//      identity. A BOX_OPS_TOKEN that is blank, or equal to HARNESS_SECRET,
//      LEAD_VERDICT_TOKEN or HUMAN_VERDICT_TOKEN, is no separate credential,
//      so it proves nothing (fail closed).
//
// THE MODE. The protected settings row owner_proof_mode, read through
// protectedMode (only the human token writes it, and the worker signs it):
//   no row or `shadow`  the request goes through and the worker logs one
//                       `[owner-proof] would-refuse route=<r> actor=<a> why=<w>`
//   `enforce`           the route answers 403 and writes nothing (box-commands
//                       writes its one refused audit row)
//   the read throws     503, nothing written
// The worker env OWNER_PROOF_ENFORCE=1 forces enforce. HUMAN_VERDICT_ENFORCE
// does not: it is already set in prod for verdicts.

import { humanTokenOk, protectedMode } from "../routes/verdicts.js";
import { normActor, isOwner } from "./box-command-args.js";
import { hexEqual, hexOf } from "./core.js";
import { json } from "./http.js";

export const OWNER_PROOF_MODE_KEY = "owner_proof_mode";

// Both sides are hashed first, so the compare below always runs over two
// 64-character digests: its time does not depend on the token's length or on
// how long a prefix of it the caller guessed.
const sha256Hex = async (s) => hexOf(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));

// → {ok:true, via:'human-token'} | {ok:true, via:'box-ops', identity}
//   | {ok:false, why: none|box_ops_token|box_ops_unset|identity_missing|not_owner}
export async function ownerProof(req, env) {
  if (humanTokenOk(req, env)) return { ok: true, via: "human-token" };
  const sent = req.headers.get("x-box-ops-token");
  if (sent === null) return { ok: false, why: "none" };
  const token = typeof env.BOX_OPS_TOKEN === "string" ? env.BOX_OPS_TOKEN.trim() : "";
  if (!token || [env.HARNESS_SECRET, env.LEAD_VERDICT_TOKEN, env.HUMAN_VERDICT_TOKEN].some((v) => typeof v === "string" && v.trim() === token)) {
    return { ok: false, why: "box_ops_unset" };
  }
  if (!hexEqual(await sha256Hex(sent.trim()), await sha256Hex(token))) return { ok: false, why: "box_ops_token" };
  const identity = normActor(req.headers.get("x-box-ops-identity"));
  if (!identity) return { ok: false, why: "identity_missing" };
  if (!isOwner(env, identity)) return { ok: false, why: "not_owner" };
  return { ok: true, via: "box-ops", identity };
}

export function ownerProofMode(env) {
  return protectedMode(env, OWNER_PROOF_MODE_KEY, "OWNER_PROOF_ENFORCE");
}

// → {proof} (a proof holds) | {proof:null, shadow:true} (no proof, shadow: the
// route runs as before) | {refuse:403} (enforce) | {refuse:503} (no mode).
// The mode is read only when there is no proof.
export async function humanGate(req, env, { route, actor }) {
  const proof = await ownerProof(req, env);
  if (proof.ok) return { proof };
  const mode = await ownerProofMode(env);
  if (mode === null) return { refuse: 503 };
  if (mode === "enforce") return { refuse: 403, why: proof.why };
  const a = String(actor ?? "").replace(/\s+/g, "_").slice(0, 96) || "-";
  console.warn(`[owner-proof] would-refuse route=${route} actor=${a} why=${proof.why}`);
  return { proof: null, shadow: true };
}

// The staff and archie routes' answer to a refusal.
export function gateRefusal(g) {
  if (g.refuse === 503) return json(503, { error: "owner_proof_mode unavailable", detail: "the settings read failed; nothing was written" });
  return json(403, { error: "human_proof_required" });
}
