// orgo-computers routes — BH-5750 (C4): the live Orgo state the /machines
// ORGO STATE column reads.
//
// The hub lane bin/orgo-state.sh reads GET /computers for each Orgo account in
// catalog/orgo-plans.json every 5 minutes and PUTs the list here. The store is
// orgo_computers (one row per Orgo computer, keyed on orgo_id) plus
// orgo_account_reads (the last read per account). Tables:
// schema.d/0015-bh-5750-orgo-computers.sql.
//
// PUT /api/orgo-computers   body {account, ok, complete, computers:[…], detail?}
//   - account: [A-Za-z0-9._-]{1,64}, a string. ok and complete: the JSON
//     literals true or false. computers: an array of at most MAX_COMPUTERS
//     objects (over it is a 400, never a silent truncation: the lane caps and
//     sends complete:false). Each entry has a non-empty string or finite number
//     `id` (stored as a string, unique in the list), and optional name/status
//     strings and cpu/ram/disk non-negative integers (ram and disk in GB, the
//     Orgo shape). An absent spec is NULL, never 0. detail: a string ≤500.
//     Any failure is a 400 and nothing is written.
//   - ok:true: every entry is upserted on orgo_id (seen_at = now, gone_at
//     cleared, raw_json = the entry). complete:true ALSO tombstones the
//     account's rows whose orgo_id is not in the list (gone_at = now; a row
//     already tombstoned keeps its first stamp). complete:false tombstones
//     nothing.
//   - ok:false: a failed read. No computer row changes.
//   - Either way the account's orgo_account_reads row is set {read_at:now, ok,
//     complete: ok && complete, detail}. Everything is ONE env.DB.batch, and
//     the list rides one JSON bind, so no statement has more than 100 binds.
//   → 200 {ok:true, account, upserted, tombstoned, complete}.
//
// GET /api/orgo-computers
//   → 200 {computers:[{orgo_id,name,account,status,cpu,ram_gb,disk_gb,seen_at,gone_at}],
//          accounts:{<account>:{read_at, ok, complete, detail}}, as_of, truncated}
//   at most MAX_ROWS computers, ordered by account then orgo_id; raw_json is not
//   served. An unapplied table is 503 (d1Guarded).

import { json, d1Guarded } from "../lib/http.js";

const ACCOUNT_RE = /^[A-Za-z0-9._-]{1,64}$/;
const MAX_COMPUTERS = 500;
const MAX_ROWS = 2000;
const MAX_ID = 128;
const MAX_TEXT = 200;
const MAX_RAW = 16384;
const MAX_DETAIL = 500;

const bad = (error) => ({ error });

function spec(v, key) {
  if (v === undefined || v === null) return { v: null };
  if (Number.isInteger(v) && v >= 0) return { v };
  return bad(`computers[].${key} must be a non-negative integer or absent`);
}

function text(v, key) {
  if (v === undefined || v === null) return { v: null };
  if (typeof v === "string" && v.length <= MAX_TEXT) return { v };
  return bad(`computers[].${key} must be a string of at most ${MAX_TEXT} characters or absent`);
}

// Validate the whole payload before any write. Returns {error} or the rows.
function parse(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return bad("body must be a JSON object");
  if (typeof body.account !== "string" || !ACCOUNT_RE.test(body.account)) {
    return bad("account must be a string matching [A-Za-z0-9._-]{1,64}");
  }
  if (body.ok !== true && body.ok !== false) return bad("ok must be true or false");
  if (body.complete !== true && body.complete !== false) return bad("complete must be true or false");
  if (!Array.isArray(body.computers)) return bad("computers must be an array");
  if (body.computers.length > MAX_COMPUTERS) {
    return bad(`computers has ${body.computers.length} entries; the most one PUT takes is ${MAX_COMPUTERS} (send the first ${MAX_COMPUTERS} with complete:false)`);
  }
  let detail = null;
  if (body.detail !== undefined && body.detail !== null) {
    if (typeof body.detail !== "string" || body.detail.length > MAX_DETAIL) return bad(`detail must be a string of at most ${MAX_DETAIL} characters`);
    detail = body.detail;
  }
  const seen = new Set();
  const rows = [];
  for (const c of body.computers) {
    if (!c || typeof c !== "object" || Array.isArray(c)) return bad("every computers[] entry must be an object");
    let id;
    if (typeof c.id === "string" && c.id.length > 0 && c.id.length <= MAX_ID) id = c.id;
    else if (typeof c.id === "number" && Number.isFinite(c.id)) id = String(c.id);
    else return bad(`every computers[] entry needs an id: a non-empty string (≤${MAX_ID}) or a number`);
    if (seen.has(id)) return bad(`computers[] id ${id} is listed twice`);
    seen.add(id);
    const name = text(c.name, "name");
    const status = text(c.status, "status");
    const cpu = spec(c.cpu, "cpu");
    const ram = spec(c.ram, "ram");
    const disk = spec(c.disk, "disk");
    for (const f of [name, status, cpu, ram, disk]) if (f.error) return f;
    const raw = JSON.stringify(c);
    if (raw.length > MAX_RAW) return bad(`computers[] id ${id} is over ${MAX_RAW} characters of JSON`);
    rows.push({ orgo_id: id, name: name.v, status: status.v, cpu: cpu.v, ram_gb: ram.v, disk_gb: disk.v, raw_json: raw });
  }
  return { account: body.account, ok: body.ok, complete: body.ok && body.complete, detail, rows };
}

export const routes = [
  ["PUT", "/api/orgo-computers", ({ env, t, body }) => d1Guarded("orgo_computers", async () => {
    const p = parse(body);
    if (p.error) return json(400, { error: p.error });
    const stmts = [];
    if (p.ok) {
      const list = JSON.stringify(p.rows);
      if (p.rows.length > 0) {
        stmts.push(env.DB.prepare(
          `INSERT INTO orgo_computers (orgo_id,name,account,status,cpu,ram_gb,disk_gb,raw_json,seen_at,gone_at)
           SELECT json_extract(value,'$.orgo_id'), json_extract(value,'$.name'), ?2, json_extract(value,'$.status'),
                  json_extract(value,'$.cpu'), json_extract(value,'$.ram_gb'), json_extract(value,'$.disk_gb'),
                  json_extract(value,'$.raw_json'), ?3, NULL
           FROM json_each(?1) WHERE true
           ON CONFLICT(orgo_id) DO UPDATE SET name=excluded.name, account=excluded.account, status=excluded.status,
             cpu=excluded.cpu, ram_gb=excluded.ram_gb, disk_gb=excluded.disk_gb, raw_json=excluded.raw_json,
             seen_at=excluded.seen_at, gone_at=NULL`,
        ).bind(list, p.account, t));
      }
      if (p.complete) {
        stmts.push(env.DB.prepare(
          "UPDATE orgo_computers SET gone_at=?2 WHERE account=?1 AND gone_at IS NULL AND orgo_id NOT IN (SELECT json_extract(value,'$.orgo_id') FROM json_each(?3))",
        ).bind(p.account, t, list));
      }
    }
    stmts.push(env.DB.prepare(
      `INSERT INTO orgo_account_reads (account,read_at,ok,complete,detail) VALUES (?1,?2,?3,?4,?5)
       ON CONFLICT(account) DO UPDATE SET read_at=excluded.read_at, ok=excluded.ok, complete=excluded.complete, detail=excluded.detail`,
    ).bind(p.account, t, p.ok ? 1 : 0, p.complete ? 1 : 0, p.detail));
    const res = await env.DB.batch(stmts);
    const tombstoned = p.ok && p.complete ? Number(res[res.length - 2]?.meta?.changes || 0) : 0;
    return json(200, { ok: true, account: p.account, upserted: p.ok ? p.rows.length : 0, tombstoned, complete: p.complete });
  })],

  ["GET", "/api/orgo-computers", ({ env, t }) => d1Guarded("orgo_computers", async () => {
    const rows = (await env.DB.prepare(
      "SELECT orgo_id,name,account,status,cpu,ram_gb,disk_gb,seen_at,gone_at FROM orgo_computers ORDER BY account, orgo_id LIMIT ?1",
    ).bind(MAX_ROWS + 1).all()).results || [];
    const reads = (await env.DB.prepare(
      "SELECT account,read_at,ok,complete,detail FROM orgo_account_reads ORDER BY account",
    ).all()).results || [];
    const accounts = {};
    for (const r of reads) accounts[r.account] = { read_at: r.read_at, ok: r.ok === 1, complete: r.complete === 1, detail: r.detail ?? null };
    return json(200, { computers: rows.slice(0, MAX_ROWS), accounts, as_of: t, truncated: rows.length > MAX_ROWS });
  })],
];
