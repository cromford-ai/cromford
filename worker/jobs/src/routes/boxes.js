// boxes routes — the box roster the console lists.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// POST /api/boxes/self-report (BH-2626) was written here directly, not moved.

import { json } from "../lib/http.js";
import { ensureColumns, ensureTable, laneName, str } from "../lib/core.js";

// The newest lane tick per box (BH-7304): ONE aggregate over lane_ticks,
// served by idx_lane_ticks_box (box, last_tick_at), merged into the roster in
// JS. Never a per-row subquery on box_status.
export const LAST_BEAT_SQL = `SELECT box, MAX(last_tick_at) AS last_beat_at FROM lane_ticks GROUP BY box`;

export const routes = [
  // The fleet's current CLI state, one row per box (bounded by fleet size).
  [
    "GET", "/api/boxes",
    async ({ env, t }) => {
      // BH-1031: the backup_* columns are ALTERed in, so a database that has
      // never taken a push does not carry them yet. Ensured on the READ as well
      // as the write, or the hub's first sync — which may well run before any
      // box's first push — would see a row shape with no backup half and write
      // nothing for a fleet that is backing up perfectly.
      //
      // last_beat_at (BH-7304) is the box's newest lane tick, any lane, or
      // null when it has none. The roster stays box_status: a box that ticks
      // with no box_status row is not added.
      await Promise.all([
        ensureColumns(env, "box_status"),
        ensureTable(env, "lane_ticks").then(() => ensureColumns(env, "lane_ticks")),
      ]);
      const [rows, beats] = await Promise.all([
        env.DB.prepare(`SELECT * FROM box_status ORDER BY box`).all(),
        env.DB.prepare(LAST_BEAT_SQL).all(),
      ]);
      const beat = new Map((beats.results || []).map((r) => [r.box, r.last_beat_at]));
      const boxes = (rows.results || []).map((r) => ({ ...r, last_beat_at: beat.get(r.box) ?? null }));
      return json(200, { boxes, as_of: t });
    },
  ],

  // ── BACKUP FRESHNESS, REPORTED BY THE BOX THAT OWNS IT (BH-1031) ──────────
  // "When did this box last get a VERIFIED off-box copy" is the quietest
  // failure in the fleet: nothing errors, nothing is late, and the only symptom
  // is the day you need it (#399, after the hub wipe #388). The hub used to
  // collect it by ssh — the probe rode bin/fleet-heartbeat.sh's 15-minute hop,
  // because that was the only thing on the hub already talking to every box —
  // and that lane is deleted in this slice. So the fact comes the other way
  // now: the box states it, on the tick that produced it, and the hub reads the
  // row.
  //
  // THREE RAW FACTS, NEVER A VERDICT, exactly as the ssh probe carried them.
  // bin/lib/backup-freshness.sh on the hub turns them into
  // ok|off|unconfigured|missing|unknown, so a box running an older bin/ cannot
  // answer in a vocabulary the hub has moved on from, and one library still
  // owns what "stale" means.
  //
  // THE TIMESTAMP IS STORED VERBATIM and is not validated beyond its length. A
  // ts that will not parse must reach the hub AS a ts that will not parse: the
  // reader has a state for that (`unknown`, which never pages and never reads
  // as fresh), and a 400 here would instead turn a corrupt stamp into no report
  // at all — which the hub reads as a box that stopped answering, a different
  // and louder story.
  [
    "POST", "/api/boxes/backup",
    async ({ env, t, body }) => {
      const box = laneName(body.box);
      if (!box) {
        return json(400, { error: "a backup report needs a box matching [A-Za-z0-9._-]{1,64}" });
      }
      await ensureColumns(env, "box_status");
      const ts = str(body.ts, 32);
      const off = str(body.off, 16);
      const unconfigured = str(body.unconfigured, 16);
      // LAST WRITER WINS ONLY IF IT IS ACTUALLY LATER — the cli_versions idiom
      // a few files over. A retry that overtakes its own original (or a box
      // whose clock jumped back) must not replace a fresh report with a stale
      // one; the guard is on the collection clock, which is the only one both
      // rows agree about.
      await env.DB.prepare(
        `INSERT INTO box_status (box, backup_ts, backup_off, backup_unconfigured, backup_reported_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?5)
         ON CONFLICT(box) DO UPDATE SET
           backup_ts=CASE WHEN box_status.backup_reported_at IS NULL OR box_status.backup_reported_at<=?5 THEN ?2 ELSE box_status.backup_ts END,
           backup_off=CASE WHEN box_status.backup_reported_at IS NULL OR box_status.backup_reported_at<=?5 THEN ?3 ELSE box_status.backup_off END,
           backup_unconfigured=CASE WHEN box_status.backup_reported_at IS NULL OR box_status.backup_reported_at<=?5 THEN ?4 ELSE box_status.backup_unconfigured END,
           backup_reported_at=CASE WHEN box_status.backup_reported_at IS NULL OR box_status.backup_reported_at<=?5 THEN ?5 ELSE box_status.backup_reported_at END,
           updated_at=?5`
      ).bind(box, ts, off, unconfigured, t).run();
      return json(200, { box, backup_reported_at: t, as_of: t });
    },
  ],

  // ── CLI VERSIONS AND RULES HASH, REPORTED BY THE BOX (BH-2626) ────────────
  // bin/box-self-report.sh posts {box, cli_version, codex_version, rules_hash,
  // at} hourly through box_self_report_set, and bin/rules-drift-check.sh and
  // bin/cli-version-check.sh read the row back before they ssh.
  //
  // TWO HALVES, EACH GUARDED ON ITS OWN CLOCK. The CLI half moves cli_version,
  // codex_version and cli_checked_at under the same `cli_checked_at<=at` guard
  // as POST /api/metrics/cli-versions, so whichever report is newer wins,
  // whichever route it came through. The rules half moves rules_hash and
  // rules_reported_at under `rules_reported_at<=at`. Each timestamp is written
  // in the same CASE as its value, so a half can never be stamped fresh without
  // its data.
  //
  // A "missing" (or empty) CLI drops the WHOLE CLI half: it never overwrites a
  // version and never makes an old version look fresh, so the hub finds the
  // row untrusted and ssh's the box, which reports MISSING itself.
  //
  // `at` must be the exact `date -u +%Y-%m-%dT%H:%M:%SZ` shape both writers
  // use, because the guard is a string compare.
  [
    "POST", "/api/boxes/self-report",
    async ({ env, t, body }) => {
      const box = laneName(body.box);
      if (!box) {
        return json(400, { error: "a self-report needs a box matching [A-Za-z0-9._-]{1,64}" });
      }
      const at = str(body.at, 40);
      if (!at || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(at)) {
        return json(400, { error: "at must be YYYY-MM-DDTHH:MM:SSZ" });
      }
      const cli = str(body.cli_version, 64);
      const codex = str(body.codex_version, 64);
      const cliOk = !!(cli && codex && cli !== "missing" && codex !== "missing");
      const rh = str(body.rules_hash, 64);
      if (rh && !/^([0-9a-f]{32}|-)$/.test(rh)) {
        return json(400, { error: "rules_hash must be an md5 hex digest or '-'" });
      }
      const rulesOk = !!rh;
      if (!cliOk && !rulesOk) return json(400, { error: "nothing to record" });
      await ensureColumns(env, "box_status");
      const cliAt = cliOk ? at : null;
      const rulesAt = rulesOk ? at : null;
      await env.DB.prepare(
        `INSERT INTO box_status (box, cli_version, codex_version, cli_checked_at, rules_hash, rules_reported_at, actor, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,'self-report',?7)
         ON CONFLICT(box) DO UPDATE SET
           cli_version=CASE WHEN ?4 IS NOT NULL AND (box_status.cli_checked_at IS NULL OR box_status.cli_checked_at<=?4) THEN ?2 ELSE box_status.cli_version END,
           codex_version=CASE WHEN ?4 IS NOT NULL AND (box_status.cli_checked_at IS NULL OR box_status.cli_checked_at<=?4) THEN ?3 ELSE box_status.codex_version END,
           cli_checked_at=CASE WHEN ?4 IS NOT NULL AND (box_status.cli_checked_at IS NULL OR box_status.cli_checked_at<=?4) THEN ?4 ELSE box_status.cli_checked_at END,
           rules_hash=CASE WHEN ?6 IS NOT NULL AND (box_status.rules_reported_at IS NULL OR box_status.rules_reported_at<=?6) THEN ?5 ELSE box_status.rules_hash END,
           rules_reported_at=CASE WHEN ?6 IS NOT NULL AND (box_status.rules_reported_at IS NULL OR box_status.rules_reported_at<=?6) THEN ?6 ELSE box_status.rules_reported_at END,
           actor=CASE WHEN (?4 IS NOT NULL AND (box_status.cli_checked_at IS NULL OR box_status.cli_checked_at<=?4))
                        OR (?6 IS NOT NULL AND (box_status.rules_reported_at IS NULL OR box_status.rules_reported_at<=?6))
                      THEN 'self-report' ELSE box_status.actor END,
           updated_at=CASE WHEN (?4 IS NOT NULL AND (box_status.cli_checked_at IS NULL OR box_status.cli_checked_at<=?4))
                        OR (?6 IS NOT NULL AND (box_status.rules_reported_at IS NULL OR box_status.rules_reported_at<=?6))
                      THEN ?7 ELSE box_status.updated_at END`
      ).bind(box, cliOk ? cli : null, cliOk ? codex : null, cliAt, rulesOk ? rh : null, rulesAt, t).run();
      // cli_recorded / rules_recorded say the half was valid and sent, NOT that
      // the guard let it through: an older report is accepted and changes nothing,
      // not even actor/updated_at, which move only when at least one half lands.
      return json(200, { box, cli_recorded: cliOk, rules_recorded: rulesOk, as_of: t });
    },
  ],
];
