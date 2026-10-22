// br-attempts routes (BH-7801, slice C1 of #4157): the blocked-resolver
// record's attempts, read back by a hub whose record file is gone.
//
// The rows: kind `br_attempt`, key `<project>/<rkey>#<stamp digits>#<n6>`,
// status = the action, detail the attempt JSON. They are written through
// PUT /api/ledger by bin/blocked-resolver.d/bh-7801-br-attempts.sh bra_put and
// read by its bra_list, from bin/lib/br/record.sh br_load.
//
// ONE statement: a key range inside one kind on the ledgers PRIMARY KEY
// (kind, key). '$' is the code point after '#', so [<p>/<rkey>#, <p>/<rkey>$)
// holds exactly one record's rows: rkey `k` never reads `k-2`
// (test/br-attempts-indexes.bh-7801.test.js proves the plan at 50,000 rows).

import { json } from "../lib/http.js";

export const ATTEMPT_KIND = "br_attempt";
const NAME_RE = /^[A-Za-z0-9._-]{1,200}$/;
const LIMIT_DEFAULT = 100;
const LIMIT_MAX = 200;

export const ATTEMPTS_SQL =
  "SELECT key, status, detail, updated_at FROM ledgers WHERE kind=?1 AND key>=?2 AND key<?3 ORDER BY key DESC LIMIT ?4";

export const routes = [
  [
    "GET", "/api/br-attempts",
    async ({ env, url, t }) => {
      const project = url.searchParams.get("project") || "";
      const rkey = url.searchParams.get("rkey") || "";
      if (!NAME_RE.test(project)) return json(400, { error: "project must match [A-Za-z0-9._-]{1,200}" });
      if (!NAME_RE.test(rkey)) return json(400, { error: "rkey must match [A-Za-z0-9._-]{1,200}" });
      const lim = Math.min(Math.max(Math.floor(Number(url.searchParams.get("limit"))) || LIMIT_DEFAULT, 1), LIMIT_MAX);
      const base = `${project}/${rkey}`;
      const rows = await env.DB.prepare(ATTEMPTS_SQL).bind(ATTEMPT_KIND, `${base}#`, `${base}$`, lim).all();
      // The newest `lim` rows, answered oldest first.
      const attempts = ((rows && rows.results) || []).slice().reverse();
      return json(200, { attempts, as_of: t });
    },
  ],
];
