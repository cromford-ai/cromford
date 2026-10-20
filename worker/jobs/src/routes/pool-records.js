// pool build records — a pool machine's build record, off the machine
// (BH-7429, BH-6896 S2). The runner posts its full RESULT, the build-dir files
// the hub relays and its failovers.log tail once per job
// (bin/lib/pool-record.sh pool_record_put, from fly/builder-runner.sh). The
// hub reap (bin/fly-pool.sh) reads the record instead of one `ssh console`
// per file, writes its hub build dir from it, and stamps it. A stopped
// machine's record is still readable. Behind the lane knob POOL_RECORD_READ.
// Contract: docs/notes/2026-10-19-BH-7429-pool-record.md.
//
// POST /api/pool/records {project, key, machine, build_dir,
//   files:[{name, b64} | {name, skipped:true, bytes}]}
//   400 on any bad field, nothing written. Then ONE batch: clear this record's
//   unread rows, then one insert per file. Every statement is guarded by
//   "no row of this record is reaped", so a re-post before the reap replaces
//   the record, and a re-post after it is 409 already_reaped with nothing
//   changed. 200 {recorded:true, files, skipped}.
// GET /api/pool/records?project=&key=&machine=&since=
//   since is YYYY-MM-DDTHH:MM:SSZ (400 else). 2 statements: the newest RESULT
//   row of this machine posted at or after since and not yet reaped, then
//   that record's files.
//   404 when there is none. 200 {record:{build_dir, machine, posted_at,
//   files:[{name, body, bytes, skipped}]}}; body is base64, null when skipped.
// POST /api/pool/records/reaped {project, key, machine, build_dir}
//   1 statement. 200 {reaped:<rows stamped>}.
//
// The clock is the worker's `t`; a machine never sends a time. No money here.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";

export const MAX_FILES = 40;
// D1 caps a row at 2 MB. The machine skips a file over 1,400,000 bytes
// (POOL_RECORD_FILE_MAX_BYTES), about 1.87 M base64 chars.
export const MAX_B64 = 1900000;

const GUARD = `NOT EXISTS (SELECT 1 FROM pool_record_files
   WHERE project=?1 AND ticket_key=?2 AND machine=?3 AND build_dir=?4 AND reaped_at IS NOT NULL)`;
// ?1 project, ?2 key, ?3 machine, ?4 build_dir. uq_pool_record_files_file.
export const CLEAR_SQL = `DELETE FROM pool_record_files
 WHERE project=?1 AND ticket_key=?2 AND machine=?3 AND build_dir=?4 AND reaped_at IS NULL AND ${GUARD}`;
// ?5 name, ?6 body, ?7 bytes, ?8 skipped, ?9 t.
export const INSERT_SQL = `INSERT INTO pool_record_files (project, ticket_key, machine, build_dir, name, body, bytes, skipped, posted_at)
 SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9 WHERE ${GUARD}
 ON CONFLICT(project, ticket_key, machine, build_dir, name) DO UPDATE SET
   body=excluded.body, bytes=excluded.bytes, skipped=excluded.skipped, posted_at=excluded.posted_at
 WHERE pool_record_files.reaped_at IS NULL`;
// ?4 since. idx_pool_record_files_result. A reaped record is never the answer:
// a reused machine that takes the same key again inside the hub's skew window
// would otherwise hand the hub the previous job's RESULT while the new job runs.
export const RESULT_READ_SQL = `SELECT build_dir, posted_at FROM pool_record_files
 WHERE project=?1 AND ticket_key=?2 AND machine=?3 AND name='RESULT' AND posted_at>=?4
   AND reaped_at IS NULL
 ORDER BY posted_at DESC LIMIT 1`;
// uq_pool_record_files_file.
export const FILES_READ_SQL = `SELECT name, body, bytes, skipped FROM pool_record_files
 WHERE project=?1 AND ticket_key=?2 AND machine=?3 AND build_dir=?4 ORDER BY name`;
// ?5 t. uq_pool_record_files_file prefix; reaped_at IS NULL makes it once.
export const STAMP_SQL = `UPDATE pool_record_files SET reaped_at=?5
 WHERE project=?1 AND ticket_key=?2 AND machine=?3 AND build_dir=?4 AND reaped_at IS NULL`;

// A build dir name or a file name: no slash, never a leading dot, so never `..`.
const DIR_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const B64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const SINCE_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;

const b64Bytes = (s) => (s.length / 4) * 3 - (s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0);

// The record's identity, or null.
function ident(b) {
  const project = laneName(b.project), key = laneName(b.key), machine = laneName(b.machine);
  const buildDir = typeof b.build_dir === "string" && DIR_RE.test(b.build_dir) ? b.build_dir : "";
  if (!project || !key || !machine || !buildDir) return null;
  return { project, key, machine, buildDir };
}

// The validated record, or { error } for a 400.
function parse(raw) {
  const b = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const id = ident(b);
  if (!id) return { error: "project, key and machine must match [A-Za-z0-9._-]{1,64}; build_dir must match [A-Za-z0-9][A-Za-z0-9._-]{0,127}" };
  if (!Array.isArray(b.files) || b.files.length === 0) return { error: "files is required: a non-empty array" };
  if (b.files.length > MAX_FILES) return { error: `files has ${b.files.length} entries; at most ${MAX_FILES}` };
  const seen = new Set();
  const files = [];
  for (const f of b.files) {
    const name = f && typeof f.name === "string" ? f.name : "";
    if (!NAME_RE.test(name)) return { error: `file name ${JSON.stringify(name).slice(0, 80)} must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}` };
    if (seen.has(name)) return { error: `file ${name} is named twice` };
    seen.add(name);
    if (f.skipped === true) {
      if (!Number.isInteger(f.bytes) || f.bytes < 0) return { error: `skipped file ${name} needs bytes: an integer >= 0` };
      files.push({ name, body: null, bytes: f.bytes, skipped: 1 });
      continue;
    }
    if (typeof f.b64 !== "string") return { error: `file ${name} needs b64, or skipped:true with bytes` };
    if (f.b64.length > MAX_B64) return { error: `file ${name} is ${f.b64.length} base64 chars; at most ${MAX_B64}` };
    if (!B64_RE.test(f.b64)) return { error: `file ${name}: b64 is not base64` };
    files.push({ name, body: f.b64, bytes: b64Bytes(f.b64), skipped: 0 });
  }
  const result = files.find((f) => f.name === "RESULT");
  if (!result || result.skipped || result.bytes === 0) return { error: "a file named RESULT with a body is required" };
  // RESULT first: its insert's change count is the 409 test.
  files.sort((a, c) => (a.name === "RESULT" ? -1 : c.name === "RESULT" ? 1 : 0));
  return { ...id, files };
}

const changes = (r) => Number((r && r.meta && r.meta.changes) || 0);

export const routes = [
  [
    "POST", "/api/pool/records",
    ({ env, t, body }) => d1Guarded("pool_record_files", async () => {
      const q = parse(body);
      if (q.error) return json(400, { error: q.error });
      const head = [q.project, q.key, q.machine, q.buildDir];
      const res = await env.DB.batch([
        env.DB.prepare(CLEAR_SQL).bind(...head),
        ...q.files.map((f) => env.DB.prepare(INSERT_SQL).bind(...head, f.name, f.body, f.bytes, f.skipped, t)),
      ]);
      if (changes(res[1]) !== 1) {
        return json(409, { error: "refused", refused: true, scope: "pool-record", reason: "already_reaped", as_of: t });
      }
      const skipped = q.files.filter((f) => f.skipped).length;
      return json(200, { recorded: true, files: q.files.length, skipped, as_of: t });
    }),
  ],
  [
    "GET", "/api/pool/records",
    ({ env, t, url }) => d1Guarded("pool_record_files", async () => {
      const p = url.searchParams;
      const project = laneName(p.get("project")), key = laneName(p.get("key")), machine = laneName(p.get("machine"));
      const since = p.get("since") || "";
      if (!project || !key || !machine) return json(400, { error: "project, key and machine must match [A-Za-z0-9._-]{1,64}" });
      if (!SINCE_RE.test(since)) return json(400, { error: "since is required: YYYY-MM-DDTHH:MM:SSZ" });
      const head = await env.DB.prepare(RESULT_READ_SQL).bind(project, key, machine, since).first();
      if (!head) return json(404, { error: "no build record for this machine since then", as_of: t });
      const rows = (await env.DB.prepare(FILES_READ_SQL).bind(project, key, machine, head.build_dir).all()).results || [];
      const files = rows.map((r) => ({ name: r.name, body: r.body ?? null, bytes: Number(r.bytes), skipped: Number(r.skipped) }));
      return json(200, { record: { build_dir: head.build_dir, machine, posted_at: head.posted_at, files }, as_of: t });
    }),
  ],
  [
    "POST", "/api/pool/records/reaped",
    ({ env, t, body }) => d1Guarded("pool_record_files", async () => {
      const id = ident(body && typeof body === "object" ? body : {});
      if (!id) return json(400, { error: "project, key, machine and build_dir are required" });
      const r = await env.DB.prepare(STAMP_SQL).bind(id.project, id.key, id.machine, id.buildDir, t).run();
      return json(200, { reaped: changes(r), as_of: t });
    }),
  ],
];
