// box-ssh routes — does the hub reach each box over ssh, and the facts the
// MCP box_health and box_restart tools read (BH-7710).
//
// The hub lane bin/box-ssh-probe.sh ssh's each registry box with a tailnet IP
// every 2 minutes and posts one row per box. GET /api/box-health joins those
// rows with the registry, the lane heartbeats and the Orgo state, so the MCP
// tools (mcp/tools/box-health.mjs, through /api/coord/box-health) make ONE
// request. Table: schema.d/202610201507-bh-7710-box-ssh-state.sql.
// Note: docs/notes/2026-10-20-BH-7710-box-health-mcp.md.
//
// POST /api/box-ssh {rows:[{box, ip, rc, lane_fails, lane_window_s, lane_last_fail_at}]}
//   rows: 1..MAX_ROWS entries, else 400 and nothing written. A row with a bad
//   field (box not [A-Za-z0-9._-]{1,64}, ip not a string <=64 or null, rc not
//   an integer 0..255, lane_fails not an integer 0..100000, lane_window_s not
//   an integer 1..86400, lane_last_fail_at not YYYY-MM-DDTHH:MM:SSZ or null), or
//   a box named twice, is counted in `rejected` and not written. The good rows
//   are ONE batch of upserts on the PRIMARY KEY. probed_at is the worker clock
//   `t`; last_ok_at moves only on rc 0. → 200 {written, rejected, as_of}.
//
// GET /api/box-health
//   → 200 {boxes:[{box, box_id, role, tailnet_ip,
//                  ssh:{rc, probed_at, last_ok_at} | null,
//                  lane_ssh_failures:{count, window_s, last_at} | null,
//                  last_beat_at,
//                  vm:{live:[{id, status, seen_at, account}], gone} | null,
//                  restart:{box:'hub', type:'orgo_restart', target, account?} | null}],
//          vm_complete, partial, truncated, as_of}
//   One entry per registry box (at most MAX_ROWS, ordered by box). ssh null =
//   no probe row. vm = the Orgo computers whose name is the registry box name:
//   live (gone_at null) and a count of tombstoned ones. restart is the
//   box-commands body that restarts the box (the console RESTART button's
//   command, run by the hub's bin/box-ops.sh), and only when the box is not the
//   hub and exactly one live computer matches. vm_complete is true only when
//   every Orgo account read is ok and complete and the list is not truncated.
//   A failed sub-read is named in `partial` ('ssh', 'heartbeat', 'vm') and its
//   fields are null, never an empty list; vm_complete is then null. The
//   registry read failing is a 503 (d1Guarded).
//   Statements: the registry_boxes column check (once per isolate), then five
//   reads in parallel.
import { d1Guarded, json } from "../lib/http.js";
import { ensureColumns, laneName } from "../lib/core.js";
import { LAST_BEAT_SQL } from "./boxes.js";

export const MAX_ROWS = 200;
const MAX_VM_ROWS = 2000;
const ISO_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const RESTART_TYPE = "orgo_restart";

// ?1 box, ?2 tailnet_ip, ?3 probe_rc, ?4 t, ?5 lane_fails, ?6 lane_window_s,
// ?7 lane_last_fail_at. The PRIMARY KEY autoindex serves the conflict.
export const UPSERT_SQL = `INSERT INTO box_ssh_state
   (box, tailnet_ip, probe_rc, probed_at, last_ok_at, lane_fails, lane_window_s, lane_last_fail_at, updated_at)
 VALUES (?1, ?2, ?3, ?4, CASE WHEN ?3 = 0 THEN ?4 END, ?5, ?6, ?7, ?4)
 ON CONFLICT(box) DO UPDATE SET
   tailnet_ip=excluded.tailnet_ip, probe_rc=excluded.probe_rc, probed_at=excluded.probed_at,
   last_ok_at=CASE WHEN excluded.probe_rc = 0 THEN excluded.probed_at ELSE box_ssh_state.last_ok_at END,
   lane_fails=excluded.lane_fails, lane_window_s=excluded.lane_window_s,
   lane_last_fail_at=excluded.lane_last_fail_at, updated_at=excluded.updated_at`;
// ?1 the row cap. A table of one row per box.
export const SSH_READ_SQL = `SELECT box, probe_rc, probed_at, last_ok_at, lane_fails, lane_window_s, lane_last_fail_at
 FROM box_ssh_state ORDER BY box LIMIT ?1`;
// ?1 the row cap. The PRIMARY KEY serves the order.
export const REGISTRY_READ_SQL = `SELECT box, box_id, tailnet_ip, role FROM registry_boxes ORDER BY box LIMIT ?1`;
// ?1 the row cap. The same bounded read as GET /api/orgo-computers, minus raw_json.
export const VM_READ_SQL = `SELECT orgo_id, name, account, status, seen_at, gone_at FROM orgo_computers
 ORDER BY account, orgo_id LIMIT ?1`;
export const VM_ACCOUNTS_SQL = `SELECT account, ok, complete FROM orgo_account_reads`;

const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;

// One posted row → the bind list, or null.
function parseRow(r) {
  if (!r || typeof r !== "object" || Array.isArray(r)) return null;
  const box = typeof r.box === "string" ? laneName(r.box) : "";
  if (!box || box !== r.box) return null;
  const ip = r.ip === undefined || r.ip === null ? null : r.ip;
  if (ip !== null && !(typeof ip === "string" && ip.length <= 64)) return null;
  if (!isInt(r.rc, 0, 255) || !isInt(r.lane_fails, 0, 100000) || !isInt(r.lane_window_s, 1, 86400)) return null;
  const last = r.lane_last_fail_at === undefined || r.lane_last_fail_at === null ? null : r.lane_last_fail_at;
  if (last !== null && !(typeof last === "string" && ISO_RE.test(last))) return null;
  return { box, ip, rc: r.rc, fails: r.lane_fails, win: r.lane_window_s, last };
}

// A read that failed is {ok:false}; the caller names it in `partial`. A thunk,
// so a prepare that throws at once is caught the same way.
const settle = (read) => Promise.resolve().then(read).then((r) => ({ ok: true, rows: r.results || [] }), (e) => ({ ok: false, error: String((e && e.message) || e) }));

function vmComplete(vm, accounts) {
  if (!vm.ok || !accounts.ok) return null;
  if (vm.rows.length > MAX_VM_ROWS || accounts.rows.length === 0) return false;
  return accounts.rows.every((a) => a.ok === 1 && a.complete === 1);
}

export const routes = [
  [
    "POST", "/api/box-ssh",
    ({ env, t, body }) => d1Guarded("box_ssh_state", async () => {
      const list = body && typeof body === "object" ? body.rows : undefined;
      if (!Array.isArray(list) || list.length === 0 || list.length > MAX_ROWS) {
        return json(400, { error: `rows is required: an array of 1..${MAX_ROWS} entries` });
      }
      const seen = new Set();
      const good = [];
      for (const raw of list) {
        const r = parseRow(raw);
        if (!r || seen.has(r.box)) continue;
        seen.add(r.box);
        good.push(r);
      }
      if (good.length) {
        await env.DB.batch(good.map((r) => env.DB.prepare(UPSERT_SQL).bind(r.box, r.ip, r.rc, t, r.fails, r.win, r.last)));
      }
      return json(200, { written: good.length, rejected: list.length - good.length, as_of: t });
    }),
  ],
  [
    "GET", "/api/box-health",
    ({ env, t }) => d1Guarded("registry_boxes", async () => {
      await ensureColumns(env, "registry_boxes");
      const [reg, ssh, beats, vm, accounts] = await Promise.all([
        env.DB.prepare(REGISTRY_READ_SQL).bind(MAX_ROWS + 1).all(),
        settle(() => env.DB.prepare(SSH_READ_SQL).bind(MAX_ROWS + 1).all()),
        settle(() => env.DB.prepare(LAST_BEAT_SQL).all()),
        settle(() => env.DB.prepare(VM_READ_SQL).bind(MAX_VM_ROWS + 1).all()),
        settle(() => env.DB.prepare(VM_ACCOUNTS_SQL).all()),
      ]);
      const regRows = reg.results || [];
      const partial = [];
      if (!ssh.ok) partial.push("ssh");
      if (!beats.ok) partial.push("heartbeat");
      if (!vm.ok || !accounts.ok) partial.push("vm");
      const sshBy = new Map(ssh.ok ? ssh.rows.map((r) => [r.box, r]) : []);
      const beatBy = new Map(beats.ok ? beats.rows.map((r) => [r.box, r.last_beat_at]) : []);
      const vmRows = vm.ok ? vm.rows.slice(0, MAX_VM_ROWS) : [];
      const vmOk = vm.ok && accounts.ok;
      const boxes = regRows.slice(0, MAX_ROWS).map((b) => {
        const s = sshBy.get(b.box);
        const mine = vmRows.filter((c) => c.name === b.box);
        const live = mine.filter((c) => !c.gone_at)
          .map((c) => ({ id: c.orgo_id, status: c.status ?? null, seen_at: c.seen_at ?? null, account: c.account ?? null }));
        let restart = null;
        if (vmOk && b.box_id !== "hub" && live.length === 1) {
          restart = { box: "hub", type: RESTART_TYPE, target: b.box_id };
          if (live[0].account) restart.account = live[0].account;
        }
        return {
          box: b.box, box_id: b.box_id, role: b.role ?? null, tailnet_ip: b.tailnet_ip ?? null,
          ssh: s ? { rc: Number(s.probe_rc), probed_at: s.probed_at, last_ok_at: s.last_ok_at ?? null } : null,
          lane_ssh_failures: s ? { count: Number(s.lane_fails), window_s: Number(s.lane_window_s), last_at: s.lane_last_fail_at ?? null } : null,
          last_beat_at: beats.ok ? beatBy.get(b.box) ?? null : null,
          vm: vmOk ? { live, gone: mine.length - live.length } : null,
          restart,
        };
      });
      return json(200, {
        boxes, vm_complete: vmComplete(vm, accounts), partial,
        truncated: regRows.length > MAX_ROWS, as_of: t,
      });
    }),
  ],
];
