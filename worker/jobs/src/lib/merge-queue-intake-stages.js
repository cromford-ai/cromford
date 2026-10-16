// BH-5669 (BH-5008 child 3): the merge-queue STAGE rows and the bisect link a
// batch-draft delivery writes. mapMergeQueueDelivery appends what this answers
// to the delivery's one env.DB.batch, after its own batch/check statements.
//
// Stage rows go through queueStageStmt only. `since` is `<stage>@<draft>`, a
// natural key: a redelivery under a new id is the same row, and two stages of
// one PR never collide in idx_pr_state_events_dedupe. Per member PR:
//   pull_request opened/reopened          → batched (#<draft>)
//   check_run (any intake action)         → checking (#<draft>), once
//   check_suite completed, success, and every stored check of the draft
//   completed with no failed conclusion   → merging (#<draft>)
//   pull_request closed, merged === true  → merged (#<draft>)
//   a failed check on a 1-member bisect draft
//                                         → dequeued (<check> failed on #<n> alone)
// Never `queued` (no delivery here carries a queue position) and never
// `deploy_verified`. A check or suite before the draft row exists writes
// nothing; the next one does. A check or suite on a batch that is already
// closed (finished_at set) writes no checking or merging row: a late first
// delivery must not move a PR back from merged.
//
// GitHub sends one check_suite per app and per workflow run, so one green
// suite does not say the batch is green. The stored checks must agree.
//
// Bisect, on opened/reopened: the newest failed or failing batch of the repo
// whose members are a strict superset of the new draft's is its parent. The
// draft gets bisect_parent, bisect_step = parent step + 1 and bisect_steps =
// the parent's, else ceil(log2(parent member count)), once.
//
// A stage row queueStageStmt refuses (a bad pr) skips that member only. A read
// that fails is not caught: the delivery is a 500 and nothing commits.

import { queueStageStmt } from "./merge-queue-stage.js";
import { membersOf, FAILED_CONCLUSIONS } from "./merge-queue-intake.js";

const CANDIDATES = 20;
const obj = (v) => (v && typeof v === "object" && !Array.isArray(v) ? v : {});

function storedMembers(raw) {
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v.filter((n) => Number.isInteger(n) && n > 0) : [];
  } catch { return []; }
}

// A check name as a stage detail: STAGE_RE allows no parentheses or newline.
const cleanName = (s) => String(s ?? "").replace(/\(/g, "[").replace(/\)/g, "]").replace(/[\r\n]+/g, " ").trim().slice(0, 150);

function rows(db, ctx, members, word, detail) {
  const out = [];
  for (const pr of members) {
    try {
      out.push(queueStageStmt(db, {
        repo: ctx.repo, pr, stage: `${word} (${detail(pr)})`, since: `${word}@${ctx.draft}`, at: ctx.at, actor: "webhook",
      }));
    } catch (e) {
      if (!/^queue stage /.test(String(e && e.message))) throw e;
    }
  }
  return out;
}

async function stored(db, ctx) {
  return db.prepare(
    `SELECT members_json, bisect_parent, finished_at FROM merge_queue_batches WHERE repo = ?1 AND draft_pr = ?2`
  ).bind(ctx.repo, ctx.draft).first();
}

// True when a stored check of the draft is not completed or has failed.
async function checksOpenOrFailed(db, ctx) {
  const ph = FAILED_CONCLUSIONS.map((_, i) => `?${i + 3}`).join(",");
  // sql-ident-ok: ph is ?N placeholder text
  const r = await db.prepare(
    `SELECT 1 AS x FROM merge_queue_checks WHERE repo = ?1 AND draft_pr = ?2
       AND (status IS NOT 'completed' OR conclusion IN (${ph})) LIMIT 1`
  ).bind(ctx.repo, ctx.draft, ...FAILED_CONCLUSIONS).first();
  return !!r;
}

const open = (row) => row.finished_at === null || row.finished_at === undefined;

async function bisectStmt(db, ctx, members) {
  const ph = FAILED_CONCLUSIONS.map((_, i) => `?${i + 3}`).join(",");
  // sql-ident-ok: ph is ?N placeholder text; CANDIDATES is a code constant
  const res = await db.prepare(
    `SELECT draft_pr, members_json, bisect_step, bisect_steps FROM merge_queue_batches b
      WHERE lower(b.repo) = lower(?1) AND b.draft_pr <> ?2
        AND (b.outcome = 'failed' OR (b.finished_at IS NULL AND EXISTS (
          SELECT 1 FROM merge_queue_checks c WHERE c.repo = b.repo AND c.draft_pr = b.draft_pr AND c.conclusion IN (${ph}))))
      ORDER BY b.started_at DESC, b.draft_pr DESC LIMIT ${CANDIDATES}`
  ).bind(ctx.repo, ctx.draft, ...FAILED_CONCLUSIONS).all();
  const parent = (res.results || []).find((r) => {
    const p = new Set(storedMembers(r.members_json));
    return members.length < p.size && members.every((n) => p.has(n));
  });
  if (!parent) return [];
  const size = storedMembers(parent.members_json).length;
  const step = (parent.bisect_step ?? 0) + 1;
  const steps = parent.bisect_steps ?? Math.ceil(Math.log2(size));
  return [db.prepare(
    `UPDATE merge_queue_batches SET bisect_parent = ?3, bisect_step = ?4, bisect_steps = ?5, updated_at = ?6
      WHERE repo = ?1 AND draft_pr = ?2 AND bisect_parent IS NULL`
  ).bind(ctx.repo, ctx.draft, parent.draft_pr, step, steps, ctx.at)];
}

export async function stageStatements(db, event, payload, ctx) {
  const c = obj(ctx);
  if (!c.repo || !Number.isInteger(c.draft)) return [];
  const p = obj(payload);
  const action = String(p.action || "");
  const tag = () => `#${c.draft}`;

  if (event === "pull_request") {
    const pr = obj(p.pull_request);
    const members = membersOf(pr.body, c.draft);
    if (action === "opened" || action === "reopened") {
      const out = rows(db, c, members, "batched", tag);
      if (members.length) out.push(...(await bisectStmt(db, c, members)));
      return out;
    }
    if (action === "closed" && pr.merged === true) return rows(db, c, members, "merged", tag);
    return [];
  }

  if (event === "check_run") {
    const row = await stored(db, c);
    if (!row) return [];
    const members = storedMembers(row.members_json);
    const out = open(row) ? rows(db, c, members, "checking", tag) : [];
    const run = obj(p.check_run);
    if (action === "completed" && FAILED_CONCLUSIONS.includes(run.conclusion)
      && members.length === 1 && row.bisect_parent !== null && row.bisect_parent !== undefined) {
      const name = cleanName(run.name);
      out.push(...rows(db, c, members, "dequeued", (n) => `${name} failed on #${n} alone`));
    }
    return out;
  }

  if (event === "check_suite") {
    if (action !== "completed" || obj(p.check_suite).conclusion !== "success") return [];
    const row = await stored(db, c);
    if (!row || !open(row) || (await checksOpenOrFailed(db, c))) return [];
    return rows(db, c, storedMembers(row.members_json), "merging", tag);
  }
  return [];
}
