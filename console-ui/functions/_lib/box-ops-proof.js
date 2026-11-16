// The Pages half of the owner proof (BH-9262). Not a route: Pages only treats
// files that export onRequest* as routes, and this one never does.
//
// An owner command or a human-only staff decision (the coord rows flagged
// `boxOps: true`) is proven to the jobs worker by two headers:
//   x-box-ops-token     this Pages project's BOX_OPS_TOKEN (a secret that only
//                       the jobs worker also holds, never a box)
//   x-box-ops-identity  the operator's email, as Cloudflare Access verified it
// They go out only when resolveIdentity answered access 'on': a request that
// Access did not verify carries neither, and the worker then reads it as the
// bearer alone (worker/jobs/src/lib/owner-proof.js). The worker checks the
// email against BOX_OPS_OWNERS. The Mac human verdict token is never read on Pages.
//
// identity: resolveIdentity's answer {actor, access, email}. → {} or the two headers.
export function boxOpsHeaders(identity, env) {
  const token = typeof env?.BOX_OPS_TOKEN === 'string' ? env.BOX_OPS_TOKEN.trim() : '';
  if (!token || !identity || identity.access !== 'on' || typeof identity.email !== 'string' || !identity.email) return {};
  return { 'x-box-ops-token': token, 'x-box-ops-identity': identity.email };
}
