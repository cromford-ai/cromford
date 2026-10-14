// lanes routes — every automatic lane: its registry, status, switches and ticks.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  intOrNull, boolInt, str, laneName, decorateLane, ensureColumns, ensureTable,
  LANES_REGISTRY, REGISTRY_SEED_ACTOR,
} from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";
import { fleetFlagRows } from "../lib/harness-flags.js";

export const routes = [
  // ── The harness control plane (BH-1132) ────────────────────────────────
  // the operator, 2026-09-20: "add hot fixes so we can have control on all those
  // harness mechanisms and be able to stop or start them or change their
  // values min max etc … a UI settings page … on a hub level and on a
  // project level so we can control each and see their stats."
  //
  // THREE ROUTES AND NO FOURTH. The registry is served as deployed; the
  // status route JOINS the registry against the rows that already exist
  // (pause_flags, settings, cost_rows, lanes); and all-off/all-on write ONE
  // pause_flags row. Turning a single lane off is PUT /api/flags and setting
  // a knob is PUT /api/settings — the routes that have always done it. A
  // second writer for the same row is how two surfaces start disagreeing
  // about whether a lane is on.
  [
    "GET", "/api/lanes/registry",
    async ({ t }) => {
      return json(200, { registry: LANES_REGISTRY, as_of: t });
    },
  ],

  // The shape is docs/verification-map/lanes-status-contract.md, field for
  // field, pinned by test/lanes-control.test.js. Phase B's screen was built
  // against it before this route existed, so a difference found here is a
  // difference; a difference found by an operator is a control panel that
  // renders and controls nothing.
  [
    "GET", "/api/lanes/status",
    async ({ env, url, t }) => {
      const project = laneName(url.searchParams.get("project") || "") || null;
      // ?project= RESOLVES, it does not filter: it decides which switch names
      // and settings keys are looked up and how spend is attributed, never
      // which lanes exist. An earlier draft hid box-scoped lanes from a project
      // view, which hid bin/preplan-tick.sh — a lane that spends model calls on
      // that project's tickets. A control plane whose project page can omit a
      // spend lane is the problem it was built to solve.
      const reg = LANES_REGISTRY.lanes || [];
      // BH-4154: every fleet flag from the store its name picks, so a ported
      // switch (automerge-disabled) is its harness_flags row, not a mirror.
      const { flags } = await fleetFlagRows(env, { limit: 2000 });
      const flagBy = new Map(flags.map((r) => [r.name, r]));
      const settings = await env.DB.prepare(
        "SELECT key, value, actor, updated_at FROM settings WHERE key LIKE 'lane.%' LIMIT 2000").all();
      const setBy = new Map((settings.results || []).map((r) => [r.key, r]));
      // `projects` is the fleet's OWN declaration — the rows the hub writes
      // from fleet.conf through PUT /api/lanes — not a list derived from
      // whatever happened to spend money today. A project that ran nothing
      // still has a tab.
      const laneRows = await env.DB.prepare(
        "SELECT project, box, last_tick_at, last_tick_kind FROM lanes ORDER BY project ASC LIMIT 500").all();
      const projects = [...new Set((laneRows.results || []).map((r) => r.project).filter(Boolean))].sort();

      // ── the BH-1165 halves: THIS ROUTE CREATES THEM, AND BOTH FAIL OPEN ──
      // The reader creates them too (BH-1291). They self-create on first use,
      // but the first use used to be the first lane to POST, so a worker that
      // deployed before any lane ticked answered this page with every lane's
      // tick unknown and wrote two "unreadable" lines per page load until one
      // did — a degrade reported on a database that was simply new. The
      // `ensureTable` calls are the BH-658 apply mechanism and belong to every
      // reader, not only to the POST routes.
      // The try/catch STAYS, and each create runs INSIDE it: a CREATE that
      // fails for a D1 reason must degrade this column, never 500 the whole
      // settings page at exactly the moment an operator is on it because
      // something is wrong. Each degrade writes one line naming the table, so
      // "no ticks anywhere" is never silent.
      let tickRows = [];
      try {
        await ensureTable(env, "lane_ticks");
        const q = await env.DB.prepare(
          "SELECT lane, project, box, last_tick_at, last_outcome, why FROM lane_ticks ORDER BY last_tick_at DESC LIMIT 2000").all();
        tickRows = q.results || [];
      } catch (e) {
        console.log(`lanes/status: lane_ticks unreadable, every lane reports an unknown tick — ${e && e.message || e}`);
      }
      let sightingRows = [];
      try {
        await ensureTable(env, "lane_flag_sightings");
        const q = await env.DB.prepare(
          "SELECT name, box, lane, project, active, seen_at FROM lane_flag_sightings WHERE active=1 LIMIT 1000").all();
        sightingRows = q.results || [];
      } catch (e) {
        console.log(`lanes/status: lane_flag_sightings unreadable, a hand-placed flag file stays invisible — ${e && e.message || e}`);
      }
      // The master switch as a FILE. `all_off` above is the pause_flags row an
      // operator can clear from this page; this is a file on a box that no row
      // drove, and the page cannot clear it — so it is reported separately and
      // named by box, which is the difference between "press this" and "ssh there".
      const MASTER_FLAG = "all-off";
      const masterSightings = sightingRows.filter(
        (r) => r && Number(r.active) === 1 && r.name === MASTER_FLAG);
      const allOffFlagBoxes = [...new Set(masterSightings.map((r) => r.box))].sort();


      const midnight = t.slice(0, 10) + "T00:00:00Z";
      const weekAgo = new Date(Date.parse(t) - 7 * 86400000).toISOString();
      // ts >= …, not substr(ts,1,10) = …, so the (project, ts) index is usable.
      const spendRows = await env.DB.prepare(
        `SELECT stage, project,
                SUM(CASE WHEN ts >= ?1 THEN COALESCE(cost_usd,0) ELSE 0 END) AS cost_today,
                SUM(CASE WHEN ts >= ?1 THEN 1 ELSE 0 END)                    AS runs_today,
                SUM(COALESCE(cost_usd,0))                                    AS cost_7d
           FROM cost_rows WHERE ts >= ?2 GROUP BY stage, project`
      ).bind(midnight, weekAgo).all();
      const spend = spendRows.results || [];
      // The detail view's rows, fetched ONCE and bucketed here rather than as
      // one query per lane: 77 lanes would otherwise be 77 round trips.
      const recentRows = await env.DB.prepare(
        `SELECT ts, stage, project, ticket, cost_usd, run_id FROM cost_rows
          WHERE ts >= ?1 AND COALESCE(cost_usd,0) > 0 ORDER BY ts DESC LIMIT 500`
      ).bind(weekAgo).all();
      const recent = recentRows.results || [];
      const allOff = flagBy.get("all-off");
      // WHICH LANES CAN BE TOLD APART BY THE COST ROWS AT ALL. bin/agent-call.sh
      // writes (stage, project) and nothing else that names a lane, so
      // merge-conductor, review-autopilot and review-prs all land as
      // stage=review with a real project — three lanes, one signature. Handing
      // each of them the same fleet-wide sum tells an operator three lanes are
      // each spending $X when one of them spent it. A number nobody can
      // attribute is worse than no number, so a shared signature reports null
      // and says why.
      //
      // `stats.cost_stage` is a string or an ARRAY of stages (BH-2304:
      // run-product calls agent-call.sh as map/signals/ideate/synth). A lane
      // has one signature per stage, and it is shared when ANY of them is —
      // the same `stage|filter` rule bin/lib/llm-gate.sh resolves a call by.
      //
      // NO STAGE AND NO FILTER MEANS NO NUMBER (BH-3557). A lane that declares
      // neither owns no cost row by any rule, and `owns()` below would match
      // every row for it: 91 lanes each showed the whole fleet's spend (or a
      // project's, on a project tab) as their own. Such a lane reports null
      // counts, no cost rows and cost_attribution "none".
      const stagesOf = (l) => {
        const cs = (l.stats || {}).cost_stage;
        if (Array.isArray(cs)) return cs.filter((x) => typeof x === "string" && x);
        return typeof cs === "string" && cs ? [cs] : [];
      };
      const sigs = (l) => stagesOf(l).map((s) => `${s}|${(l.stats || {}).cost_project_filter || "-"}`);
      const sigCount = new Map();
      for (const l of reg) {
        for (const k of sigs(l)) sigCount.set(k, (sigCount.get(k) || 0) + 1);
      }

      // ── WHAT THE CONDUCTOR PUBLISHED (BH-1201) ──────────────────────────
      // Two settings rows the merge conductor writes and this page only reads.
      // They are a SECOND query because the settings read above is
      // `key LIKE 'lane.%'` and could never see either key. Same degrade shape
      // as the two reads above: one line naming the table, both fields null,
      // and the page still renders — an operator is on this screen precisely
      // when something is wrong with the conductor.
      let condMode = null, condHeld = null;
      try {
        const cs = await env.DB.prepare(
          "SELECT key, value FROM settings WHERE key IN ('merge-conductor.mode','merge-conductor.held_pages')").all();
        for (const r of cs.results || []) {
          if (r.key === 'merge-conductor.mode') condMode = r.value ?? null;
          if (r.key === 'merge-conductor.held_pages') condHeld = r.value ?? null;
        }
      } catch (e) {
        console.log(`lanes/status: settings unreadable for merge-conductor.mode — ${e && e.message || e}`);
      }

      const lanes = reg.map((l) => {
        const st = l.stats || {};
        const scoped = l.scope === "project" && project;
        // A HUB LANE CAN BE HELD ON ONE PROJECT (BH-1466). #1463 gave five of
        // them `per_project_hold`, and bin/lib/lane-gate.sh stops that lane for
        // that project alone on one `lane-off-<id>-<project>` row. This reads
        // the same row so the page says what the gate does. `scoped` is NOT
        // widened to cover it: `scoped` also picks the knob key (`pk` below)
        // and the cost attribution (`owns`), and a hub lane reads neither per
        // project — offering a per-project knob would be a control that does
        // nothing, and splitting its spend by tab would invent a number.
        const projectHold = l.per_project_hold === true && Boolean(project);
        const names = [`lane-off-${l.id}`];
        if (scoped || projectHold) names.push(`lane-off-${l.id}-${project}`);
        // The truth about "is this lane off" includes the switches that predate
        // BH-1132 (automerge-disabled, preplan-speculative-off, …). A page that
        // showed only the new flag would report a lane as ON while an old one
        // held it — the exact class of lie the registry exists to end.
        // ALIAS POLARITY. `switch.aliases` is not a list of off-switches: some
        // of the flags that predate BH-1132 are ENABLE flags
        // (flags/fly-pool-<p> is what makes the pool run at all;
        // conductor-owns-merges and merge-conductor-merge arm the conductor),
        // and some only change behaviour (…-observe). Counting an active enable
        // row as "held" showed the conductor as OFF precisely when it was armed,
        // and the toggle written to clear it was a no-op. Only off_when
        // "present" may make a lane off; "absent" rows are reported as what
        // arms it, and "partial" rows only as modifiers.
        const alias = ((l.switch && l.switch.aliases) || []).map(
          (a) => (typeof a === "string" ? { name: a, off_when: "present" } : a));
        const expand = (n) => (n.endsWith("-") && project ? n + project : n);
        const rowOf = (n) => flagBy.get(expand(n));
        const held = [...names.map((n) => flagBy.get(n)),
                      ...alias.filter((a) => a.off_when === "present").map((a) => rowOf(a.name))]
          .filter((r) => r && r.active);
        const enables = alias.filter((a) => a.off_when === "absent")
          .map((a) => ({ name: expand(a.name), active: Boolean(rowOf(a.name) && rowOf(a.name).active) }));
        const modifiers = alias.filter((a) => a.off_when === "partial")
          .map((a) => ({ name: expand(a.name), active: Boolean(rowOf(a.name) && rowOf(a.name).active) }))
          .filter((m) => m.active);
        const masterOn = Boolean(allOff && allOff.active);
        // A BOX-LOCAL FILE IS A REAL STOP (BH-1165). The gate reports what it
        // found under flags/ that no row drove; until it could, this page said
        // such a lane was ON, which is the lie the registry exists to end. The
        // sighting is matched on the switch NAME, so an alias file (the
        // pre-BH-1132 names) counts exactly as its row would.
        const nameSet = new Set([...names, ...alias.map((a) => expand(a.name))]);
        // A HAND-TOUCHED `flags/all-off` HOLDS EVERY LANE ON THAT BOX (BH-1165
        // review), not just whichever one happened to tick first. The gate's
        // sighting marker is keyed on the flag NAME, so the first lane to reach
        // an hourly refresh posts the row with its own id and the other 77 are
        // throttled for an hour — matching it by `r.lane === l.id` reported one
        // lane of 78 as off while the box was fully stopped. Master sightings
        // are lifted out and applied to every lane; `all_off_flag_boxes` at the
        // top level is the same fact for the header, next to the `pause_flags`
        // row's own `all_off`.
        // AND THE `r.lane === l.id` FALLBACK IS PROJECT-SCOPED (BH-1165 review
        // round 2). It exists for a sighting whose NAME this view did not build
        // — an alias, or a name from a newer box. Unscoped, it also matched a
        // SIBLING project's file: on `?project=project-3` a sighting of
        // `lane-off-review-prs-project-2` reported project-3's review-prs as
        // stopped by a file on orgo-2, and the operator who ssh'd there found
        // nothing of project-3's. A sighting that names a project belongs to that
        // project's view; one that names none is box-wide and holds for all.
        // And that fallback is reachable for the five HOLD lanes now (BH-1466):
        // per-project files exist for them, so an unscoped test would report
        // the conductor stopped on every project's tab because project-3's file was
        // seen on the hub.
        const ownsSighting = (r) => !(scoped || projectHold) || !r.project || r.project === "-" || r.project === project;
        // A PER-BOX SWITCH IS ONE BOX'S (BH-2327). `lane-off-<id>.box.<box>`
        // stops this lane on that box alone, so a file of that name must not
        // reach the `r.lane === l.id` fallback and read as "off fleet-wide".
        // It is reported per box in `boxes` below instead.
        const boxPrefix = `lane-off-${l.id}.box.`;
        const sightings = [
          ...masterSightings,
          ...sightingRows.filter((r) => r && Number(r.active) === 1
            && r.name !== MASTER_FLAG && !String(r.name).startsWith(boxPrefix)
            && (nameSet.has(r.name) || (r.lane === l.id && ownsSighting(r)))),
        ];
        const off = Boolean(masterOn || held.length || sightings.length);
        const by = masterOn ? allOff : (held[0] || null);
        // The ROW outranks the sighting: both are true, but the row is the one
        // an operator can clear from this page, so it is what the page names.
        const off_source = !off ? null
          : (masterOn ? "all-off" : (held.length ? "db" : "flag"));


        const knobs = {};
        for (const k of l.knobs || []) {
          if (!k.env) continue;
          // lane.<id>[.<project>].<env lowercased> — the published contract's
          // form and the one the console writes. One knob, one key.
          const e0 = String(k.env).toLowerCase();
          const gk = `lane.${l.id}.${e0}`.toLowerCase();
          // A `project_scoped` knob on a box/hub lane is read per project too
          // (BH-1985): the gate reads that project's row for it (lane-reaper's
          // deadline, harness-ctl `project_scoped`). `scoped` still owns the
          // switch names and the spend, so those stay fleet-wide.
          const pk = (scoped || (project && k.project_scoped === true))
            ? `lane.${l.id}.${project}.${e0}`.toLowerCase() : null;
          // A REGISTRY-SEED row is the DB's copy of the default (BH-1511.1),
          // ranked below the env on every box — so it is not a value the
          // database sets, and reporting it as one would claim every knob was
          // set from here while each box ran its own env/global.env.
          const own = (k0) => { const r0 = k0 && setBy.get(k0); return r0 && r0.actor !== REGISTRY_SEED_ACTOR ? r0 : null; };
          const row = own(pk) || own(gk) || null;
          // ONLY a row lands here. This map supplies VALUES; the registry
          // supplies BOUNDS and defaults. A knob absent from it means "the
          // database does not set this", which is exactly true — the worker
          // cannot see a box's env/global.env and must not claim a value it
          // has not read.
          if (!row) continue;
          const num = Number(row.value);
          knobs[k.env] = {
            value: Number.isFinite(num) && k.type !== "string" ? num : row.value,
            source: "settings",
            key: own(pk) ? pk : gk,
            min: k.min ?? null, max: k.max ?? null,
            type: k.type || null, zero_means: k.zero_means ?? null,
            set_by: row.actor || null, set_at: row.updated_at || null,
          };
        }

        const myStages = stagesOf(l);
        const mySigs = sigs(l);
        const owns = (r) => (!myStages.length || myStages.includes(r.stage))
          && (st.cost_project_filter ? r.project === st.cost_project_filter
                                     : (!scoped || r.project === project));
        const ambiguous = mySigs.some((k) => (sigCount.get(k) || 0) > 1) && !scoped;
        const noCost = !myStages.length && !st.cost_project_filter;
        const mine = (ambiguous || noCost) ? [] : spend.filter(owns);
        // NULL, not 0, when no source mentions this lane. "Unknown" and "did
        // nothing" are different answers and the screen renders them
        // differently (NO STATUS vs a calm zero).
        const sum = (f) => (mine.length ? mine.reduce((a, r) => a + (Number(r[f]) || 0), 0) : null);
        const shared = ambiguous
          ? reg.filter((o) => o.id !== l.id && sigs(o).some((k) => mySigs.includes(k))).map((o) => o.id) : [];

        // THE LANE'S OWN TICK FIRST (BH-1165). lane_ticks is keyed
        // (lane, project, box), so a conductor tick is the conductor's. The
        // `lanes` table stays the FALLBACK for the one lane the registry marks
        // `stats.lanes_row` — the triage lane, whose (project, box) row every
        // stale-lane pager already reads — so nothing that worked before this
        // stops working while the fleet rolls out.
        const myTicks = tickRows.filter((r) => r && r.lane === l.id
          && (l.scope !== "project" || !project || r.project === project));
        const newest = myTicks.reduce((a, r) =>
          (!a || String(r.last_tick_at) > String(a.last_tick_at) ? r : a), null);
        const legacy = (st.lanes_row && project)
          ? (laneRows.results || []).find((r) => r.project === project) || null
          : null;
        const tickRow = newest
          ? { last_tick_at: newest.last_tick_at, last_tick_kind: newest.last_outcome }
          : legacy;

        // ── PER-BOX STATE, box lanes only (BH-2327) ──────────────────────
        // The boxes are every box that ticked this lane, every box holding a
        // per-box row (on or off, so a switched box that never ticked, or was
        // decommissioned, can still be cleared), and every box reporting a
        // per-box file. A hub or project lane carries no `boxes` key at all:
        // absent means "not switched per box", which is not an empty fleet.
        let perBox = {};
        if (l.scope === "box") {
          const boxOf = (n) => n.slice(boxPrefix.length);
          const bset = new Set(myTicks.map((r) => r.box).filter(Boolean));
          for (const n of flagBy.keys()) if (n.startsWith(boxPrefix) && boxOf(n)) bset.add(boxOf(n));
          const boxSight = sightingRows.filter((r) => r && Number(r.active) === 1
            && String(r.name).startsWith(boxPrefix) && r.box === boxOf(String(r.name)));
          for (const r of boxSight) bset.add(r.box);
          const boxes = [...bset].sort().map((b) => {
            const sw = boxPrefix + b;
            const row = flagBy.get(sw);
            const dbOff = Boolean(row && Number(row.active) === 1);
            const seen = boxSight.find((r) => r.box === b) || null;
            const bt = myTicks.filter((r) => r.box === b).reduce((a, r) =>
              (!a || String(r.last_tick_at) > String(a.last_tick_at) ? r : a), null);
            const bOff = dbOff || Boolean(seen);
            return {
              box: b, switch_name: sw, off: bOff,
              off_source: dbOff ? "db" : (seen ? "flag" : null),
              paused_since: dbOff ? row.updated_at : (seen ? seen.seen_at : null),
              paused_by: dbOff ? row.actor : (seen ? seen.box : null),
              paused_reason: dbOff ? row.reason
                : (seen ? `a file nothing in the database wrote: flags/${sw} on ${b}` : null),
              last_tick_at: bt ? bt.last_tick_at : null,
              last_outcome: bt ? bt.last_outcome : null,
            };
          });
          // The box list came from a capped read when lane_ticks filled its
          // LIMIT, and it says so rather than implying the fleet is complete.
          perBox = { boxes, boxes_off: boxes.filter((b) => b.off).length, boxes_complete: tickRows.length < 2000 };
        }


        return {
          id: l.id, name: l.name || l.id, scope: l.scope,
          per_project_hold: Boolean(l.per_project_hold),
          project: l.scope === "project" ? project : null,
          cadence: l.cadence || null, script: l.script || null,
          wired: Boolean(l.wired),
          off, off_source,
          paused_since: off ? (by ? by.updated_at : (sightings[0] ? sightings[0].seen_at : null)) : null,
          paused_by: off ? (by ? by.actor : (sightings[0] ? sightings[0].box : null)) : null,
          paused_reason: off ? (by ? by.reason
            : (sightings[0] ? `a file nothing in the database wrote: flags/${sightings[0].name} on ${sightings[0].box}` : null)) : null,
          held_by: [...held.map((r) => r.name), ...sightings.map((r) => r.name)]
            .filter((n, i, a) => a.indexOf(n) === i),
          // WHICH BOXES are holding a file nobody wrote a row for. A hub lane
          // has one; a box lane can be stopped on one box and running on eight.
          flag_boxes: sightings.map((r) => r.box).filter((b, i, a) => a.indexOf(b) === i).sort(),
          switch: { kind: "flag", name: `lane-off-${l.id}`, aliases: alias },
          enables, modifiers,
          last_tick_at: tickRow ? tickRow.last_tick_at : null,
          last_outcome: tickRow ? tickRow.last_tick_kind : null,
          runs_today: sum("runs_today"),
          cost_today: sum("cost_today"),
          cost_7d: sum("cost_7d"),
          knobs,
          cost_attribution: ambiguous ? "shared" : (noCost ? "none" : "lane"),
          cost_shared_with: shared,
          cost_rows: (ambiguous || noCost ? [] : recent.filter(owns)).slice(0, 10).map((r) => ({
            at: r.ts, stage: r.stage, ticket: r.ticket || null,
            usd: Number(r.cost_usd) || 0, build_dir: r.run_id || null,
          })),
          stats: { cost_stage: st.cost_stage || null, cost_project_filter: st.cost_project_filter || null, log: st.log || null },
          // ONE LANE ONLY. `held_pages` is the conductor's own summary string
          // ("3 STUCK=2 BUDGET=1" / "0"), unparsed: null means it has published
          // nothing, which is not the same answer as holding nothing (D11).
          ...(l.id === "merge-conductor" ? { mode: condMode, held_pages: condHeld } : {}),
          ...perBox,
        };
      });

      return json(200, {
        as_of: t, projects, project,
        all_off: Boolean(allOff && allOff.active),
        all_off_at: allOff && allOff.active ? allOff.updated_at : null,
        // A hand-touched flags/all-off, per box. It is NOT `all_off`: that one
        // is the row this page can clear, and this one is a file that only an
        // ssh can. Empty list = nobody reported one (BH-1165 review).
        all_off_flag_boxes: allOffFlagBoxes,
        lanes,
      });
    },
  ],

  // THE BOXES THAT RUN LANE-GATE (review round 2 of #1565, B1). The distinct
  // lane_ticks.box that ticked any lane inside `within_s`, each at its newest
  // tick. This, not box_status, is the fleet `harness-ctl seed-registry` must
  // prove: box_status also holds the CLI sweep's cron_box_id_for aliases
  // (box-hub -> hub), which never carry a harness_commit, and it has
  // no row for a box that ticks lanes but never reported a backup or a CLI
  // version. Every lane-gate, old or new, writes lane_ticks under the same
  // name its liveness post writes box_status under.
  //
  // THE CALLER OWNS THE WINDOW: no default, and one this route cannot honour
  // is a 400 rather than a guess. A read error is NOT caught — a gate that
  // cannot read the fleet must fail, never see an empty one.
  [
    "GET", "/api/lanes/tick-boxes",
    async ({ env, url, t }) => {
      const raw = url.searchParams.get("within_s") || "";
      const within = /^[0-9]{1,7}$/.test(raw) ? Number(raw) : NaN;
      if (!(within >= 60 && within <= 2592000)) {
        return json(400, { error: "within_s must be an integer number of seconds, 60..2592000" });
      }
      await ensureTable(env, "lane_ticks");
      const since = new Date(Date.parse(t) - within * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
      const q = await env.DB.prepare(
        `SELECT box, MAX(last_tick_at) AS last_tick_at FROM lane_ticks
          WHERE last_tick_at >= ?1 GROUP BY box ORDER BY box ASC LIMIT 500`
      ).bind(since).all();
      return json(200, { boxes: q.results || [], within_s: within, since, as_of: t });
    },
  ],

  // The master switch. ONE row named all-off, which bin/lib/lane-gate.sh
  // checks before anything else, so a single write stops every registered
  // lane on every box without touching 77 rows (and without 77 chances to
  // half-succeed). all-on clears that row and NOTHING else: a lane an
  // operator turned off last week stays off, because "resume everything"
  // must not silently undo a decision nobody revisited. Since BH-2377 the
  // upsert is batched with a `flag` config_changes row when `active` changed.
  [
    "POST", ["/api/lanes/all-off", "/api/lanes/all-on"],
    async ({ env, path, t, body }) => {
      const active = path.endsWith("all-off") ? 1 : 0;
      // BOTH WAYS, AND BOTH FIELDS. Stopping or resuming the entire fleet is
      // the one row you most want attributed, and defaulting the actor to "api"
      // is how a row ends up naming nobody. `all-on` is not the harmless half:
      // resuming during an incident is a decision too.
      const actor = str(body.actor, 128);
      const reason = str(body.reason, 512);
      if (!actor) return json(400, { error: "actor required — a fleet stop or resume names a human" });
      if (!reason) return json(400, { error: "reason required — it is what the next person reads" });
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare("SELECT * FROM pause_flags WHERE name='all-off'").first();
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO pause_flags (name, active, actor, reason, updated_at) VALUES ('all-off',?1,?2,?3,?4)
           ON CONFLICT(name) DO UPDATE SET active=?1, actor=?2, reason=?3, updated_at=?4`
        ).bind(active, actor, reason, t),
        ...configChangeStmts(env, CONFIG_KINDS.FLAG, "all-off", was, { active }, ["active"], actor, reason, t),
      ]);
      const row = await env.DB.prepare("SELECT * FROM pause_flags WHERE name='all-off'").first();
      return json(200, { flag: row, all_off: active === 1, as_of: t });
    },
  ],

  // ── Lane liveness (2026-08-30) ─────────────────────────────────────────
  // The one thing no other table here could express: an ABSENCE. Everything
  // above records work that HAPPENED, so a lane whose crontab vanished left
  // nothing to age — which is exactly how project-7 went ten hours unnoticed.
  // See the `lanes` comment in schema.sql.
  [
    "GET", "/api/lanes",
    async ({ env, url, t }) => {
      await ensureColumns(env, "lanes");
      const rows = await env.DB.prepare(
        "SELECT * FROM lanes ORDER BY project ASC, box ASC LIMIT 500"
      ).all();
      let lanes = (rows.results || []).map((r) => decorateLane(r, t));
      // ?stale=1 — what the watchdog asks for. The THRESHOLD is the row's own
      // (derived from its cadence), so every reader of this API judges a lane
      // by the same number and the console cannot drift from the pager.
      if (url.searchParams.get("stale") === "1") lanes = lanes.filter((l) => l.stale);
      // ?proc=1 / ?proc_stale=1 — the PROCESS half (BH-1031). The reaper asks
      // for the second one; a console asks for the first. Both judged by the
      // row's own proc threshold, for the same reason as the line above.
      //
      // AND THE DEFAULT EXCLUDES THEM. Every reader that exists today —
      // bin/jobs-watchdog.sh's lane pass, the console's LANES table — is asking
      // "what does fleet.conf say should be ticking", and a process row is not
      // an answer to that. Letting hb.* rows into the default list would have
      // the watchdog resolve a latch it never set and the console show lanes
      // fleet.conf never declared. Opt-in, so nothing that reads this route
      // today changes at all.
      const procOnly = url.searchParams.get("proc_stale") === "1"
        ? "stale" : (url.searchParams.get("proc") === "1" ? "all" : "");
      if (procOnly === "stale") lanes = lanes.filter((l) => l.proc_stale);
      else if (procOnly === "all") lanes = lanes.filter((l) => l.proc_state !== "none");
      else lanes = lanes.filter((l) => !String(l.project || "").startsWith("hb."));
      return json(200, { lanes, as_of: t });
    },
  ],

  // The hub's declaration of what SHOULD be ticking, derived from fleet.conf.
  // Idempotent: it runs every 10 minutes and must be a no-op when nothing has
  // changed, which is why every write here is an upsert and the retirement is
  // a single set-difference rather than a delete.
  [
    "PUT", "/api/lanes",
    async ({ env, t, body }) => {
      const list = Array.isArray(body.lanes) ? body.lanes : [];
      // AN EMPTY SET RETIRES NOTHING. A mid-rsync or unreadable fleet.conf
      // yields no lanes, and honouring that would silently un-watch the entire
      // fleet — the most reassuring possible shape for a total outage. This is
      // the same judgement bin/fleet-status-push.sh already makes about pushing
      // an empty project list.
      if (!list.length) {
        return json(400, {
          error: "an empty expected set would retire the whole fleet — refusing, so an unreadable fleet.conf cannot un-watch it",
        });
      }
      const actor = str(body.actor, 64);
      const keys = [], stmts = [];
      for (const l of list) {
        const project = laneName(l && l.project), box = laneName(l && l.box);
        if (!project || !box) {
          return json(400, { error: "each lane needs a project and a box, both matching [A-Za-z0-9._-]{1,64}" });
        }
        keys.push(`${project}|${box}`);
        stmts.push(env.DB.prepare(
          `INSERT INTO lanes (project, box, cadence_min, offset_min, expected_since, actor, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6,?5)
           ON CONFLICT(project, box) DO UPDATE SET
             cadence_min=?3, offset_min=?4,
             expected_since=CASE WHEN lanes.retired_at IS NOT NULL THEN ?5
                                 ELSE COALESCE(lanes.expected_since, ?5) END,
             retired_at=NULL, actor=COALESCE(?6, lanes.actor), updated_at=?5`
        ).bind(project, box, intOrNull(l.cadence_min), intOrNull(l.offset_min), t, actor));
      }
      // expected_since is COALESCEd rather than overwritten because it is the
      // clock the never-ticked rule ages. Bumping it on every 10-minute push
      // would make a lane whose box never booted look permanently fresh — the
      // incident's twin, reintroduced by the fix. A lane coming BACK from
      // retirement does restart it, because that expectation is genuinely new.
      await env.DB.batch(stmts);
      const holes = keys.map((_, i) => `?${i + 2}`).join(",");
      const retired = await env.DB.prepare(
        `UPDATE lanes SET retired_at=?1, updated_at=?1
          WHERE retired_at IS NULL AND expected_since IS NOT NULL
            AND (project || '|' || box) NOT IN (${holes})`
      ).bind(t, ...keys).run();
      return json(200, {
        expected: keys.length,
        retired: (retired.meta && retired.meta.changes) || 0,
        as_of: t,
      });
    },
  ],

  // A LANE TICK IS NOT A JOB HEARTBEAT. job_heartbeat beats a claim that
  // exists; this records that a cron FIRED, whether or not it claimed
  // anything. A gate `SKIP` — the normal shape of a quiet board — claims
  // nothing and spends nothing and is still the lane being alive, so if only
  // claimed ticks counted, every healthy quiet lane would page.
  [
    "POST", "/api/lanes/tick",
    async ({ env, t, body }) => {
      const project = laneName(body.project), box = laneName(body.box);
      if (!project || !box) {
        return json(400, { error: "a tick needs a project and a box, both matching [A-Za-z0-9._-]{1,64}" });
      }
      const kind = str(body.kind, 32) || "tick";
      await ensureColumns(env, "lanes");
      // ── A PROCESS BEAT IS NOT A CRON TICK (BH-1031) ─────────────────────────
      // `event` is what tells them apart, and the two write DISJOINT columns on
      // purpose. A long-lived lane beating every five minutes must not make the
      // cron half read healthy: on 2026-08-30 the lane that died was a CRON, and
      // a process beat landing in last_tick_at would have hidden exactly that.
      // So: no event = today's behaviour, byte for byte; an event writes only
      // the proc_* columns and never last_tick_at, expected_since, retired_at or
      // alerted_at.
      const event = ["start", "beat", "done"].includes(String(body.event || ""))
        ? String(body.event) : "";
      if (event) {
        const pid = intOrNull(body.pid);
        const note = str(body.note, 500);
        const interval = intOrNull(body.interval_s);
        const expect = intOrNull(body.expect_s);
        // expect_s 0 is a real declaration — "this loop runs for ever on
        // purpose" (WAKE_LOOP_CYCLES=0) — and must clear any deadline a
        // previous launch left, or the lane reads overdue for ever.
        const deadline = expect && expect > 0
          ? new Date(Date.parse(t) + expect * 1000).toISOString() : null;
        if (event === "done") {
          await env.DB.prepare(
            `INSERT INTO lanes (project, box, proc_pid, proc_note, proc_beat_at, proc_ended_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?5,?5)
             ON CONFLICT(project, box) DO UPDATE SET
               proc_ended_at=?5, proc_note=COALESCE(?4, lanes.proc_note), updated_at=?5`
          ).bind(project, box, pid, note || null, t).run();
        } else if (event === "start") {
          // A LAUNCH CLEARS THE PREVIOUS INSTANCE'S EXIT. Without that, a lane
          // that finished cleanly and was relaunched would keep reading `ended`
          // and its next death would never page.
          await env.DB.prepare(
            `INSERT INTO lanes (project, box, proc_pid, proc_note, proc_started_at,
                                proc_interval_s, proc_deadline_at, proc_beat_at, proc_ended_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?5,NULL,?5)
             ON CONFLICT(project, box) DO UPDATE SET
               proc_pid=?3, proc_note=?4, proc_started_at=?5, proc_interval_s=?6,
               proc_deadline_at=?7, proc_beat_at=?5, proc_ended_at=NULL, updated_at=?5`
          ).bind(project, box, pid, note || null, t, interval, deadline).run();
        } else {
          // A BEAT NEVER REWRITES THE LAUNCH'S NUMBERS — the same rule
          // bin/lib/heartbeat.sh's hb_tick keeps against the file — so a lane
          // that adopted the one-line beat cannot quietly move its own
          // expected-by every pass and never be overdue.
          //
          // WHICH MEANS THE ROW WINS ON proc_interval_s, not the beat
          // (round 1 on #1150). COALESCE(?6, lanes.…) was the wrong way round:
          // a beat that carried an interval — a box on an older bin/ sends the
          // library default 300 — silently retuned the threshold of every lane
          // that had declared its own at launch. blocked-resolver declares
          // 1800 and its fix rounds legitimately run to 5400s, so that beat
          // dropped its threshold to 900s and paged `silent` for a healthy
          // round while the file on the box read fresh. The beat's number is
          // only ever a seed for a row that has never had one.
          await env.DB.prepare(
            `INSERT INTO lanes (project, box, proc_pid, proc_note, proc_started_at,
                                proc_interval_s, proc_beat_at, proc_ended_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?5,NULL,?5)
             ON CONFLICT(project, box) DO UPDATE SET
               proc_pid=COALESCE(?3, lanes.proc_pid), proc_note=?4,
               proc_interval_s=COALESCE(lanes.proc_interval_s, ?6),
               proc_beat_at=?5, proc_ended_at=NULL, updated_at=?5`
          ).bind(project, box, pid, note || null, t, interval).run();
        }
        const prow = await env.DB.prepare(
          "SELECT * FROM lanes WHERE project=?1 AND box=?2").bind(project, box).first();
        return json(200, { lane: prow ? decorateLane(prow, t) : null, as_of: t });
      }
      // Deliberately touches NOTHING but the tick columns: a box cannot enrol
      // itself (expected_since), cannot un-retire a lane an operator dropped
      // (retired_at), and cannot swallow the recovery notice the watchdog owes
      // the operator (alerted_at).
      await env.DB.prepare(
        `INSERT INTO lanes (project, box, last_tick_kind, last_tick_at, updated_at)
         VALUES (?1,?2,?3,?4,?4)
         ON CONFLICT(project, box) DO UPDATE SET
           last_tick_at=?4, last_tick_kind=?3, updated_at=?4`
      ).bind(project, box, kind, t).run();
      const row = await env.DB.prepare(
        "SELECT * FROM lanes WHERE project=?1 AND box=?2").bind(project, box).first();
      return json(200, { lane: row ? decorateLane(row, t) : null, as_of: t });
    },
  ],

// ── PER-LANE LIVENESS (BH-1165) ────────────────────────────────────────
  // A DIFFERENT ROW FROM /api/lanes/tick, and that is the whole point. That
  // one is keyed (project, box) and is the TRIAGE lane's staleness row, so a
  // merge-conductor tick posted there refreshes a clock the stale-lane pager
  // reads for something else. This is keyed (lane, project, box).
  //
  // A PAUSED TICK IS A TICK. The gate posts on every run, gated or not:
  // "stopped" and "dead" are different answers and only a lane that keeps
  // reporting while it is stopped can tell them apart.
  [
    "POST", "/api/lanes/liveness",
    async ({ env, t, body }) => {
      await ensureTable(env, "lane_ticks");
      const lane = str(body.lane, 64);
      // THE REGISTRY IS THE VOCABULARY. A typo'd id in one shipped script would
      // otherwise fill this table with rows for a lane nobody can find, and the
      // page would grow a line for automation that does not exist.
      if (!lane || !(LANES_REGISTRY.lanes || []).some((l) => l.id === lane)) {
        return json(400, { error: "lane must be an id in catalog/lanes.json" });
      }
      const box = laneName(body.box);
      if (!box) return json(400, { error: "a tick needs the box that ran it" });
      const outcome = str(body.outcome, 16);
      if (outcome !== "ran" && outcome !== "paused") {
        return json(400, { error: "outcome is ran or paused" });
      }
      // '-' and never NULL: a NULL inside a composite PRIMARY KEY lets SQLite
      // store the same hub lane once per tick instead of once.
      const project = laneName(body.project || "") || "-";
      await env.DB.prepare(
        `INSERT INTO lane_ticks (lane, project, box, last_outcome, last_tick_at, why, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?5)
         ON CONFLICT(lane, project, box) DO UPDATE SET
           last_tick_at=?5, last_outcome=?4, why=?6, updated_at=?5`
      ).bind(lane, project, box, outcome, t, str(body.why, 200) || null).run();
      // WHICH HARNESS COMMIT THIS BOX RUNS (BH-1511.1 review, I2). Sent at most
      // hourly by bin/lib/lane-gate.sh — the contract version, so a box that
      // reports one is by construction running a lane-gate that knows the
      // registry-seed actor. `harness-ctl seed-registry` refuses unless every
      // box has reported recently. Only a hex sha is stored; anything else is
      // ignored and the tick still lands.
      const sha = typeof body.harness_commit === "string" ? body.harness_commit.trim() : "";
      if (/^[0-9a-f]{7,40}$/.test(sha)) {
        await ensureColumns(env, "box_status");
        await env.DB.prepare(
          `INSERT INTO box_status (box, harness_commit, harness_reported_at, actor, updated_at)
           VALUES (?1,?2,?3,'lane-gate',?3)
           ON CONFLICT(box) DO UPDATE SET harness_commit=?2, harness_reported_at=?3, updated_at=?3`
        ).bind(box, sha, t).run();
      }
      return json(200, { tick: { lane, project, box, outcome, at: t } });
    
    },
  ],

  // ── A BOX-LOCAL FLAG FILE, REPORTED (BH-1165) ──────────────────────────
  // IT IS A SIGHTING AND NOT A DECISION. It would be one line to write the
  // file back into pause_flags, and that line would turn one box's hand touch
  // (or its cost autohalt) into a fleet-wide stop the next time every other
  // box reconciled — a reporting mechanism that changes what it reports.
  // Nothing gates on this table; the settings page reads it.
  [
    "POST", "/api/lanes/flag-seen",
    async ({ env, t, body }) => {
      await ensureTable(env, "lane_flag_sightings");
      const name = String(body.name || "").trim().slice(0, 128);
      if (!name || !/^[A-Za-z0-9._-]+$/.test(name)) return json(400, { error: "valid flag name required" });
      const box = laneName(body.box);
      if (!box) return json(400, { error: "a sighting names the box that saw it" });
      const active = boolInt(body.active) === 1 ? 1 : 0;
      const lane = str(body.lane, 64) || null;
      const project = laneName(body.project || "") || null;
      await env.DB.prepare(
        `INSERT INTO lane_flag_sightings (name, box, lane, project, active, seen_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?6)
         ON CONFLICT(name, box) DO UPDATE SET
           lane=COALESCE(?3, lane), project=COALESCE(?4, project),
           active=?5, seen_at=?6, updated_at=?6`
      ).bind(name, box, lane, project, active, t).run();
      return json(200, { sighting: { name, box, lane, project, active, seen_at: t } });
    
    },
  ],

  // THE DEDUPE AND THE RECOVERY ARE ONE COLUMN. Set when a stale lane is
  // paged, cleared when it comes back — and the clearing is what makes the
  // "resumed" line possible. A hub-local seen-file could do the first half
  // and never the second, and would forget even that on every rebuild.
  [
    "PATCH", "/api/lanes/alert",
    async ({ env, t, body }) => {
      const project = laneName(body.project), box = laneName(body.box);
      if (!project || !box) return json(400, { error: "project and box are required" });
      const row = await env.DB.prepare(
        "SELECT * FROM lanes WHERE project=?1 AND box=?2").bind(project, box).first();
      if (!row) return json(404, { error: `no lane ${project}@${box}` });
      const on = boolInt(body.alerted) === 1;
      await env.DB.prepare(
        "UPDATE lanes SET alerted_at=?1, updated_at=?4 WHERE project=?2 AND box=?3"
      ).bind(on ? t : null, project, box, t).run();
      return json(200, { lane: { ...row, alerted_at: on ? t : null }, as_of: t });
    },
  ],
];
