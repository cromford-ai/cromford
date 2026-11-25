// The per-kind ledger audit (BH-6780 decision 9): which ledger kinds the
// ledgers.archive retention rule (routes/retention.d/bh-6865-ledgers-archive.js)
// may move from hot `ledgers` to the archive store. A code safety floor, not a
// setting: an operator lists kinds in retention.ledgers.archive_kinds, and a
// listed kind moves only when this map calls it movable.
//
// THE METHOD. For each kind, every reader and writer was listed from the code:
// job_ledger_get, job_ledger_row, job_ledger_claim, job_ledger_put,
// job_ledger_list, ledger_page, merge_ledger_has, direct GET /api/ledger?kind=,
// POST /api/ledger/claim, and worker SQL on `ledgers` outside routes/ledger.js.
//   key         every reader is a GET /api/ledger?kind&key point read. The
//               archive fallback (lib/ledger-archive.js) answers a moved key. A
//               worker read of the last few days is allowed (shorter than the
//               LEDGER_ARCHIVE_FLOOR_DAYS floor).
//   list-only   every reader is a list read with a window shorter than the floor.
//   write-only  no reader.
//   never       any reader the fallback does not cover: worker SQL on hot
//               `ledgers` with no short window, a list read with an unverified
//               window, a POST /api/ledger/claim kind (the claim guard refuses a
//               re-claim of an archived key), or an exactly-once record.
// A kind not in the map is "unaudited" and does not move. A kind changes to a
// movable class only in a PR that repeats this audit for it.
//
// THE TABLE. These 50 rows (15 key, 35 never) are the r2 rebuild of the audit;
// they replaced the lost 98-row table of the BH-6780 plan (BH-6865 comment
// 6565721483). The 15 key kinds were re-grepped on main 4ded20624, on
// 69ce222bb, on 41dd49ab2 (2026-11-02), on 0bebd1d8d, on 22d8c0ad9
// (2026-11-03) and again on 45ae12e2 (2026-11-24): no list read, no worker SQL
// outside a short window, no claim.

// The absolute floor and code fallback of the settings row
// retention.ledgers.archive_min_days (schema.d/202611240347-bh-6865-*.sql); a
// row below it is ignored.
export const LEDGER_ARCHIVE_FLOOR_DAYS = 91;
const MIN_DAYS_KEY = "retention.ledgers.archive_min_days";
const MIN_DAYS_MAX = 3650;  // the same cap intSetting gives every rule window

// The lowest retention.ledgers.archive_days the ledgers.archive rule accepts:
// the row when it is in LEDGER_ARCHIVE_FLOOR_DAYS..3650, else the floor. So a
// row can raise the floor and can never lower it.
export function ledgerArchiveMinDays(byKey) {
  const row = byKey && byKey.get(MIN_DAYS_KEY);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return LEDGER_ARCHIVE_FLOOR_DAYS;
  const n = Number(v);
  return n >= LEDGER_ARCHIVE_FLOOR_DAYS && n <= MIN_DAYS_MAX ? n : LEDGER_ARCHIVE_FLOOR_DAYS;
}

export const LEDGER_KIND_CLASS = Object.freeze({
  review_block_fp: "key",        // bin/lib/needs-human/trip.sh row read + put; digest reads one day
  block_ci_clear: "key",         // bin/lib/block-gate.sh, bin/lib/mc/block-ci.sh key reads + put
  "canary-inference": "key",     // bin/lib/cred-probe.sh key read + puts
  hold_ambiguous: "key",         // bin/lib/hold.sh key read + put
  hold_comment: "key",           // bin/lib/mc-hold-comment.sh key read + put
  lead_empty_block: "key",       // bin/lead-review-land.sh key read + puts
  "mbc-issue-commented": "key",  // bin/merged-build-closeout.sh key read + put
  "pool-result": "key",          // bin/lib/pool-result-row.sh key read + put
  post_merge_verify: "key",      // bin/lib/post-merge-verify.sh key read + put
  pr_superseded: "key",          // bin/lib/pr-owner/superseded.sh key read + puts
  "rr-consumed": "key",          // bin/lib/rr-relay.sh key reads (job_ledger_row); bin/lib/rr-cursor.sh put
  "rr-handled": "key",           // bin/lib/rr-cursor.sh key read + put
  stuck_work_seen: "key",        // bin/lib/stuck-work/seen.sh key read + put
  "trigger-actor": "key",        // bin/lib/trigger-actor.sh key reads + puts
  "untrusted-input": "key",      // bin/lib/untrusted-input.sh key reads + puts
  migration: "never",            // exactly-once apply record
  pr_state: "never",             // list reads (scheduler, routes/dora.js)
  issue_state: "never",
  issue_state_wm: "never",
  build_note: "never",           // claim kind
  repro_gate_claim: "never",     // claim kind
  merge: "never",                // exactly-once merge record; worker SQL aggregates (routes/review-counts.js)
  pr_merged: "never",            // merge record twin (merge_ledger_has)
  deploy: "never",               // list reads; routes/dora.js
  deploy_rollback: "never",      // worker SQL (daily digest)
  deploy_train_rollback: "never",
  abandoned: "never",            // list read; worker SQL (daily digest)
  ticket_hold: "never",          // worker SQL reads every held row
  self_heal: "never",            // worker SQL (daily digest)
  pr_health: "never",            // worker SQL reads every row
  stuck_work_snapshot: "never",  // worker SQL (daily digest)
  spend_p99: "never",            // worker SQL reads every row
  main_red_attrib: "never",      // worker SQL (routes/review-tiers.js)
  batch_member: "never",         // worker SQL (daily digest)
  br_record: "never",            // worker SQL (daily digest)
  br_attempt: "never",           // worker key-range read on env.DB (routes/br-attempts.js, routes/ticket-status.js)
  "build-tripwire": "never",     // worker SQL (daily digest)
  child_plan_tripwire: "never",  // worker SQL (daily digest)
  "ironlaw-accept": "never",     // worker key read on env.DB, no fallback
  "ironlaw-head-accept": "never",// claim kind
  daily_digest: "never",         // claim kind
  lesson_measure: "never",       // claim kind
  lesson_proposal: "never",      // claim kind; list reads
  lookback_cluster: "never",     // list read
  autoenqueue: "never",          // list read
  "stack-wait": "never",         // list read
  "outcome-check": "never",      // list read, window not verified
  box_offer: "never",            // claim flow
  box_launch: "never",           // claim
  reopen_rate: "never",          // a live gauge
});

const MOVABLE = new Set(["key", "list-only", "write-only"]);

// The class of a kind, or "unaudited". An own-property read, so an inherited
// name ("constructor", "__proto__") is unaudited.
export function ledgerKindClass(kind) {
  return Object.hasOwn(LEDGER_KIND_CLASS, kind) ? LEDGER_KIND_CLASS[kind] : "unaudited";
}

export function ledgerKindMovable(kind) {
  return MOVABLE.has(ledgerKindClass(kind));
}
